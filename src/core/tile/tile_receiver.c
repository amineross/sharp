#include "sharp/tile_receiver.h"
#include "sharp/tile_sender.h"

#include "zstd.h"

#include <stdlib.h>
#include <string.h>

static uint32_t read_pixel32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void write_pixel32(uint8_t *p, uint32_t value) {
    memcpy(p, &value, sizeof(value));
}

static uint16_t read_u16(const uint8_t *p) {
    uint16_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint8_t paeth_predictor(uint8_t a, uint8_t b, uint8_t c) {
    int p = (int)a + (int)b - (int)c;
    int pa = abs(p - (int)a);
    int pb = abs(p - (int)b);
    int pc = abs(p - (int)c);
    if (pa <= pb && pa <= pc) {
        return a;
    }
    if (pb <= pc) {
        return b;
    }
    return c;
}

static void paeth_unfilter_bgra_tile(uint8_t *data, uint32_t w, uint32_t h) {
    size_t row_bytes = (size_t)w * 4u;
    for (uint32_t y = 0; y < h; y++) {
        for (size_t x = 0; x < row_bytes; x++) {
            uint8_t left = x >= 4u ? data[(size_t)y * row_bytes + x - 4u] : 0;
            uint8_t up = y > 0 ? data[(size_t)(y - 1u) * row_bytes + x] : 0;
            uint8_t up_left =
                (y > 0 && x >= 4u) ? data[(size_t)(y - 1u) * row_bytes + x - 4u] : 0;
            uint8_t pred = paeth_predictor(left, up, up_left);
            data[(size_t)y * row_bytes + x] =
                (uint8_t)(data[(size_t)y * row_bytes + x] + pred);
        }
    }
}

static void dirty_bounds_add(sharp_tile_dirty_bounds_t *bounds,
                             const sharp_tile_rect_t *rect) {
    if (bounds == NULL || rect == NULL || rect->w == 0 || rect->h == 0) {
        return;
    }
    uint32_t x0 = rect->x;
    uint32_t y0 = rect->y;
    uint32_t x1 = x0 + rect->w;
    uint32_t y1 = y0 + rect->h;
    if (!bounds->valid) {
        bounds->x = x0;
        bounds->y = y0;
        bounds->w = rect->w;
        bounds->h = rect->h;
        bounds->valid = 1;
        return;
    }
    uint32_t bx1 = bounds->x + bounds->w;
    uint32_t by1 = bounds->y + bounds->h;
    uint32_t nx0 = x0 < bounds->x ? x0 : bounds->x;
    uint32_t ny0 = y0 < bounds->y ? y0 : bounds->y;
    uint32_t nx1 = x1 > bx1 ? x1 : bx1;
    uint32_t ny1 = y1 > by1 ? y1 : by1;
    bounds->x = nx0;
    bounds->y = ny0;
    bounds->w = nx1 - nx0;
    bounds->h = ny1 - ny0;
}

static int generation_is_older(uint32_t candidate, uint32_t current) {
    return (int32_t)(candidate - current) < 0;
}

int sharp_tile_receiver_init(sharp_tile_receiver_t *receiver, uint32_t width,
                             uint32_t height) {
    if (receiver == NULL) {
        return -1;
    }
    memset(receiver, 0, sizeof(*receiver));
    if (sharp_framebuf_init(&receiver->fb, width, height) != 0) {
        return -1;
    }
    receiver->reassembler = sharp_tile_reassembler_create(width, height);
    if (receiver->reassembler == NULL) {
        sharp_framebuf_destroy(&receiver->fb);
        return -1;
    }
    receiver->tile_count = sharp_tile_count(width, height);
    receiver->tile_generations = calloc(receiver->tile_count,
                                        sizeof(receiver->tile_generations[0]));
    receiver->tile_hashes =
        calloc(receiver->tile_count, sizeof(receiver->tile_hashes[0]));
    if (receiver->tile_generations == NULL || receiver->tile_hashes == NULL) {
        free(receiver->tile_hashes);
        free(receiver->tile_generations);
        sharp_tile_reassembler_destroy(receiver->reassembler);
        sharp_framebuf_destroy(&receiver->fb);
        memset(receiver, 0, sizeof(*receiver));
        return -1;
    }
    receiver->zstd_dctx = ZSTD_createDCtx();
    if (receiver->zstd_dctx == NULL) {
        free(receiver->tile_hashes);
        free(receiver->tile_generations);
        sharp_tile_reassembler_destroy(receiver->reassembler);
        sharp_framebuf_destroy(&receiver->fb);
        memset(receiver, 0, sizeof(*receiver));
        return -1;
    }
    return 0;
}

void sharp_tile_receiver_destroy(sharp_tile_receiver_t *receiver) {
    if (receiver != NULL) {
        sharp_tile_reassembler_destroy(receiver->reassembler);
        free(receiver->tile_hashes);
        free(receiver->tile_generations);
        if (receiver->zstd_dctx != NULL) {
            ZSTD_freeDCtx((ZSTD_DCtx *)receiver->zstd_dctx);
        }
        sharp_framebuf_destroy(&receiver->fb);
        memset(receiver, 0, sizeof(*receiver));
    }
}

static int decode_and_patch_tile(sharp_tile_receiver_t *receiver,
                                 const shtp_header_t *sh,
                                 const sharp_tile_chunk_header_t *th,
                                 const sharp_tile_rect_t *rect,
                                 const uint8_t *tile_data, size_t tile_len,
                                 int *patched_out,
                                 sharp_tile_dirty_bounds_t *dirty_out) {
    if (th->tile_id >= receiver->tile_count) {
        receiver->stats.invalid_packets++;
        return -1;
    }
    if (generation_is_older(th->generation,
                            receiver->tile_generations[th->tile_id])) {
        receiver->stats.complete_tiles++;
        receiver->stats.stale_tiles++;
        return 0;
    }

    uint8_t decoded[SHARP_TILE_BYTES];
    const uint8_t *patch_data = tile_data;
    size_t patch_len = tile_len;
    if (th->encoding == SHARP_TILE_ENCODING_SOLID) {
        if (tile_len != 4u) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        uint32_t color = read_pixel32(tile_data);
        for (uint32_t i = 0; i < (uint32_t)rect->w * (uint32_t)rect->h; i++) {
            write_pixel32(decoded + (size_t)i * 4u, color);
        }
        patch_data = decoded;
        patch_len = (size_t)rect->w * (size_t)rect->h * 4u;
    } else if (th->encoding == SHARP_TILE_ENCODING_TWOCOLOR) {
        size_t pixels = (size_t)rect->w * (size_t)rect->h;
        size_t bit_len = (pixels + 7u) / 8u;
        if (tile_len != 8u + bit_len) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        uint32_t c0 = read_pixel32(tile_data);
        uint32_t c1 = read_pixel32(tile_data + 4u);
        const uint8_t *bits = tile_data + 8u;
        for (size_t i = 0; i < pixels; i++) {
            uint32_t color = (bits[i / 8u] & (uint8_t)(1u << (i % 8u))) ? c1 : c0;
            write_pixel32(decoded + i * 4u, color);
        }
        patch_data = decoded;
        patch_len = pixels * 4u;
    } else if (th->encoding == SHARP_TILE_ENCODING_SPARSE_BGRA) {
        size_t pixels = (size_t)rect->w * (size_t)rect->h;
        if (tile_len < 6u || (tile_len - 6u) % 6u != 0u) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        uint32_t base = read_pixel32(tile_data);
        uint16_t override_count = read_u16(tile_data + 4u);
        if (tile_len != 6u + (size_t)override_count * 6u) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        for (size_t i = 0; i < pixels; i++) {
            write_pixel32(decoded + i * 4u, base);
        }
        const uint8_t *entry = tile_data + 6u;
        for (uint16_t i = 0; i < override_count; i++) {
            uint16_t pixel_index = read_u16(entry);
            if (pixel_index >= pixels) {
                receiver->stats.invalid_packets++;
                return -1;
            }
            uint32_t color = read_pixel32(entry + 2u);
            write_pixel32(decoded + (size_t)pixel_index * 4u, color);
            entry += 6u;
        }
        patch_data = decoded;
        patch_len = pixels * 4u;
    } else if (th->encoding == SHARP_TILE_ENCODING_RLE_BGRA) {
        size_t pixels = (size_t)rect->w * (size_t)rect->h;
        if (tile_len == 0 || tile_len % 6u != 0u) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        size_t out_pixel = 0;
        const uint8_t *entry = tile_data;
        const uint8_t *end = tile_data + tile_len;
        while (entry < end) {
            uint16_t run = read_u16(entry);
            uint32_t color = read_pixel32(entry + 2u);
            if (run == 0 || out_pixel + run > pixels) {
                receiver->stats.invalid_packets++;
                return -1;
            }
            for (uint16_t i = 0; i < run; i++) {
                write_pixel32(decoded + (out_pixel + i) * 4u, color);
            }
            out_pixel += run;
            entry += 6u;
        }
        if (out_pixel != pixels) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        patch_data = decoded;
        patch_len = pixels * 4u;
    } else if (th->encoding == SHARP_TILE_ENCODING_ZSTD) {
        size_t decoded_len = (size_t)rect->w * (size_t)rect->h * 4u;
        if (receiver->zstd_dctx == NULL || tile_len == 0 ||
            decoded_len > sizeof(decoded)) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        size_t zret = ZSTD_decompressDCtx((ZSTD_DCtx *)receiver->zstd_dctx,
                                          decoded, decoded_len, tile_data, tile_len);
        if (ZSTD_isError(zret) || zret != decoded_len) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        paeth_unfilter_bgra_tile(decoded, rect->w, rect->h);
        patch_data = decoded;
        patch_len = decoded_len;
    } else if (th->encoding != SHARP_TILE_ENCODING_BGRA_RAW) {
        receiver->stats.invalid_packets++;
        return -1;
    }

    if (sharp_framebuf_patch_tile(&receiver->fb, rect, patch_data, patch_len) != 0) {
        receiver->stats.invalid_packets++;
        return -1;
    }
    receiver->tile_generations[th->tile_id] = th->generation;
    receiver->tile_hashes[th->tile_id] =
        sharp_tile_hash_bgra(receiver->fb.pixels, receiver->fb.stride, rect);
    receiver->stats.complete_tiles++;
    receiver->stats.patched_tiles++;
    receiver->stats.last_patched_frame = sh->frame_id;
    receiver->stats.have_last_patched_frame = 1;
    if (!receiver->stats.have_newest_patched_frame ||
        sh->frame_id > receiver->stats.newest_patched_frame) {
        receiver->stats.newest_patched_frame = sh->frame_id;
        receiver->stats.have_newest_patched_frame = 1;
    }
    dirty_bounds_add(dirty_out, rect);
    if (patched_out != NULL) {
        *patched_out = 1;
    }
    return 0;
}

static int handle_tile_payload(sharp_tile_receiver_t *receiver, const shtp_header_t *sh,
                               const uint8_t *payload, int *patched_out,
                               sharp_tile_dirty_bounds_t *dirty_out) {
    if (sh->payload_len < sizeof(sharp_tile_chunk_header_t)) {
        receiver->stats.invalid_packets++;
        return -1;
    }

    sharp_tile_chunk_header_t th;
    memcpy(&th, payload, sizeof(th));
    sharp_tile_chunk_header_wire_to_host(&th);

    const uint8_t *chunk = payload + sizeof(th);
    size_t chunk_len = sh->payload_len - sizeof(th);
    if (sharp_tile_reassembler_push(receiver->reassembler, &th, sh->chunk_id,
                                    sh->chunk_count, chunk, chunk_len) != 0) {
        receiver->stats.invalid_packets++;
        return -1;
    }

    receiver->stats.tile_chunks++;

    sharp_tile_rect_t rect;
    const uint8_t *tile_data = NULL;
    size_t tile_len = 0;
    uint32_t generation = 0;
    if (sharp_tile_reassembler_take_complete(receiver->reassembler, th.tile_id, &rect,
                                             &tile_data, &tile_len, &generation)) {
        (void)generation;
        return decode_and_patch_tile(receiver, sh, &th, &rect, tile_data, tile_len,
                                     patched_out, dirty_out);
    }

    return 0;
}

static int handle_tile_batch_payload(sharp_tile_receiver_t *receiver,
                                     const shtp_header_t *sh,
                                     const uint8_t *payload, int *patched_out,
                                     sharp_tile_dirty_bounds_t *dirty_out) {
    size_t offset = 0;
    uint16_t records = 0;
    while (offset < sh->payload_len) {
        if (sh->payload_len - offset < sizeof(sharp_tile_chunk_header_t)) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        sharp_tile_chunk_header_t th;
        memcpy(&th, payload + offset, sizeof(th));
        sharp_tile_chunk_header_wire_to_host(&th);
        offset += sizeof(th);
        if (!sharp_tile_chunk_header_is_valid(&th, receiver->fb.width,
                                              receiver->fb.height) ||
            th.offset != 0 || th.chunk_len != th.total_len ||
            sh->payload_len - offset < th.chunk_len) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        const uint8_t *tile_data = payload + offset;
        if (sharp_tile_checksum(tile_data, th.total_len) != th.checksum) {
            receiver->stats.invalid_packets++;
            return -1;
        }
        sharp_tile_rect_t rect;
        rect.tile_id = th.tile_id;
        rect.x = th.x;
        rect.y = th.y;
        rect.w = th.w;
        rect.h = th.h;
        receiver->stats.tile_chunks++;
        if (decode_and_patch_tile(receiver, sh, &th, &rect, tile_data, th.total_len,
                                  patched_out, dirty_out) != 0) {
            return -1;
        }
        offset += th.chunk_len;
        records++;
    }
    if (records == 0 || (sh->chunk_count != 0 && records != sh->chunk_count)) {
        receiver->stats.invalid_packets++;
        return -1;
    }
    return 0;
}

int sharp_tile_receiver_handle_datagram(sharp_tile_receiver_t *receiver,
                                        const uint8_t *datagram, size_t datagram_len,
                                        int *patched_out,
                                        sharp_tile_dirty_bounds_t *dirty_out) {
    if (patched_out != NULL) {
        *patched_out = 0;
    }
    if (dirty_out != NULL) {
        memset(dirty_out, 0, sizeof(*dirty_out));
    }
    if (receiver == NULL || datagram == NULL) {
        return -1;
    }

    receiver->stats.packets++;
    receiver->stats.bytes += datagram_len;
    if (datagram_len < sizeof(shtp_header_t)) {
        receiver->stats.invalid_packets++;
        return -1;
    }

    shtp_header_t sh;
    memcpy(&sh, datagram, sizeof(sh));
    shtp_header_wire_to_host(&sh);
    if (!shtp_header_is_valid(&sh, datagram_len)) {
        receiver->stats.invalid_packets++;
        return -1;
    }

    if (sh.type == SHTP_PACKET_BYE) {
        receiver->stats.final_frame = sh.frame_id;
        receiver->stats.have_bye = 1;
        return 0;
    }

    if (sh.type == SHTP_PACKET_FRAME_END) {
        receiver->stats.frame_end = sh.frame_id;
        receiver->stats.frame_end_send_time_ns = sh.send_time_ns;
        receiver->stats.frame_end_tile_count = sh.chunk_count;
        receiver->stats.have_frame_end = 1;
        receiver->stats.frame_end_packets++;
        return 0;
    }

    if (sh.type != SHTP_PACKET_DATA) {
        receiver->stats.ignored_packets++;
        return 0;
    }

    if (sh.payload_type == SHTP_PAYLOAD_BGRA_TILE) {
        return handle_tile_payload(receiver, &sh, datagram + sizeof(shtp_header_t),
                                   patched_out, dirty_out);
    }
    if (sh.payload_type == SHTP_PAYLOAD_TILE_BATCH) {
        return handle_tile_batch_payload(receiver, &sh,
                                         datagram + sizeof(shtp_header_t),
                                         patched_out, dirty_out);
    }
    receiver->stats.ignored_packets++;
    return 0;
}

uint32_t sharp_tile_receiver_tile_generation(const sharp_tile_receiver_t *receiver,
                                             uint16_t tile_id) {
    if (receiver == NULL || receiver->tile_generations == NULL ||
        tile_id >= receiver->tile_count) {
        return 0;
    }
    return receiver->tile_generations[tile_id];
}

uint64_t sharp_tile_receiver_tile_hash(const sharp_tile_receiver_t *receiver,
                                       uint16_t tile_id) {
    if (receiver == NULL || receiver->tile_hashes == NULL ||
        tile_id >= receiver->tile_count) {
        return 0;
    }
    return receiver->tile_hashes[tile_id];
}

size_t sharp_tile_receiver_validate_synthetic(const sharp_tile_receiver_t *receiver) {
    if (receiver == NULL || !receiver->stats.have_bye) {
        return (size_t)-1;
    }
    return sharp_framebuf_count_synthetic_mismatches(&receiver->fb,
                                                     receiver->stats.final_frame);
}
