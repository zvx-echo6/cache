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
 *   "no_space"       not enough free disk space for an update_library or video_download job; the job error also has the
 *                    numbers "needed" and "available" (bytes)
 *   "damaged"        a library's files are incomplete; nothing was changed
 *   "not_configured" the cs_open config has no "user" section (saved places), "live" section (live data), "video"
 *                    section (videos) or "layers" section (map layers)
 *   "fetch_failed"   a live-source download failed (network, HTTP status); the last good copy is kept
 *   "quota"          a live source reached its per-minute, per-day or per-month download cap
 *   "key_missing"    a live source needs an API key and the request gave none
 *   "bad_response"   a live-source response was not what its definition expects; the last good copy is kept
 *   "auth_failed"    a video instance refused the login or the access token (wrong password, expired or revoked token,
 *                    a video that needs a login)
 *   "otp_required"   the video account has two-factor login on: repeat the login with the "otp" code
 *   "limit_exceeded" a layer download is over the layer's limit (tiles or bytes per download)
 *   "offline"        a layer or action needs a connection and the engine is offline (or the layer is online only)
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

/* {"version":"0.1.0","index_format":3} */
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
 *   "user": {"db_path": ".../user.sqlite"},          optional: where saved places are stored (cs_places_*)
 *   "video": {"dir": ".../videos"},                 optional: PeerTube instances, offline downloads (cs_video_*, job
 *                                                   kind video_download); holds instances.json and downloads/
 *   "live": {"db_path": ".../live.sqlite",           optional: the live data engine (cs_live_*); sources_dir holds
 *            "sources_dir": ".../sources",           the source definition files (*.json, see DESIGN.md)
 *            "live_radius_km": 30},                  optional, default 30: live_data uses the nearest stored place's data
 *                                                    within this distance of the place asked about
 *   "places": {"packs": [".../idaho/places.sqlite"]},  optional: registers the nearby and locate tools over these places
 *                                  packs (docs/TOOLS.md). Packs are opened on demand: nearby is left out of
 *                                  cs_tool_schemas until a pack exists; locate with a GPS fix needs no pack
 *   "routing": {"valhalla": {"tiles": ".../tiles.tar", "shim": ".../valhalla_shim.dll"},   optional: the navigate tool
 *               "offroad": {"pack": ".../offroad.sqlite", "elevation": ".../elevation.pmtiles"}},  (see DESIGN.md)
 *   "layers": {"dir": ".../layers",                  optional: the map layer engine (cs_layers_*, DESIGN-LAYERS.md);
 *              "defs_dirs": [".../layer-defs"],      read-only folders of definition files (the starter ones)
 *              "catalogue_urls": ["https://..."],    optional; JSON lists of definitions fetched by cs_layers_refresh and merged with
 *                                                    the starter ones. Default ["https://cache.echo6.co/catalogue.json"]; [] = none
 *              "cache_max_bytes": 268435456,         optional cap of the viewed-tile cache (default 256 MiB)
 *              "online": true}                       optional, default true; false = never use the network
 *   "min_term_coverage": 0.5       optional, default 0.5: keyword hits matching fewer than this fraction of the
 *                                  query terms are
 *                                  dropped unless that leaves fewer than k+offset results
 *   "min_relevance": 0.5           optional, default 0.5: keyword hits scoring below this fraction of their source's
 *                                  best hit are dropped on the same terms
 *   "prewarm": true                optional, default true (false on Android): open libzim on the ZIMs with a built-in index
 *                                  on background threads as soon as the sources are set, so the first search does not pay
 *                                  for it; only as many as fit in zim_budget_mb, smallest first
 *   "zim_budget_mb": 1024          optional, default 384 on Android and 1024 elsewhere: memory budget in MiB for the open
 *                                  libzim archives together with their searchers and caches, which also serve cs_read and cs_zim_get (the old name of this key,
 *                                  "searcher_budget_mb", is still read when "zim_budget_mb" is absent). Each ZIM costs an
 *                                  estimate of about 10 MiB plus ~11 bytes per entry plus its searchers; when opening one
 *                                  would go over the budget the least recently used archives are closed first (they reopen
 *                                  on their next query); an archive over the whole budget is opened for the query and closed
 *                                  after it; 0 does that for every query. Changes speed only, never the results. See DESIGN.md
 *   "zim_cluster_cache_mb": 4      optional, default 4 (libzim's own default is 16): limit in MiB of compressed data of
 *                                  libzim's cluster cache, shared by all archives in the process (the last cs_open or
 *                                  cs_set_sources in the process sets it). What it holds is about 8 times larger once
 *                                  decompressed, and that is taken off the top of zim_budget_mb
 *   "zim_dirent_cache": 512        optional, default 512 (libzim's own default): dirents each open archive's dirent cache holds
 * }
 * A library is a Qdrant collection's shard opened read-only with Qdrant Edge; opening never modifies its files.
 * "settings" is the library settings file's JSON (see DESIGN.md; the app reads cache-library.json and passes it
 * here, the core never looks for the file); it is optional, and without it the core guesses from payload field
 * names and vector size.
 * cs_open returns at once. A ZIM is opened before it returns; each library is opened on a background thread
 * inside the core and is listed by cs_status with "opening":true until it is ready. Search skips a library
 * that is still opening, as it skips a source that is being built; cs_read for it fails with code "busy". A
 * library that fails to open is recorded on its source in cs_status like any other source error ("opening"
 * false, "id":null, "error" set), not as a failure of cs_open; a library whose segments_manifest.json lists
 * segments that are missing is reported with code "damaged" and is neither used nor changed. A malformed settings object is a failure of
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
 * skips it. "opening" is false for everything else, and always for ZIMs. "keyword_source" is null for a library that
 * is still opening. A ZIM that carries its own Xapian index (builds with the "xapian" feature: Windows, Android) is
 * searched through it with no index_dir: it is "indexed":true, "building":false, "stale":false, "docs" its entry
 * count, and has "keyword_source":"own" (placed after "embedding_model"); other ZIMs have no "keyword_source" field. A library that finished opening is reported as before.
 * "error" codes of a library source include "damaged" (see above) as well as "not_found" and "io".
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
 * With libzim built in (the xapian feature) cs_read, cs_zim_get and cs_zim_main_page read through the same open libzim archive
 * the searches use, so they count against zim_budget_mb and keep that archive recently used; a ZIM libzim cannot open, and a
 * build without the feature, use the Rust zim crate reader. The bytes, MIME type, title and errors are identical either way.
 * address: "zim:<uuid>/<path>". *mime_out is set to a string freed with cs_free_string.
 * Returns NULL on error (cs_last_error). Free the buffer with cs_free_bytes. */
