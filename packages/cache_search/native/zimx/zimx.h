/* zimx: a small C ABI over Kiwix's libzim (its built-in Xapian full-text index and title index).
 *
 * Conventions (same as cache_search.h): every string is UTF-8; results are JSON strings that the caller frees with
 * zimx_free; nothing crosses this boundary as a C++ exception. A call that fails returns {"error":"<message>"}
 * (zimx_open returns NULL and writes that JSON to *err instead).
 *
 *   zimx_search -> {"total":<estimated matches>,"hits":[{"path","title","snippet","score"}...]}
 *   zimx_suggest -> {"total":<estimated matches>,"hits":[{"path","title"}...]}
 *   zimx_get -> {"found":true,"path","title","mime"} plus the raw bytes in *data; zimx_main_page -> {"found":true,"path"}
 *   (the entry reads of cs_read / cs_zim_get / cs_zim_main_page: the same open archive as the searches, see below)
 *
 * "snippet" is libzim's own snippet: HTML that may carry <b> around matched words (the caller strips it; on the real
 * ZIMs tried none came back marked, so nothing relies on the marks). "score" is libzim's
 * integer relevance (best first): Xapian's percentage, which is 100 for the best hit of the query in this ZIM and lower
 * for the others (measured on 18 real ZIMs: the best hit is always 100). It is relative to this ZIM's best hit, so
 * scores from two ZIMs cannot be compared with each other.
 *
 * A handle may be used from several threads at once (libzim's Archive is read-only and thread safe); the searchers are
 * built when the caller says to keep them and released with zimx_drop, and calls that use them are serialised by a mutex inside the handle. */
#ifndef ZIMX_H
#define ZIMX_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#define ZIMX_API
#else
#define ZIMX_API __attribute__((visibility("default")))
#endif

typedef struct zimx zimx;

/* Open a ZIM file. NULL on failure, with a malloc'd {"error":...} JSON in *err (may be NULL; free with zimx_free). */
ZIMX_API zimx *zimx_open(const char *path, char **err);
/* Like zimx_open with archive options; -1 keeps libzim's default for that option. preload_xapian: 1/0 preload the Xapian
 * database at open; preload_dirent_ranges: how many dirent ranges to preload (0 = none); dirent_cache: the archive's dirent
 * cache limit in dirents. See DESIGN.md "Memory budget". */
ZIMX_API zimx *zimx_open_with(const char *path, int preload_xapian, int preload_dirent_ranges, long long dirent_cache, char **err);
ZIMX_API void zimx_close(zimx *z);
/* {"dirent_cache_max":n,"dirent_cache_current":n,"all_entries":n} for this archive. */
ZIMX_API char *zimx_archive_info(zimx *z);

/* 1 if the ZIM carries the built-in full-text index (X/fulltext/xapian) / the title index; 0 if not or z is NULL. */
ZIMX_API int zimx_has_fulltext(zimx *z);
ZIMX_API int zimx_has_title_index(zimx *z);

/* Full-text search: results offset..offset+k. keep != 0 builds the searcher if needed and keeps it; keep == 0 uses a kept
 * searcher if there is one and otherwise builds a temporary one that is dropped before the call returns. */
ZIMX_API char *zimx_search(zimx *z, const char *query, int offset, int k, int keep);
/* Build and keep the full-text and/or title searchers now (opens the Xapian databases), so the first search or suggestion
 * does not pay for it. Returns {"ok":true}, or {"error":...}. A searcher the ZIM cannot have is skipped. */
ZIMX_API char *zimx_prewarm(zimx *z, int fulltext, int titles);
/* Release the kept full-text and/or title searcher (the archive stays open). Returns {"ok":true}, or {"error":...}. */
ZIMX_API char *zimx_drop(zimx *z, int fulltext, int titles);
/* Title-prefix suggestions: the first k. keep as for zimx_search. */
ZIMX_API char *zimx_suggest(zimx *z, const char *prefix, int k, int keep);

/* Read one entry through the same open archive the searches use (so it counts against the memory budget and shares libzim's
 * caches). `path` is the path as the ZIM stores it for a new-scheme archive; for an old-scheme one it is the path without
 * the namespace and the namespaces C, A, I and - are tried in that order. Only an exact path matches (libzim's own
 * "strip a leading namespace" fallback is not taken). Redirects are followed: `iterations` is how many entries are
 * examined at most (an entry that is not a redirect ends it).
 * Returns {"found":true,"path":<path of the entry holding the content, no namespace>,"title":<its title, or its path when
 * it has none>,"mime":<its MIME type>} and sets *data (malloc'd, free with zimx_free) and *len to the raw bytes;
 * {"found":false} when there is no such entry; {"found":false,"loop":true} when the redirect chain does not end within
 * `iterations`; {"error":...} on failure (then *data is NULL and *len is -1). */
ZIMX_API char *zimx_get(zimx *z, const char *path, int iterations, unsigned char **data, long long *len);
/* The main page: {"found":true,"path":<path without namespace, redirects followed within `iterations`>}, {"found":false}
 * when the ZIM has none, {"found":false,"loop":true} for a redirect chain that does not end, or {"error":...}. */
ZIMX_API char *zimx_main_page(zimx *z, int iterations);

/* libzim's cluster cache, which is shared by every archive in the process (not by one handle): {"current":<bytes>,"max":<bytes>}. */
ZIMX_API char *zimx_cluster_cache(void);

/* Set the cluster cache limit in bytes (process-wide; entries over the new limit are dropped). Measurement hook: the core does not call it. */
ZIMX_API char *zimx_set_cluster_cache_max(unsigned long long bytes);

/* libzim's version string, e.g. "9.8.2". */
ZIMX_API char *zimx_version(void);

/* Test hook: mode 0 throws std::runtime_error, 1 throws an int, 2 throws std::bad_alloc, other: returns {"ok":true}.
 * Always inside the same guard as the real calls, so it proves the exception becomes an {"error"}. */
ZIMX_API char *zimx_selftest_throw(int mode);

ZIMX_API void zimx_free(char *s);

#ifdef __cplusplus
}
#endif
#endif
