#ifndef SHARP_SHTP_PROTOCOL_H
#define SHARP_SHTP_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

#define SHTP_MAGIC 0x53485450u
#define SHTP_VERSION 1u
#define SHTP_DEFAULT_PORT 49152u
#define SHTP_MAX_DATAGRAM 9216u
#define SHTP_HEADER_BYTES 48u
#define SHTP_FLAG_VERIFIED_HYBRID 0x00010000u
#define SHTP_FRAME_END_FLAG_VIDEO_REGIONS 0x00000001u
#define SHTP_FRAME_END_FLAG_MOTION_MASK 0x00000002u

typedef enum shtp_packet_type {
    SHTP_PACKET_DATA = 1,
    SHTP_PACKET_PING = 2,
    SHTP_PACKET_PONG = 3,
    SHTP_PACKET_BYE = 4,
    SHTP_PACKET_STATS = 5,
    SHTP_PACKET_FRAME_END = 6
} shtp_packet_type_t;

typedef enum shtp_payload_type {
    SHTP_PAYLOAD_SYNTH_TILE = 1,
    SHTP_PAYLOAD_SYNTH_CURSOR = 2,
    SHTP_PAYLOAD_CONTROL = 3,
    SHTP_PAYLOAD_BGRA_TILE = 4,
    SHTP_PAYLOAD_H264_REGION = 5,
    SHTP_PAYLOAD_TILE_BATCH = 6,
    SHTP_PAYLOAD_TILE_DIGEST = 7,
    SHTP_PAYLOAD_CURSOR_IMAGE = 8,
    SHTP_PAYLOAD_HYBRID_STATE = 9
} shtp_payload_type_t;

#define SHARP_TILE_DIGEST_MAGIC 0x54444753u
#define SHARP_TILE_DIGEST_VERSION 1u
/* The reserved field carries requests that cannot be inferred from pixels. */
#define SHARP_TILE_DIGEST_REFRESH_REQUIRED 1u

typedef struct __attribute__((packed)) sharp_tile_digest_header {
    uint32_t magic;
    uint16_t version;
    uint16_t entry_count;
} sharp_tile_digest_header_t;

typedef struct __attribute__((packed)) sharp_tile_digest_entry {
    uint16_t tile_id;
    uint16_t reserved;
    uint64_t hash;
} sharp_tile_digest_entry_t;

_Static_assert(sizeof(sharp_tile_digest_header_t) == 8,
               "unexpected tile digest header size");
_Static_assert(sizeof(sharp_tile_digest_entry_t) == 12,
               "unexpected tile digest entry size");

typedef struct __attribute__((packed)) shtp_header {
    uint32_t magic;
    uint8_t version;
    uint8_t header_bytes;
    uint8_t type;
    uint8_t payload_type;
    uint32_t sequence;
    uint32_t frame_id;
    uint16_t chunk_id;
    uint16_t chunk_count;
    uint32_t payload_len;
    uint64_t send_time_ns;
    uint64_t aux_time_ns;
    uint32_t flags;
    uint32_t header_crc;
} shtp_header_t;

_Static_assert(sizeof(shtp_header_t) == SHTP_HEADER_BYTES, "unexpected shTP header size");

typedef struct __attribute__((packed)) sharp_cursor_position {
    uint32_t seq;
    int32_t x;
    int32_t y;
    uint16_t stream_width;
    uint16_t stream_height;
    uint16_t hotspot_x;
    uint16_t hotspot_y;
    uint32_t flags;
    uint64_t sample_time_ns;
    uint32_t image_id;
    uint32_t reserved;
} sharp_cursor_position_t;

typedef enum sharp_cursor_image_id {
    SHARP_CURSOR_IMAGE_ARROW = 1,
    SHARP_CURSOR_IMAGE_IBEAM = 2,
    SHARP_CURSOR_IMAGE_LINK = 3,
    SHARP_CURSOR_IMAGE_CROSSHAIR = 4,
    SHARP_CURSOR_IMAGE_MOVE = 5,
    SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL = 6,
    SHARP_CURSOR_IMAGE_RESIZE_VERTICAL = 7,
    SHARP_CURSOR_IMAGE_UNAVAILABLE = 8,
    SHARP_CURSOR_IMAGE_ALTERNATE = 9,
    /* Window-corner resize. Older receivers draw the arrow for unknown IDs. */
    SHARP_CURSOR_IMAGE_RESIZE_DIAGONAL_NWSE = 10,
    SHARP_CURSOR_IMAGE_RESIZE_DIAGONAL_NESW = 11,
    SHARP_CURSOR_IMAGE_MAX = 12
} sharp_cursor_image_id_t;

_Static_assert(sizeof(sharp_cursor_position_t) == 40,
               "unexpected cursor position size");

uint64_t shtp_htonll(uint64_t value);
uint64_t shtp_ntohll(uint64_t value);
void shtp_header_host_to_wire(shtp_header_t *header);
void shtp_header_wire_to_host(shtp_header_t *header);
int shtp_header_is_valid(const shtp_header_t *header, size_t datagram_len);
void sharp_tile_digest_header_host_to_wire(sharp_tile_digest_header_t *header);
void sharp_tile_digest_header_wire_to_host(sharp_tile_digest_header_t *header);
void sharp_tile_digest_entry_host_to_wire(sharp_tile_digest_entry_t *entry);
void sharp_tile_digest_entry_wire_to_host(sharp_tile_digest_entry_t *entry);

#endif