uint8_t *cs_zim_get(cs_handle *h, const char *address, char **mime_out, int64_t *len_out);

/* {"address":"zim:<uuid>/<main page path>"} */
char *cs_zim_main_page(cs_handle *h, const char *zim_id);

/* Title suggestions for the address bar.
 * options_json: {"k":10,"sources":[ids]|null}. Returns {"suggestions":[{"title","address","source_id"}]}
 * A ZIM with a title index is answered from it (builds with the "xapian" feature), the others from their Tantivy index. */
char *cs_suggest(cs_handle *h, const char *prefix, const char *options_json);

/* --- [n] numbering, one cs_conv per chat --- */

cs_conv *cs_conversation_new(void);

/* results_json: the "results" array from cs_search, or any list of {"address","title","snippet"} (e.g. a
 * live-source tool's results). Returns {"tool_message":"[1] Title — snippet\n...","ids":[{"n","address","title"}]}.
 * Numbers continue across calls; an address already numbered keeps its number. */
char *cs_format(cs_conv *c, const char *results_json);

/* The id map so far: {"ids":[{"n","address","title"}]}, for the citation check. */
char *cs_conversation_ids(cs_conv *c);

/* The conversation's whole state as JSON, so a chat can be saved and continued later (or in another process) with the
 * same numbering and the same `read` fallback. Format 1, keys in this order:
 *   {"format":1,
 *    "next_n":N,                                   the number the next new address gets (last id + 1; 1 when empty)
 *    "ids":[{"n","address","title"}, ...],         every number given, ascending
 *    "web_hits":{"<address>":{"title","snippet","fetched"}, ...}}
 *                                                  what web_search showed per web:<url> address (keys sorted), the
 *                                                  stored title/snippet `read` falls back to when the page fetch fails
 * The same state always gives the same bytes. NULL on error (cs_last_error(NULL)). */
char *cs_conversation_export(cs_conv *c);

/* A new conversation from cs_conversation_export's output; continuing on it gives byte-identical cs_format / cs_tool
 * results to continuing the original. NULL on error, with cs_last_error(NULL): "bad_json" for malformed JSON or an
 * export whose ids/next_n disagree, "unsupported" for a "format" other than 1. Free it with cs_conversation_free. */
cs_conv *cs_conversation_import(const char *json);

void cs_conversation_free(cs_conv *c);

/* --- tools --- */

/* The tools the model can call. search and read are built in; the host registers the others in Rust
 * (Handle::register_tool: navigate, nearby, locate, live_data, ...; web_search is registered by cs_open and switched on
 * with cs_set_web). See docs/TOOLS.md for the
 * schemas and results, and DESIGN.md, Tools, for the dispatch. */

/* The phone's GPS fix, for the tools that default to "where I am". accuracy_m < 0 means unknown. fixed_at is the
 * time of the fix, ISO 8601 with offset, e.g. "2026-10-25T14:20:05-06:00". lat must be in -90..90 and lon in
 * -180..180. Returns 0; -1 with code "bad_json" for a value out of range or a missing fixed_at.
 * cs_clear_location removes the fix (the tools then answer no_location). Returns 0. */
int32_t cs_set_location(cs_handle *h, double lat, double lon, double accuracy_m, const char *fixed_at);
int32_t cs_clear_location(cs_handle *h);

/* Web search settings. provider is "kagi", or NULL for web search off; key is the provider's API key, or NULL for none;
 * online is 0 or 1, the app's own view of whether the phone has a connection. web_search is offered in
 * cs_tool_schemas only while a provider, a key and online=1 are all set; without them cs_tool answers it with
 * not_set_up. Each call replaces all three settings. The key is kept in memory only: it is never written to disk,
 * logged, or put in any result or error. Returns 0; -1 with code "bad_json" for an unknown provider or an online
 * value other than 0 or 1 (nothing changes). Web results exist only in the conversation: nothing from the web is
 * stored or added to a library. A cs_tool result for a web search or a read of a web result also carries a
 * "timing_ms" field ({"search": ms} or {"fetch": ms}) for measurement; it is not part of what the model sees. */
int32_t cs_set_web(cs_handle *h, const char *provider, const char *key, int32_t online);

