#ifndef SHARP_H264_LIMIT_H
#define SHARP_H264_LIMIT_H

#include <stdint.h>

void sharp_h264_picture_size(uint32_t width, uint32_t height,
                             uint32_t *out_width, uint32_t *out_height);

#endif
