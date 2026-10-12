#include "sharp/h264_limit.h"

/* Hardware H.264 High Level 5.2: even edges, each ≤ 4096, ≤ 36864
 * macroblocks. Same integers as SharpResolution.encodeSize. */

static uint32_t even_at_least_2(uint32_t value) {
    if (value < 2u) {
        return 2u;
    }
    return (value & 1u) == 0u ? value : value - 1u;
}

static uint32_t force_even(uint32_t value) {
    return (value & 1u) == 0u ? value : value - 1u;
}

static int picture_fits(uint32_t width, uint32_t height) {
    uint32_t macroblocks;
    if ((width & 1u) != 0u || (height & 1u) != 0u || width > 4096u ||
        height > 4096u) {
        return 0;
    }
    macroblocks = ((width + 15u) / 16u) * ((height + 15u) / 16u);
    return macroblocks <= 36864u;
}

void sharp_h264_picture_size(uint32_t width, uint32_t height,
                             uint32_t *out_width, uint32_t *out_height) {
    uint32_t original_width;
    uint32_t original_height;
    width = even_at_least_2(width);
    height = even_at_least_2(height);
    original_width = width;
    original_height = height;
    if (width > 4096u) {
        height = (uint32_t)(((uint64_t)height * 4096u) / width);
        width = 4096u;
    }
    if (height > 4096u) {
        width = (uint32_t)(((uint64_t)width * 4096u) / height);
        height = 4096u;
    }
    width = force_even(width);
    height = force_even(height);
    while (!picture_fits(width, height) && width > 2u && height > 2u) {
        width -= 2u;
        height = (uint32_t)(((uint64_t)original_height * width) / original_width);
        height = force_even(height);
    }
    *out_width = width;
    *out_height = height;
}