/* Live fetch policy and keys. The host decides when the core may fetch live data and holds the API keys; it pushes both in
 * (no callbacks). The handle keeps them in a built-in cache_tool::LiveFetcher that tools see as ToolCtx.live_fetcher.
 *
 * cs_live_set_fetch_policy: policy_json is {"online":bool,"allow_metered":bool,"metered":bool,"enabled_sources":[ids]}
 * ("online" and "enabled_sources" are required; "allow_metered" and "metered" default to false; no other field).
 * can_fetch(source) = online && source in enabled_sources && (!metered || allow_metered). Each call replaces the
 * policy; NULL policy_json clears it. With no policy set can_fetch is false for every source and ToolCtx.live_fetcher
 * is None, so a capture or a test never fetches. Returns 0; -1 with code "bad_json" for a malformed policy (the old one
 * stays).
 * cs_live_set_key: the API key of one source (source_id is a live source id, e.g. "alerts"); NULL key_or_null (or an empty
 * one) clears it. The key is kept in memory only: it is never written to disk, logged, or put in any result, error,
 * status or debug output; it is cleared by NULL and on cs_close. Returns 0; -1 with code "bad_json" for a NULL source_id.
 * Both only store state: a fetch itself is made by cs_live_fetch or by a tool built on the fetcher. */
int32_t cs_live_set_fetch_policy(cs_handle *h, const char *policy_json);
int32_t cs_live_set_key(cs_handle *h, const char *source_id, const char *key_or_null);

/* A JSON array of the function schemas ({"type":"function","function":{...}}) of the tools available now, in this
 * order where present: search, read, navigate, nearby, locate, live_data, web_search (any other registered tool
 * after them). A tool that is registered but has nothing installed to work with (its schema is None) is left out. */
char *cs_tool_schemas(cs_handle *h);

/* Run one tool call. name is the tool's name; args_json the call's arguments (a JSON object); now the local
 * date and time of the call, ISO 8601 with offset (required, not empty).
 * Returns {"content":"<exactly the tool message the model sees>","ids":[{"n","address","title"}]}.
 *   - content of search and read is their plain text; of every other tool the result JSON, compact.
 *   - The call's sources are numbered in c like cs_format does: a source already numbered keeps its number, and
 *     "ids" holds only the numbers this call gave, in order. The tool never numbers anything itself.
 *   - A failure of the tool is not an error of this function: content is the error JSON
 *     {"ok":false,"error":{"type","detail",...}}, with type one of bad_arguments (also an unknown tool name or
 *     arguments that break the tool's schema: the detail names the field), no_location, not_set_up (the tool is
 *     registered but its data is not installed), not_found (read of a number not in c), internal (the tool
 *     failed), expired, no_data, unknown_source, not_configured, fetch_failed, quota, key_missing, bad_response.
 *   - NULL (cs_last_error) only for a NULL or invalid handle or conv, an args_json that is not JSON, or an empty
 *     now.
 * The arguments are checked against the tool's schema before it runs: type (string, integer, number, boolean,
 * object), enum, minLength, maxLength, minimum, maximum, required and additionalProperties:false. Defaults are not
 * filled in. */
char *cs_tool(cs_handle *h, cs_conv *c, const char *name, const char *args_json, const char *now);

/* --- saved places (user.sqlite; logic in the cache_user crate) ---
 *
 * Tools and live data resolve a place name against saved places first (by key, then by name, ignoring case).
 * All three fail with "not_configured" when the cs_open config has no "user" section. */

/* {"places":[{"key","name","lat","lon","label"?}]}, oldest first. */
char *cs_places_list(cs_handle *h);

/* place_json: {"key"?:"home","name":"Home","lat":42.536,"lon":-113.792,"label"?:"home"}. Inserts, or updates the
 * place with that key. Without a key one is made from the name ("home", then "home-2", ...); a key is letters,
 * digits and _ - . : , + (it is used inside addresses). Returns the saved place, same shape as above. */
char *cs_place_save(cs_handle *h, const char *place_json);

/* Deletes the saved place and the live data downloaded for it. {"deleted":"<key>"}, or "not_found". */
char *cs_place_delete(cs_handle *h, const char *key);

/* --- live data (live.sqlite; logic in the cache_live crate) ---
 *
 * One general engine: a source is a definition file (data, never code; format in DESIGN.md, "Live sources"). The
 * core has no scheduler: the app calls cs_live_fetch when it is online. All three fail with "not_configured" when
 * the cs_open config has no "live" section. */

/* {"sources":[{"id","title","provider","description","attribution","refresh_minutes",
 *              "api_key":null|{"alias","required"},"basic_auth":null|{"user_alias","password_alias","required"},
 *              "params":[{"name","label"?,"type"?,"default"?,"required","choices","min"?,"max"?,"help"?}],
 *              "quota":{"per_minute","per_day","per_month"}}],
 *  "errors":[{"file","message"}]}   (definition files that could not be read) */
char *cs_live_sources(cs_handle *h);

/* request_json: {"source":"weather","place":<place>,"params"?:{"<name>":value},"api_key"?:"...","secrets"?:{"<alias>":"..."},
 *                "force"?:false,"now"?:"<ISO 8601 with offset>"}
 * <place> is a saved place's key or name (a string) or {"key","name","lat","lon"} (the app passes the phone's
 * position this way; for "where the phone is" use the key "at:<lat>,<lon>" rounded to 2 decimals, which is the key the
 * live_data tool looks for). An object place may also carry "state","state_name","county","county_fips","country",
 * "country_name" (from the app's geocoder) for sources whose request needs them ({state} in the definition); a source
 * that needs one the place lacks fails with "fetch_failed" saying which. "params" are the user's values for the source's
 * "params" (cs_live_sources lists them; a missing one takes its default). With parameters other than the defaults the
 * row is stored under the place key "<key>~<8 hex>" (reported in the result's "place"). "secrets" gives other
 * secrets by alias (a Basic login: both of its aliases); "api_key" is the value for the source's api_key alias. "now" defaults to the system clock. Downloads (HTTPS; User-Agent "Cache/<version>")
 * unless the stored copy is younger than the source's refresh interval and still valid (then "fetched":false and no
 * network); maps the response with the definition and stores it with the raw response. The API key is used for this
 * call only and never stored. A failed download returns NULL (codes fetch_failed, quota, key_missing, bad_response,
 * not_found, bad_json) and keeps the last good copy; cs_live_get then shows it with "last_error" (an upstream 4xx/5xx reads
 * like "HTTP 404: No such site"; a rate limit is waited for as the provider asks, inside the quotas).
 * Returns what cs_live_get returns plus "fetched":true|false. */
