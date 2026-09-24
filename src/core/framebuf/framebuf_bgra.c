#include "sharp/framebuf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int sharp_framebuf_init(sharp_framebuf_t *fb, uint32_t width, uint32_t height) {
    if (fb == NULL || width == 0 || height == 0) {
        return -1;
    }
    memset(fb, 0, sizeof(*fb));
    fb->width = width;
    fb->height = height;
    fb->stride = width * 4u;
    fb->pixels = calloc((size_t)height, fb->stride);
    return fb->pixels != NULL ? 0 : -1;
}

void sharp_framebuf_destroy(sharp_framebuf_t *fb) {
    if (fb != NULL) {
        free(fb->pixels);
        memset(fb, 0, sizeof(*fb));
    }
}

void sharp_framebuf_clear(sharp_framebuf_t *fb) {
    if (fb != NULL && fb->pixels != NULL) {
        memset(fb->pixels, 0, (size_t)fb->height * fb->stride);
    }
}

int sharp_framebuf_patch_tile(sharp_framebuf_t *fb, const sharp_tile_rect_t *rect,
                              const uint8_t *bgra, size_t len) {
    if (fb == NULL || rect == NULL || bgra == NULL || fb->pixels == NULL ||
        rect->x + rect->w > fb->width || rect->y + rect->h > fb->height ||
        len != (size_t)rect->w * (size_t)rect->h * 4u) {
        return -1;
    }

    for (uint32_t row = 0; row < rect->h; row++) {
        uint8_t *dst = fb->pixels + ((size_t)rect->y + row) * fb->stride +
                       (size_t)rect->x * 4u;
        const uint8_t *src = bgra + (size_t)row * (size_t)rect->w * 4u;
        memcpy(dst, src, (size_t)rect->w * 4u);
    }
    return 0;
}

int sharp_framebuf_fill_synthetic(sharp_framebuf_t *fb, uint32_t frame_id) {
    if (fb == NULL || fb->pixels == NULL) {
        return -1;
    }
    uint32_t count = sharp_tile_count(fb->width, fb->height);
    uint8_t tile[SHARP_TILE_BYTES];
    for (uint32_t tile_id = 0; tile_id < count; tile_id++) {
        sharp_tile_rect_t rect;
        size_t len = 0;
        if (sharp_synthetic_make_tile(fb->width, fb->height, frame_id, (uint16_t)tile_id,
                                      tile, sizeof(tile), &rect, &len, NULL) != 0 ||
            sharp_framebuf_patch_tile(fb, &rect, tile, len) != 0) {
            return -1;
        }
    }
    return 0;
}

size_t sharp_framebuf_count_synthetic_mismatches(const sharp_framebuf_t *fb,
                                                 uint32_t frame_id) {
    if (fb == NULL || fb->pixels == NULL) {
        return (size_t)-1;
    }

    sharp_framebuf_t expected;
    if (sharp_framebuf_init(&expected, fb->width, fb->height) != 0) {
        return (size_t)-1;
    }
    if (sharp_framebuf_fill_synthetic(&expected, frame_id) != 0) {
        sharp_framebuf_destroy(&expected);
        return (size_t)-1;
    }

    size_t mismatches = 0;
    size_t total = (size_t)fb->height * fb->stride;
    for (size_t i = 0; i < total; i++) {
        if (fb->pixels[i] != expected.pixels[i]) {
            mismatches++;
        }
    }
    sharp_framebuf_destroy(&expected);
    return mismatches;
}

int sharp_framebuf_write_ppm(const sharp_framebuf_t *fb, const char *path) {
    if (fb == NULL || fb->pixels == NULL || path == NULL) {
        return -1;
    }
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        return -1;
    }
    if (fprintf(f, "P6\n%u %u\n255\n", fb->width, fb->height) < 0) {
        fclose(f);
        return -1;
    }
    for (uint32_t y = 0; y < fb->height; y++) {
        const uint8_t *row = fb->pixels + (size_t)y * fb->stride;
        for (uint32_t x = 0; x < fb->width; x++) {
            const uint8_t *bgra = row + (size_t)x * 4u;
            uint8_t rgb[3] = {bgra[2], bgra[1], bgra[0]};
            if (fwrite(rgb, 1, sizeof(rgb), f) != sizeof(rgb)) {
                fclose(f);
                return -1;
            }
        }
    }
    return fclose(f);
}
