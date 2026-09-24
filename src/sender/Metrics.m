#import "Internal.h"

@implementation SharpScreenSender (Metrics)
- (void)writeH264RegionSummaryToFile:(FILE *)file {
    if (file == NULL) {
        return;
    }
    fprintf(file,
            "m1-screen-send-h264-regions"
            " r0_id=%u r0_frames=%" PRIu64 " r0_keyframes=%" PRIu64
            " r0_pframes=%" PRIu64 " r0_nacks=%" PRIu64
            " r0_retrans=%" PRIu64 " r0_misses=%" PRIu64
            " r0_idr_req=%" PRIu64 " r0_idr_sent=%" PRIu64
            " r0_warmup_skips=%" PRIu64
            " r0_selected_frames=%" PRIu64
            " r0_lifetime_frames=%u"
            " r0_envelope=%ux%u+%u+%u"
            " r0_motion_candidate_tiles=%" PRIu64
            " r0_motion_covered_tiles=%" PRIu64
            " r0_fallback_lossless_tiles=%" PRIu64
            " r0_envelope_expands=%" PRIu64
            " r0_encoder_resets=%" PRIu64
            " r1_id=%u r1_frames=%" PRIu64 " r1_keyframes=%" PRIu64
            " r1_pframes=%" PRIu64 " r1_nacks=%" PRIu64
            " r1_retrans=%" PRIu64 " r1_misses=%" PRIu64
            " r1_idr_req=%" PRIu64 " r1_idr_sent=%" PRIu64
            " r1_warmup_skips=%" PRIu64
            " r1_selected_frames=%" PRIu64
            " r1_lifetime_frames=%u"
            " r1_envelope=%ux%u+%u+%u"
            " r1_motion_candidate_tiles=%" PRIu64
            " r1_motion_covered_tiles=%" PRIu64
            " r1_fallback_lossless_tiles=%" PRIu64
            " r1_envelope_expands=%" PRIu64
            " r1_encoder_resets=%" PRIu64 "\n",
            _h264Streams[0].active ? _h264Streams[0].region_id : 0u,
            _h264Streams[0].frames, _h264Streams[0].keyframes,
            _h264Streams[0].pframes, _h264Streams[0].nacks,
            _h264Streams[0].retransmit_packets,
            _h264Streams[0].retransmit_misses,
            _h264Streams[0].idr_requests, _h264Streams[0].idr_sent,
            _h264Streams[0].warmup_skips,
            _h264Streams[0].selected_frames,
            _h264Streams[0].active
                ? _h264Streams[0].last_seen_frame - _h264Streams[0].first_seen_frame + 1u
                : 0u,
            _h264Streams[0].width, _h264Streams[0].height,
            _h264Streams[0].x, _h264Streams[0].y,
            _h264Streams[0].candidate_motion_tiles,
            _h264Streams[0].covered_motion_tiles,
            _h264Streams[0].fallback_lossless_tiles,
            _h264Streams[0].envelope_expands,
            _h264Streams[0].encoder_resets,
            _h264Streams[1].active ? _h264Streams[1].region_id : 0u,
            _h264Streams[1].frames, _h264Streams[1].keyframes,
            _h264Streams[1].pframes, _h264Streams[1].nacks,
            _h264Streams[1].retransmit_packets,
            _h264Streams[1].retransmit_misses,
            _h264Streams[1].idr_requests, _h264Streams[1].idr_sent,
            _h264Streams[1].warmup_skips,
            _h264Streams[1].selected_frames,
            _h264Streams[1].active
                ? _h264Streams[1].last_seen_frame - _h264Streams[1].first_seen_frame + 1u
                : 0u,
            _h264Streams[1].width, _h264Streams[1].height,
            _h264Streams[1].x, _h264Streams[1].y,
            _h264Streams[1].candidate_motion_tiles,
            _h264Streams[1].covered_motion_tiles,
            _h264Streams[1].fallback_lossless_tiles,
            _h264Streams[1].envelope_expands,
            _h264Streams[1].encoder_resets);
    fprintf(file, "m1-screen-send-h264-streams");
    for (size_t i = 0; i < SHARP_H264_STREAM_TRACK_SLOTS; i++) {
        if (!_h264Streams[i].active) {
            continue;
        }
        uint32_t lifetime =
            _h264Streams[i].last_seen_frame - _h264Streams[i].first_seen_frame + 1u;
        fprintf(file,
                " id=%u frames=%" PRIu64 " key=%" PRIu64 " p=%" PRIu64
                " selected=%" PRIu64 " lifetime=%u envelope=%ux%u+%u+%u"
                " covered=%" PRIu64 " candidate=%" PRIu64
                " fallback=%" PRIu64 " resets=%" PRIu64 ";",
                _h264Streams[i].region_id, _h264Streams[i].frames,
                _h264Streams[i].keyframes, _h264Streams[i].pframes,
                _h264Streams[i].selected_frames, lifetime,
                _h264Streams[i].width, _h264Streams[i].height,
                _h264Streams[i].x, _h264Streams[i].y,
                _h264Streams[i].covered_motion_tiles,
                _h264Streams[i].candidate_motion_tiles,
                _h264Streams[i].fallback_lossless_tiles,
                _h264Streams[i].encoder_resets);
    }
    fprintf(file, "\n");
}
@end
