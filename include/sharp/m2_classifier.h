#ifndef SHARP_M2_CLASSIFIER_H
#define SHARP_M2_CLASSIFIER_H

#include "sharp/tile.h"

#include <stddef.h>
#include <stdint.h>

typedef enum sharp_m2_tile_class {
    SHARP_M2_TILE_STATIC = 0,
    SHARP_M2_TILE_MOTION = 1,
    SHARP_M2_TILE_PENDING_REFINE = 2
} sharp_m2_tile_class_t;

typedef enum sharp_m2_region_event {
    SHARP_M2_REGION_STABLE = 0,
    SHARP_M2_REGION_BORN = 1,
    SHARP_M2_REGION_RESIZED = 2,
    SHARP_M2_REGION_DIED = 3
} sharp_m2_region_event_t;

typedef struct sharp_m2_tile_probe {
    uint16_t tile_id;
    uint8_t color_count_probe;
    uint32_t edge_energy;
} sharp_m2_tile_probe_t;

typedef struct sharp_m2_region {
    uint32_t id;
    sharp_m2_region_event_t event;
    uint16_t min_tx;
    uint16_t min_ty;
    uint16_t max_tx;
    uint16_t max_ty;
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
    uint16_t tile_count;
} sharp_m2_region_t;

typedef struct sharp_m2_frame_result {
    uint32_t frame_id;
    size_t dirty_tiles;
    size_t static_tiles;
    size_t motion_tiles;
    size_t pending_refine_tiles;
    size_t refine_tiles;
    size_t regions;
    size_t born_regions;
    size_t resized_regions;
    size_t died_regions;
} sharp_m2_frame_result_t;

typedef struct sharp_m2_classifier_config {
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint8_t motion_streak_frames;
    uint8_t text_motion_streak_frames;
    uint8_t settle_frames;
    uint8_t text_color_threshold;
    uint32_t text_edge_threshold;
    double resize_threshold;
} sharp_m2_classifier_config_t;

typedef struct sharp_m2_classifier sharp_m2_classifier_t;

void sharp_m2_classifier_default_config(uint32_t width, uint32_t height, uint32_t fps,
                                        sharp_m2_classifier_config_t *config);
sharp_m2_classifier_t *sharp_m2_classifier_create(
    const sharp_m2_classifier_config_t *config);
void sharp_m2_classifier_destroy(sharp_m2_classifier_t *classifier);

void sharp_m2_probe_bgra_tile(uint32_t width, uint32_t height, uint16_t tile_id,
                              const uint8_t *bgra, uint32_t stride,
                              sharp_m2_tile_probe_t *probe);

int sharp_m2_classifier_update(sharp_m2_classifier_t *classifier, uint32_t frame_id,
                               const uint16_t *dirty_tiles,
                               const sharp_m2_tile_probe_t *probes,
                               size_t dirty_count, uint16_t *refine_tiles,
                               size_t refine_cap,
                               sharp_m2_frame_result_t *result);

void sharp_m2_classifier_mark_refined(sharp_m2_classifier_t *classifier,
                                      const uint16_t *tiles, size_t tile_count);

size_t sharp_m2_classifier_regions(const sharp_m2_classifier_t *classifier,
                                   sharp_m2_region_t *regions, size_t region_cap);

sharp_m2_tile_class_t sharp_m2_classifier_tile_class(
    const sharp_m2_classifier_t *classifier, uint16_t tile_id);
uint8_t sharp_m2_classifier_tile_consecutive_frames(
    const sharp_m2_classifier_t *classifier, uint16_t tile_id);

const char *sharp_m2_tile_class_name(sharp_m2_tile_class_t klass);
const char *sharp_m2_region_event_name(sharp_m2_region_event_t event);

#endif
