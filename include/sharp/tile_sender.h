#ifndef SHARP_TILE_SENDER_H
#define SHARP_TILE_SENDER_H

#include <stddef.h>
#include <stdint.h>

#include "sharp/tile.h"

typedef struct sharp_tile_sender_stats {
    uint64_t packets;
    uint64_t bytes;
    uint64_t frames;
    uint64_t tiles;
    uint64_t batch_packets;
    uint64_t batch_tiles;
    uint64_t solid_tiles;
    uint64_t twocolor_tiles;
    uint64_t sparse_tiles;
    uint64_t rle_tiles;
    uint64_t raw_tiles;
    uint64_t zstd_tiles;
} sharp_tile_sender_stats_t;

typedef struct sharp_tile_sender_codec {
    void *zstd_cctx;
    int zstd_enabled;
    uint64_t session;
} sharp_tile_sender_codec_t;

typedef struct sharp_tile_batch_writer {
    uint8_t *packet;
    size_t payload_cap;
    size_t payload_len;
    uint16_t tile_count;
    uint64_t solid_tiles;
    uint64_t twocolor_tiles;
    uint64_t sparse_tiles;
    uint64_t rle_tiles;
    uint64_t raw_tiles;
    uint64_t zstd_tiles;
    int per_record_generations;
    sharp_tile_sender_codec_t codec;
} sharp_tile_batch_writer_t;

typedef struct sharp_tile_dirty_map {
    uint32_t width;
    uint32_t height;
    uint32_t tile_count;
    uint64_t *hashes;
    uint8_t *candidates;
    int initialized;
} sharp_tile_dirty_map_t;

typedef struct sharp_dirty_rect {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
} sharp_dirty_rect_t;

int sharp_tile_dirty_map_init(sharp_tile_dirty_map_t *map, uint32_t width,
                              uint32_t height);
void sharp_tile_dirty_map_destroy(sharp_tile_dirty_map_t *map);
uint64_t sharp_tile_hash_bgra(const uint8_t *bgra, uint32_t stride,
                              const sharp_tile_rect_t *rect);
size_t sharp_tile_dirty_map_collect(sharp_tile_dirty_map_t *map, const uint8_t *bgra,
                                    uint32_t stride, int force_all, uint16_t *out,
                                    size_t out_cap);
size_t sharp_tile_dirty_map_collect_rects(sharp_tile_dirty_map_t *map,
                                          const uint8_t *bgra, uint32_t stride,
                                          const sharp_dirty_rect_t *rects,
                                          size_t rect_count, int force_all,
                                          uint16_t *out, size_t out_cap,
                                          size_t *candidate_tiles_out,
                                          size_t *unchanged_tiles_out);
int sharp_tile_sender_send_bgra_tile(int fd, uint32_t width, uint32_t height,
                                     uint32_t frame_id, uint16_t tile_id,
                                     const uint8_t *bgra, uint32_t stride,
                                     uint32_t *sequence, unsigned int payload_size,
                                     sharp_tile_sender_stats_t *stats);
int sharp_tile_sender_send_bgra_tile_pixels(int fd, uint32_t frame_id,
                                            const sharp_tile_rect_t *rect,
                                            const uint8_t *bgra,
                                            uint32_t stride,
                                            uint32_t *sequence,
                                            unsigned int payload_size,
                                            sharp_tile_sender_stats_t *stats);
int sharp_tile_sender_send_bgra_tile_pixels_with_codec(
    int fd, uint32_t frame_id, const sharp_tile_rect_t *rect,
    const uint8_t *bgra, uint32_t stride, uint32_t *sequence,
    unsigned int payload_size, sharp_tile_sender_stats_t *stats,
    const sharp_tile_sender_codec_t *codec);
int sharp_tile_sender_send_bgra_tile_pixels_generation(
    int fd, uint32_t frame_id, uint32_t generation, const sharp_tile_rect_t *rect,
    const uint8_t *bgra, uint32_t stride, uint32_t *sequence,
    unsigned int payload_size, sharp_tile_sender_stats_t *stats,
    const sharp_tile_sender_codec_t *codec);
int sharp_tile_batch_writer_begin(sharp_tile_batch_writer_t *writer,
                                  uint8_t *packet_buf,
                                  unsigned int payload_size);
int sharp_tile_batch_writer_begin_with_codec(
    sharp_tile_batch_writer_t *writer, uint8_t *packet_buf,
    unsigned int payload_size, const sharp_tile_sender_codec_t *codec);
int sharp_tile_batch_writer_add(sharp_tile_batch_writer_t *writer,
                                const sharp_tile_rect_t *rect,
                                const uint8_t *bgra, uint32_t stride);
int sharp_tile_batch_writer_add_with_generation(
    sharp_tile_batch_writer_t *writer, uint32_t generation,
    const sharp_tile_rect_t *rect, const uint8_t *bgra, uint32_t stride);
int sharp_tile_batch_writer_flush(int fd, sharp_tile_batch_writer_t *writer,
                                  uint32_t frame_id, uint32_t *sequence,
                                  sharp_tile_sender_stats_t *stats);
/* Encode once, then append, flush a full batch, or send a chunked tile.
 * The caller flushes the final pending batch and paces emitted byte counts. */
int sharp_tile_batch_writer_send_pixels(
    int fd, sharp_tile_batch_writer_t *writer, uint32_t frame_id,
    uint32_t generation, const sharp_tile_rect_t *rect, const uint8_t *bgra,
    uint32_t stride, uint32_t *sequence, sharp_tile_sender_stats_t *stats);
void *sharp_tile_zstd_cctx_create(void);
void sharp_tile_zstd_cctx_destroy(void *cctx);
int sharp_tile_sender_send_frame_end(int fd, uint32_t frame_id, uint16_t tile_count,
                                     uint32_t *sequence);
int sharp_tile_sender_send_bye(int fd, uint32_t frame_id, uint32_t *sequence);

#endif
