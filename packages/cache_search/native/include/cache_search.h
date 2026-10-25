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

/* {"version":"0.1.0","index_format":2} */
char *cs_version(void);

/* --- handle and sources --- */

/* config_json: {
 *   "sources": [
 *     {"kind":"zim",     "path":"/.../wikimed.zim",  "index_dir":"/.../wikimed.idx"},
 *     {"kind":"library", "path":"<shard dir>",       "index_dir":"<tantivy dir>",
 *      "settings":{"format":1,"library_id":"...","title":"...","fields":{"text":"content",...},
 *                  "leave_out":[...],"embedding":{"vector":"","model":"...","sha256":"...","dims":1024},
 *                  "keyword_index":"auto"}}
 *   ],
 *   "snippet_chars": 400,          optional, default 400
 *   "candidates_per_list": 50,     optional, default 50
 *   "min_term_coverage": 0.5       optional, default 0.5: keyword hits matching fewer than this fraction of the
 *                                  query terms are dropped unless that leaves fewer than k+offset results
 * }
 * A library is a Qdrant collection's shard opened read-only with Qdrant Edge; opening never modifies its files.
 * "settings" is the library settings file's JSON (see DESIGN.md; the app reads cache-library.json and passes it
 * here, the core never looks for the file); it is optional, and without it the core guesses from payload field
 * names and vector size.
 * cs_open returns at once. A ZIM is opened before it returns; each library is opened on a background thread
 * inside the core and is listed by cs_status with "opening":true until it is ready. Search skips a library
 * that is still opening, as it skips a source that is being built; cs_read for it fails with code "busy". A
 * library that fails to open is recorded on its source in cs_status like any other source error ("opening"
 * false, "id":null, "error" set), not as a failure of cs_open. A malformed settings object is a failure of
 * cs_open ("bad_json"). Closing the handle while a library is still opening is safe.
 * Each source gets a stable id: the ZIM's UUID, or the library's library_id. A source with a missing, stale or
 * building index is reported by cs_status() and skipped by search; it is not an error for cs_open. */
cs_handle *cs_open(const char *config_json);

/* Replace the source list (a ZIM or library was added or removed). Same JSON as cs_open, and like cs_open it
 * returns at once: a newly added library opens on a background thread ("opening":true in cs_status until
 * ready); libraries already open (or opening) at the same path are kept. 0 on success. */
int32_t cs_set_sources(cs_handle *h, const char *config_json);

/* {"sources":[{"id","kind","path","title","language","indexed":bool,"building":bool,"stale":bool,
 *              "opening":bool,"updating":bool,"docs":N,"embedding_model":"..."|null,
 *              "library_id":"..."|null,"keyword_source":"own"|"device"|"none"|null,
 *              "settings":{...}|null (libraries: the settings in use, with "guessed":bool),
 *              "error":null|{"code","message"}}]}
 * "opening" is true for a library whose background open (see cs_open) has not finished: until then it has no
 * docs, no embedding_model unless settings were given, "indexed" false, and "keyword_source" null; search
 * skips it. "opening" is false for everything else, and always for ZIMs. "keyword_source" is null for ZIMs and
 * for a library that is still opening. A library that finished opening is reported as before.
 * "updating" is true for a library an update_library job owns (see cs_job_start): its shard is closed, search skips
 * it, cs_read for it fails with code "busy", and when the job has ended the core opens it again on a background
 * thread ("opening":true until ready). "updating" is false for everything else.
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
 * The vector is used only for libraries whose settings embedding.model matches this model id; other sources
 * are keyword-only.
 * Returns {"results":[{"address","title","snippet","source_id","source_kind","source_title","page"}],
 *          "total_estimate":N, "vector_sources":["<id>",...], "keyword_only_sources":["<id>",...]} */
char *cs_search(cs_handle *h, const char *query, const char *options_json);

/* Text for an address ("zim:<uuid>/<path>" or "lib:<library-id>/<point-id>", the point id as Qdrant gives it:
 * an integer or a UUID string), cut to max_chars at a paragraph end. An address not in the current file (e.g.
 * a library replaced by a newer snapshot) returns NULL with code "not_found".
 * ZIM:     {"address","title","text","truncated":bool}
 * Library: {"address","title","text","truncated":bool,"author","page","source_type"}
 *          (fields are null when the library's settings do not map them) */
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
 * kind "index_library": {"library_path","index_dir","heap_mb":200}
 *   builds the device Tantivy index from the library's mapped text field.
 * kind "update_library": {"library_path","snapshot_path","snapshot_manifest_path"}
 *   closes the library, applies a partial snapshot to its shard directory, rewrites segments_manifest.json and
 *   reopens it read-only (see DESIGN.md, Libraries / Updates). snapshot_manifest_path is the library's snapshot
 *   manifest JSON that was sent to the server when the partial snapshot was requested; it must list exactly the
 *   segments in library_path/segments. The job finds the library through its (canonical) path, not through a
 *   handle: every handle that has it open sees it as "updating" and opens it again afterwards. The library is
 *   marked updating before cs_job_start returns. cs_job_start fails with "busy" if another update or an
 *   index_library job is using that library, "not_found" if a path does not exist and "bad_json" for a manifest
 *   that is not valid or does not match the library. Progress is in steps (done/total, total 5): closed,
 *   snapshot unpacked and checked, applied, segments_manifest.json rewritten, library reopened (checked).
 *   cs_job_cancel is honoured only before the apply step starts (the library is then reopened unchanged);
 *   after that the job runs to the end. A failed job leaves the library reopened from whatever is on disk (a
 *   failed apply can leave it half-merged: replace it from a full snapshot) or, if that does not open, listed in
 *   cs_status with its error. Freeing a running update_library job waits for it to finish.
 *   The last step opens the library read-only once; that shard is handed to every handle that had the library
 *   open (no second open).
 * kind "library_manifest": {"library_path","out_path"}
 *   writes the library's snapshot manifest (JSON, the body of the server's partial snapshot request) to
 *   out_path, which must not be inside the library folder. Like update_library it closes the library in every
 *   handle (marked updating, search skips it, cs_read says busy), does the read-write load that computing the
 *   manifest needs, rewrites segments_manifest.json, reopens the library read-only once and hands that shard to
 *   the handles. Progress is in steps (done/total, total 5): closed, loaded and manifest computed, manifest
 *   written, segments_manifest.json rewritten, library reopened (checked). cs_job_cancel is honoured only
 *   before the read-write load. cs_job_start fails with "busy" if an update, another library_manifest or an
 *   index_library job is using that library, "not_found" if library_path or the folder of out_path does not
 *   exist and "bad_json" for empty paths or an out_path inside the library.
 * Resumes from the last checkpoint if index_dir holds an unfinished build. The index format version and the
 * tokenizer (from the ZIM or library language; English stemmer by default) are recorded in index_dir. */
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
