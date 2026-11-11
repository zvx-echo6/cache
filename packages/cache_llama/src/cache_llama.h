// Cache native LLM layer: a small C ABI over llama.cpp and its chat engine
// (chat templates, tool-call grammar and output parsing).
//
// Typical turn: cl_start -> loop cl_next until -1 -> cl_finish.
// One handle runs one generation at a time. cl_stop may be called from any thread.
#ifndef CACHE_LLAMA_H
#define CACHE_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define CL_API __declspec(dllexport)
#else
#define CL_API __attribute__((visibility("default"))) __attribute__((used))
#endif

// Process-wide options for the next cl_load, as JSON (keys left out keep their value):
//   "prefix_dir":     a folder for the saved prompt prefix (the KV state of the stable start of the system prompt and tool schemas,
//                     for the model file, engine build and n_ctx; at most 2 files are kept). "" turns the saving off (the default).
//   "repack_weights": Android only, for measurement: true repacks the CPU weights (an anonymous copy that can be swapped).
//                     false (the default) keeps them file-backed through mmap, as every Android load does unless this is set.
//                     It is never set automatically. Other platforms ignore it.
//   "preread_mbps":   after a successful cl_load, a background thread reads the model file (all tensors except per_layer_token_embd*)
//                     into the page cache at this many MB/s (steps already in the page cache are skipped), so the first prompt does not fault it in all at once. 0, the default, is off. The thread is stopped when the handle is freed.
// Returns 0, or -1 when the JSON does not parse.
CL_API int cl_configure(const char * options_json);

// Load a GGUF model and create a context. n_ctx <= 0 means 8192. n_threads <= 0 means automatic: on
// Android, the fast CPU cores (the slowest cluster is left out, at most 5 threads) and the threads are
// pinned to them; elsewhere, or if the cores cannot be read, 4 threads.
// Returns a handle, or NULL with the reason in err.
CL_API void * cl_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len);

// Writes JSON {"description","n_ctx","chat_format","supports_tools","engine_build","weights","weights_reason"}. weights:
// "mmap" (file-backed, no repack: the Android default, reason "default on Android"), "repacked" (CPU repacked copy: Android
// only with the repack_weights opt-in) or "default" (the platform's own choice, not Android).
// Returns the length, or -1 if out is too small.
CL_API int cl_info(void * h, char * out_json, int len);

// Start a generation. request_json is OpenAI style: {"messages":[...],"tools":[...]} (tools optional) plus an optional top-level "enable_thinking": true|false (default true)
// and an optional "temperature" (0 = greedy), and an optional "tool_choice": "auto" (default) | "none" | "required". With
// "none" the tools are still rendered (the prompt start stays the same), but there is no tool-call grammar and the generation
// ends at a tool-call opening token.
// Builds the prompt with the model's chat template and decodes it. The start of the prompt that is
// the same as the previous prompt plus its answer is not decoded again (KV cache reuse). With a prefix_dir (cl_configure),
// the stable start of the system prompt and tools (the part that stays the same from one request to the next) is restored
// from disk when the cache does not hold it, and saved once.
// Returns 0, -1 (reason in err) or -3 when the prompt does not fit the context (err holds the engine text for the log; the
// caller must not show it: the chat is full).
CL_API int cl_start(void * h, const char * request_json, char * err, int err_len);

// cl_start for a caller that queues the call (the app's worker isolate): [epoch] is cl_stop_epoch as of when the question was
// queued. If a cl_stop came after that and before the call began, the question ends at once as a stop before the first token does
// (returns 0, no decode, cl_next returns -1, cl_finish gives an empty answer). A stop before it was queued does not affect it.
CL_API int cl_start_e(void * h, const char * request_json, unsigned long long epoch, char * err, int err_len);

// Reads the prompt start ahead, before any question: [request_json] is a request as cl_start takes it but with no user message
// (the system message, the tools, enable_thinking). It is rendered by the same code as cl_start's, the stable prompt start is
// found the same way (the tokens the template renders for it with two different one-word questions share), and that start is
// decoded into the KV cache and saved as a prefix file exactly as cl_start does when it passes the prefix. Unlike cl_start it
// counts the whole start as stable (this shape is about to be used). It never loads a model and the caller serializes it with
// cl_start (one handle, one call at a time); cl_stop may end it from any thread (llama.cpp's abort hook and the check between
// batches apply, as when cl_start reads a prompt): batches decoded whole stay in the cache, a batch aborted midway clears it, and
// no prefix file is written unless the whole start was decoded.
// [epoch]: cl_stop_epoch as of when the call was queued.
// [check_only] non-zero: renders and tokenizes but decodes nothing and changes no cache. [n_tokens] (may be null): the tokens
// still to read (check_only), read (done) or read before the stop.
// Returns 0 when the stable start is covered already (the KV cache holds it, or a saved prefix file does: nothing to do),
// 1 when it needs reading (check_only) or was read, 2 when stopped before it was whole, 3 when there is nothing to read (no
// prefix folder, no tools, no system message, or a start too short or too long), -1 on error (reason in err).
CL_API int cl_warm(void * h, const char * request_json, int check_only, unsigned long long epoch, int * n_tokens, char * err, int err_len);

