/* cache_search.h — C ABI of Cache's search core. Draft, interface only.
 *
 * All structured data crosses the boundary as UTF-8 JSON strings.
 * Every char* returned by this library is owned by the caller and is freed with cs_free_string();
 * byte buffers from cs_zim_get() are freed with cs_free_bytes().
 * NULL (or a negative return) means an error; cs_last_error() then describes it.
 * A cs_handle and a cs_conv are used from one thread at a time. Jobs run on internal threads and are polled.
 * A source whose index is being built by a job is not searched by any handle until that job is done
 * (cs_status shows "indexed":false,"building":true for it).
 *
 * Error codes (the "code" field of cs_last_error and of job errors), stable across versions:
 *   "bad_json"       input JSON is malformed or missing a required field
 *   "not_found"      address, source or entry does not exist
 *   "index_missing"  a source has no index yet
 *   "index_stale"    a source's index was built by an older index format and must be rebuilt
 *   "busy"           the source's index is being built by a job
 *   "unsupported"    the file or feature is not supported (e.g. an unknown ZIM compression)
 *   "io"             a file could not be read or written
 *   "cancelled"      a job was cancelled
 *   "internal"       anything else (a bug); message has detail
 */
#ifndef CACHE_SEARCH_H
#define CACHE_SEARCH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cs_handle cs_handle;
typedef struct cs_conv cs_conv;
typedef struct cs_job cs_job;

/* {"version":"0.1.0","pack_format":1,"index_format":2} */
char *cs_version(void);

/* --- handle and sources --- */

/* config_json: {
 *   "sources": [
 *     {"kind":"zim",  "path":"/.../wikimed.zim",        "index_dir":"/.../wikimed.idx"},
 *     {"kind":"pack", "path":"/.../recon.cachepack",    "index_dir":"/.../recon.idx"}
 *   ],
 *   "snippet_chars": 400,          optional, default 400
 *   "candidates_per_list": 50,     optional, default 50
 *   "min_term_coverage": 0.5       optional, default 0.5: keyword hits matching fewer than this fraction of the
 *                                  query terms are dropped unless that leaves fewer than k+offset results
 * }
 * Each source gets a stable id: the ZIM's UUID, or the pack's pack_id. A source with a missing, stale or
 * building index is reported by cs_status() and skipped by search; it is not an error for cs_open. */
cs_handle *cs_open(const char *config_json);

/* Replace the source list (a ZIM or pack was added or removed). Same JSON as cs_open. 0 on success. */
int32_t cs_set_sources(cs_handle *h, const char *config_json);

/* {"sources":[{"id","kind","path","title","language","indexed":bool,"building":bool,"stale":bool,
 *              "docs":N,"embedding_model":"..."|null,"error":null|{"code","message"}}]}
 * A ZIM that could not be opened (file missing, SD card removed, unsupported) is listed with "id":null,
 * "indexed":false and its "error"; the other sources work normally. */
char *cs_status(cs_handle *h);

/* Last error on this handle: {"code","message"}, or NULL if none.
 * cs_last_error(NULL) returns the calling thread's last handle-less error (a failed cs_open or cs_job_start,
 * or a call made with a NULL handle), or NULL if there is none. */
char *cs_last_error(cs_handle *h);

void cs_close(cs_handle *h);

/* --- search and read --- */

/* options_json: {
 *   "k": 5, "offset": 0,                      paging for Browse "See all"
 *   "sources": ["<id>", ...] | null,          null = all sources
 *   "query_vector": {"model":"<embedding model id>","vector":[...]} | null
 * }
 * The vector is used only for packs built with that embedding model; other sources are keyword-only.
 * Returns {"results":[{"address","title","snippet","source_id","source_kind","source_title","page"}],
 *          "total_estimate":N, "vector_sources":["<id>",...], "keyword_only_sources":["<id>",...]} */
char *cs_search(cs_handle *h, const char *query, const char *options_json);

/* Text for an address ("zim:<uuid>/<path>" or "pack:<pack-id>/<concept-id>"), cut to max_chars at a
 * paragraph end.
 * ZIM:  {"address","title","text","truncated":bool}
 * Pack: {"address","title","text","truncated":bool,"book_title","author","page","published_year"} */
char *cs_read(cs_handle *h, const char *address, int32_t max_chars);

/* --- Browse: raw ZIM entries --- */

/* Raw bytes of a ZIM entry (HTML, CSS, image, ...), following redirects.
 * Path lookup order (paths copied from links in ZIM HTML work as they are): 1. a "#fragment" is stripped;
 * 2. the percent-decoded path (UTF-8) is looked up; 3. then the path as given; 4. if it contains "?", steps 2-3
 * are repeated with the "?query" removed. Each lookup tries namespace 'C', then 'A', 'I' and '-' (old ZIMs).
 * cs_read uses the same lookup. Relative links must be made absolute by the caller.
 * address: "zim:<uuid>/<path>". *mime_out is set to a string freed with cs_free_string.
 * Returns NULL on error (cs_last_error). Free the buffer with cs_free_bytes. */
uint8_t *cs_zim_get(cs_handle *h, const char *address, char **mime_out, int64_t *len_out);

/* {"address":"zim:<uuid>/<main page path>"} */
char *cs_zim_main_page(cs_handle *h, const char *zim_id);

/* Title suggestions for the address bar.
 * options_json: {"k":10,"sources":[ids]|null}. Returns {"suggestions":[{"title","address","source_id"}]} */
char *cs_suggest(cs_handle *h, const char *prefix, const char *options_json);

/* --- [n] numbering, one cs_conv per chat --- */

cs_conv *cs_conversation_new(void);

/* results_json: the "results" array from cs_search, or any list of {"address","title","snippet"} (e.g. a
 * live-source tool's results). Returns {"tool_message":"[1] Title — snippet\n...","ids":[{"n","address","title"}]}.
 * Numbers continue across calls; an address already numbered keeps its number. */
char *cs_format(cs_conv *c, const char *results_json);

/* The id map so far: {"ids":[{"n","address","title"}]}, for the citation check. */
char *cs_conversation_ids(cs_conv *c);

void cs_conversation_free(cs_conv *c);

/* --- long jobs --- */

/* kind "index_zim":  {"zim_path","index_dir","heap_mb":200}
 * kind "index_pack": {"pack_path","index_dir"}
 * Resumes from the last checkpoint if index_dir holds an unfinished build. The index format version and the
 * tokenizer (from the ZIM or pack language; English stemmer by default) are recorded in index_dir. */
cs_job *cs_job_start(const char *kind, const char *params_json);

/* {"state":"running"|"done"|"cancelled"|"failed","done":N,"total":N,"error":null|{"code","message"}} */
char *cs_job_progress(cs_job *j);

/* Ask the job to stop at its next checkpoint. Returns 0. Poll cs_job_progress until "cancelled". */
int32_t cs_job_cancel(cs_job *j);

/* Free a job that is done, cancelled or failed (cancel first if running). */
void cs_job_free(cs_job *j);

/* --- memory --- */

void cs_free_string(char *s);
void cs_free_bytes(uint8_t *p, int64_t len);

#ifdef __cplusplus
}
#endif

#endif /* CACHE_SEARCH_H */
