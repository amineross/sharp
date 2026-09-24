#include "sharp/tile_sender.h"

#include "sharp/shtp_protocol.h"
#include "sharp/shtp_time.h"
#include "sharp/tile.h"

#include "zstd.h"

#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

int sharp_tile_dirty_map_init(sharp_tile_dirty_map_t *map, uint32_t width,
                              uint32_t height) {
    if (map == NULL || width == 0 || height == 0) {
        return -1;
    }
    memset(map, 0, sizeof(*map));
    map->width = width;
    map->height = height;
    map->tile_count = sharp_tile_count(width, height);
    map->hashes = calloc(map->tile_count, sizeof(map->hashes[0]));
    map->candidates = calloc(map->tile_count, sizeof(map->candidates[0]));
    if (map->hashes == NULL || map->candidates == NULL) {
        free(map->hashes);
        free(map->candidates);
        memset(map, 0, sizeof(*map));
        return -1;
    }
    return 0;
}

void sharp_tile_dirty_map_destroy(sharp_tile_dirty_map_t *map) {
    if (map != NULL) {
        free(map->hashes);
        free(map->candidates);
        memset(map, 0, sizeof(*map));
    }
}

static uint64_t hash_mix64(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}

uint64_t sharp_tile_hash_bgra(const uint8_t *bgra, uint32_t stride,
                              const sharp_tile_rect_t *rect) {
    uint64_t hash = 1469598103934665603ULL;
    hash = hash_mix64(hash, rect->w);
    hash = hash_mix64(hash, rect->h);
    for (uint32_t row = 0; row < rect->h; row++) {
        const uint8_t *src = bgra + ((size_t)rect->y + row) * stride +
                             (size_t)rect->x * 4u;
        size_t row_bytes = (size_t)rect->w * 4u;
        size_t offset = 0;
        while (offset + sizeof(uint64_t) <= row_bytes) {
            uint64_t word;
            memcpy(&word, src + offset, sizeof(word));
            hash = hash_mix64(hash, word);
            offset += sizeof(word);
        }
        if (offset < row_bytes) {
            uint64_t tail = 0;
            memcpy(&tail, src + offset, row_bytes - offset);
            hash = hash_mix64(hash, tail);
        }
    }
    return hash;
}

size_t sharp_tile_dirty_map_collect(sharp_tile_dirty_map_t *map, const uint8_t *bgra,
                                    uint32_t stride, int force_all, uint16_t *out,
                                    size_t out_cap) {
    if (map == NULL || bgra == NULL || out == NULL || stride < map->width * 4u) {
        return 0;
    }

    size_t count = 0;
    for (uint32_t tile_id = 0; tile_id < map->tile_count; tile_id++) {
        sharp_tile_rect_t rect;
        if (sharp_tile_rect_for_id(map->width, map->height, (uint16_t)tile_id, &rect) !=
            0) {
            continue;
        }
        uint64_t hash = sharp_tile_hash_bgra(bgra, stride, &rect);
        if (force_all || !map->initialized || map->hashes[tile_id] != hash) {
            map->hashes[tile_id] = hash;
            if (count < out_cap) {
                out[count++] = (uint16_t)tile_id;
            }
        }
    }
    map->initialized = 1;
    return count;
}

static void mark_tile_candidate(uint8_t *candidates, uint32_t tile_count,
                                uint16_t tile_id, size_t *candidate_count) {
    if (tile_id >= tile_count || candidates[tile_id]) {
        return;
    }
    candidates[tile_id] = 1u;
    (*candidate_count)++;
}

