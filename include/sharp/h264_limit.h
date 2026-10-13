#ifndef SHARP_H264_LIMIT_H
#define SHARP_H264_LIMIT_H

#include <stdint.h>

void sharp_h264_picture_size(uint32_t width, uint32_t height,
                             uint32_t *out_width, uint32_t *out_height);

/* Default cap on the full-frame video width while the screen is in motion.
 * Lossless tiles still restore the native size once the screen settles. */
#define SHARP_H264_MOTION_MAX_WIDTH_DEFAULT 2560u
/* The motion cap applies only to sources wider than this (5K and up).
 * 4K and smaller streams keep their own encode size. */
#define SHARP_H264_MOTION_CAP_ABOVE_WIDTH 4096u

/* Like sharp_h264_picture_size, but when the source is wider than
 * SHARP_H264_MOTION_CAP_ABOVE_WIDTH it first scales the picture down
 * (keeping the aspect ratio, even edges) so its width is at most max_width.
 * max_width == 0 disables the cap. */
void sharp_h264_motion_picture_size(uint32_t width, uint32_t height,
                                    uint32_t max_width, uint32_t *out_width,
                                    uint32_t *out_height);

#endif
