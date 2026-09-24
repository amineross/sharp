#include "sharp/m2_classifier.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SHARP_M2_MAX_TRACKED_REGIONS 128u

typedef struct sharp_m2_tile_state {
    sharp_m2_tile_class_t klass;
    uint8_t dirty_streak;
    uint8_t idle_frames;
    uint8_t was_dirty;
    uint8_t text_like;
    uint32_t edge_energy;
    uint8_t color_count_probe;
} sharp_m2_tile_state_t;

typedef struct sharp_m2_tracked_region {
    sharp_m2_region_t region;
    uint8_t alive;
    uint8_t matched;
} sharp_m2_tracked_region_t;

struct sharp_m2_classifier {
    sharp_m2_classifier_config_t config;
    uint16_t cols;
    uint16_t rows;
    uint32_t tile_count;
    uint32_t next_region_id;
    sharp_m2_tile_state_t *tiles;
    uint8_t *dirty;
    uint8_t *visited;
    uint16_t *queue;
    sharp_m2_tracked_region_t tracked[SHARP_M2_MAX_TRACKED_REGIONS];
    sharp_m2_region_t regions[SHARP_M2_MAX_TRACKED_REGIONS * 2u];
    size_t region_count;
};

static uint32_t div_ceil_u32(uint32_t a, uint32_t b) {
    return (a + b - 1u) / b;
}

void sharp_m2_classifier_default_config(uint32_t width, uint32_t height, uint32_t fps,
                                        sharp_m2_classifier_config_t *config) {
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->width = width;
    config->height = height;
    config->fps = fps == 0 ? 30u : fps;
    config->motion_streak_frames = 5u;
    config->text_motion_streak_frames = 10u;
    config->settle_frames = (uint8_t)div_ceil_u32(config->fps * 150u, 1000u);
    if (config->settle_frames < 2u) {
        config->settle_frames = 2u;
    }
    if (config->settle_frames > 12u) {
        config->settle_frames = 12u;
    }
    config->text_color_threshold = 8u;
    config->text_edge_threshold = 6000u;
    config->resize_threshold = 0.20;
}

sharp_m2_classifier_t *sharp_m2_classifier_create(
    const sharp_m2_classifier_config_t *config) {
    if (config == NULL || config->width == 0 || config->height == 0) {
        return NULL;
    }
    uint32_t tile_count = sharp_tile_count(config->width, config->height);
    if (tile_count == 0 || tile_count > UINT16_MAX) {
        return NULL;
    }

    sharp_m2_classifier_t *classifier = calloc(1, sizeof(*classifier));
    if (classifier == NULL) {
        return NULL;
    }
    classifier->config = *config;
    classifier->cols = sharp_tile_cols(config->width);
    classifier->rows = sharp_tile_rows(config->height);
    classifier->tile_count = tile_count;
    classifier->next_region_id = 1u;
    classifier->tiles = calloc(tile_count, sizeof(classifier->tiles[0]));
    classifier->dirty = calloc(tile_count, sizeof(classifier->dirty[0]));
    classifier->visited = calloc(tile_count, sizeof(classifier->visited[0]));
    classifier->queue = calloc(tile_count, sizeof(classifier->queue[0]));
    if (classifier->tiles == NULL || classifier->dirty == NULL ||
        classifier->visited == NULL || classifier->queue == NULL) {
        sharp_m2_classifier_destroy(classifier);
        return NULL;
    }
    return classifier;
}

void sharp_m2_classifier_destroy(sharp_m2_classifier_t *classifier) {
    if (classifier != NULL) {
        free(classifier->tiles);
        free(classifier->dirty);
        free(classifier->visited);
        free(classifier->queue);
        free(classifier);
    }
}

static uint32_t read_pixel32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint8_t luma8(uint32_t bgra) {
    uint8_t b = (uint8_t)(bgra & 0xffu);
    uint8_t g = (uint8_t)((bgra >> 8u) & 0xffu);
    uint8_t r = (uint8_t)((bgra >> 16u) & 0xffu);
    return (uint8_t)(((uint32_t)r * 77u + (uint32_t)g * 150u + (uint32_t)b * 29u) >> 8u);
}

