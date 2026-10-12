#include "sharp/h264_limit.h"

#include <assert.h>
#include <stdio.h>

static int picture_fits(uint32_t width, uint32_t height) {
    return (width % 2u) == 0u && (height % 2u) == 0u && width >= 2u &&
           height >= 2u && width <= 4096u && height <= 4096u &&
           ((width + 15u) / 16u) * ((height + 15u) / 16u) <= 36864u;
}

static void expect(uint32_t width, uint32_t height, uint32_t want_width,
                   uint32_t want_height) {
    uint32_t out_width = 0;
    uint32_t out_height = 0;
    sharp_h264_picture_size(width, height, &out_width, &out_height);
    assert(out_width == want_width && out_height == want_height);
    assert(picture_fits(out_width, out_height));
}

int main(void) {
    uint32_t out_width = 0;
    uint32_t out_height = 0;
    expect(5120, 2880, 4096, 2304);
    expect(5120, 2160, 4096, 1728);
    expect(3840, 2160, 3840, 2160);
    expect(2560, 1440, 2560, 1440);
    expect(1920, 1080, 1920, 1080);
    sharp_h264_picture_size(1921, 1080, &out_width, &out_height);
    assert((out_width % 2u) == 0u);
    assert(picture_fits(out_width, out_height));
    sharp_h264_picture_size(0, 0, &out_width, &out_height);
    assert(out_width >= 2u && out_height >= 2u);
    assert(picture_fits(out_width, out_height));
    sharp_h264_motion_picture_size(5120, 2880, 2560, &out_width, &out_height);
    assert(out_width == 2560u && out_height == 1440u);
    sharp_h264_motion_picture_size(5120, 2880, 0, &out_width, &out_height);
    assert(out_width == 4096u && out_height == 2304u);
    sharp_h264_motion_picture_size(1920, 1080, 2560, &out_width, &out_height);
    assert(out_width == 1920u && out_height == 1080u);
    sharp_h264_motion_picture_size(5120, 2160, 2561, &out_width, &out_height);
    assert(out_width == 2560u && out_height == 1080u);
    sharp_h264_motion_picture_size(5120, 2880, 8000, &out_width, &out_height);
    assert(out_width == 4096u && out_height == 2304u);
    sharp_h264_motion_picture_size(5121, 2879, 1279, &out_width, &out_height);
    assert((out_width % 2u) == 0u && (out_height % 2u) == 0u);
    assert(picture_fits(out_width, out_height) && out_width <= 1278u);
    /* 4K and smaller sources are never capped. */
    sharp_h264_motion_picture_size(3840, 2160, 2560, &out_width, &out_height);
    assert(out_width == 3840u && out_height == 2160u);
    sharp_h264_motion_picture_size(4096, 2304, 2560, &out_width, &out_height);
    assert(out_width == 4096u && out_height == 2304u);
    sharp_h264_motion_picture_size(3200, 1800, 2560, &out_width, &out_height);
    assert(out_width == 3200u && out_height == 1800u);
    printf("h264 limit PASS\n");
    return 0;
}
