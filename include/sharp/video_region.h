#ifndef SHARP_VIDEO_REGION_H
#define SHARP_VIDEO_REGION_H

#include <stddef.h>
#include <stdint.h>

#define SHARP_VIDEO_REGION_MAX_CHUNKS 4096u
#define SHARP_VIDEO_REGION_FULLFRAME_ID 3u
#define SHARP_VIDEO_REGION_FLAG_KEYFRAME 0x1u
#define SHARP_VIDEO_REGION_FLAG_HAS_CONFIG 0x2u
#define SHARP_VIDEO_REGION_FLAG_PARITY 0x4u

typedef struct __attribute__((packed)) sharp_video_region_chunk_header {
    uint16_t region_id;
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
    uint32_t generation;
    uint32_t total_len;
    uint32_t offset;
    uint32_t chunk_len;
    uint32_t flags;
    uint32_t checksum;
} sharp_video_region_chunk_header_t;

_Static_assert(sizeof(sharp_video_region_chunk_header_t) == 34,
               "unexpected video region chunk header size");

typedef struct sharp_video_region_reassembler sharp_video_region_reassembler_t;

uint32_t sharp_video_region_checksum(const uint8_t *data, size_t len);
void sharp_video_region_chunk_header_host_to_wire(
    sharp_video_region_chunk_header_t *header);
void sharp_video_region_chunk_header_wire_to_host(
    sharp_video_region_chunk_header_t *header);
int sharp_video_region_chunk_header_is_valid(
    const sharp_video_region_chunk_header_t *header, uint32_t width,
    uint32_t height);

sharp_video_region_reassembler_t *sharp_video_region_reassembler_create(
    uint32_t width, uint32_t height);
void sharp_video_region_reassembler_destroy(
    sharp_video_region_reassembler_t *reassembler);
int sharp_video_region_reassembler_push(
    sharp_video_region_reassembler_t *reassembler,
    const sharp_video_region_chunk_header_t *header, uint16_t chunk_id,
    uint16_t chunk_count, const uint8_t *chunk_data, size_t chunk_len,
    sharp_video_region_chunk_header_t *missed_header_out,
    uint16_t *missed_chunks_out);
int sharp_video_region_reassembler_next_missing(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    uint32_t generation, int include_tail,
    sharp_video_region_chunk_header_t *header_out, uint16_t *chunk_id_out,
    uint16_t *chunk_count_out);
int sharp_video_region_reassembler_generation_incomplete(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    uint32_t generation);
uint64_t sharp_video_region_reassembler_fec_recovered_chunks(
    const sharp_video_region_reassembler_t *reassembler);
uint64_t sharp_video_region_reassembler_fec_unrecovered_generations(
    const sharp_video_region_reassembler_t *reassembler);
int sharp_video_region_reassembler_take_complete_repair(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    sharp_video_region_chunk_header_t *header_out, const uint8_t **data_out,
    size_t *len_out, int *had_repair_out);
int sharp_video_region_reassembler_take_complete(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    sharp_video_region_chunk_header_t *header_out, const uint8_t **data_out,
    size_t *len_out);

#endif