size_t sharp_tile_dirty_map_collect_rects(sharp_tile_dirty_map_t *map,
                                          const uint8_t *bgra, uint32_t stride,
                                          const sharp_dirty_rect_t *rects,
                                          size_t rect_count, int force_all,
                                          uint16_t *out, size_t out_cap,
                                          size_t *candidate_tiles_out,
                                          size_t *unchanged_tiles_out) {
    if (candidate_tiles_out != NULL) {
        *candidate_tiles_out = 0;
    }
    if (unchanged_tiles_out != NULL) {
        *unchanged_tiles_out = 0;
    }
    if (map == NULL || bgra == NULL || out == NULL || stride < map->width * 4u) {
        return 0;
    }

    if (force_all || !map->initialized) {
        size_t count = sharp_tile_dirty_map_collect(map, bgra, stride, 1, out, out_cap);
        if (candidate_tiles_out != NULL) {
            *candidate_tiles_out = map->tile_count;
        }
        return count;
    }

    if (rects == NULL || rect_count == 0) {
        return 0;
    }

    if (map->candidates == NULL) {
        return 0;
    }
    memset(map->candidates, 0, (size_t)map->tile_count * sizeof(map->candidates[0]));

    uint16_t cols = sharp_tile_cols(map->width);
    size_t candidate_count = 0;
    for (size_t i = 0; i < rect_count; i++) {
        if (rects[i].w == 0 || rects[i].h == 0 ||
            rects[i].x >= map->width || rects[i].y >= map->height) {
            continue;
        }

        uint32_t x1 = rects[i].x + rects[i].w;
        uint32_t y1 = rects[i].y + rects[i].h;
        if (x1 < rects[i].x || x1 > map->width) {
            x1 = map->width;
        }
        if (y1 < rects[i].y || y1 > map->height) {
            y1 = map->height;
        }
        if (x1 <= rects[i].x || y1 <= rects[i].y) {
            continue;
        }

        uint32_t tx0 = rects[i].x / SHARP_TILE_SIZE;
        uint32_t ty0 = rects[i].y / SHARP_TILE_SIZE;
        uint32_t tx1 = (x1 - 1u) / SHARP_TILE_SIZE;
        uint32_t ty1 = (y1 - 1u) / SHARP_TILE_SIZE;
        for (uint32_t ty = ty0; ty <= ty1; ty++) {
            for (uint32_t tx = tx0; tx <= tx1; tx++) {
                mark_tile_candidate(map->candidates, map->tile_count,
                                    (uint16_t)(ty * cols + tx), &candidate_count);
            }
        }
    }

    size_t count = 0;
    size_t unchanged = 0;
    for (uint32_t tile_id = 0; tile_id < map->tile_count; tile_id++) {
        if (!map->candidates[tile_id]) {
            continue;
        }
        sharp_tile_rect_t rect;
        if (sharp_tile_rect_for_id(map->width, map->height, (uint16_t)tile_id, &rect) !=
            0) {
            continue;
        }
        uint64_t hash = sharp_tile_hash_bgra(bgra, stride, &rect);
        if (map->hashes[tile_id] != hash) {
            map->hashes[tile_id] = hash;
            if (count < out_cap) {
                out[count++] = (uint16_t)tile_id;
            }
        } else {
            unchanged++;
        }
    }

    if (candidate_tiles_out != NULL) {
        *candidate_tiles_out = candidate_count;
    }
    if (unchanged_tiles_out != NULL) {
        *unchanged_tiles_out = unchanged;
    }
    return count;
}

static void make_shtp_header(shtp_header_t *h, uint8_t payload_type,
                             uint32_t sequence, uint32_t frame_id,
                             uint16_t chunk_id, uint16_t chunk_count,
                             uint32_t payload_len) {
    memset(h, 0, sizeof(*h));
    h->magic = SHTP_MAGIC;
    h->version = SHTP_VERSION;
    h->header_bytes = SHTP_HEADER_BYTES;
    h->type = SHTP_PACKET_DATA;
    h->payload_type = payload_type;
    h->sequence = sequence;
    h->frame_id = frame_id;
    h->chunk_id = chunk_id;
    h->chunk_count = chunk_count;
    h->payload_len = payload_len;
    h->send_time_ns = shtp_now_ns();
}

static void add_encoding_stats(sharp_tile_sender_stats_t *stats,
                               sharp_tile_encoding_t encoding) {
    if (stats == NULL) {
        return;
    }
    stats->tiles++;
    if (encoding == SHARP_TILE_ENCODING_SOLID) {
        stats->solid_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_TWOCOLOR) {
        stats->twocolor_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_SPARSE_BGRA) {
        stats->sparse_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_RLE_BGRA) {
        stats->rle_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_ZSTD) {
        stats->zstd_tiles++;
    } else {
        stats->raw_tiles++;
    }
}