void sharp_m2_probe_bgra_tile(uint32_t width, uint32_t height, uint16_t tile_id,
                              const uint8_t *bgra, uint32_t stride,
                              sharp_m2_tile_probe_t *probe) {
    if (probe == NULL) {
        return;
    }
    memset(probe, 0, sizeof(*probe));
    probe->tile_id = tile_id;
    sharp_tile_rect_t rect;
    if (bgra == NULL || stride < width * 4u ||
        sharp_tile_rect_for_id(width, height, tile_id, &rect) != 0) {
        return;
    }

    uint32_t colors[9];
    uint8_t color_count = 0;
    uint32_t edge = 0;
    uint32_t step_x = rect.w >= 16u ? rect.w / 16u : 1u;
    uint32_t step_y = rect.h >= 16u ? rect.h / 16u : 1u;

    for (uint32_t sy = 0; sy < 16u && sy * step_y < rect.h; sy++) {
        uint32_t y = rect.y + sy * step_y;
        uint8_t prev_luma = 0;
        int have_prev = 0;
        for (uint32_t sx = 0; sx < 16u && sx * step_x < rect.w; sx++) {
            uint32_t x = rect.x + sx * step_x;
            const uint8_t *p = bgra + (size_t)y * stride + (size_t)x * 4u;
            uint32_t color = read_pixel32(p);
            if (color_count < 9u) {
                int known = 0;
                for (uint8_t i = 0; i < color_count; i++) {
                    if (colors[i] == color) {
                        known = 1;
                        break;
                    }
                }
                if (!known) {
                    colors[color_count++] = color;
                }
            }
            uint8_t lum = luma8(color);
            if (have_prev) {
                edge += lum > prev_luma ? (uint32_t)(lum - prev_luma)
                                        : (uint32_t)(prev_luma - lum);
            }
            prev_luma = lum;
            have_prev = 1;
        }
    }

    probe->color_count_probe = color_count;
    probe->edge_energy = edge;
}

static int is_text_like(const sharp_m2_classifier_t *classifier,
                        const sharp_m2_tile_probe_t *probe) {
    return probe->color_count_probe > 0 &&
           (probe->color_count_probe <= classifier->config.text_color_threshold ||
            probe->edge_energy >= classifier->config.text_edge_threshold);
}

static void mark_refine(uint16_t tile_id, uint16_t *refine_tiles, size_t refine_cap,
                        size_t *refine_count, uint8_t *refine_seen) {
    if (refine_seen[tile_id]) {
        return;
    }
    refine_seen[tile_id] = 1u;
    if (*refine_count < refine_cap) {
        refine_tiles[*refine_count] = tile_id;
    }
    (*refine_count)++;
}

static void add_region(sharp_m2_classifier_t *classifier,
                       const sharp_m2_region_t *region) {
    if (classifier->region_count < sizeof(classifier->regions) /
                                       sizeof(classifier->regions[0])) {
        classifier->regions[classifier->region_count++] = *region;
    }
}

static uint32_t region_area_tiles(const sharp_m2_region_t *r) {
    return (uint32_t)(r->max_tx - r->min_tx + 1u) *
           (uint32_t)(r->max_ty - r->min_ty + 1u);
}

static double region_iou_tiles(const sharp_m2_region_t *a,
                               const sharp_m2_region_t *b) {
    uint16_t ix0 = a->min_tx > b->min_tx ? a->min_tx : b->min_tx;
    uint16_t iy0 = a->min_ty > b->min_ty ? a->min_ty : b->min_ty;
    uint16_t ix1 = a->max_tx < b->max_tx ? a->max_tx : b->max_tx;
    uint16_t iy1 = a->max_ty < b->max_ty ? a->max_ty : b->max_ty;
    if (ix1 < ix0 || iy1 < iy0) {
        return 0.0;
    }
    uint32_t inter = (uint32_t)(ix1 - ix0 + 1u) * (uint32_t)(iy1 - iy0 + 1u);
    uint32_t area_a = region_area_tiles(a);
    uint32_t area_b = region_area_tiles(b);
    uint32_t uni = area_a + area_b - inter;
    return uni == 0 ? 0.0 : (double)inter / (double)uni;
}

