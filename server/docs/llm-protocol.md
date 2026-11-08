# The chat model protocol, `/api/llm/*` (version 1)

The browser build of Cache runs the whole Ask loop itself (prompt, tools, citations). Only the model runs on the server, through
`libcache_llama.so` (the library the embedder already uses). The browser's `LlamaSession` talks to these routes.

**The rule: this protocol mirrors the app's native session, `packages/cache_llama/lib/llama_session_io.dart`.** A `load` is that
file's `load`, a `generate` is that file's `generate`, and the events carry exactly what a `PartialMessage`
(`packages/cache_llama/lib/partial_message.dart`) is made from. Where the two ever differ, the Dart file is right and this server
is wrong. Code: `server/src/llm.rs` (service, queue, events), the chat calls are `packages/cache_search/native/cache_embed/src/chat.rs`.

## Common rules

- Every route needs a signed-in session (the same cookie as the other `/api/` routes); without one: 401.
- Every `POST` body is a JSON object with `"v": 1`. A missing or other `v` is **400** `unsupported_version`. `GET /api/llm/models`
  has no body; it takes an optional `?v=1` and refuses another value.
- Errors before a stream starts are the server's usual `{"ok":false,"error":{"code","message"}}`. Success replies of `models`,
  `load` and `stop` are `{"ok":true,"result":...}`. `generate` answers with a stream (below), not that envelope.
- One model is loaded for the whole server (not per browser). One generation (or load) runs at a time; the others wait in
  arrival order. Nothing here blocks the other HTTP routes: the native calls run on worker threads.

## `GET /api/llm/models`

The chat models on the server: every `.gguf` file in `<data>/models/` except the embedding model the server uses
(`bge-m3-Q8_0.gguf`). The server cannot tell chat models from other GGUF files without opening them, so every other `.gguf` is
listed. `.part` files and other file types are not.

    {"ok":true,"result":{"v":1,"models":[
      {"id":"Qwen3-4B-Q4_K_M.gguf","size":2497281120,"loaded":false},
      {"id":"other.gguf","size":123,"loaded":true,"n_ctx":8192,"info":{"description","n_ctx","chat_format","supports_tools"}}]}}

`id` is the file name and the only handle a client ever has. `info` and `n_ctx` appear for the loaded model only.

## `POST /api/llm/load`

    {"v":1,"model":"<id>","n_ctx":8192}

`n_ctx` is optional (default 8192, as `LlamaSession.load`; 256 to 262144). The reply is the model's `ModelInfo`, the JSON of
`cl_info`, in the shape of Dart's `ModelInfo.fromJson`:

    {"ok":true,"result":{"description":"...","n_ctx":8192,"chat_format":"...","supports_tools":true}}