void *sharp_tile_zstd_cctx_create(void) {
    return ZSTD_createCCtx();
}

void sharp_tile_zstd_cctx_destroy(void *cctx) {
    if (cctx != NULL) {
        ZSTD_freeCCtx((ZSTD_CCtx *)cctx);
    }
}

static int send_control_packet(int fd, uint8_t type, uint32_t frame_id,
                               uint16_t chunk_count,
                               uint32_t *sequence) {
    if (sequence == NULL) {
        return -1;
    }
    shtp_header_t h;
    memset(&h, 0, sizeof(h));
    h.magic = SHTP_MAGIC;
    h.version = SHTP_VERSION;
    h.header_bytes = SHTP_HEADER_BYTES;
    h.type = type;
    h.payload_type = SHTP_PAYLOAD_CONTROL;
    h.sequence = (*sequence)++;
    h.frame_id = frame_id;
    h.chunk_count = chunk_count;
    h.send_time_ns = shtp_now_ns();
    shtp_header_host_to_wire(&h);
    return send(fd, &h, sizeof(h), 0) == (ssize_t)sizeof(h) ? 0 : -1;
}

static uint32_t read_pixel32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void write_pixel32(uint8_t *p, uint32_t value) {
    memcpy(p, &value, sizeof(value));
}

