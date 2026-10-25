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

// Load a GGUF model and create a context. n_ctx <= 0 means 8192; n_threads <= 0 means 4.
// Returns a handle, or NULL with the reason in err.
CL_API void * cl_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len);

// Writes JSON {"description","n_ctx","chat_format","supports_tools"}. Returns the length, or -1 if out is too small.
CL_API int cl_info(void * h, char * out_json, int len);

// Start a generation. request_json is OpenAI style: {"messages":[...],"tools":[...]} (tools optional) plus an optional top-level "enable_thinking": true|false (default true).
// Builds the prompt with the model's chat template and decodes it. Returns 0 or -1 (reason in err).
CL_API int cl_start(void * h, const char * request_json, char * err, int err_len);

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
// Returns the length, or -1 if out is too small.
CL_API int cl_finish(void * h, char * out_json, int len);

// Token counts of the current/last generation (prompt tokens, generated tokens).
CL_API int cl_prompt_tokens(void * h);
CL_API int cl_generated_tokens(void * h);

// Ask the running generation to end; the next cl_next returns -1. Thread-safe.
CL_API void cl_stop(void * h);

CL_API void cl_free(void * h);

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
