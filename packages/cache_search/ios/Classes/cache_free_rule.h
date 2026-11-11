// The one rule for how much room a download or a sync may count on (see cache_free_bytes_on_disk in cache_search.c).
#ifndef CACHE_FREE_RULE_H
#define CACHE_FREE_RULE_H

#include <stdint.h>

// Free now (statvfs) plus half of what iOS could purge on top of it (important usage minus free now). Purging is not instant and
// not certain, so only half of it counts. Never below free now, and free now alone when the important figure is lower or unknown.
static inline int64_t cache_free_allowance(int64_t free_now, int64_t important) {
    if (free_now < 0) return -1;
    if (important <= free_now) return free_now;
    return free_now + (important - free_now) / 2;
}

#endif