// The stop epoch: it grows by one with every cl_stop. The caller reads it (from any thread, as it calls cl_stop) when it queues a
// cl_warm and passes it as [epoch]; a cl_warm that finds a newer one was stopped while it waited and returns 2 at once, reading
// nothing and leaving the stop flag alone. Thread-safe.
CL_API unsigned long long cl_stop_epoch(void * h);

// Prompt tokens decoded since the load by cl_start and cl_warm together (tokens taken from the cache or a file are not counted).
// For tests: a start read ahead and then reused is decoded once.
CL_API int cl_prompt_decoded(void * h);

// Generate the next token. Writes its UTF-8 text to buf and returns the byte count (may be 0 while an
// incomplete multi-byte character is held back). Returns -1 when finished, -2 on error.
CL_API int cl_next(void * h, char * buf, int buf_len);

// Partial parse of what has been generated so far (call between cl_next calls). Same JSON shape as
// cl_finish, but content holds only the visible answer text: thinking and tool-call syntax are
// split out into reasoning_content / tool_calls. Returns the length, or -1 if out is too small.
CL_API int cl_partial(void * h, char * out_json, int len);

// Parse everything generated so far into an OpenAI style assistant message:
// {"role","content","tool_calls":[{"id","type":"function","function":{"name","arguments"}}]}.
// If the output does not parse, content is the raw text and "parse_error" is set.
// "stop":"context" is added when the generation ended because the context filled up (the answer is cut off).
// Returns the length, or -1 if out is too small.
CL_API int cl_finish(void * h, char * out_json, int len);

// Token counts of the current/last generation (prompt tokens, generated tokens).
CL_API int cl_prompt_tokens(void * h);
CL_API int cl_generated_tokens(void * h);
// How many of the prompt tokens of the last cl_start were taken from the KV cache instead of decoded.
CL_API int cl_reused_tokens(void * h);
// The first token of the last cl_start's prompt, or -1.
CL_API int cl_first_prompt_token(void * h);
// What the last cl_start did with the saved prompt prefix, one line for the app log ("Prompt prefix restored (N tokens, T ms)",
// "... saved ...", or why a file was dropped), or "" when nothing. Returns the length, or -1 if out is too small.
CL_API int cl_prefix_note(void * h, char * out, int len);
// The BOS token id when the model's vocab wants BOS added to every prompt (add_bos_token), else -1.
CL_API int cl_bos_token(void * h);

// Ask the running generation to end; the next cl_next returns -1. Thread-safe.
CL_API void cl_stop(void * h);

CL_API void cl_free(void * h);

// Frees every chat handle of the process not freed yet, and returns how many. The app calls it before it loads a model:
// a handle left by an earlier Flutter engine of the same process (Android made a new window) is never freed by it.
// Not while another handle of the process is generating. cl_free of a handle freed here does nothing.
CL_API int cl_free_all(void);

// ---- Embeddings (separate handle type: an app may hold a chat handle and an embedding handle at once) ----
// Not thread-safe per handle: one cl_embed at a time on a given embedding handle.
// Prefixes some models expect (e.g. "query: " / "passage: ", or an instruction line) are the caller's job:
// cl_embed embeds exactly the text it is given.

// Load a GGUF embedding model. Pooling comes from the model's metadata; if it has none, mean pooling.
// n_ctx <= 0 means 512 (also capped at the model's trained context); n_threads <= 0 means 4.
// Returns a handle, or NULL with the reason in err.
CL_API void * cl_embed_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len);

// Writes JSON {"description","n_embd","pooling","n_ctx"}. Returns the length, or -1 if out is too small.
CL_API int cl_embed_info(void * h, char * out_json, int len);

// Embed text (special tokens added as the model expects; markup in text is not parsed as special tokens).
// Text longer than n_ctx tokens is truncated to n_ctx tokens. Writes n_embd floats to out
// (L2-normalised if normalize != 0) and returns n_embd, or a negative error:
// -1 bad handle/exception, -2 out_len < n_embd, -3 nothing to embed, -4 decode failed, -5 no embedding produced.
CL_API int cl_embed(void * h, const char * text, float * out, int out_len, int normalize);

CL_API void cl_embed_free(void * h);

#ifdef __cplusplus
}
#endif
#endif