char *cs_live_fetch(cs_handle *h, const char *request_json);

/* request_json: {"source","place","params"?,"now"?}. The stored data for Home cards and map layers, expired or not:
 * {"source":{"id","title","provider","description","attribution"},"place":{"key","name","lat","lon"},
 *  "fetched_at","valid_until","age":"2 hours old","age_seconds","expired":bool,"not_covered_after":null|"<date>",
 *  "last_error":null|{"code","message","at"},"truncated"?:true (a paged result was cut at the definition's page cap),
 *  "missing_requests"?:n (repeated requests that failed and are missing),"params"?:{...} (the values it was fetched with),
 *  "items":[{"address":"live:<source>/<place-key>/<item-key>","label","time"?,"fields":{"<label>":"<value with unit>"},
 *            "point"?:{"lat","lon"},"area"?:<GeoJSON geometry>}]}
 * Times are ISO 8601 in the place's local offset (the zone comes from the response, else from an offline lookup of the
 * place's position; daylight saving is applied). Items that have ended are left out. This is the same data the live_data tool gives the model, from the same code. "not_found" when nothing
 * was ever downloaded for that source and place. */
char *cs_live_get(cs_handle *h, const char *request_json);

/* For writing a connector (the future in-app builder, and `cs live-check` / `cs live-preview`). No handle: nothing is
 * opened, stored or counted against a quota. request_json:
 *   {"definition": <the source definition as a JSON object, or its text>,
 *    "place"?: {"lat","lon","name"?,"state"?,"state_name"?,"county"?,"county_fips"?,"country"?,"country_name"?},
 *    "params"?: {"<name>": value}, "api_key"?: "...", "secrets"?: {"<alias>": "..."}, "now"?: "<ISO 8601 with offset>",
 *    "check_only"?: false, "raw_chars"?: 12000, "max_items"?: 20}
 * With "check_only": parses and validates only (no network, no place needed) and returns
 *   {"valid":true,"source":{"id","title","provider","format","refresh_minutes","needs_key","needs_login","params","items"},
 *    "requests":[{"step","method","url"}],"warnings":["..."]}.
 * Otherwise downloads once (every step and page; the definition's own timeout and size limit apply) and returns
 *   {"valid":true,"source":{...},"place":{...},"params":{...},"requests":[{"step","method","url"(secrets removed),"status","bytes","ms"}],
 *    "truncated":bool,"missing_requests"?:n,"raw":<the response tree, long lists and text cut so it can be read>,
 *    "paths":["features  (list of 25)","features[0].properties.name = \"...\"", ...],   (paths in the mapping's syntax)
 *    "zone","valid_until","not_covered_after"?,"item_count":n,"items":[<as cs_live_get items, without address>],
 *    "mapping_error"?:{"code","message"},"warnings":[...]}
 * A definition the mapping cannot read still returns the raw tree, with "mapping_error". An invalid definition is
 * "bad_json" with every problem in the message, each naming its field (items[0].fields[2].time.in: ...); a failed
 * download is "fetch_failed"/"bad_response"/"key_missing" as cs_live_fetch. NULL on error: cs_last_error(NULL). */
char *cs_live_preview(const char *request_json);

