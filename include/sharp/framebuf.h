#ifndef SHARP_FRAMEBUF_H
#define SHARP_FRAMEBUF_H

#include "sharp/tile.h"

#include <stddef.h>
#include <stdint.h>

typedef struct sharp_framebuf {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint8_t *pixels;
} sharp_framebuf_t;

/*
 * Framebuffer convention: 32-bit BGRA, top-left origin, row-major rows.
 * pixels + y * stride + x * 4 addresses pixel (x, y), and tile coordinates
 * use the same origin.
 */

int sharp_framebuf_init(sharp_framebuf_t *fb, uint32_t width, uint32_t height);
void sharp_framebuf_destroy(sharp_framebuf_t *fb);
void sharp_framebuf_clear(sharp_framebuf_t *fb);
int sharp_framebuf_patch_tile(sharp_framebuf_t *fb, const sharp_tile_rect_t *rect,
                              const uint8_t *bgra, size_t len);
int sharp_framebuf_fill_synthetic(sharp_framebuf_t *fb, uint32_t frame_id);
size_t sharp_framebuf_count_synthetic_mismatches(const sharp_framebuf_t *fb,
                                                 uint32_t frame_id);
int sharp_framebuf_write_ppm(const sharp_framebuf_t *fb, const char *path);

#endif