static double region_motion_match_score(const sharp_m2_region_t *candidate,
                                        const sharp_m2_region_t *tracked) {
    double iou = region_iou_tiles(candidate, tracked);
    if (iou > 0.0) {
        return iou;
    }

    uint32_t candidate_area = region_area_tiles(candidate);
    uint32_t tracked_area = region_area_tiles(tracked);
    if (candidate_area == 0 || tracked_area == 0) {
        return 0.0;
    }
    uint32_t smaller = candidate_area < tracked_area ? candidate_area : tracked_area;
    uint32_t larger = candidate_area > tracked_area ? candidate_area : tracked_area;
    if ((double)smaller / (double)larger < 0.35) {
        return 0.0;
    }

    int candidate_cx = (int)candidate->min_tx + (int)candidate->max_tx;
    int candidate_cy = (int)candidate->min_ty + (int)candidate->max_ty;
    int tracked_cx = (int)tracked->min_tx + (int)tracked->max_tx;
    int tracked_cy = (int)tracked->min_ty + (int)tracked->max_ty;
    int dx = candidate_cx - tracked_cx;
    int dy = candidate_cy - tracked_cy;
    uint32_t dist2 = (uint32_t)(dx * dx + dy * dy);

    uint32_t candidate_w = (uint32_t)(candidate->max_tx - candidate->min_tx + 1u);
    uint32_t candidate_h = (uint32_t)(candidate->max_ty - candidate->min_ty + 1u);
    uint32_t tracked_w = (uint32_t)(tracked->max_tx - tracked->min_tx + 1u);
    uint32_t tracked_h = (uint32_t)(tracked->max_ty - tracked->min_ty + 1u);
    uint32_t span = candidate_w > candidate_h ? candidate_w : candidate_h;
    if (tracked_w > span) span = tracked_w;
    if (tracked_h > span) span = tracked_h;
    uint32_t max_delta = (span + 4u) * 2u;
    uint32_t max_dist2 = max_delta * max_delta;
    if (dist2 > max_dist2) {
        return 0.0;
    }

    return 0.20 + 0.30 * (1.0 - (double)dist2 / (double)max_dist2);
}

static void snap_region_pixels(const sharp_m2_classifier_t *classifier,
                               sharp_m2_region_t *region) {
    uint32_t tx0 = region->min_tx > 0 ? (uint32_t)region->min_tx - 1u : 0u;
    uint32_t ty0 = region->min_ty > 0 ? (uint32_t)region->min_ty - 1u : 0u;
    uint32_t tx1 = region->max_tx + 1u < classifier->cols
                       ? (uint32_t)region->max_tx + 1u
                       : (uint32_t)classifier->cols - 1u;
    uint32_t ty1 = region->max_ty + 1u < classifier->rows
                       ? (uint32_t)region->max_ty + 1u
                       : (uint32_t)classifier->rows - 1u;
    uint32_t x0 = tx0 * SHARP_TILE_SIZE;
    uint32_t y0 = ty0 * SHARP_TILE_SIZE;
    uint32_t x1 = (tx1 + 1u) * SHARP_TILE_SIZE;
    uint32_t y1 = (ty1 + 1u) * SHARP_TILE_SIZE;
    if (x1 > classifier->config.width) {
        x1 = classifier->config.width;
    }
    if (y1 > classifier->config.height) {
        y1 = classifier->config.height;
    }
    x0 &= ~15u;
    y0 &= ~15u;
    x1 = (x1 + 15u) & ~15u;
    y1 = (y1 + 15u) & ~15u;
    if (x1 > classifier->config.width) {
        x1 = classifier->config.width;
    }
    if (y1 > classifier->config.height) {
        y1 = classifier->config.height;
    }
    region->x = x0;
    region->y = y0;
    region->w = x1 > x0 ? x1 - x0 : 0;
    region->h = y1 > y0 ? y1 - y0 : 0;
}

