#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

extern int64_t cache_free_bytes_on_disk(const char *path);
extern int64_t cache_total_bytes_on_disk(const char *path);

int main(int argc, char **argv) {
    assert(argc == 3);
    assert(cache_free_bytes_on_disk(NULL) == -1);
    assert(cache_free_bytes_on_disk("") == -1);
    assert(cache_free_bytes_on_disk(argv[2]) == -1);
    const int64_t available = cache_free_bytes_on_disk(argv[1]);
    assert(available >= 0);
    assert(cache_total_bytes_on_disk(NULL) == -1);
    assert(cache_total_bytes_on_disk(argv[2]) == -1);
    assert(cache_total_bytes_on_disk(argv[1]) >= available);
    printf("Disk-space helper: valid path reports %" PRId64 " bytes; invalid paths report unavailable\n", available);
    return 0;
}