#ifndef SHARP_VIDEO_FEEDBACK_H
#define SHARP_VIDEO_FEEDBACK_H

#include <stdint.h>

#define SHARP_VIDEO_FEEDBACK_MAGIC 0x53564642u

typedef enum sharp_video_feedback_kind {
    SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST = 1,
    SHARP_VIDEO_FEEDBACK_MISSING_GENERATION = 2,
    SHARP_VIDEO_FEEDBACK_VSLICE_NACK = 3,
    SHARP_VIDEO_FEEDBACK_IDR_REQ = 4,
    SHARP_VIDEO_FEEDBACK_PRESENT_REPORT = 5
} sharp_video_feedback_kind_t;

#define SHARP_VIDEO_FEEDBACK_V1_BYTES 16u
#define SHARP_VIDEO_FEEDBACK_VERSION 5u
#define SHARP_VIDEO_FEEDBACK_V2_BYTES 40u
#define SHARP_VIDEO_FEEDBACK_V3_BYTES 56u
#define SHARP_VIDEO_FEEDBACK_V4_BYTES 72u
#define SHARP_VIDEO_FEEDBACK_V5_BYTES 80u

typedef struct __attribute__((packed)) sharp_video_feedback {
    uint32_t magic;
    uint16_t kind;
    uint16_t region_id;
    uint32_t generation;
    uint16_t missing_chunks;
    uint16_t chunk_id;
    uint8_t version;
    uint8_t reserved[7];
    uint64_t frame_end_send_ns;
    uint64_t present_ns;
    uint64_t vsync_ns;
    uint64_t vsync_period_ns;
    uint64_t final_packet_rx_ns;
    uint64_t decode_callback_ns;
    uint64_t fresh_content_presents;
} sharp_video_feedback_t;

_Static_assert(SHARP_VIDEO_FEEDBACK_V1_BYTES == 16,
               "unexpected video feedback v1 size");
_Static_assert(SHARP_VIDEO_FEEDBACK_V2_BYTES == 40,
               "unexpected video feedback v2 size");
_Static_assert(SHARP_VIDEO_FEEDBACK_V3_BYTES == 56,
               "unexpected video feedback v3 size");
_Static_assert(sizeof(sharp_video_feedback_t) == SHARP_VIDEO_FEEDBACK_V5_BYTES,
               "unexpected video feedback size");

void sharp_video_feedback_host_to_wire(sharp_video_feedback_t *feedback);
void sharp_video_feedback_wire_to_host(sharp_video_feedback_t *feedback);
int sharp_video_feedback_is_valid(const sharp_video_feedback_t *feedback);

#endif
