#include "sharp/tile.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

typedef struct tile_slot {
    uint8_t data[SHARP_TILE_BYTES];
    uint8_t chunks_seen[SHARP_TILE_REASSEMBLER_MAX_CHUNKS];
    uint16_t chunk_count;
    uint16_t received_chunks;
    uint16_t tile_id;
    uint32_t generation;
    uint32_t total_len;
    uint32_t checksum;
    sharp_tile_rect_t rect;
    int active;
    int complete;
} tile_slot_t;

struct sharp_tile_reassembler {
    uint32_t width;
    uint32_t height;
    uint32_t tile_count;
    tile_slot_t *slots;
};

uint16_t sharp_tile_cols(uint32_t width) {
    return (uint16_t)((width + SHARP_TILE_SIZE - 1u) / SHARP_TILE_SIZE);
}

uint16_t sharp_tile_rows(uint32_t height) {
    return (uint16_t)((height + SHARP_TILE_SIZE - 1u) / SHARP_TILE_SIZE);
}

uint32_t sharp_tile_count(uint32_t width, uint32_t height) {
    return (uint32_t)sharp_tile_cols(width) * (uint32_t)sharp_tile_rows(height);
}

int sharp_tile_rect_for_id(uint32_t width, uint32_t height, uint16_t tile_id,
                           sharp_tile_rect_t *out) {
    uint16_t cols = sharp_tile_cols(width);
    uint16_t rows = sharp_tile_rows(height);
    if (out == NULL || cols == 0 || rows == 0 || tile_id >= (uint32_t)cols * rows) {
        return -1;
    }

    uint16_t tx = (uint16_t)(tile_id % cols);
    uint16_t ty = (uint16_t)(tile_id / cols);
    uint32_t x = (uint32_t)tx * SHARP_TILE_SIZE;
    uint32_t y = (uint32_t)ty * SHARP_TILE_SIZE;
    uint32_t w = width - x < SHARP_TILE_SIZE ? width - x : SHARP_TILE_SIZE;
    uint32_t h = height - y < SHARP_TILE_SIZE ? height - y : SHARP_TILE_SIZE;

    out->tile_id = tile_id;
    out->x = (uint16_t)x;
    out->y = (uint16_t)y;
    out->w = (uint16_t)w;
    out->h = (uint16_t)h;
    return 0;
}

uint32_t sharp_tile_checksum(const uint8_t *data, size_t len) {
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= 16777619u;
    }
    return hash;
}

void sharp_tile_chunk_header_host_to_wire(sharp_tile_chunk_header_t *header) {
    header->tile_id = htons(header->tile_id);
    header->x = htons(header->x);
    header->y = htons(header->y);
    header->w = htons(header->w);
    header->h = htons(header->h);
    header->encoding = htons(header->encoding);
    header->generation = htonl(header->generation);
    header->total_len = htonl(header->total_len);
    header->offset = htonl(header->offset);
    header->chunk_len = htonl(header->chunk_len);
    header->checksum = htonl(header->checksum);
}

void sharp_tile_chunk_header_wire_to_host(sharp_tile_chunk_header_t *header) {
    header->tile_id = ntohs(header->tile_id);
    header->x = ntohs(header->x);
    header->y = ntohs(header->y);
    header->w = ntohs(header->w);
    header->h = ntohs(header->h);
    header->encoding = ntohs(header->encoding);
    header->generation = ntohl(header->generation);
    header->total_len = ntohl(header->total_len);
    header->offset = ntohl(header->offset);
    header->chunk_len = ntohl(header->chunk_len);
    header->checksum = ntohl(header->checksum);
}

int sharp_tile_chunk_header_is_valid(const sharp_tile_chunk_header_t *header,
                                     uint32_t width, uint32_t height) {
    sharp_tile_rect_t expected;
    if (header == NULL ||
        sharp_tile_rect_for_id(width, height, header->tile_id, &expected) != 0) {
        return 0;
    }
    if (header->x != expected.x || header->y != expected.y || header->w != expected.w ||
        header->h != expected.h) {
        return 0;
    }
    uint32_t pixel_count = (uint32_t)header->w * (uint32_t)header->h;
    uint32_t expected_len = 0;
    if (header->encoding == SHARP_TILE_ENCODING_BGRA_RAW) {
        expected_len = pixel_count * 4u;
    } else if (header->encoding == SHARP_TILE_ENCODING_SOLID) {
        expected_len = 4u;
    } else if (header->encoding == SHARP_TILE_ENCODING_TWOCOLOR) {
        expected_len = 8u + ((pixel_count + 7u) / 8u);
    } else if (header->encoding == SHARP_TILE_ENCODING_SPARSE_BGRA) {
        if (header->total_len < 6u || (header->total_len - 6u) % 6u != 0u) {
            return 0;
        }
        uint32_t override_count = (header->total_len - 6u) / 6u;
        if (override_count > pixel_count) {
            return 0;
        }
        expected_len = header->total_len;
    } else if (header->encoding == SHARP_TILE_ENCODING_RLE_BGRA) {
        if (header->total_len < 6u || header->total_len % 6u != 0u) {
            return 0;
        }
        expected_len = header->total_len;
    } else if (header->encoding == SHARP_TILE_ENCODING_ZSTD) {
        if (header->total_len == 0 || header->total_len > SHARP_TILE_BYTES) {
            return 0;
        }
        expected_len = header->total_len;
    } else {
        return 0;
    }
    if (header->total_len != expected_len || header->total_len > SHARP_TILE_BYTES) {
        return 0;
    }
    if (header->chunk_len == 0 || header->offset >= header->total_len ||
        header->offset + header->chunk_len > header->total_len) {
        return 0;
    }
    return 1;
}