/* --- the map: search, route, guidance (cache_places::map, cache_navigate::map) ---
 * The Maps tab's own calls, direct (no model in the loop). They need the "places" and "routing" sections of the cs_open config
 * (not_configured otherwise). Distances are metres, durations seconds, bearings degrees clockwise from north. A request with a
 * key the call does not know is bad_json.
 *
 * cs_map_search: {"query": "...", "near"?: {"lat","lon"}, "limit"?: 10 (1-30), "meaning"?: true, "query_vector"?: {"model","vector":[...]}}
 *   One search box. The query is read as: coordinates (decimal, degrees-minutes-seconds, USNG/MGRS, Plus Codes; a short Plus
 *   Code is completed from "near"), else a place name, a category ("pharmacy", "gas"), or a meaning ("somewhere to get water").
 *   A town named in the query anchors it ("pharmacy near Burley" ranks from Burley). "near" is the map centre or the GPS fix
 *   (default: the fix from cs_set_location); every result reports its distance and direction from it. "meaning" runs the
 *   vector step when the pack has vectors (places_pack embed) and a vector of the pack's model is given as "query_vector" or
 *   the handle has a query embedder; otherwise it is skipped and "meaning" in the answer says why.
 *   Returns {"query","near","interpreted":{"kind":"coordinates"|"text"|"empty","anchor"?,"categories"?},
 *     "meaning":"used"|"off"|"no_embedder"|"no_vectors"|"model_mismatch","results":[...]}. A result is
 *     {"id","type":"place"|"town"|"category"|"coordinates","name","kind","category","address","lat","lon","distance_m",
 *      "direction","bearing_deg","matched":"name"|"category"|"meaning"|"coordinates","score", and when known "phone","hours",
 *      "website","summary","wikipedia_title","wikidata_id"}; a coordinates result also has "formats" (decimal, dms, usng,
 *      plus_code), "format" and "precision_m"; a category result has no position (its nearest places follow it). "id" is what
 *      cs_map_route takes as an end: "place:<id>", "town:<id>", "loc:<lat>,<lon>".
 *
 * cs_map_route: {"from"?, "to", "via"?: [...], "mode"?: "drive"|"walk"|"bike", "land_access"?: "strict"|"pragmatic"|"emergency",
 *   "alternatives"?: 0-3 (default 2)}
 *   An end is {"id"?, "lat"?, "lon"?, "name"?} (a result's id brings the place's own category) or a string (an id, coordinates,
 *   a saved place, a place name). No "from" is the last GPS fix. The complete route, built by the same code as the navigate
 *   tool: {"ok":true,"route_id","mode","land_access","routing":"road"|"offroad","from","via","to","distance_m","duration_s",
 *   "totals":{distance_m,duration_s,road_m,offroad_m,ascent_m,descent_m},"geometry":"<polyline6>","point_count",
 *   "segments":[{"kind":"road"|"offroad"|"follow","travel","start_index","end_index","distance_m"}],
 *   "maneuvers":[{"index","kind","type","instruction","street_names","distance_m","duration_s","lat","lon","begin_index",
 *     "end_index","bearing_deg","cardinal","travel", and for off-road legs "grade_class","elev_gain_m","elev_loss_m",
 *     "terrain","follow"}],"major_roads","warnings":[{"code":"offroad_unavailable",...}],"alternatives":[<route objects>]}.
 *   ALL maneuvers are returned. Indices point into the decoded geometry. Alternatives are Valhalla's, for a plain road route.
 *   A route that cannot be made is {"ok":false,"route_id","mode","from","to","errors":[{"code","message"}]} with code no_route,
 *   too_far, out_of_coverage, route_too_long, upstream_timeout or internal. The route (and each alternative) is kept for
 *   cs_map_progress.
 *
 * cs_map_progress: {"route_id" | "route": <a route object>, "lat","lon","accuracy_m"?,"now"?,"reset"?,"off_route_m"?: 50,
 *   "off_route_fixes"?: 3,"arrive_m"?: 25}
 *   Where a GPS fix is on a route from cs_map_route (found by route_id; after a restart send the route object as "route"
 *   and it is loaded again). Fixes are matched near the last match first, so a route that passes itself is not confused.
 *   Returns {"route_id","fix","matched":{lat,lon,distance_along_m,offset_m,segment,route_bearing_deg},"on_route","off_route",
 *   "off_route_count","arrived","progress","remaining":{distance_m,duration_s,eta?},"total","current","next","then","leg"}.
 *   "off_route" is true once the fix has been more than off_route_m from the route (or the GPS accuracy if larger; twice
 *   as much on an off-road leg) for off_route_fixes fixes in a row: the app then calls cs_map_route from the fix. "current",
 *   "next" and "then" are maneuvers: {index,kind,type,instruction,street_names,travel,lat,lon,distance_m,length_m,cardinal,bearing_deg}
 *   (and follow, elev_gain_m, elev_loss_m, grade_class for off-road ones); "next" is the coming maneuver with the distance to
 *   it, "then" the one after (its distance is from "next"), "leg" (off-road only) the bearing, distance and climb to the
 *   next point: {kind,target:{lat,lon},bearing_deg,cardinal,distance_m,climb_m,descent_m,grade_class,travel}. "now" (ISO 8601) adds "eta". Free the result with cs_free_string. */
char *cs_map_search(cs_handle *h, const char *request_json);
char *cs_map_route(cs_handle *h, const char *request_json);
char *cs_map_progress(cs_handle *h, const char *request_json);

/* --- videos (PeerTube; logic in the cache_video crate) ---
 *
 * A generic PeerTube connector over PeerTube's official REST API only (no scraping): any instance, added by address.
 * All fail with "not_configured" when the cs_open config has no "video" section. Requests are JSON objects; unknown
 * fields are "bad_json". Every network request has the User-Agent "Cache/<version>". An instance must be https (http is
 * accepted only for 127.0.0.1/localhost). Access tokens are never stored by the core: the app keeps them in its secure
 * storage and passes "token" (the access token) in each request that needs a login; cs_video_login and
 * cs_video_refresh return the tokens to the caller. An instance is named by its "id" (its host, with ":" as "_" for a
 * port) or by its address. Network trouble is "fetch_failed", an instance rate limit "quota", 401/403 "auth_failed"
 * (two-factor: "otp_required"), a missing video/instance/channel "not_found".
 * A video is named by its uuid, short uuid or numeric id. Lists take "start" (default 0) and "count" (default 20, max 100).
 *
 * Shapes used below:
 *   <channel> = {"name","display_name","handle","host","avatar":null|url}      ("handle" is what cs_video_list takes)
 *   <video>   = {"uuid","short_uuid","id","title","duration_s","published_at","views","channel":<channel>,
 *                "thumbnail":null|url,"nsfw","is_live","downloaded":bool}
 *   <manifest> = {"version":1,"instance","instance_url","id","uuid","short_uuid","title","description","channel":<channel>,
 *                "duration_s","published_at","kind":"video"|"audio","resolution":"480"|"audio","resolution_label",
 *                "source":"web"|"hls"|"hls+audio","size","sha256","checksum_verified":null|"playlist","file",
 *                "thumbnail":null|name,"captions":[{"language","label","automatic","file"}],"warnings":[...],
 *                "downloaded_at", and, added when listed: "dir","path","thumbnail_path","captions"[i]."path"} */

/* {"instances":[{"id","url","name","version","added_at"}]} */
char *cs_video_instances(cs_handle *h);

/* request_json: {"url":"stream.example.org"} (https:// optional; anything after the host is ignored). Reads
 * GET /api/v1/config to confirm it is PeerTube and to take its display name. Returns the instance record
 * {"id","url","name","version","added_at"}; adding one that is there refreshes its name and version. */
char *cs_video_instance_add(cs_handle *h, const char *request_json);

/* request_json: {"instance":"<id|address>","delete_downloads"?:false}. Its downloaded videos are kept (they play
 * without it) unless delete_downloads is true. {"removed":"<id>","downloads_deleted":bool} */