- Loads by id only. The id must be a bare file name ending `.gguf`: no `/`, `\`, `..`, NUL or leading `.` (400 `bad_model`), and it
  must be in the list above (404 `model_not_found`; the embedder is not). A path from a client is never used.
- The same model at the same `n_ctx` again is a no-op and returns the same info. Another model (or another `n_ctx`) frees the
  loaded one first, then loads, exactly as the app does (so a failed load leaves nothing loaded).
- The call waits for a running generation to end, then loads (loads share the generation queue, so when 8 are already waiting it
answers 429 `busy`). The server stays responsive during the load. It can take a while; the reply comes when the model is ready.
- Failure to load (library missing, CPU without AVX2, native error): 503 `load_failed` with the native reason.
- Native call: `cl_load(path, n_ctx, 0 /* threads: automatic */, err, 512)`, then `cl_info(h, buf, 4 MiB)` (`{}` if it fails).

## `POST /api/llm/generate`

    {"v":1,"model":"<id>","request":{ ...the map LlamaSession.generate receives... }}

`model` is optional and sits beside `v` and `request`, not inside `request` (which goes to the model untouched). When given, it must
be the id that is loaded at the moment this generation's turn starts; otherwise the stream is a single `error` event with code
`model_changed` and nothing is generated. A client that loaded a model should send its id, so that another browser loading a
different model in between cannot make the answer come from the wrong one.

`request` is passed to the model whole, as `jsonEncode(request)` is on the phone: `messages`, optional `tools`, optional
`enable_thinking` (default true), optional `temperature` (0 = greedy), and `max_tokens`. The body may be up to 16 MiB.

Before the stream starts: 400 (`bad_json`, `unsupported_version`), 409 `no_model` (nothing loaded). Otherwise 200, `Content-Type: application/x-ndjson`, one JSON object per line (`\n`), each with a
`type`:

| `type` | when | fields |
|---|---|---|
| `queued` | the generation has to wait for another; again whenever its place changes | `position`: how many are ahead (the running one counts), so 1 is next |
| `started` | the generation has its turn and the native call `cl_start` has returned (the prompt is ready); sent once, before the first `partial` | `id`: a random 128-bit id (32 hex digits), new for every generation; `POST /api/llm/stop` takes it |
| `partial` | after each token that produced text | the `cl_partial` message: `role`, `content` (visible answer only), `reasoning_content`, `tool_calls` (`[{id,type:"function",function:{name,arguments}}]`), maybe `parse_error`; feed it to `PartialMessage.fromJson(json)` |
| `done` | the end | the `cl_finish` message (same fields) plus `prompt_tokens` and `generated_tokens`; feed it to `PartialMessage.fromJson(json, isFinal: true, promptTokens: ..., generatedTokens: ...)` |
| `error` | something failed | `code`, `message` |

`error` codes: `busy` (8 generations are already waiting; the limit is checked under the queue lock, so it is exact),
`model_changed` (see `model` above), `no_model` (no model was loaded when its turn came), `start_failed` (`cl_start` refused; `message` is the native reason),
`generation_failed` (`cl_next` returned -2; `message` is "The model stopped with an error while answering"), `internal` (the engine
crashed). After `done` or `error` the stream ends. A stream that ends without either was cut off and is an error to the client.
A generation that is stopped, or reaches `max_tokens`, still ends with `done`.

How the native layer is driven (the worker in `llama_session_io.dart`, call for call):

1. `cl_start(h, jsonEncode(request), err, 512)`; non-zero is `start_failed`.
2. Loop `n = cl_next(h, tok, 1024)` while `n >= 0`. After each call, `capped = max_tokens != null && cl_generated_tokens(h) >= max_tokens`.
   If `n > 0`, `cl_partial(h, buf, 4 MiB)` (if it is not negative) is sent as a `partial`. If `capped`, break.
   `max_tokens` counts only when it is a whole number above 0 (the native layer ignores the key).
3. `n == -2` is `generation_failed`. Otherwise `cl_finish(h, buf, 4 MiB)` (the empty assistant message
   `{"role":"assistant","content":""}` if it fails) and `done` carries it with `cl_prompt_tokens` and `cl_generated_tokens`.

**Every `partial` carries the whole message so far** (all of `content`, `reasoning_content` and `tool_calls` up to now), not a
delta. This mirrors Dart, where each `cl_partial` replaces the previous `PartialMessage`. The cost is bandwidth: an answer of N
tokens sends on the order of N^2/2 tokens of text over the stream. It is bounded by `max_tokens` (the app uses 2048), and a
client that wants less can ignore partials it has not yet had time to draw; it cannot ask for deltas in version 1.

**Client disconnect:** if writing an event fails (the browser went away or canceled the request), the server calls `cl_stop`,
lets the generation drain, and sends nothing more. A client that keeps the connection open but stops reading counts as gone too:
if one event cannot be queued for 30 seconds, the generation is stopped the same way (otherwise it would hold the one turn for
everyone). A client that is still waiting in the queue leaves it. This is what canceling
the Dart stream does (`stop()` in `onCancel`).

## `POST /api/llm/stop`

    {"v":1,"id":"<id from started>"}   ->   {"ok":true,"result":{"stopped":true}}

Calls `cl_stop` on the generation with that id; its stream still ends with `done`, carrying the answer so far, exactly as
`LlamaSession.stop()` on the phone ends with the final message. `id` is optional but must be a string when given. `stopped` is
false when that generation is not the one running (it ended, or never started): nothing is stopped then, and nobody else's
generation can be hit with an id.

- **Without `id`**, the current behavior: `cl_stop` on **whatever is running**, which with several browsers signed in may be
  someone else's. Clients should always send the id.
- **The `started` event is sent after `cl_start` returns**, and `cl_start` clears the model's stop flag. So a stop sent once the
  client has seen `started` is never lost; a stop sent earlier (the client has no id before it) would be.
- **Before `started`** (waiting in the queue, or the prompt being prepared) a client has no id. To cancel then, **close your
  `generate` request** (abort the fetch). That takes it out of the queue if it is waiting, or stops it at its first event if it is
  running, and touches nobody else's. The stream ends with no message.
- Closing the request after `started` also stops it, but the client then gets no final message. The browser's `LlamaSession.stop()` sends
  `POST /stop` with the id and goes on reading until `done`.