static void build_motion_regions(sharp_m2_classifier_t *classifier,
                                 sharp_m2_frame_result_t *result,
                                 uint16_t *refine_tiles, size_t refine_cap,
                                 size_t *refine_count, uint8_t *refine_seen) {
    memset(classifier->visited, 0, classifier->tile_count);
    for (size_t i = 0; i < SHARP_M2_MAX_TRACKED_REGIONS; i++) {
        classifier->tracked[i].matched = 0u;
    }
    classifier->region_count = 0;

    for (uint32_t tile_id = 0; tile_id < classifier->tile_count; tile_id++) {
        if (classifier->visited[tile_id] ||
            classifier->tiles[tile_id].klass != SHARP_M2_TILE_MOTION) {
            continue;
        }

        size_t head = 0;
        size_t tail = 0;
        classifier->queue[tail++] = (uint16_t)tile_id;
        classifier->visited[tile_id] = 1u;
        sharp_m2_region_t region;
        memset(&region, 0, sizeof(region));
        region.min_tx = (uint16_t)(tile_id % classifier->cols);
        region.max_tx = region.min_tx;
        region.min_ty = (uint16_t)(tile_id / classifier->cols);
        region.max_ty = region.min_ty;

        while (head < tail) {
            uint16_t cur = classifier->queue[head++];
            uint16_t tx = (uint16_t)(cur % classifier->cols);
            uint16_t ty = (uint16_t)(cur / classifier->cols);
            if (tx < region.min_tx) region.min_tx = tx;
            if (tx > region.max_tx) region.max_tx = tx;
            if (ty < region.min_ty) region.min_ty = ty;
            if (ty > region.max_ty) region.max_ty = ty;
            region.tile_count++;

            int offsets[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
            for (size_t n = 0; n < 4; n++) {
                int nx = (int)tx + offsets[n][0];
                int ny = (int)ty + offsets[n][1];
                if (nx < 0 || ny < 0 || nx >= classifier->cols ||
                    ny >= classifier->rows) {
                    continue;
                }
                uint16_t next = (uint16_t)((uint32_t)ny * classifier->cols +
                                           (uint32_t)nx);
                if (!classifier->visited[next] &&
                    classifier->tiles[next].klass == SHARP_M2_TILE_MOTION) {
                    classifier->visited[next] = 1u;
                    classifier->queue[tail++] = next;
                }
            }
        }

        snap_region_pixels(classifier, &region);

        double best_score = 0.0;
        size_t best_idx = SHARP_M2_MAX_TRACKED_REGIONS;
        for (size_t i = 0; i < SHARP_M2_MAX_TRACKED_REGIONS; i++) {
            if (!classifier->tracked[i].alive || classifier->tracked[i].matched) {
                continue;
            }
            double score =
                region_motion_match_score(&region, &classifier->tracked[i].region);
            if (score > best_score) {
                best_score = score;
                best_idx = i;
            }
        }

        if (best_score > 0.20 && best_idx < SHARP_M2_MAX_TRACKED_REGIONS) {
            sharp_m2_region_t old = classifier->tracked[best_idx].region;
            region.id = old.id;
            double old_area = (double)region_area_tiles(&old);
            double new_area = (double)region_area_tiles(&region);
            double delta = old_area > 0.0 ? fabs(new_area - old_area) / old_area : 1.0;
            region.event = delta > classifier->config.resize_threshold
                               ? SHARP_M2_REGION_RESIZED
                               : SHARP_M2_REGION_STABLE;
            classifier->tracked[best_idx].region = region;
            classifier->tracked[best_idx].matched = 1u;
            if (region.event == SHARP_M2_REGION_RESIZED) {
                result->resized_regions++;
            }
        } else {
            size_t slot = SHARP_M2_MAX_TRACKED_REGIONS;
            for (size_t i = 0; i < SHARP_M2_MAX_TRACKED_REGIONS; i++) {
                if (!classifier->tracked[i].alive) {
                    slot = i;
                    break;
                }
            }
            if (slot < SHARP_M2_MAX_TRACKED_REGIONS) {
                region.id = classifier->next_region_id++;
                region.event = SHARP_M2_REGION_BORN;
                classifier->tracked[slot].region = region;
                classifier->tracked[slot].alive = 1u;
                classifier->tracked[slot].matched = 1u;
                result->born_regions++;
            }
        }

        add_region(classifier, &region);
        result->regions++;
    }

    for (size_t i = 0; i < SHARP_M2_MAX_TRACKED_REGIONS; i++) {
        if (!classifier->tracked[i].alive || classifier->tracked[i].matched) {
            continue;
        }
        sharp_m2_region_t died = classifier->tracked[i].region;
        died.event = SHARP_M2_REGION_DIED;
        add_region(classifier, &died);
        result->died_regions++;

        uint16_t min_ty = died.min_ty > 0 ? (uint16_t)(died.min_ty - 1u) : died.min_ty;
        uint16_t min_tx = died.min_tx > 0 ? (uint16_t)(died.min_tx - 1u) : died.min_tx;
        uint16_t max_ty = died.max_ty + 1u < classifier->rows
                              ? (uint16_t)(died.max_ty + 1u)
                              : died.max_ty;
        uint16_t max_tx = died.max_tx + 1u < classifier->cols
                              ? (uint16_t)(died.max_tx + 1u)
                              : died.max_tx;
        for (uint16_t ty = min_ty; ty <= max_ty; ty++) {
            for (uint16_t tx = min_tx; tx <= max_tx; tx++) {
                uint16_t id = (uint16_t)((uint32_t)ty * classifier->cols + tx);
                if (id < classifier->tile_count) {
                    if (classifier->tiles[id].klass == SHARP_M2_TILE_MOTION) {
                        classifier->tiles[id].klass = SHARP_M2_TILE_PENDING_REFINE;
                    }
                    mark_refine(id, refine_tiles, refine_cap, refine_count, refine_seen);
                }
            }
        }
        classifier->tracked[i].alive = 0u;
    }
}

int sharp_m2_classifier_update(sharp_m2_classifier_t *classifier, uint32_t frame_id,
                               const uint16_t *dirty_tiles,
                               const sharp_m2_tile_probe_t *probes,
                               size_t dirty_count, uint16_t *refine_tiles,
                               size_t refine_cap,
                               sharp_m2_frame_result_t *result) {
    if (classifier == NULL || (dirty_count > 0 && (dirty_tiles == NULL ||
                                                  probes == NULL))) {
        return -1;
    }
    sharp_m2_frame_result_t local_result;
    if (result == NULL) {
        result = &local_result;
    }
    memset(result, 0, sizeof(*result));
    result->frame_id = frame_id;
    result->dirty_tiles = dirty_count;
    memset(classifier->dirty, 0, classifier->tile_count);
    uint8_t *refine_seen = calloc(classifier->tile_count, sizeof(refine_seen[0]));
    if (refine_seen == NULL) {
        return -1;
    }
    size_t refine_count = 0;

    for (size_t i = 0; i < dirty_count; i++) {
        uint16_t tile_id = dirty_tiles[i];
        if (tile_id >= classifier->tile_count) {
            continue;
        }
        classifier->dirty[tile_id] = 1u;
        sharp_m2_tile_state_t *tile = &classifier->tiles[tile_id];
        tile->dirty_streak = tile->dirty_streak < 15u ? tile->dirty_streak + 1u : 15u;
        tile->idle_frames = 0u;
        tile->was_dirty = 1u;
        tile->color_count_probe = probes[i].color_count_probe;
        tile->edge_energy = probes[i].edge_energy;
        tile->text_like = (uint8_t)is_text_like(classifier, &probes[i]);

        if (tile->klass == SHARP_M2_TILE_PENDING_REFINE) {
            tile->klass = SHARP_M2_TILE_MOTION;
        } else if (tile->klass == SHARP_M2_TILE_STATIC) {
            uint8_t threshold = tile->text_like ? classifier->config.text_motion_streak_frames
                                                : classifier->config.motion_streak_frames;
            if (tile->dirty_streak >= threshold) {
                tile->klass = SHARP_M2_TILE_MOTION;
            }
        }
    }

    for (uint32_t tile_id = 0; tile_id < classifier->tile_count; tile_id++) {
        sharp_m2_tile_state_t *tile = &classifier->tiles[tile_id];
        if (!classifier->dirty[tile_id]) {
            tile->dirty_streak = 0u;
            if (tile->idle_frames < 255u) {
                tile->idle_frames++;
            }
            if (tile->klass == SHARP_M2_TILE_MOTION &&
                tile->idle_frames >= classifier->config.settle_frames) {
                tile->klass = SHARP_M2_TILE_PENDING_REFINE;
                mark_refine((uint16_t)tile_id, refine_tiles, refine_cap, &refine_count,
                            refine_seen);
            }
        }

        if (tile->klass == SHARP_M2_TILE_MOTION) {
            result->motion_tiles++;
        } else if (tile->klass == SHARP_M2_TILE_PENDING_REFINE) {
            result->pending_refine_tiles++;
        } else {
            result->static_tiles++;
        }
    }

    build_motion_regions(classifier, result, refine_tiles, refine_cap, &refine_count,
                         refine_seen);
    result->refine_tiles = refine_count <= refine_cap ? refine_count : refine_cap;
    free(refine_seen);
    return 0;
}

void sharp_m2_classifier_mark_refined(sharp_m2_classifier_t *classifier,
                                      const uint16_t *tiles, size_t tile_count) {
    if (classifier == NULL || tiles == NULL) {
        return;
    }
    for (size_t i = 0; i < tile_count; i++) {
        uint16_t tile_id = tiles[i];
        if (tile_id < classifier->tile_count &&
            classifier->tiles[tile_id].klass == SHARP_M2_TILE_PENDING_REFINE) {
            classifier->tiles[tile_id].klass = SHARP_M2_TILE_STATIC;
            classifier->tiles[tile_id].idle_frames = 0u;
        }
    }
}

size_t sharp_m2_classifier_regions(const sharp_m2_classifier_t *classifier,
                                   sharp_m2_region_t *regions, size_t region_cap) {
    if (classifier == NULL) {
        return 0;
    }
    size_t n = classifier->region_count < region_cap ? classifier->region_count
                                                     : region_cap;
    if (regions != NULL && n > 0) {
        memcpy(regions, classifier->regions, n * sizeof(regions[0]));
    }
    return classifier->region_count;
}

sharp_m2_tile_class_t sharp_m2_classifier_tile_class(
    const sharp_m2_classifier_t *classifier, uint16_t tile_id) {
    if (classifier == NULL || tile_id >= classifier->tile_count) {
        return SHARP_M2_TILE_STATIC;
    }
    return classifier->tiles[tile_id].klass;
}

uint8_t sharp_m2_classifier_tile_consecutive_frames(
    const sharp_m2_classifier_t *classifier, uint16_t tile_id) {
    if (classifier == NULL || tile_id >= classifier->tile_count) {
        return 0;
    }
    return classifier->tiles[tile_id].dirty_streak;
}

const char *sharp_m2_tile_class_name(sharp_m2_tile_class_t klass) {
    switch (klass) {
    case SHARP_M2_TILE_STATIC:
        return "STATIC";
    case SHARP_M2_TILE_MOTION:
        return "MOTION";
    case SHARP_M2_TILE_PENDING_REFINE:
        return "PENDING_REFINE";
    }
    return "UNKNOWN";
}

const char *sharp_m2_region_event_name(sharp_m2_region_event_t event) {
    switch (event) {
    case SHARP_M2_REGION_STABLE:
        return "STABLE";
    case SHARP_M2_REGION_BORN:
        return "BORN";
    case SHARP_M2_REGION_RESIZED:
        return "RESIZED";
    case SHARP_M2_REGION_DIED:
        return "DIED";
    }
    return "UNKNOWN";
}
