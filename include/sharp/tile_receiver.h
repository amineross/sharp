#ifndef SHARP_TILE_RECEIVER_H
#define SHARP_TILE_RECEIVER_H

#include "sharp/framebuf.h"
#include "sharp/shtp_protocol.h"
#include "sharp/tile.h"

#include <stddef.h>
#include <stdint.h>

typedef struct sharp_tile_receiver_stats {
    uint64_t packets;
    uint64_t tile_chunks;
    uint64_t complete_tiles;
    uint64_t patched_tiles;
    uint64_t stale_tiles;
    uint64_t invalid_packets;
    uint64_t ignored_packets;
    uint64_t bytes;
    uint64_t frame_end_packets;
    uint64_t frame_end_send_time_ns;
    uint32_t frame_end;
    uint16_t frame_end_tile_count;
    uint32_t newest_patched_frame;
    uint32_t last_patched_frame;
    uint32_t final_frame;
    int have_frame_end;
    int have_newest_patched_frame;
    int have_last_patched_frame;
    int have_bye;
} sharp_tile_receiver_stats_t;

typedef struct sharp_tile_receiver {
    sharp_framebuf_t fb;
    sharp_tile_reassembler_t *reassembler;
    void *zstd_dctx;
    uint32_t tile_count;
    uint32_t *tile_generations;
    uint64_t *tile_hashes;
    sharp_tile_receiver_stats_t stats;
} sharp_tile_receiver_t;

int sharp_tile_receiver_init(sharp_tile_receiver_t *receiver, uint32_t width,
                             uint32_t height);
void sharp_tile_receiver_destroy(sharp_tile_receiver_t *receiver);
int sharp_tile_receiver_handle_datagram(sharp_tile_receiver_t *receiver,
                                        const uint8_t *datagram, size_t datagram_len,
                                        int *patched_out,
                                        sharp_tile_dirty_bounds_t *dirty_out);
uint32_t sharp_tile_receiver_tile_generation(const sharp_tile_receiver_t *receiver,
                                             uint16_t tile_id);
uint64_t sharp_tile_receiver_tile_hash(const sharp_tile_receiver_t *receiver,
                                       uint16_t tile_id);
size_t sharp_tile_receiver_validate_synthetic(const sharp_tile_receiver_t *receiver);

#endif