char *cs_video_instance_remove(cs_handle *h, const char *request_json);

/* Login with PeerTube's OAuth password flow (GET /api/v1/oauth-clients/local, then POST /api/v1/users/token).
 * request_json: {"instance","username","password","otp"?}. Returns {"instance","token_type","access_token",
 * "refresh_token","expires_in","refresh_token_expires_in"}; the caller stores them. The password is used for this
 * call only and is never in an error message. Wrong credentials: "auth_failed"; "otp_required" when the account
 * has two-factor login and "otp" was not given. */
char *cs_video_login(cs_handle *h, const char *request_json);

/* request_json: {"instance","refresh_token"}. Same answer as cs_video_login (the refresh token changes too). */
char *cs_video_refresh(cs_handle *h, const char *request_json);

/* request_json: {"instance","token"}. GET /api/v1/users/me: {"instance","username","display_name","role"}. */
char *cs_video_me(cs_handle *h, const char *request_json);

/* request_json: {"instance","search"?:"text","start"?,"count"?,"token"?}. Channels of the instance (newest first), or the
 * ones matching "search" (the instance's own, searchTarget=local).
 * {"instance","total","start","channels":[<channel> plus {"description","followers"}]} */
char *cs_video_channels(cs_handle *h, const char *request_json);

/* request_json: {"instance","channel"?:"<handle>","start"?,"count"?,"sort"?:"-publishedAt","token"?}. The instance's
 * latest videos, or a channel's. {"instance","total","start","videos":[<video>]} */
char *cs_video_list(cs_handle *h, const char *request_json);

/* request_json: {"instance","query","start"?,"count"?,"sort"?:"-match","token"?}. Search the instance's own videos.
 * Same answer as cs_video_list. */
char *cs_video_search(cs_handle *h, const char *request_json);

/* request_json: {"instance","video","token"?}. The video page:
 * {"instance","uuid","short_uuid","id","title","description","duration_s","published_at","views","privacy","is_live",
 *  "nsfw","tags","channel":<channel>,"thumbnail","preview","download_enabled":bool,
 *  "captions":[{"language","label","automatic","url"}],
 *  "options":[{"key","label","kind":"video"|"audio","size":null|bytes,"source":"web"|"hls"|"hls+audio"}],
 *  "stream":{"hls":null|url,"mp4":null|url,"needs_auth":bool},
 *  "downloaded":null|{"kind","resolution","size","downloaded_at"}}
 * "options" are the download choices, resolutions high to low then "audio" (audio only, only when the instance has an
 * audio-only file), with the size to show before downloading. For one resolution the file is chosen like this: a web-video
 * MP4 if there is one; else the HLS playlist's fragmented MP4 (a downloadable file) when it has sound; else, on
 * instances that keep audio in its own file, the video-only HLS file joined with the audio-only file by the instance's
 * /download/videos/generate endpoint ("hls+audio": that download cannot be resumed). "download_enabled" false means the
 * video can only be streamed: a video_download job refuses it. */
char *cs_video_get(cs_handle *h, const char *request_json);

/* Downloaded videos, newest first: {"downloads":[<manifest>],"total_bytes"} (works without any network or instance). */
char *cs_video_downloads(cs_handle *h);

/* request_json: {"instance","video"}. Deletes the downloaded video's files (and a half-finished download of it).
 * {"deleted":"<uuid>","instance","freed_bytes"}, or "not_found". */
char *cs_video_delete(cs_handle *h, const char *request_json);

/* Citations: where to open a video at a time. request_json: {"video":"<link|uuid|short uuid>","instance"?:"<id|address>",
 * "offset_s"?:12.5,"token"?}. "video" may be a PeerTube link (/w/<id>, /videos/watch/<id>, /videos/embed/<id>; a start= or t=
 * in it such as 1m30s is the offset when offset_s is absent; the link's host is the instance, even one that was never
 * added); a bare id looks in the downloads of every instance, then asks "instance" or each added instance in turn.
 * A downloaded video is answered from disk with no network:
 *   {"kind":"local","instance","uuid","title","media":"video"|"audio","path","offset_s","duration_s","resolution",
 *    "captions":[{"language","label","path"}],"thumbnail_path"}
 * otherwise the instance is asked and the answer is a stream:
 *   {"kind":"stream","instance","uuid","title","url","format":"hls"|"mp4","offset_s","duration_s","needs_auth","thumbnail"}
 * "url" is the HLS master playlist when the instance has HLS, else an MP4 file (the highest resolution up to 720 with
 * sound). For a video that needs a login a short-lived file token is added to the URL (token required, else
 * "auth_failed"). offset_s is clamped to the duration. Live streams are "unsupported". */
char *cs_video_resolve(cs_handle *h, const char *request_json);

/* --- map layers (DESIGN-LAYERS.md) ---
 *
 * A layer is a definition file (data, never code). The core keeps the catalogue, serves tiles to the map on
 * 127.0.0.1 and downloads areas for offline use. Needs "layers" in the cs_open config ("not_configured" otherwise).
 * Returned strings are freed with cs_free_string. Errors: see cs_last_error. */

/* Every layer with its installed state:
 * {"layers":[{"definition":{...format 1...},"origin":"folder"|"catalogue"|"user","download_layer":"<id>",
 *             "downloadable":bool,"needs_connection":bool,
 *             "installed":{"downloaded":bool,"bytes":N (the layer's tile store),"areas":[{"id","name","layer","bbox","polygon",
 *                          "minzoom","maxzoom","version","tiles_requested","tiles_present","bytes" (of its cover, shared
 *                          tiles included),"created","source"}] (finished areas),
 *                          "partial":[{"area","name","tiles_total","version"}]},
 *             "update_available":bool,"latest_version":null|"..","viewed_cache_bytes":N,
 *             "health":{"state":"unknown"|"ok"|"degraded"|"unreachable","recent_requests","recent_failures",
 *                       "recent_timeouts","last_success_at","last_failure":null|{"at","message"}}}],
 *  "invalid":[{"file","id"?,"error"}],"online":bool,"viewed_cache":{"bytes","max_bytes"},"catalogue_urls":[".."]}
 * hillshade and contours list the elevation layer's installed areas ("download_layer"). */
