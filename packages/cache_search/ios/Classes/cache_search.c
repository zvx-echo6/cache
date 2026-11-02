// The search core is in ../native/libcache_search.a (see ../build-core.sh).
// Keep this helper in the pod so statvfs uses the iOS SDK's actual struct layout.
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/statvfs.h>

// What iPhone Storage in Settings shows as available: free space plus what iOS can purge for the app
// (kCFURLVolumeAvailableCapacityForImportantUsageKey). statvfs leaves the purgeable part out and is only the fallback.
// 0 when it cannot be read.
static int available_for_important_usage(const char *path, int64_t *out) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (url == NULL) return 0;
    CFTypeRef value = NULL;
    int found = 0;
    if (CFURLCopyResourcePropertyForKey(url, kCFURLVolumeAvailableCapacityForImportantUsageKey, &value, NULL) && value != NULL) {
        int64_t bytes = 0;
        if (CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &bytes) &&
            bytes >= 0) {
            *out = bytes;
            found = 1;
        }
    }
    if (value != NULL) CFRelease(value);
    CFRelease(url);
    return found;
}

// Dart resolves this symbol with DynamicLibrary.process(), and the Rust core's free-space checks call it on iPhone.
// 'used' prevents dead stripping once linked; the app must also root the archive member with
// -Wl,-u,_cache_free_bytes_on_disk. Verify the symbol in the final Runner.
__attribute__((used, visibility("default")))
int64_t cache_free_bytes_on_disk(const char *path) {
    if (path == NULL || path[0] == '\0') return -1;

    struct statvfs fs;
    if (statvfs(path, &fs) != 0) return -1;

    int64_t important = 0;
    if (available_for_important_usage(path, &important)) return important;

    const uint64_t available = (uint64_t)fs.f_bavail;
    const uint64_t fragment_size = (uint64_t)fs.f_frsize;
    if (fragment_size == 0 || available > INT64_MAX / fragment_size) {
        return -1;
    }
    return (int64_t)(available * fragment_size);
}

// The size of the storage holding path (kCFURLVolumeTotalCapacityKey, else statvfs), for the space Cache leaves the phone
// (10% of it, 5 to 20 GB). Dart resolves it like cache_free_bytes_on_disk; -1 when it cannot be read.
__attribute__((used, visibility("default")))
int64_t cache_total_bytes_on_disk(const char *path) {
    if (path == NULL || path[0] == '\0') return -1;

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (url != NULL) {
        CFTypeRef value = NULL;
        int64_t bytes = -1;
        if (CFURLCopyResourcePropertyForKey(url, kCFURLVolumeTotalCapacityKey, &value, NULL) && value != NULL) {
            if (CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &bytes)) {
                bytes = -1;
            }
        }
        if (value != NULL) CFRelease(value);
        CFRelease(url);
        if (bytes > 0) return bytes;
    }

    struct statvfs fs;
    if (statvfs(path, &fs) != 0) return -1;
    const uint64_t blocks = (uint64_t)fs.f_blocks;
    const uint64_t fragment_size = (uint64_t)fs.f_frsize;
    if (fragment_size == 0 || blocks > INT64_MAX / fragment_size) return -1;
    return (int64_t)(blocks * fragment_size);
}
