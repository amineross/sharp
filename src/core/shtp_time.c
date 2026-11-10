#include "sharp/shtp_time.h"

#include <errno.h>
#include <mach/mach_time.h>
#include <time.h>

uint64_t shtp_now_ns(void) {
    if (__builtin_available(macOS 10.12, *)) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
    }
    /* El Capitan has no clock_gettime. */
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

void shtp_sleep_until_ns(uint64_t deadline_ns) {
    for (;;) {
        uint64_t now = shtp_now_ns();
        if (now >= deadline_ns) {
            return;
        }
        uint64_t delta = deadline_ns - now;
        struct timespec req;
        req.tv_sec = (time_t)(delta / 1000000000ULL);
        req.tv_nsec = (long)(delta % 1000000000ULL);
        if (nanosleep(&req, NULL) == 0 || errno != EINTR) {
            return;
        }
    }
}
