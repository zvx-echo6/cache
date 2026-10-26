/* zimx: a small C ABI over Kiwix's libzim (its built-in Xapian full-text index and title index).
 *
 * Conventions (same as cache_search.h): every string is UTF-8; results are JSON strings that the caller frees with
 * zimx_free; nothing crosses this boundary as a C++ exception. A call that fails returns {"error":"<message>"}
 * (zimx_open returns NULL and writes that JSON to *err instead).
 *
 *   zimx_search -> {"total":<estimated matches>,"hits":[{"path","title","snippet","score"}...]}
 *   zimx_suggest -> {"total":<estimated matches>,"hits":[{"path","title"}...]}
 *
 * "snippet" is libzim's own snippet: HTML that may carry <b> around matched words (the caller strips it; on the real
 * ZIMs tried none came back marked, so nothing relies on the marks). "score" is libzim's
 * integer relevance (best first): Xapian's percentage, which is 100 for the best hit of the query in this ZIM and lower
 * for the others (measured on 18 real ZIMs: the best hit is always 100). It is relative to this ZIM's best hit, so
 * scores from two ZIMs cannot be compared with each other.
 *
 * A handle may be used from several threads at once (libzim's Archive is read-only and thread safe; the searchers are
 * created per call). */
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
ZIMX_API void zimx_close(zimx *z);

/* 1 if the ZIM carries the built-in full-text index (X/fulltext/xapian) / the title index; 0 if not or z is NULL. */
ZIMX_API int zimx_has_fulltext(zimx *z);
ZIMX_API int zimx_has_title_index(zimx *z);

/* Full-text search: results offset..offset+k. */
ZIMX_API char *zimx_search(zimx *z, const char *query, int offset, int k);
/* Title-prefix suggestions: the first k. */
ZIMX_API char *zimx_suggest(zimx *z, const char *prefix, int k);

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