char *cs_layers_list(cs_handle *h);

/* Fetch every catalogue in "catalogue_urls" (valid definitions are stored and merged with the starter ones, a later
 * catalogue wins by id; invalid ones are reported) and each layer's update.check_url ({"version":".."}). Needs a
 * connection ("offline"); fails with "fetch_failed" only if no catalogue could be fetched. Returns
 * {"catalogues":[{"url","layers":N,"invalid":[...]}|{"url","error":{"code","message"}}],"updates":{"<id>":"<version>"|{"error"}}}. */
char *cs_layers_refresh(cs_handle *h);

/* Add or edit a user definition (the Advanced section): the JSON of one definition, validated ("bad_json" lists every
 * problem). A user definition overrides one with the same id. Returns {"id","saved":true}. */
char *cs_layers_save(cs_handle *h, const char *definition_json);

/* Remove a user definition ("not_found" for ids from folders or the catalogue). Returns {"id","removed":true}. */
char *cs_layers_remove(cs_handle *h, const char *id);

/* Start the local tile server (once per handle; later calls return the same port) and optionally set whether the
 * engine may use the network: options_json NULL or {"online":bool}. Returns
 * {"port":N,"base_url":"http://127.0.0.1:N","tilejson":"http://127.0.0.1:N/layers/{id}/tilejson.json","online":bool}.
 * The server is the one place the map reads tiles from: GET /layers/{id}/{z}/{x}/{y} answers, in order, from tiles
 * downloaded for offline use, from the cache of tiles viewed before, then (online, if the definition allows) from the
 * source, which is cached. 200 with the tile (header X-Cache-Status: downloaded|cache|network|generated); 204 where
 * the source has no tile; 404 with X-Cache-Status: miss when it is not on the device and there is no connection;
 * 503 "needs a connection" (X-Cache-Status: needs-connection) for an online-only layer; JSON {"code","message"}
 * errors otherwise. GET /layers/{id}/tilejson.json is a TileJSON 3.0 (tiles, minzoom, maxzoom, bounds, attribution,
 * "type": vector|raster|raster-dem, "encoding":"terrarium" and "tileSize" for elevation, vector_layers, style_hints).
 * Vector tiles are sent uncompressed. The server stops when the handle is closed. */
char *cs_layers_server(cs_handle *h, const char *options_json);

/* The dry run of a download. request_json: {"layer","area"?:"<id>","name"?,"bbox":[w,s,e,n] | "polygon":[[lon,lat],..],
 * "minzoom"?,"maxzoom"?,"update"?:bool}. Downloaded tiles are kept once per layer in one merged store, so the plan counts
 * only the tiles NOT already on the device. Returns {"layer","download_layer","area","mode":"new"|"extend"|"resume"|"update",
 * "tiles" (the area's cover),"tiles_to_download","tiles_already","already_bytes","tiles_present"?,"per_zoom",
 * "minzoom","maxzoom","estimated_bytes" (of the tiles to download),"estimate_method":"directory"|"sample of N tiles"|"none",
 * "limits":{...},"free_bytes","version","exists","resumable","ok_to_start":bool,
 * "problems":[{"code":"limit_exceeded"|"no_space","message"}]}. The layer's limits apply to the tiles to download.
 * Online-only layers fail with "offline"; the size needs a connection. An area id already used for another shape or
 * zoom range fails with "bad_json". */
char *cs_layers_plan(cs_handle *h, const char *request_json);

/* Delete a downloaded area ({"layer","area"}): only the tiles no other area covers are removed. Or all of a layer's areas,
 * unfinished downloads and tiles ({"layer"}). Returns {"layer","removed":["<area>",..],"tiles_removed","tiles_kept",
 * "freed_bytes","file_bytes_before","file_bytes_after"}. */
char *cs_layers_delete(cs_handle *h, const char *request_json);

/* Empty the viewed-tile cache of one layer, or of all layers (layer NULL). Returns {"cleared":N}. */
char *cs_layers_clear_cache(cs_handle *h, const char *layer);

/* One tile through the server's own path (for tests and headless use). Returns the bytes and sets *mime_out (free with
 * cs_free_string) and *len_out; an empty tile is a non-NULL pointer, length 0 and an empty MIME. NULL on error:
 * "not_found" (miss: not on the device, no connection), "offline" (online-only layer), others as above.
 * Free the bytes with cs_free_bytes. */
uint8_t *cs_layers_tile(cs_handle *h, const char *layer, int32_t z, int32_t x, int32_t y, char **mime_out, int64_t *len_out);

/* --- long jobs --- */