static void write_u16(uint8_t *p, uint16_t value) {
    memcpy(p, &value, sizeof(value));
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

static void paeth_filter_bgra_tile(const uint8_t *raw, uint32_t w, uint32_t h,
                                   uint8_t *out) {
    size_t row_bytes = (size_t)w * 4u;
    for (uint32_t y = 0; y < h; y++) {
        for (size_t x = 0; x < row_bytes; x++) {
            uint8_t left = x >= 4u ? raw[(size_t)y * row_bytes + x - 4u] : 0;
            uint8_t up = y > 0 ? raw[(size_t)(y - 1u) * row_bytes + x] : 0;
            uint8_t up_left =
                (y > 0 && x >= 4u) ? raw[(size_t)(y - 1u) * row_bytes + x - 4u] : 0;
            uint8_t pred = paeth_predictor(left, up, up_left);
            out[(size_t)y * row_bytes + x] =
                (uint8_t)(raw[(size_t)y * row_bytes + x] - pred);
        }
    }
}

static int maybe_encode_zstd_tile(const sharp_tile_rect_t *rect,
                                  const uint8_t *raw, size_t raw_len,
                                  uint8_t *out, size_t *len_in_out,
                                  sharp_tile_encoding_t *encoding_in_out,
                                  const sharp_tile_sender_codec_t *codec) {
    if (rect == NULL || raw == NULL || out == NULL || len_in_out == NULL ||
        encoding_in_out == NULL || codec == NULL || !codec->zstd_enabled ||
        codec->zstd_cctx == NULL || raw_len == 0 || raw_len > SHARP_TILE_BYTES) {
        return 0;
    }

    uint8_t filtered[SHARP_TILE_BYTES];
    uint8_t compressed[SHARP_TILE_BYTES];
    paeth_filter_bgra_tile(raw, rect->w, rect->h, filtered);
    size_t compressed_len =
        ZSTD_compressCCtx((ZSTD_CCtx *)codec->zstd_cctx, compressed,
                          sizeof(compressed), filtered, raw_len, 1);
    if (ZSTD_isError(compressed_len) || compressed_len >= *len_in_out) {
        return 0;
    }

    memcpy(out, compressed, compressed_len);
    *len_in_out = compressed_len;
    *encoding_in_out = SHARP_TILE_ENCODING_ZSTD;
    return 1;
}

static int copy_encoded_tile_pixels(const sharp_tile_rect_t *rect,
                                    const uint8_t *bgra, uint32_t stride,
                                    uint8_t *out, size_t *len_out,
                                    uint32_t *checksum_out,
                                    sharp_tile_encoding_t *encoding_out,
                                    const sharp_tile_sender_codec_t *codec) {
    if (rect == NULL || bgra == NULL || out == NULL ||
        rect->w == 0 || rect->h == 0 || rect->w > SHARP_TILE_SIZE ||
        rect->h > SHARP_TILE_SIZE || stride < (uint32_t)rect->w * 4u) {
        return -1;
    }

    size_t offset = 0;
    uint32_t colors[2] = {0, 0};
    uint8_t color_count = 0;
    uint8_t packed_bits[(SHARP_TILE_SIZE * SHARP_TILE_SIZE + 7u) / 8u];
    memset(packed_bits, 0, sizeof(packed_bits));

    for (uint32_t row = 0; row < rect->h; row++) {
        const uint8_t *src = bgra + (size_t)row * stride;
        size_t row_bytes = (size_t)rect->w * 4u;
        memcpy(out + offset, src, row_bytes);
        for (uint32_t col = 0; col < rect->w && color_count < 3; col++) {
            uint32_t color = read_pixel32(src + (size_t)col * 4u);
            if (color_count == 0) {
                colors[0] = color;
                color_count = 1;
            } else if (colors[0] == color) {
                continue;
            } else if (color_count == 1) {
                colors[1] = color;
                color_count = 2;
                size_t pixel_index = (size_t)row * rect->w + col;
                packed_bits[pixel_index / 8u] |= (uint8_t)(1u << (pixel_index % 8u));
            } else if (colors[1] == color) {
                size_t pixel_index = (size_t)row * rect->w + col;
                packed_bits[pixel_index / 8u] |= (uint8_t)(1u << (pixel_index % 8u));
            } else {
                color_count = 3;
            }
        }
        offset += row_bytes;
    }

    sharp_tile_encoding_t encoding = SHARP_TILE_ENCODING_BGRA_RAW;
    size_t encoded_len = offset;
    uint8_t raw[SHARP_TILE_BYTES];
    size_t raw_len = offset;
    memcpy(raw, out, raw_len);
    if (color_count == 1) {
        write_pixel32(out, colors[0]);
        encoded_len = 4u;
        encoding = SHARP_TILE_ENCODING_SOLID;
    } else if (color_count == 2) {
        size_t bit_len = ((size_t)rect->w * rect->h + 7u) / 8u;
        write_pixel32(out, colors[0]);
        write_pixel32(out + 4u, colors[1]);
        memcpy(out + 8u, packed_bits, bit_len);
        encoded_len = 8u + bit_len;
        encoding = SHARP_TILE_ENCODING_TWOCOLOR;
    } else {
        uint32_t candidate = 0;
        int vote = 0;
        size_t pixels = (size_t)rect->w * rect->h;
        for (size_t i = 0; i < pixels; i++) {
            uint32_t color = read_pixel32(out + i * 4u);
            if (vote == 0) {
                candidate = color;
                vote = 1;
            } else if (candidate == color) {
                vote++;
            } else {
                vote--;
            }
        }

        size_t override_count = 0;
        for (size_t i = 0; i < pixels; i++) {
            if (read_pixel32(out + i * 4u) != candidate) {
                override_count++;
            }
        }

        uint8_t sparse[SHARP_TILE_BYTES];
        size_t sparse_len = 6u + override_count * 6u;
        if (override_count <= UINT16_MAX && sparse_len < encoded_len &&
            sparse_len <= SHARP_TILE_BYTES) {
            write_pixel32(sparse, candidate);
            write_u16(sparse + 4u, (uint16_t)override_count);
            size_t pos = 6u;
            for (size_t i = 0; i < pixels; i++) {
                uint32_t color = read_pixel32(out + i * 4u);
                if (color == candidate) {
                    continue;
                }
                write_u16(sparse + pos, (uint16_t)i);
                write_pixel32(sparse + pos + 2u, color);
                pos += 6u;
            }
            encoded_len = sparse_len;
            encoding = SHARP_TILE_ENCODING_SPARSE_BGRA;
        }

        uint8_t rle[SHARP_TILE_BYTES];
        size_t rle_len = 0;
        size_t i = 0;
        while (i < pixels && rle_len + 6u <= sizeof(rle)) {
            uint32_t color = read_pixel32(out + i * 4u);
            uint16_t run = 1;
            while (i + run < pixels && run < UINT16_MAX &&
                   read_pixel32(out + (i + run) * 4u) == color) {
                run++;
            }
            write_u16(rle + rle_len, run);
            write_pixel32(rle + rle_len + 2u, color);
            rle_len += 6u;
            i += run;
        }
        if (i == pixels && rle_len < encoded_len && rle_len <= SHARP_TILE_BYTES) {
            memcpy(out, rle, rle_len);
            encoded_len = rle_len;
            encoding = SHARP_TILE_ENCODING_RLE_BGRA;
        }

        if (encoding == SHARP_TILE_ENCODING_SPARSE_BGRA) {
            memcpy(out, sparse, sparse_len);
        } else if (encoding == SHARP_TILE_ENCODING_RLE_BGRA) {
            memcpy(out, rle, rle_len);
        }
    }

    maybe_encode_zstd_tile(rect, raw, raw_len, out, &encoded_len, &encoding, codec);

    if (len_out != NULL) {
        *len_out = encoded_len;
    }
    if (checksum_out != NULL) {
        *checksum_out = sharp_tile_checksum(out, encoded_len);
    }
    if (encoding_out != NULL) {
        *encoding_out = encoding;
    }
    return 0;
}

static int send_encoded_tile(int fd, uint32_t frame_id, uint32_t generation,
                             const sharp_tile_rect_t *rect, const uint8_t *tile,
                             size_t tile_len, uint32_t checksum,
                             sharp_tile_encoding_t encoding, uint32_t *sequence,
                             unsigned int payload_size, sharp_tile_sender_stats_t *stats,
                             const sharp_tile_sender_codec_t *codec) {
    size_t max_chunk_data = payload_size - sizeof(sharp_tile_chunk_header_t);
    uint16_t chunk_count = (uint16_t)((tile_len + max_chunk_data - 1u) / max_chunk_data);
    uint8_t packet[SHTP_MAX_DATAGRAM];
    size_t offset = 0;
    for (uint16_t chunk_id = 0; chunk_id < chunk_count; chunk_id++) {
        size_t chunk_len = tile_len - offset < max_chunk_data ? tile_len - offset
                                                              : max_chunk_data;
        sharp_tile_chunk_header_t th;
        memset(&th, 0, sizeof(th));
        th.tile_id = rect->tile_id;
        th.x = rect->x;
        th.y = rect->y;
        th.w = rect->w;
        th.h = rect->h;
        th.encoding = encoding;
        th.generation = generation;
        th.total_len = (uint32_t)tile_len;
        th.offset = (uint32_t)offset;
        th.chunk_len = (uint32_t)chunk_len;
        th.checksum = checksum;

        shtp_header_t sh;
        make_shtp_header(&sh, SHTP_PAYLOAD_BGRA_TILE, (*sequence)++, frame_id,
                         chunk_id, chunk_count,
                         (uint32_t)(sizeof(th) + chunk_len));
        if (codec != NULL && codec->session) {
            sh.flags |= SHTP_FLAG_VERIFIED_HYBRID; sh.aux_time_ns = codec->session;
        }
        shtp_header_host_to_wire(&sh);
        sharp_tile_chunk_header_host_to_wire(&th);

        memcpy(packet, &sh, sizeof(sh));
        memcpy(packet + sizeof(sh), &th, sizeof(th));
        memcpy(packet + sizeof(sh) + sizeof(th), tile + offset, chunk_len);

        size_t packet_len = sizeof(sh) + sizeof(th) + chunk_len;
        if (send(fd, packet, packet_len, 0) < 0) {
            return -1;
        }
        if (stats != NULL) {
            stats->packets++;
            stats->bytes += packet_len;
        }
        offset += chunk_len;
    }

    add_encoding_stats(stats, encoding);
    return 0;
}

static int send_bgra_tile_pixels(int fd, uint32_t frame_id, uint32_t generation,
                                 const sharp_tile_rect_t *rect,
                                 const uint8_t *bgra, uint32_t stride,
                                 uint32_t *sequence, unsigned int payload_size,
                                 sharp_tile_sender_stats_t *stats,
                                 const sharp_tile_sender_codec_t *codec) {
    if (sequence == NULL ||
        payload_size <= sizeof(sharp_tile_chunk_header_t) ||
        payload_size > SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES ||
        rect == NULL || bgra == NULL) {
        return -1;
    }

    uint8_t tile[SHARP_TILE_BYTES];
    size_t tile_len = 0;
    uint32_t checksum = 0;
    sharp_tile_encoding_t encoding = SHARP_TILE_ENCODING_BGRA_RAW;
    if (copy_encoded_tile_pixels(rect, bgra, stride, tile, &tile_len, &checksum,
                                 &encoding, codec) != 0) {
        return -1;
    }

    return send_encoded_tile(fd, frame_id, generation, rect, tile, tile_len,
                             checksum, encoding, sequence, payload_size, stats, codec);
}

int sharp_tile_batch_writer_begin(sharp_tile_batch_writer_t *writer,
                                  uint8_t *packet_buf,
                                  unsigned int payload_size) {
    return sharp_tile_batch_writer_begin_with_codec(writer, packet_buf, payload_size,
                                                   NULL);
}

int sharp_tile_batch_writer_begin_with_codec(
    sharp_tile_batch_writer_t *writer, uint8_t *packet_buf,
    unsigned int payload_size, const sharp_tile_sender_codec_t *codec) {
    if (writer == NULL || packet_buf == NULL ||
        payload_size <= sizeof(sharp_tile_chunk_header_t) ||
        payload_size > SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES) {
        return -1;
    }
    memset(writer, 0, sizeof(*writer));
    writer->packet = packet_buf;
    writer->payload_cap = payload_size;
    if (codec != NULL) {
        writer->codec = *codec;
    }
    return 0;
}

static int batch_writer_add_encoded(sharp_tile_batch_writer_t *writer,
                                    uint32_t generation, int preserve_generation,
                                    const sharp_tile_rect_t *rect, const uint8_t *tile,
                                    size_t tile_len, uint32_t checksum,
                                    sharp_tile_encoding_t encoding) {
    size_t record_len = sizeof(sharp_tile_chunk_header_t) + tile_len;
    if (record_len > writer->payload_cap || tile_len > UINT32_MAX) {
        return -1;
    }
    if (writer->payload_len + record_len > writer->payload_cap) {
        return 1;
    }

    sharp_tile_chunk_header_t th;
    memset(&th, 0, sizeof(th));
    th.tile_id = rect->tile_id;
    th.x = rect->x;
    th.y = rect->y;
    th.w = rect->w;
    th.h = rect->h;
    th.encoding = encoding;
    th.generation = generation;
    th.total_len = (uint32_t)tile_len;
    th.offset = 0;
    th.chunk_len = (uint32_t)tile_len;
    th.checksum = checksum;
    sharp_tile_chunk_header_host_to_wire(&th);

    uint8_t *payload = writer->packet + SHTP_HEADER_BYTES;
    memcpy(payload + writer->payload_len, &th, sizeof(th));
    memcpy(payload + writer->payload_len + sizeof(th), tile, tile_len);
    writer->payload_len += record_len;
    writer->tile_count++;
    if (preserve_generation) {
        writer->per_record_generations = 1;
    }
    if (encoding == SHARP_TILE_ENCODING_SOLID) {
        writer->solid_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_TWOCOLOR) {
        writer->twocolor_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_SPARSE_BGRA) {
        writer->sparse_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_RLE_BGRA) {
        writer->rle_tiles++;
    } else if (encoding == SHARP_TILE_ENCODING_ZSTD) {
        writer->zstd_tiles++;
    } else {
        writer->raw_tiles++;
    }
    return 0;
}

static int batch_writer_add(sharp_tile_batch_writer_t *writer,
                            uint32_t generation, int preserve_generation,
                            const sharp_tile_rect_t *rect,
                            const uint8_t *bgra, uint32_t stride) {
    if (writer == NULL || writer->packet == NULL || rect == NULL || bgra == NULL) {
        return -1;
    }
    if (writer->tile_count > 0 &&
        writer->per_record_generations != preserve_generation) {
        return -1;
    }

    uint8_t tile[SHARP_TILE_BYTES];
    size_t tile_len = 0;
    uint32_t checksum = 0;
    sharp_tile_encoding_t encoding = SHARP_TILE_ENCODING_BGRA_RAW;
    if (copy_encoded_tile_pixels(rect, bgra, stride, tile, &tile_len, &checksum,
                                 &encoding, &writer->codec) != 0) {
        return -1;
    }

    return batch_writer_add_encoded(writer, generation, preserve_generation,
                                    rect, tile, tile_len, checksum, encoding);
}

int sharp_tile_batch_writer_add(sharp_tile_batch_writer_t *writer,
                                const sharp_tile_rect_t *rect,
                                const uint8_t *bgra, uint32_t stride) {
    return batch_writer_add(writer, 0, 0, rect, bgra, stride);
}

int sharp_tile_batch_writer_add_with_generation(
    sharp_tile_batch_writer_t *writer, uint32_t generation,
    const sharp_tile_rect_t *rect, const uint8_t *bgra, uint32_t stride) {
    return batch_writer_add(writer, generation, 1, rect, bgra, stride);
}

int sharp_tile_batch_writer_flush(int fd, sharp_tile_batch_writer_t *writer,
                                  uint32_t frame_id, uint32_t *sequence,
                                  sharp_tile_sender_stats_t *stats) {
    if (writer == NULL || writer->packet == NULL || sequence == NULL) {
        return -1;
    }
    if (writer->tile_count == 0) {
        return 0;
    }

    /*
     * Records are encoded before a TX job is assigned to a datagram. Stamp the
     * generation at flush time so batched tiles have the same latest-wins
     * semantics as individually chunked tiles.
     */
    uint8_t *payload = writer->packet + SHTP_HEADER_BYTES;
    size_t offset = 0;
    uint16_t records = 0;
    while (offset < writer->payload_len) {
        if (writer->payload_len - offset < sizeof(sharp_tile_chunk_header_t)) {
            return -1;
        }
        sharp_tile_chunk_header_t th;
        memcpy(&th, payload + offset, sizeof(th));
        sharp_tile_chunk_header_wire_to_host(&th);
        if (th.offset != 0 || th.chunk_len != th.total_len ||
            writer->payload_len - offset - sizeof(th) < th.chunk_len) {
            return -1;
        }
        size_t record_len = sizeof(th) + th.chunk_len;
        if (!writer->per_record_generations) {
            th.generation = frame_id;
        }
        sharp_tile_chunk_header_host_to_wire(&th);
        memcpy(payload + offset, &th, sizeof(th));
        offset += record_len;
        records++;
    }
    if (records != writer->tile_count) {
        return -1;
    }

    shtp_header_t sh;
    make_shtp_header(&sh, SHTP_PAYLOAD_TILE_BATCH, (*sequence)++, frame_id, 0,
                     writer->tile_count, (uint32_t)writer->payload_len);
    if (writer->codec.session) {
        sh.flags |= SHTP_FLAG_VERIFIED_HYBRID; sh.aux_time_ns = writer->codec.session;
    }
    shtp_header_host_to_wire(&sh);
    memcpy(writer->packet, &sh, sizeof(sh));

    size_t packet_len = SHTP_HEADER_BYTES + writer->payload_len;
    if (send(fd, writer->packet, packet_len, 0) < 0) {
        return -1;
    }
    if (stats != NULL) {
        stats->packets++;
        stats->bytes += packet_len;
        stats->tiles += writer->tile_count;
        stats->batch_packets++;
        stats->batch_tiles += writer->tile_count;
        stats->solid_tiles += writer->solid_tiles;
        stats->twocolor_tiles += writer->twocolor_tiles;
        stats->sparse_tiles += writer->sparse_tiles;
        stats->rle_tiles += writer->rle_tiles;
        stats->raw_tiles += writer->raw_tiles;
        stats->zstd_tiles += writer->zstd_tiles;
    }
    writer->payload_len = 0;
    writer->tile_count = 0;
    writer->solid_tiles = 0;
    writer->twocolor_tiles = 0;
    writer->sparse_tiles = 0;
    writer->rle_tiles = 0;
    writer->raw_tiles = 0;
    writer->zstd_tiles = 0;
    writer->per_record_generations = 0;
    return 0;
}

int sharp_tile_sender_send_bgra_tile(int fd, uint32_t width, uint32_t height,
                                     uint32_t frame_id, uint16_t tile_id,
                                     const uint8_t *bgra, uint32_t stride,
                                     uint32_t *sequence, unsigned int payload_size,
                                     sharp_tile_sender_stats_t *stats) {
    sharp_tile_rect_t rect;
    if (bgra == NULL ||
        sharp_tile_rect_for_id(width, height, tile_id, &rect) != 0 ||
        stride < width * 4u) {
        return -1;
    }
    const uint8_t *tile_bgra =
        bgra + (size_t)rect.y * stride + (size_t)rect.x * 4u;
    return send_bgra_tile_pixels(fd, frame_id, frame_id, &rect, tile_bgra, stride, sequence,
                                 payload_size, stats, NULL);
}

int sharp_tile_sender_send_bgra_tile_pixels(int fd, uint32_t frame_id,
                                            const sharp_tile_rect_t *rect,
                                            const uint8_t *bgra,
                                            uint32_t stride,
                                            uint32_t *sequence,
                                            unsigned int payload_size,
                                            sharp_tile_sender_stats_t *stats) {
    return send_bgra_tile_pixels(fd, frame_id, frame_id, rect, bgra, stride, sequence,
                                 payload_size, stats, NULL);
}

int sharp_tile_sender_send_bgra_tile_pixels_with_codec(
    int fd, uint32_t frame_id, const sharp_tile_rect_t *rect,
    const uint8_t *bgra, uint32_t stride, uint32_t *sequence,
    unsigned int payload_size, sharp_tile_sender_stats_t *stats,
    const sharp_tile_sender_codec_t *codec) {
    return send_bgra_tile_pixels(fd, frame_id, frame_id, rect, bgra, stride, sequence,
                                 payload_size, stats, codec);
}

int sharp_tile_sender_send_bye(int fd, uint32_t frame_id, uint32_t *sequence) {
    return send_control_packet(fd, SHTP_PACKET_BYE, frame_id, 0, sequence);
}

int sharp_tile_sender_send_frame_end(int fd, uint32_t frame_id, uint16_t tile_count,
                                     uint32_t *sequence) {
    return send_control_packet(fd, SHTP_PACKET_FRAME_END, frame_id, tile_count,
                               sequence);
}

int sharp_tile_sender_send_bgra_tile_pixels_generation(
    int fd, uint32_t frame_id, uint32_t generation, const sharp_tile_rect_t *rect,
    const uint8_t *bgra, uint32_t stride, uint32_t *sequence,
    unsigned int payload_size, sharp_tile_sender_stats_t *stats,
    const sharp_tile_sender_codec_t *codec) {
    return send_bgra_tile_pixels(fd, frame_id, generation, rect, bgra, stride,
                                 sequence, payload_size, stats, codec);
}

int sharp_tile_batch_writer_send_pixels(
    int fd, sharp_tile_batch_writer_t *writer, uint32_t frame_id,
    uint32_t generation, const sharp_tile_rect_t *rect, const uint8_t *bgra,
    uint32_t stride, uint32_t *sequence, sharp_tile_sender_stats_t *stats) {
    if (!writer || !writer->packet || !sequence || !rect || !bgra ||
        writer->payload_cap <= sizeof(sharp_tile_chunk_header_t) ||
        writer->payload_cap > SHTP_MAX_DATAGRAM-SHTP_HEADER_BYTES ||
        (writer->tile_count && !writer->per_record_generations)) return -1;
    uint8_t tile[SHARP_TILE_BYTES];
    size_t tile_len = 0;
    uint32_t checksum = 0;
    sharp_tile_encoding_t encoding = SHARP_TILE_ENCODING_BGRA_RAW;
    if (copy_encoded_tile_pixels(rect, bgra, stride, tile, &tile_len, &checksum,
                                 &encoding, &writer->codec) != 0) return -1;
    size_t record_len = sizeof(sharp_tile_chunk_header_t) + tile_len;
    if (writer->payload_len + record_len > writer->payload_cap) {
        if (sharp_tile_batch_writer_flush(fd, writer, frame_id, sequence, stats) != 0)
            return -1;
    }
    if (record_len > writer->payload_cap)
        return send_encoded_tile(fd, frame_id, generation, rect, tile, tile_len,
                                 checksum, encoding, sequence, writer->payload_cap,
                                 stats, &writer->codec);
    return batch_writer_add_encoded(writer, generation, 1, rect, tile, tile_len,
                                    checksum, encoding);
}
