#include "sharp/video_feedback.h"
#include "sharp/shtp_protocol.h"

#include <arpa/inet.h>

void sharp_video_feedback_host_to_wire(sharp_video_feedback_t *feedback) {
    feedback->magic = htonl(feedback->magic);
    feedback->kind = htons(feedback->kind);
    feedback->region_id = htons(feedback->region_id);
    feedback->generation = htonl(feedback->generation);
    feedback->missing_chunks = htons(feedback->missing_chunks);
    feedback->chunk_id = htons(feedback->chunk_id);
    feedback->frame_end_send_ns = shtp_htonll(feedback->frame_end_send_ns);
    feedback->present_ns = shtp_htonll(feedback->present_ns);
    feedback->vsync_ns = shtp_htonll(feedback->vsync_ns);
    feedback->vsync_period_ns = shtp_htonll(feedback->vsync_period_ns);
    feedback->final_packet_rx_ns = shtp_htonll(feedback->final_packet_rx_ns);
    feedback->decode_callback_ns = shtp_htonll(feedback->decode_callback_ns);
    feedback->fresh_content_presents =
        shtp_htonll(feedback->fresh_content_presents);
}

void sharp_video_feedback_wire_to_host(sharp_video_feedback_t *feedback) {
    feedback->magic = ntohl(feedback->magic);
    feedback->kind = ntohs(feedback->kind);
    feedback->region_id = ntohs(feedback->region_id);
    feedback->generation = ntohl(feedback->generation);
    feedback->missing_chunks = ntohs(feedback->missing_chunks);
    feedback->chunk_id = ntohs(feedback->chunk_id);
    feedback->frame_end_send_ns = shtp_ntohll(feedback->frame_end_send_ns);
    feedback->present_ns = shtp_ntohll(feedback->present_ns);
    feedback->vsync_ns = shtp_ntohll(feedback->vsync_ns);
    feedback->vsync_period_ns = shtp_ntohll(feedback->vsync_period_ns);
    feedback->final_packet_rx_ns = shtp_ntohll(feedback->final_packet_rx_ns);
    feedback->decode_callback_ns = shtp_ntohll(feedback->decode_callback_ns);
    feedback->fresh_content_presents =
        shtp_ntohll(feedback->fresh_content_presents);
}

int sharp_video_feedback_is_valid(const sharp_video_feedback_t *feedback) {
    if (feedback == 0 || feedback->magic != SHARP_VIDEO_FEEDBACK_MAGIC) {
        return 0;
    }
    return feedback->kind == SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST ||
           feedback->kind == SHARP_VIDEO_FEEDBACK_MISSING_GENERATION ||
           feedback->kind == SHARP_VIDEO_FEEDBACK_VSLICE_NACK ||
           feedback->kind == SHARP_VIDEO_FEEDBACK_IDR_REQ ||
           feedback->kind == SHARP_VIDEO_FEEDBACK_PRESENT_REPORT;
}
