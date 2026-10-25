/* valhalla_shim: thin C ABI over Valhalla's tyr::actor_t (Valhalla 3.7.0).
 *
 * Every request/response is Valhalla's own JSON. The shim does no interpretation.
 * A handle serialises its calls internally (actor_t is not thread-safe); use one
 * handle per thread for parallel requests.
 */
#ifndef VALHALLA_SHIM_H
#define VALHALLA_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  ifdef VALHALLA_SHIM_BUILDING
#    define VALHALLA_SHIM_API __declspec(dllexport)
#  else
#    define VALHALLA_SHIM_API __declspec(dllimport)
#  endif
#else
#  define VALHALLA_SHIM_API __attribute__((visibility("default")))
#endif

typedef struct valhalla_shim valhalla_shim_t;

/* Valhalla version string, e.g. "3.7.0". Static storage; do not free. */
VALHALLA_SHIM_API const char* valhalla_shim_version(void);

/* Create a handle. `config` is either a path to a Valhalla config JSON file or
 * the config JSON itself (same rule as valhalla::config()). The config selects
 * the tiles (mjolnir.tile_extract tar or mjolnir.tile_dir).
 * Returns NULL on failure; read the reason with valhalla_shim_last_error(NULL). */
VALHALLA_SHIM_API valhalla_shim_t* valhalla_shim_init(const char* config);

/* Each returns a newly allocated NUL-terminated JSON string (free with
 * valhalla_shim_string_free), or NULL on failure (see valhalla_shim_last_error). */
VALHALLA_SHIM_API char* valhalla_shim_route(valhalla_shim_t* h, const char* request_json);
VALHALLA_SHIM_API char* valhalla_shim_matrix(valhalla_shim_t* h, const char* request_json); /* sources_to_targets */
VALHALLA_SHIM_API char* valhalla_shim_locate(valhalla_shim_t* h, const char* request_json);

VALHALLA_SHIM_API void valhalla_shim_string_free(char* s);
VALHALLA_SHIM_API void valhalla_shim_destroy(valhalla_shim_t* h);

/* Message of the last failure. With a handle: that handle's last error. With
 * NULL: the last error of the calling thread outside a handle (e.g. init).
 * Pointer is valid until the next call on the same handle/thread. Empty string if none. */
VALHALLA_SHIM_API const char* valhalla_shim_last_error(valhalla_shim_t* h);

#ifdef __cplusplus
}
#endif
#endif
