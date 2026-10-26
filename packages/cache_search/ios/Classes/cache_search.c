// The search core is in ../native/libcache_search.a (see ../build-core.sh).
// Keep this helper in the pod so statvfs uses the iOS SDK's actual struct layout.
#include <stddef.h>
#include <stdint.h>
#include <sys/statvfs.h>

// Dart resolves this symbol with DynamicLibrary.process(). 'used' prevents
// dead stripping once linked; the app must also root the archive member with
// -Wl,-u,_cache_free_bytes_on_disk. Verify the symbol in the final Runner.
__attribute__((used, visibility("default")))
int64_t cache_free_bytes_on_disk(const char *path) {
    if (path == NULL || path[0] == '\0') return -1;

    struct statvfs fs;
    if (statvfs(path, &fs) != 0) return -1;

    const uint64_t available = (uint64_t)fs.f_bavail;
    const uint64_t fragment_size = (uint64_t)fs.f_frsize;
    if (fragment_size == 0 || available > INT64_MAX / fragment_size) {
        return -1;
    }
    return (int64_t)(available * fragment_size);
}
