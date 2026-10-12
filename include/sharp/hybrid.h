#ifndef SHARP_HYBRID_H
#define SHARP_HYBRID_H
#include <stdint.h>
#include <stddef.h>
#include "sharp/tile.h"

/* Each manifest is independent. Missing fragments never authorize an overlay. */
#define SHARP_HYBRID_MAX_TILES 4096u
#define SHARP_HYBRID_MAP_SLOTS 64u
#define SHARP_HYBRID_CHUNK_TILES 256u
#define SHARP_HYBRID_STATIC 1u
#define SHARP_HYBRID_COMMITTED 2u
#define SHARP_HYBRID_MAGIC 0x48594231u

enum { SHARP_HYBRID_HELLO = 1, SHARP_HYBRID_OFFER, SHARP_HYBRID_CONFIRM,
       SHARP_HYBRID_READY, SHARP_HYBRID_MAP, SHARP_HYBRID_ACK };
typedef struct sharp_hybrid_message {
    uint64_t session, nonce;
    uint32_t frame;
    uint16_t kind, flags, width, height, total, first, count;
    uint32_t versions[SHARP_HYBRID_CHUNK_TILES];
} sharp_hybrid_message_t;
/* Wire helpers also validate bounds, fragment shape and checksum. */
size_t sharp_hybrid_encode(uint8_t *dst, size_t cap, const sharp_hybrid_message_t *m);
int sharp_hybrid_decode(sharp_hybrid_message_t *m, const uint8_t *src, size_t len);

typedef struct sharp_hybrid_map {
    uint32_t frame;
    uint16_t flags, received;
    uint8_t valid, complete;
    uint32_t versions[SHARP_HYBRID_MAX_TILES];
} sharp_hybrid_map_t;
typedef struct sharp_hybrid_receiver {
    uint64_t session;
    uint32_t latest_frame, latest_video_frame, committed_frame;
    uint16_t width, height, total;
    sharp_hybrid_map_t maps[SHARP_HYBRID_MAP_SLOTS];
} sharp_hybrid_receiver_t;
int sharp_hybrid_receiver_init(sharp_hybrid_receiver_t *r, uint64_t session,
                              uint16_t width, uint16_t height);
int sharp_hybrid_accept_map(sharp_hybrid_receiver_t *r, const sharp_hybrid_message_t *m);
const sharp_hybrid_map_t *sharp_hybrid_find_map(const sharp_hybrid_receiver_t *r, uint32_t frame);
/* Tile generations identify the capture owning the cached pixels. A manifest's
 * version is the capture where those pixels last changed. This closed interval
 * proves equality without requiring a hash or a second tile wire format. */
int sharp_hybrid_tile_matches(const sharp_hybrid_map_t *m, uint32_t tile,
                             uint32_t cached_capture);
uint32_t sharp_hybrid_video_mask(const sharp_hybrid_receiver_t *r,
                                const sharp_hybrid_map_t *m,
                                const uint32_t *cached_captures, uint8_t *mask);
int sharp_hybrid_static_ready(const sharp_hybrid_receiver_t *r,
                             const sharp_hybrid_map_t *m,
                             const uint32_t *cached_captures);

typedef struct sharp_hybrid_source {
    uint16_t width, height, total;
    uint32_t frame;
    uint8_t *pixels;
    uint32_t versions[SHARP_HYBRID_MAX_TILES];
    uint64_t changed_ns[SHARP_HYBRID_MAX_TILES];
    uint8_t streak[SHARP_HYBRID_MAX_TILES];
} sharp_hybrid_source_t;
int sharp_hybrid_source_init(sharp_hybrid_source_t *s, uint16_t width, uint16_t height);
void sharp_hybrid_source_destroy(sharp_hybrid_source_t *s);
/* Exact byte comparisons; capture dirty-rectangle hints cannot authorize reuse. */
uint32_t sharp_hybrid_source_update(sharp_hybrid_source_t *s, const uint8_t *pixels,
                                  uint32_t stride, uint32_t frame, uint64_t now,
                                  uint32_t *repeated);
/* A scene change is at least one eighth of the tiles, and at least 8.
 * A caret or a clock is smaller and stays on lossless tiles. */
int sharp_hybrid_scene_change(uint32_t changed, uint32_t total);
/* Sustained local motion: at least min_tiles tiles that changed on three or
 * more consecutive captures (0 selects SHARP_HYBRID_REPEAT_TILES_DEFAULT).
 * A blinking caret or a typed word touches one or two tiles and stays on
 * lossless tiles; a video playing in a window (480x270 covers about 40
 * tiles of 64 px) switches to video. */
#define SHARP_HYBRID_REPEAT_TILES_DEFAULT 8u
int sharp_hybrid_repeated_motion(uint32_t repeated, uint32_t min_tiles);
/* Tiles touched by motion while video is active. Exiting video repairs these
 * first, from the motion centroid outward; everything else is already
 * verified. The centroid is accumulated in tile units. */
typedef struct sharp_hybrid_dirty {
    uint8_t bits[SHARP_HYBRID_MAX_TILES / 8u];
    uint32_t count;
    uint64_t sum_x, sum_y;
} sharp_hybrid_dirty_t;
void sharp_hybrid_dirty_reset(sharp_hybrid_dirty_t *d);
int sharp_hybrid_dirty_test(const sharp_hybrid_dirty_t *d, uint32_t tile);
/* Marks one tile; returns 1 when it was newly marked. */
int sharp_hybrid_dirty_mark(sharp_hybrid_dirty_t *d, uint32_t tile, uint32_t cols);
/* Marks every tile whose version equals frame (the tiles that frame changed). */
uint32_t sharp_hybrid_dirty_mark_frame(sharp_hybrid_dirty_t *d,
                                       const sharp_hybrid_source_t *s, uint32_t frame);
/* Drops tiles the receiver already acknowledged at their current version
 * (acked[t] != 0 and acked[t] >= versions[t]). A tile touched once during
 * video, e.g. by the entry frame, and then refined by the background scan
 * while video kept running needs no exit repair. Returns tiles dropped. */
uint32_t sharp_hybrid_dirty_prune_acked(sharp_hybrid_dirty_t *d,
                                        const sharp_hybrid_source_t *s,
                                        const uint32_t *acked);
/* Writes the dirty tiles to order[] (capacity SHARP_HYBRID_MAX_TILES), nearest
 * 2x2 tile group to the motion centroid first, so the receiver's 128x128
 * publish groups complete as early as possible. Ties break by tile id, so the
 * order is deterministic. Returns the number of tiles written. */
uint32_t sharp_hybrid_repair_order(const sharp_hybrid_dirty_t *d, uint16_t width,
                                   uint16_t height, uint16_t *order);
#endif
