#ifndef SHARP_TILE_H
#define SHARP_TILE_H

#include <stddef.h>
#include <stdint.h>

#define SHARP_TILE_SIZE 64u
#define SHARP_TILE_BYTES (SHARP_TILE_SIZE * SHARP_TILE_SIZE * 4u)
#define SHARP_TILE_REASSEMBLER_MAX_CHUNKS 64u

typedef enum sharp_tile_encoding {
    SHARP_TILE_ENCODING_BGRA_RAW = 1,
    SHARP_TILE_ENCODING_SOLID = 2,
    SHARP_TILE_ENCODING_TWOCOLOR = 3,
    SHARP_TILE_ENCODING_SPARSE_BGRA = 4,
    SHARP_TILE_ENCODING_RLE_BGRA = 5,
    SHARP_TILE_ENCODING_ZSTD = 6
} sharp_tile_encoding_t;

typedef struct sharp_tile_rect {
    uint16_t tile_id;
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
} sharp_tile_rect_t;

typedef struct sharp_tile_dirty_bounds {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
    int valid;
} sharp_tile_dirty_bounds_t;

typedef struct __attribute__((packed)) sharp_tile_chunk_header {
    uint16_t tile_id;
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
    uint16_t encoding;
    uint32_t generation;
    uint32_t total_len;
    uint32_t offset;
    uint32_t chunk_len;
    uint32_t checksum;
} sharp_tile_chunk_header_t;

_Static_assert(sizeof(sharp_tile_chunk_header_t) == 32, "unexpected tile chunk header size");

typedef struct sharp_tile_reassembler sharp_tile_reassembler_t;

uint16_t sharp_tile_cols(uint32_t width);
uint16_t sharp_tile_rows(uint32_t height);
uint32_t sharp_tile_count(uint32_t width, uint32_t height);
int sharp_tile_rect_for_id(uint32_t width, uint32_t height, uint16_t tile_id,
                           sharp_tile_rect_t *out);
uint32_t sharp_tile_checksum(const uint8_t *data, size_t len);

void sharp_tile_chunk_header_host_to_wire(sharp_tile_chunk_header_t *header);
void sharp_tile_chunk_header_wire_to_host(sharp_tile_chunk_header_t *header);
int sharp_tile_chunk_header_is_valid(const sharp_tile_chunk_header_t *header,
                                     uint32_t width, uint32_t height);

int sharp_synthetic_make_tile(uint32_t width, uint32_t height, uint32_t frame_id,
                              uint16_t tile_id, uint8_t *out, size_t out_cap,
                              sharp_tile_rect_t *rect_out, size_t *len_out,
                              uint32_t *checksum_out);
size_t sharp_synthetic_dirty_tiles(uint32_t width, uint32_t height, uint32_t frame_id,
                                   uint16_t *out, size_t out_cap);

sharp_tile_reassembler_t *sharp_tile_reassembler_create(uint32_t width, uint32_t height);
void sharp_tile_reassembler_destroy(sharp_tile_reassembler_t *reassembler);
int sharp_tile_reassembler_push(sharp_tile_reassembler_t *reassembler,
                                const sharp_tile_chunk_header_t *header,
                                uint16_t chunk_id, uint16_t chunk_count,
                                const uint8_t *chunk_data, size_t chunk_len);
int sharp_tile_reassembler_take_complete(sharp_tile_reassembler_t *reassembler,
                                         uint16_t tile_id, sharp_tile_rect_t *rect_out,
                                         const uint8_t **data_out, size_t *len_out,
                                         uint32_t *generation_out);

#endif