static void synthetic_pixel(uint32_t width, uint32_t height, uint32_t frame_id,
                            uint32_t x, uint32_t y, uint8_t *bgra) {
    uint32_t block = width < 192 || height < 192 ? 64u : 128u;
    if (block > width) {
        block = width;
    }
    if (block > height) {
        block = height;
    }
    uint32_t max_x = width > block ? width - block : 1u;
    uint32_t max_y = height > block ? height - block : 1u;
    uint32_t bx = (frame_id * 17u) % max_x;
    uint32_t by = (frame_id * 11u) % max_y;

    if (x >= bx && x < bx + block && y >= by && y < by + block) {
        bgra[0] = (uint8_t)(32u + ((x + frame_id * 5u) & 0x7fu));
        bgra[1] = (uint8_t)(180u + ((y + frame_id * 3u) & 0x3fu));
        bgra[2] = (uint8_t)(80u + (((x ^ y) + frame_id * 9u) & 0x7fu));
        bgra[3] = 255u;
        return;
    }

    bgra[0] = (uint8_t)((x * 3u + y * 5u) & 0xffu);
    bgra[1] = (uint8_t)((x / 4u + y / 2u) & 0xffu);
    bgra[2] = (uint8_t)(40u + ((x ^ y) & 0x3fu));
    bgra[3] = 255u;
}

int sharp_synthetic_make_tile(uint32_t width, uint32_t height, uint32_t frame_id,
                              uint16_t tile_id, uint8_t *out, size_t out_cap,
                              sharp_tile_rect_t *rect_out, size_t *len_out,
                              uint32_t *checksum_out) {
    sharp_tile_rect_t rect;
    if (out == NULL || sharp_tile_rect_for_id(width, height, tile_id, &rect) != 0) {
        return -1;
    }

    size_t len = (size_t)rect.w * (size_t)rect.h * 4u;
    if (out_cap < len) {
        return -1;
    }

    size_t offset = 0;
    for (uint32_t row = 0; row < rect.h; row++) {
        for (uint32_t col = 0; col < rect.w; col++) {
            synthetic_pixel(width, height, frame_id, (uint32_t)rect.x + col,
                            (uint32_t)rect.y + row, out + offset);
            offset += 4u;
        }
    }

    if (rect_out != NULL) {
        *rect_out = rect;
    }
    if (len_out != NULL) {
        *len_out = len;
    }
    if (checksum_out != NULL) {
        *checksum_out = sharp_tile_checksum(out, len);
    }
    return 0;
}

static void add_tile_id(uint16_t *out, size_t out_cap, size_t *count, uint16_t tile_id) {
    for (size_t i = 0; i < *count; i++) {
        if (out[i] == tile_id) {
            return;
        }
    }
    if (*count < out_cap) {
        out[*count] = tile_id;
        (*count)++;
    }
}

static void add_block_tiles(uint32_t width, uint32_t height, uint32_t frame_id,
                            uint16_t *out, size_t out_cap, size_t *count) {
    uint32_t block = width < 192 || height < 192 ? 64u : 128u;
    if (block > width) {
        block = width;
    }
    if (block > height) {
        block = height;
    }
    uint32_t max_x = width > block ? width - block : 1u;
    uint32_t max_y = height > block ? height - block : 1u;
    uint32_t bx = (frame_id * 17u) % max_x;
    uint32_t by = (frame_id * 11u) % max_y;
    uint32_t x0 = bx / SHARP_TILE_SIZE;
    uint32_t y0 = by / SHARP_TILE_SIZE;
    uint32_t x1 = (bx + block - 1u) / SHARP_TILE_SIZE;
    uint32_t y1 = (by + block - 1u) / SHARP_TILE_SIZE;
    uint16_t cols = sharp_tile_cols(width);

    for (uint32_t y = y0; y <= y1; y++) {
        for (uint32_t x = x0; x <= x1; x++) {
            add_tile_id(out, out_cap, count, (uint16_t)(y * cols + x));
        }
    }
}

