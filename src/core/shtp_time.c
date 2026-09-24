#include "sharp/shtp_time.h"

#include <errno.h>
#include <time.h>

uint64_t shtp_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
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
