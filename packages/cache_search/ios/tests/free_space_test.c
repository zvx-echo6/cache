#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#include "../Classes/cache_free_rule.h"

extern int64_t cache_free_bytes_on_disk(const char *path);
extern int64_t cache_free_now_bytes_on_disk(const char *path);
extern int64_t cache_total_bytes_on_disk(const char *path);

int main(int argc, char **argv) {
    assert(argc == 3);
    assert(cache_free_bytes_on_disk(NULL) == -1);
    assert(cache_free_bytes_on_disk("") == -1);
    assert(cache_free_bytes_on_disk(argv[2]) == -1);
    const int64_t available = cache_free_bytes_on_disk(argv[1]);
    assert(available >= 0);
    // The pre-check rule: free now plus half of the purgeable part; never less than free now; unknown stays unknown.
    assert(cache_free_allowance(10, 30) == 20);
    assert(cache_free_allowance(10, 11) == 10);
    assert(cache_free_allowance(10, 10) == 10);
    assert(cache_free_allowance(10, 5) == 10);
    assert(cache_free_allowance(0, 8) == 4);
    assert(cache_free_allowance(-1, 8) == -1);
    // Free now is what statvfs says and never more than the allowance.
    assert(cache_free_now_bytes_on_disk(NULL) == -1);
    assert(cache_free_now_bytes_on_disk(argv[2]) == -1);
    const int64_t now = cache_free_now_bytes_on_disk(argv[1]);
    assert(now >= 0 && now <= available);
    assert(cache_total_bytes_on_disk(NULL) == -1);
    assert(cache_total_bytes_on_disk(argv[2]) == -1);
    assert(cache_total_bytes_on_disk(argv[1]) >= available);
    printf("Disk-space helper: valid path reports %" PRId64 " bytes; invalid paths report unavailable\n", available);
    return 0;
}