size_t sharp_synthetic_dirty_tiles(uint32_t width, uint32_t height, uint32_t frame_id,
                                   uint16_t *out, size_t out_cap) {
    if (out == NULL || out_cap == 0) {
        return 0;
    }

    uint32_t count_all = sharp_tile_count(width, height);
    if (frame_id == 0) {
        size_t n = count_all < out_cap ? count_all : out_cap;
        for (size_t i = 0; i < n; i++) {
            out[i] = (uint16_t)i;
        }
        return n;
    }

    size_t count = 0;
    add_block_tiles(width, height, frame_id - 1u, out, out_cap, &count);
    add_block_tiles(width, height, frame_id, out, out_cap, &count);
    return count;
}

sharp_tile_reassembler_t *sharp_tile_reassembler_create(uint32_t width, uint32_t height) {
    uint32_t tile_count = sharp_tile_count(width, height);
    if (tile_count == 0 || tile_count > UINT16_MAX) {
        return NULL;
    }
    sharp_tile_reassembler_t *r = calloc(1, sizeof(*r));
    if (r == NULL) {
        return NULL;
    }
    r->slots = calloc(tile_count, sizeof(r->slots[0]));
    if (r->slots == NULL) {
        free(r);
        return NULL;
    }
    r->width = width;
    r->height = height;
    r->tile_count = tile_count;
    return r;
}

void sharp_tile_reassembler_destroy(sharp_tile_reassembler_t *reassembler) {
    if (reassembler != NULL) {
        free(reassembler->slots);
        free(reassembler);
    }
}

static void reset_slot(tile_slot_t *slot, const sharp_tile_chunk_header_t *header,
                       uint16_t chunk_count) {
    memset(slot, 0, sizeof(*slot));
    slot->active = 1;
    slot->tile_id = header->tile_id;
    slot->generation = header->generation;
    slot->total_len = header->total_len;
    slot->checksum = header->checksum;
    slot->chunk_count = chunk_count;
    slot->rect.tile_id = header->tile_id;
    slot->rect.x = header->x;
    slot->rect.y = header->y;
    slot->rect.w = header->w;
    slot->rect.h = header->h;
}

int sharp_tile_reassembler_push(sharp_tile_reassembler_t *reassembler,
                                const sharp_tile_chunk_header_t *header,
                                uint16_t chunk_id, uint16_t chunk_count,
                                const uint8_t *chunk_data, size_t chunk_len) {
    if (reassembler == NULL || header == NULL || chunk_data == NULL ||
        header->tile_id >= reassembler->tile_count ||
        !sharp_tile_chunk_header_is_valid(header, reassembler->width, reassembler->height) ||
        chunk_len != header->chunk_len || chunk_count == 0 ||
        chunk_count > SHARP_TILE_REASSEMBLER_MAX_CHUNKS || chunk_id >= chunk_count) {
        return -1;
    }

    uint32_t nominal_chunk_len =
        (header->offset == 0 && chunk_count > 1) ? header->chunk_len : 0u;
    if (nominal_chunk_len != 0) {
        uint32_t expected_count =
            (header->total_len + nominal_chunk_len - 1u) / nominal_chunk_len;
        if (expected_count != chunk_count) {
            return -1;
        }
    }

    tile_slot_t *slot = &reassembler->slots[header->tile_id];
    if (!slot->active || slot->generation != header->generation ||
        slot->total_len != header->total_len || slot->chunk_count != chunk_count) {
        reset_slot(slot, header, chunk_count);
    }

    if (slot->chunks_seen[chunk_id]) {
        return 0;
    }

    memcpy(slot->data + header->offset, chunk_data, chunk_len);
    slot->chunks_seen[chunk_id] = 1u;
    slot->received_chunks++;
    if (slot->received_chunks == slot->chunk_count) {
        if (sharp_tile_checksum(slot->data, slot->total_len) != slot->checksum) {
            reset_slot(slot, header, chunk_count);
            return -2;
        }
        slot->complete = 1;
    }
    return 0;
}

int sharp_tile_reassembler_take_complete(sharp_tile_reassembler_t *reassembler,
                                         uint16_t tile_id, sharp_tile_rect_t *rect_out,
                                         const uint8_t **data_out, size_t *len_out,
                                         uint32_t *generation_out) {
    if (reassembler == NULL || tile_id >= reassembler->tile_count) {
        return 0;
    }
    tile_slot_t *slot = &reassembler->slots[tile_id];
    if (!slot->active || !slot->complete) {
        return 0;
    }
    if (rect_out != NULL) {
        *rect_out = slot->rect;
    }
    if (data_out != NULL) {
        *data_out = slot->data;
    }
    if (len_out != NULL) {
        *len_out = slot->total_len;
    }
    if (generation_out != NULL) {
        *generation_out = slot->generation;
    }
    slot->complete = 0;
    return 1;
}