/* kind "index_zim":  {"zim_path","index_dir","heap_mb":200}
 * kind "index_library": {"library_path","index_dir","heap_mb":200}
 *   builds the device Tantivy index from the library's mapped text field.
 * kind "update_library": {"library_path","snapshot_path","snapshot_manifest_path"}
 *   closes the library, applies a partial snapshot to a REAL COPY of its shard directory
 *   (<library_path>.cs-stage, beside it, no hard links), rewrites the copy's segments_manifest.json, swaps the copy
 *   in with two renames (library -> <library_path>.cs-old, copy -> library, then deletes .cs-old) and opens the
 *   library read-only (see DESIGN.md, Libraries / Updates). The library folder is not written to until the
 *   swap: a job that fails before it deletes the copy and leaves the library exactly as it was (the handles open
 *   it again); a library can no longer be left half-merged, so there is no replace-from-a-full-snapshot remedy
 *   for a failed update. snapshot_manifest_path is the library's snapshot
 *   manifest JSON that was sent to the server when the partial snapshot was requested; it must list exactly the
 *   segments in library_path/segments. The job finds the library through its (canonical) path, not through a
 *   handle: every handle that has it open sees it as "updating" and opens it again afterwards. The library is
 *   marked updating before cs_job_start returns. cs_job_start fails with "busy" if another update or an
 *   index_library job is using that library, "not_found" if a path does not exist and "bad_json" for a manifest
 *   that is not valid or does not match the library.
 *   Free space: before it closes the library or creates anything the job needs library size + snapshot file size
 *   + a margin of max(5% of the library size, 256 MiB) free on the library's file system (the staging copy, the
 *   unpacked snapshot and the old library exist side by side at the end). If not, the job fails at once with code
 *   "no_space", {"code","message","needed","available"} (bytes), and has changed nothing on disk.
 *   Progress is in steps (done/total, total 5): closed, snapshot unpacked and checked, staging copy updated
 *   (copied, snapshot applied, segments_manifest.json rewritten), swapped, library opened once at its final path
 *   (checked). cs_job_cancel is honoured only before the staging copy starts (the library is then reopened
 *   unchanged); after that the job runs to the end. A failed job leaves the library as it was and the handles
 *   open it again (or, if that does not open, list it in cs_status with its error). If the last open fails the
 *   swap is undone. Freeing a running update_library job waits for it to finish.
 *   The last step opens the library read-only once; that shard is handed to every handle that had the library
 *   open (no second open).
 *   Crash leftovers beside the library are put right when a library is opened (cs_open) and when an update
 *   starts: a <library_path>.cs-stage folder is always deleted; <library_path>.cs-old is deleted if the library
 *   is complete (segments_manifest.json lists at least one segment, every listed segment folder exists, and the
 *   library opens read-only), renamed back to the library if the library is missing, and, if the library is there
 *   but not complete, the library is deleted and .cs-old renamed back.
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
 * kind "video_download": {"dir","instance","video","choice"?:"lowest","token"?}
 *   downloads one video for offline use. "dir" is the "video" folder of the cs_open config; "choice" is "audio",
 *   "lowest", "highest" or a resolution from cs_video_get's options (a resolution the video lacks gives the nearest one
 *   below it, else above); "token" is the access token for videos that need a login. cs_job_start fails at once with
 *   "bad_json" or "not_found" (unknown instance). On the job's thread it reads the video's details from the instance,
 *   refuses a live stream and a video with download_enabled false ("unsupported", nothing is downloaded), picks the file (see
 *   cs_video_get), then checks free space: file size + 16 MiB must fit ("no_space" with "needed" and "available",
 *   nothing downloaded). The file goes to <dir>/downloads/<instance>/<uuid>/video.part and is resumed with HTTP Range
 *   from what is there: a cancelled or failed job keeps it and a new job for the same file continues; network trouble
 *   is retried 3 times (1 s, 2 s, 4 s) before the job fails ("fetch_failed"). At most 2 downloads per instance and 4 in
 *   all run at once; the others wait ("running", done 0). The finished file's size must equal the size the instance gave
 *   and, when the instance publishes a checksum for it (HLS playlists' segments-sha256 list), its sha256 must match
 *   ("damaged": the file is deleted); the manifest always records the sha256 computed. Then the thumbnail and the
 *   captions (VTT) are saved and manifest.json is written last. A new download of a video replaces the earlier one.
 *   Progress: done/total in bytes of the video file (total 0 until known). Cancel keeps the partial file.
 * kind "layer_download": {"layers":<the "layers" section of the cs_open config>, "layer", "area"?, "name"?,
 *                         "bbox"|"polygon", "minzoom"?, "maxzoom"?, "update"?}   (see cs_layers_plan)
 *   downloads a layer for an area (a box or a polygon) and a zoom range into the layer's ONE merged tile store
 *   (<dir>/store/<layer>.sqlite): only tiles not already stored are fetched, so overlapping areas share tiles; the tile
 *   server serves them at once. cs_job_start fails at once with "not_found" (no such layer), "offline" (an online-only
 *   layer), "bad_json" (bad area, or an area id used for another shape) or "busy" (the same area is already being
 *   downloaded). The job checks the layer's limits (max_tiles_per_download, max_bytes_per_download, applied to the tiles
 *   to fetch; the bytes limit is also enforced on what is written) and the free disk space first and fails with
 *   "limit_exceeded" or "no_space" (with "needed" and "available") before downloading anything. Progress is tiles done
 *   over tiles to fetch, "detail":{"bytes"}. Tiles are fetched with the layer's max_parallel and the app User-Agent
 *   "Cache/<version>", retried with backoff. cs_job_cancel stops at the next batch; the area stays "partial" with its tiles
 *   in the store, and starting the same request again fetches only what is missing. "update":true re-fetches the area's
 *   tiles that are older than the layer's version into a staging table and swaps them in, with the new version, in one
 *   transaction when complete; until then the old tiles keep serving.
 * Resumes from the last checkpoint if index_dir holds an unfinished build. The index format version and the
 * tokenizer (from the ZIM or library language; English stemmer by default) are recorded in index_dir. */
cs_job *cs_job_start(const char *kind, const char *params_json);

/* {"state":"running"|"done"|"cancelled"|"failed","done":N,"total":N,"error":null|{"code","message"}}
 * layer_download jobs add "detail":{"bytes":N} (bytes written so far). */
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
