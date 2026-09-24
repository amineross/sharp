#ifndef SHARP_SHTP_TIME_H
#define SHARP_SHTP_TIME_H

#include <stdint.h>

uint64_t shtp_now_ns(void);
void shtp_sleep_until_ns(uint64_t deadline_ns);

#endif
