#pragma once
// Internal engine state. Queue and lock ownership stays unchanged during extraction.
#include "sharp/framebuf.h"
#include "sharp/hybrid.h"
#pragma clang diagnostic ignored "-Woverlength-strings"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include "sharp/shtp_net.h"
#include "sharp/shtp_protocol.h"
#include "sharp/shtp_time.h"
#include "sharp/m2_classifier.h"
#include "sharp/tile.h"
#include "sharp/tile_sender.h"
#include "sharp/video_feedback.h"
#include "sharp/video_region.h"

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <mach/mach_time.h>
#include <objc/message.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SHARP_H264_RESEND_MIN_GENERATIONS 8u
#define SHARP_H264_RESEND_MAX_GENERATIONS 32u
#define SHARP_H264_MAX_ACTIVE_REGIONS 2u
#define SHARP_H264_FIRST_LANE_ID 1u
#define SHARP_H264_FULLFRAME_ID \
    (SHARP_H264_FIRST_LANE_ID + SHARP_H264_MAX_ACTIVE_REGIONS)
#define SHARP_H264_ENCODER_SLOTS (SHARP_H264_MAX_ACTIVE_REGIONS + 1u)
#define SHARP_H264_STREAM_TRACK_SLOTS 16u
#define SHARP_H264_EMIT_TRACK_SLOTS 512u
#define SHARP_CAPTURE_TIME_TRACK_SLOTS 512u
#define SHARP_CLOCK_RTT_SAMPLES 32u
#define SHARP_FRESHNESS_BUCKETS 20u
#define SHARP_H264_REGION_WARMUP_FRAMES 5u
#define SHARP_H264_REGION_IDLE_GRACE_FRAMES 30u
#define SHARP_H264_FULLFRAME_MIN_MOTION_TILES 24u
#define SHARP_H264_FULLFRAME_MIN_QUIET_TILES 8u
#define SHARP_H264_FULLFRAME_ENTER_HOLD_NS 600000000ULL
#define SHARP_H264_FULLFRAME_SCENE_ENTER_HOLD_NS 200000000ULL
#define SHARP_H264_FULLFRAME_BURST_RATIO 0.05
#define SHARP_H264_FULLFRAME_HARD_BURST_RATIO 0.10
#define SHARP_H264_FULLFRAME_BURST_HOLD_NS 50000000ULL
#define SHARP_H264_FULLFRAME_EXIT_QUIET_NS 1500000000ULL
#define SHARP_H264_FULLFRAME_MIN_DURATION_NS 2000000000ULL
#define SHARP_H264_FULLFRAME_REENTRY_DWELL_NS 2000000000ULL
/* An SCK idle event confirms unchanged pixels, unlike classifier hysteresis. */
#define SHARP_CAPTURE_IDLE_REFINE_NS 150000000ULL
#define SHARP_TX_CLEANUP_BATCH_TILES 32u
#define SHARP_TX_LATENCY_SAMPLES 8192u
#define SHARP_SCK_STATUS_BUCKETS 8u
#define SHARP_PHASE_LOCK_LEAD_INITIAL_NS 12000000ULL
#define SHARP_PHASE_LOCK_LEAD_MIN_NS 8000000ULL
#define SHARP_PHASE_LOCK_LEAD_MAX_NS 16000000ULL
#define SHARP_PHASE_LOCK_MAX_ADJUST_NS_PER_SEC 500000ULL
#define SHARP_ROLLING_SAMPLE_CAP 4096u
#define SHARP_ROLLING_WINDOW_NS 10000000000ULL
#define SHARP_FRAME_TIMING_SLOTS 2048u

typedef struct sharp_rolling_metric {
    uint64_t observed_ns[SHARP_ROLLING_SAMPLE_CAP];
    uint64_t value_ns[SHARP_ROLLING_SAMPLE_CAP];
    uint32_t next;
    uint32_t count;
} sharp_rolling_metric_t;

typedef struct sharp_frame_timing {
    uint32_t frame_id;
    uint8_t valid;
    uint64_t source_ns;
    uint64_t callback_ns;
    uint64_t analyzer_ns;
    uint64_t analyzer_done_ns;
    uint64_t vt_submit_ns;
    uint64_t vt_callback_ns;
    uint64_t final_packet_send_ns;
} sharp_frame_timing_t;

typedef enum screen_tx_tile_kind {
    SCREEN_TX_TILE_INITIAL_SYNC = 1,
    SCREEN_TX_TILE_STATIC_DETAIL = 2,
    SCREEN_TX_TILE_REFINEMENT = 3,
    SCREEN_TX_TILE_MOTION_FALLBACK = 4
} screen_tx_tile_kind_t;



typedef struct h264_resend_chunk {
    uint8_t *packet;
    size_t len;
} h264_resend_chunk_t;

typedef struct h264_resend_generation {
    uint8_t active;
    uint8_t repair_active;
    uint16_t region_id;
    uint32_t generation;
    uint16_t chunk_count;
    uint64_t stored_ns;
    uint64_t last_feedback_ns;
    uint32_t nack_count;
    uint32_t retransmit_count;
    h264_resend_chunk_t *chunks;
} h264_resend_generation_t;

typedef struct h264_encoder_slot {
    uint8_t active;
    uint16_t region_id;
    uint32_t width;
    uint32_t height;
    VTCompressionSessionRef session;
    CVPixelBufferPoolRef pixel_buffer_pool;
} h264_encoder_slot_t;

typedef struct h264_region_stream {
    uint8_t active;
    uint8_t has_keyframe;
    uint8_t need_keyframe;
    uint8_t force_idr;
    uint16_t region_id;
    uint16_t x;
    uint16_t y;
    uint32_t width;
    uint32_t height;
    uint32_t first_seen_frame;
    uint32_t last_seen_frame;
    uint32_t consecutive_frames;
    uint64_t frames;
    uint64_t keyframes;
    uint64_t pframes;
    uint64_t nacks;
    uint64_t retransmit_packets;
    uint64_t retransmit_misses;
    uint64_t idr_requests;
    uint64_t idr_sent;
    uint64_t recovered_generations;
    uint64_t unrecovered_generations;
    uint64_t warmup_skips;
    uint64_t selected_frames;
    uint64_t candidate_motion_tiles;
    uint64_t covered_motion_tiles;
    uint64_t fallback_lossless_tiles;
    uint64_t envelope_expands;
    uint64_t encoder_resets;
} h264_region_stream_t;

typedef struct screen_tx_tile {
    uint16_t tile_id;
    uint8_t kind;
    sharp_tile_rect_t rect;
    uint8_t bgra[SHARP_TILE_BYTES];
} screen_tx_tile_t;

typedef struct screen_tx_frame_job {
    struct screen_tx_frame_job *next;
    uint32_t frame_id;
    uint64_t enqueue_ns;
    uint64_t estimated_bytes;
    uint16_t tile_count;
    uint16_t static_tiles;
    uint16_t refine_tiles;
    uint16_t motion_fallback_tiles;
    uint16_t expected_patches;
    uint16_t video_region_count;
    uint16_t video_region_mask;
    uint8_t *motion_mask;
    uint16_t motion_mask_bytes;
    uint8_t has_motion_mask;
    uint8_t initial_sync;
    screen_tx_tile_t tiles[];
} screen_tx_frame_job_t;

typedef struct screen_tx_cleanup_record {
    uint8_t active;
    uint8_t kind;
    uint8_t protected_tile;
    uint16_t tile_id;
    uint32_t frame_id;
    uint64_t enqueue_ns;
    sharp_tile_rect_t rect;
    uint8_t bgra[SHARP_TILE_BYTES];
} screen_tx_cleanup_record_t;

typedef struct screen_tile_repair_batch {
    uint32_t frame_id;
    uint16_t count;
    screen_tx_tile_t tiles[];
} screen_tile_repair_batch_t;

typedef enum sharp_h264_keyframe_reason {
    SHARP_H264_KEYFRAME_REASON_NONE = 0,
    SHARP_H264_KEYFRAME_REASON_ENTRY = 1,
    SHARP_H264_KEYFRAME_REASON_LOSS_ESCALATION = 2,
    SHARP_H264_KEYFRAME_REASON_PERIODIC = 3,
} sharp_h264_keyframe_reason_t;















typedef struct screen_config {
    const char *target_ip;
    const char *source_ip;
    unsigned int port;
    unsigned int width;
    unsigned int height;
    unsigned int duration;
    unsigned int stats_interval;
    unsigned int fps;
    unsigned int payload_size;
    unsigned int initial_full_frames;
    double full_refresh_interval;
    double pacing_mbps;
    const char *frame_log_path;
    const char *m2_log_path;
    const char *episode_log_path;
    int hybrid_h264;
    unsigned int vslice_drop_every;
    int request_permission;
    int check_permission;
} screen_config_t;

typedef struct h264_sample_context {
    uint16_t region_id;
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
    uint32_t generation;
    uint8_t full_frame_direct;
    uint8_t emit_frame_end;
    uint8_t keyframe_reason;
    uint8_t *motion_mask;
    uint16_t motion_mask_bytes;
    uint64_t submit_ns;
    uint64_t callback_ns;
    CVPixelBufferRef retained_pixel_buffer;
} h264_sample_context_t;



extern volatile sig_atomic_t g_sharp_stop_requested;
/* Set when ScreenCaptureKit ends the stream; main exits with SHARP_EXIT_CAPTURE_STOPPED. */
extern volatile sig_atomic_t g_sharp_capture_stopped;
#define SHARP_EXIT_CAPTURE_STOPPED 75

@interface SharpScreenSender : NSObject <SCStreamOutput, SCStreamDelegate> {
    pthread_mutex_t _sendLock;
    pthread_mutex_t _timingLock;
    h264_resend_generation_t _h264Resend[SHARP_H264_RESEND_MAX_GENERATIONS];
    uint8_t *_h264FecParityScratch;
    size_t _h264FecParityScratchCap;
    void *_tileZstdCCtx;
    h264_encoder_slot_t _h264Encoders[SHARP_H264_ENCODER_SLOTS];
    h264_region_stream_t _h264Streams[SHARP_H264_STREAM_TRACK_SLOTS];
    CMSampleBufferRef _pendingSampleBuffer;
    CMSampleBufferRef _lastCompleteSampleBuffer;
    sharp_hybrid_source_t *_verifiedSource;
    uint64_t _verifiedSession, _verifiedNonce, _verifiedLastControlNs, _verifiedLastMotionNs;
    uint64_t _verifiedHandshakeStartNs, _verifiedExitStartNs;
    uint32_t _verifiedLastCommitLogged, _verifiedLastMapFrame, _verifiedCommittedFrame;
    uint32_t _verifiedAttemptVersion[SHARP_HYBRID_MAX_TILES], _verifiedNextTile;
    uint64_t _verifiedLastMapNs, _verifiedLastCaptureNs;
    uint32_t _verifiedLastFlushedFrame;
    uint64_t _verifiedFirstAttemptNs[SHARP_HYBRID_MAX_TILES];
    _Atomic(uint64_t) _verifiedPacingBps;
    uint64_t _verifiedPacingAdjustNs;
    uint64_t _verifiedRateWindowNs, _verifiedRateWindowBytes;
    uint32_t _verifiedAcknowledged[SHARP_HYBRID_MAX_TILES];
    uint64_t _verifiedAttemptNs[SHARP_HYBRID_MAX_TILES];
    BOOL _verifiedReady, _verifiedWantVideo, _verifiedExitPending;
    uint32_t _verifiedDropStaticMaps, _verifiedLastDumpFrame;
    uint32_t _verifiedTargetFrame;
    dispatch_source_t _verifiedTimer;
    uint64_t _captureIdleSinceNs;
    uint64_t _motionPrerollDeadlineNs;
    BOOL _idleRefineInProgress;
    uint64_t _pendingCallbackNs;
    uint64_t _pendingSourceNs;
    uint8_t _processingScheduled;
    dispatch_source_t _encodeTickTimer;
    uint32_t _scratchTileCap;
    uint16_t *_dirtyScratch;
    uint16_t *_sendScratch;
    uint16_t *_refineScratch;
    sharp_m2_tile_probe_t *_m2ProbeScratch;
    uint8_t *_sendSeenScratch;
    uint8_t *_sendKindScratch;
    sharp_dirty_rect_t *_rectScratch;
    screen_tx_frame_job_t *_txHead;
    screen_tx_frame_job_t *_motionPrerollJob;
    uint8_t _txPumpScheduled;
    _Atomic uint8_t _txStopping;
    _Atomic uint32_t _txLatestOfferedFrame;
    uint32_t _txPendingJobs;
    screen_tx_cleanup_record_t *_cleanupRecords;
    uint32_t _cleanupTileCap;
    uint32_t _cleanupPendingTiles;
    uint64_t _cleanupLatencySamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _cleanupLatencyCount;
    uint64_t _txLatestSourceLagSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _txLatestSourceLagCount;
    uint64_t _h264FrameBytesSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _h264FrameBytesCount;
    uint32_t _h264EmittedFrameIds[SHARP_H264_EMIT_TRACK_SLOTS];
    uint16_t _h264EmittedMasks[SHARP_H264_EMIT_TRACK_SLOTS];
    uint64_t _callbackToProcessSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _callbackToProcessCount;
    uint64_t _processDurationSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _processDurationCount;
    uint64_t _fullFrameProcessDurationSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _fullFrameProcessDurationCount;
    uint64_t _fullFrameEncodeSubmitSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _fullFrameEncodeSubmitCount;
    uint64_t _fullFrameCopySamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _fullFrameCopyCount;
    uint64_t _fullFrameConvertSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _fullFrameConvertCount;
    VTPixelTransferSessionRef _vtPixelTransferSession;
    uint8_t *_fullFrameEpisodeMask;
    uint8_t *_fullFrameCurrentMask;
    uint32_t _fullFrameEpisodeMaskCap;
    uint64_t _h264CallbackLatencySamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _h264CallbackLatencyCount;
    uint64_t _sckStatusCounts[SHARP_SCK_STATUS_BUCKETS];
    uint64_t _sckStatusOther;
    uint8_t *_latestFrameBgra;
    uint32_t _latestFrameStride;
    size_t _latestFrameBytes;
    uint32_t _latestFrameBgraFrameId;
    uint8_t _latestFrameBgraValid;
    uint32_t _captureFrameIds[SHARP_CAPTURE_TIME_TRACK_SLOTS];
    uint64_t _captureFrameNs[SHARP_CAPTURE_TIME_TRACK_SLOTS];
    int64_t _clockOffsetNs;
    uint64_t _clockRttNs;
    uint64_t _clockRttSamples[SHARP_CLOCK_RTT_SAMPLES];
    uint32_t _clockRttSampleCount;
    uint64_t _g2gSamples[SHARP_TX_LATENCY_SAMPLES];
    uint32_t _g2gSampleCount;
    uint64_t _freshnessBuckets[SHARP_FRESHNESS_BUCKETS];
    uint64_t _presentReports;
    sharp_frame_timing_t _frameTimings[SHARP_FRAME_TIMING_SLOTS];
    sharp_rolling_metric_t _rollingSourceToCallback;
    sharp_rolling_metric_t _rollingCallbackToAnalyzer;
    sharp_rolling_metric_t _rollingAnalyzerToSubmit;
    sharp_rolling_metric_t _rollingVtCallback;
    sharp_rolling_metric_t _rollingCallbackToFinalSend;
    sharp_rolling_metric_t _rollingSourceToPresent;
    sharp_rolling_metric_t _rollingFinalSendToPresent;
    sharp_rolling_metric_t _rollingFinalRxToDecode;
    sharp_rolling_metric_t _rollingDecodeToPresent;
    sharp_rolling_metric_t _rollingFreshReports;
    uint64_t _lastReceiverFreshCount;
    uint8_t _haveReceiverFreshCount;
    uint64_t _sourceTimestampMissing;
    uint64_t _tileDigestPackets;
    uint64_t _tileDigestEntries;
    uint64_t _tileDigestMismatches;
    uint64_t _tileDigestRepairsQueued;
    uint64_t _encodeTickIntervalNs;
    uint64_t _encodeTickNextFireNs;
    uint64_t _phaseLockLeadNs;
    uint64_t _phaseLockLastAdjustNs;
    uint64_t _phaseLockFeedbackReports;
    uint64_t _phaseLockTimerAdjustments;
    uint64_t _phaseLockTimerAdjustmentAbsNs;
    uint64_t _phaseLockLastPeriodNs;
    int64_t _phaseLockLastErrorNs;
    int64_t _phaseLockLastAdjustmentNs;
    int _fd;
    uint32_t _width;
    uint32_t _height;
    uint32_t _sequence;
    uint32_t _frameId;
    unsigned int _payloadSize;
    unsigned int _fps;
    unsigned int _initialFullFrames;
    uint64_t _fullRefreshIntervalNs;
    uint64_t _nextFullRefreshNs;
    double _pacingMbps;
    sharp_tile_dirty_map_t _dirtyMap;
    sharp_tile_sender_stats_t _stats;
    uint64_t _firstFrameNs;
    uint64_t _captureStartNs;
    uint64_t _firstH264Ns;
    uint64_t _lastFrameNs;
    uint64_t _captureCallbacks;
    uint64_t _sentFrames;
    uint64_t _idleFrames;
    uint64_t _fullFrames;
    uint64_t _dirtyRectFrames;
    uint64_t _dirtyRects;
    uint64_t _dirtyRectScaledFrames;
    uint64_t _dirtyRectClipped;
    uint64_t _candidateTiles;
    uint64_t _falseDirtyTiles;
    uint64_t _metadataFallbackFrames;
    uint64_t _skippedFrames;
    uint64_t _replacedFrames;
    uint64_t _invalidFrames;
    FILE * _frameLog;
    FILE * _m2Log;
    FILE * _episodeLog;
    sharp_m2_classifier_t * _m2Classifier;
    uint64_t _m2MotionFrames;
    uint64_t _m2MotionTiles;
    uint64_t _m2RefineTiles;
    uint64_t _m2BornRegions;
    uint64_t _m2ResizedRegions;
    uint64_t _m2DiedRegions;
    BOOL _hybridH264;
    VTCompressionSessionRef _h264Session;
    uint32_t _h264Width;
    uint32_t _h264Height;
    uint32_t _h264RegionId;
    uint32_t _h264Generation;
    uint64_t _h264Frames;
    uint64_t _h264EncodeSubmissions;
    uint64_t _h264EncodeInFlight;
    uint64_t _h264MaxEncodeInFlight;
    uint64_t _h264PixelBufferPoolCreates;
    uint64_t _h264PixelBufferPoolFailures;
    uint64_t _h264FrameEndWaits;
    uint64_t _h264FrameEndWaitTimeouts;
    uint64_t _h264FrameEndVideoDrops;
    uint64_t _h264Packets;
    uint64_t _h264Bytes;
    uint64_t _h264TargetBitrate;
    uint64_t _h264Keyframes;
    uint64_t _h264EncodeFailures;
    uint64_t _h264FeedbackPackets;
    uint64_t _h264FullFrameFeedbackIgnored;
    uint64_t _h264FullFrameKeyframeRequests;
    uint64_t _h264MissingGenerations;
    uint64_t _h264KeyframeRequests;
    uint64_t _h264VsliceNacks;
    uint64_t _h264RetransmitPackets;
    uint64_t _h264RetransmitBytes;
    uint64_t _h264RetransmitMisses;
    uint64_t _h264IdrRequests;
    uint64_t _h264IdrSent;
    uint64_t _h264MaxActiveRegions;
    uint64_t _h264Pframes;
    uint64_t _h264WarmupSkips;
    uint64_t _h264MotionCandidateTiles;
    uint64_t _h264MotionCoveredTiles;
    uint64_t _h264MotionFallbackLosslessTiles;
    uint64_t _h264LaneAdoptions;
    uint64_t _h264LaneBirths;
    uint64_t _h264LaneRetires;
    BOOL _fullFrameEnabled;
    BOOL _fullFrameDirectFeed;
    BOOL _motionMaskEnabled;
    BOOL _motionPrerollEnabled;
    uint64_t _motionPrerollHeldFrames;
    uint64_t _motionPrerollReleasedFrames;
    uint64_t _motionPrerollDiscardedFrames;
    BOOL _fullFrameActive;
    BOOL _fullFrameForceKeyframe;
    BOOL _fullFrameExitRefinePending;
    uint64_t _fullFrameMotionStartNs;
    uint64_t _fullFrameQuietStartNs;
    uint64_t _fullFrameEnteredNs;
    uint64_t _fullFrameLastExitNs;
    uint64_t _fullFrameEntries;
    uint64_t _fullFrameExits;
    uint64_t _fullFrameModeFrames;
    uint64_t _fullFrameH264Frames;
    uint64_t _fullFrameH264Bytes;
    uint64_t _fullFrameProcessedFrames;
    uint64_t _fullFrameEncodeSubmissions;
    uint64_t _fullFrameEncodeInFlight;
    uint64_t _fullFrameMaxEncodeInFlight;
    uint64_t _fullFrameSendDrops;
    uint64_t _fullFrameTraceUntilNs;
    uint64_t _fullFrameTraceSendDropsBase;
    BOOL _fullFrameTraceKeyframeAttempted;
    uint64_t _fullFrameFrameEndsFromCallback;
    uint64_t _fullFrameDirectSubmissions;
    uint64_t _fullFrameCopiedSubmissions;
    uint64_t _fullFrameDirectFallbacks;
    uint64_t _fullFrameAnalyzerSkippedFrames;
    uint64_t _fullFrameExitRefinementTiles;
    uint64_t _fullFrameEpisodeMaskTiles;
    uint64_t _fullFrameEpisodeMaskPeakTiles;
    uint64_t _fullFrameMotionCandidateTiles;
    uint64_t _fullFrameMotionCoveredTiles;
    uint64_t _fullFrameSuppressedLosslessTiles;
    BOOL _h264AdaptiveBitrateEnabled;
    uint64_t _h264AdaptiveBitrate;
    uint64_t _h264AdaptiveMinBitrate;
    uint64_t _h264AdaptiveMaxBitrate;
    uint64_t _h264AdaptiveLastAdjustNs;
    uint64_t _h264AdaptiveBackoffs;
    uint64_t _h264AdaptiveRamps;
    uint64_t _txFrames;
    uint64_t _txTiles;
    uint64_t _txFailures;
    uint64_t _txFrameEnds;
    uint64_t _txDroppedJobs;
    uint64_t _txDroppedTiles;
    uint64_t _txDroppedMotionFallbackTiles;
    uint64_t _txDroppedRefineTiles;
    uint64_t _txDroppedStaleFrames;
    uint64_t _txCoalescedJobs;
    uint64_t _txMaxPendingJobs;
    uint64_t _txMaxJobAgeMs;
    uint64_t _txEstimatedBytes;
    uint64_t _cleanupReplacedTiles;
    uint64_t _cleanupCoalescedTiles;
    uint64_t _cleanupCancelledTiles;
    uint64_t _cleanupSentTiles;
    uint64_t _cleanupProtectedTiles;
    uint64_t _cleanupObsoleteTiles;
    uint64_t _cleanupMaxLatencyMs;
    uint64_t _txOldestCleanupAgeMs;
    uint64_t _txLatestSourceLagMaxFrames;
    uint64_t _h264InducedDrops;
    uint64_t _h264OriginalPackets;
    uint64_t _h264FecPackets;
    uint64_t _h264FecBytes;
    uint64_t _h264ResendEvictions;
    uint64_t _h264ResendRepairEvictions;
    uint64_t _h264FreshMotionSkippedForRepair;
    uint64_t _h264RepairPressureFrames;
    uint64_t _h264PostFrameRepairDrains;
    uint32_t _h264ResendTarget;
    uint32_t _h264ResendMaxActive;
    uint16_t _h264RequestedRegion;
    BOOL _h264HaveKeyframeRequest;
    BOOL _h264RequestIsIdr;
    unsigned int _vsliceDropEvery;
    BOOL _fecEnabled;
    BOOL _encodeTickEnabled;
    BOOL _tileBatchEnabled;
    BOOL _tileZstdEnabled;
    uint64_t _encodeTickFires;
    uint64_t _encodeTickIdleSkips;
    BOOL _phaseLockEnabled;
    BOOL _vtLowLatencyRequested;
    BOOL _vtLowLatencyActive;
    uint64_t _vtLowLatencyFallbacks;
    BOOL _vtSpeedPriorityActive;
    BOOL _vtFrameDelayBounded;
    BOOL _vtFastProfileRequested;
    BOOL _vtFastProfileActive;
    BOOL _vtReferenceBufferBounded;
    BOOL _vtHardwareEncoder;
    BOOL _vtNv12Requested;
    BOOL _vtNv12Active;
    uint64_t _vtPixelTransferFailures;
    uint64_t _pacingNextNs;
    dispatch_queue_t _processingQueue;
    dispatch_queue_t _txQueue;
    dispatch_queue_t _h264OutputQueue;
}
@property(nonatomic, assign) int fd;
@property(nonatomic, assign) uint32_t width;
@property(nonatomic, assign) uint32_t height;
@property(nonatomic, assign) uint32_t sequence;
@property(nonatomic, assign) uint32_t frameId;
@property(nonatomic, assign) unsigned int payloadSize;
@property(nonatomic, assign) unsigned int fps;
@property(nonatomic, assign) unsigned int initialFullFrames;
@property(nonatomic, assign) uint64_t fullRefreshIntervalNs;
@property(nonatomic, assign) uint64_t nextFullRefreshNs;
@property(nonatomic, assign) double pacingMbps;
@property(nonatomic, assign) sharp_tile_dirty_map_t dirtyMap;
@property(nonatomic, assign) sharp_tile_sender_stats_t stats;
@property(nonatomic, assign) uint64_t firstFrameNs;
@property(nonatomic, assign) uint64_t captureStartNs;
@property(nonatomic, assign) uint64_t firstH264Ns;
@property(nonatomic, assign) uint64_t lastFrameNs;
@property(nonatomic, assign) uint64_t captureCallbacks;
@property(nonatomic, assign) uint64_t sentFrames;
@property(nonatomic, assign) uint64_t idleFrames;
@property(nonatomic, assign) uint64_t fullFrames;
@property(nonatomic, assign) uint64_t dirtyRectFrames;
@property(nonatomic, assign) uint64_t dirtyRects;
@property(nonatomic, assign) uint64_t dirtyRectScaledFrames;
@property(nonatomic, assign) uint64_t dirtyRectClipped;
@property(nonatomic, assign) uint64_t candidateTiles;
@property(nonatomic, assign) uint64_t falseDirtyTiles;
@property(nonatomic, assign) uint64_t metadataFallbackFrames;
@property(nonatomic, assign) uint64_t skippedFrames;
@property(nonatomic, assign) uint64_t replacedFrames;
@property(nonatomic, assign) uint64_t invalidFrames;
@property(nonatomic, assign) FILE *frameLog;
@property(nonatomic, assign) FILE *m2Log;
@property(nonatomic, assign) FILE *episodeLog;
@property(nonatomic, assign) sharp_m2_classifier_t *m2Classifier;
@property(nonatomic, assign) uint64_t m2MotionFrames;
@property(nonatomic, assign) uint64_t m2MotionTiles;
@property(nonatomic, assign) uint64_t m2RefineTiles;
@property(nonatomic, assign) uint64_t m2BornRegions;
@property(nonatomic, assign) uint64_t m2ResizedRegions;
@property(nonatomic, assign) uint64_t m2DiedRegions;
@property(nonatomic, assign) BOOL hybridH264;
@property(nonatomic, assign) VTCompressionSessionRef h264Session;
@property(nonatomic, assign) uint32_t h264Width;
@property(nonatomic, assign) uint32_t h264Height;
@property(nonatomic, assign) uint32_t h264RegionId;
@property(nonatomic, assign) uint32_t h264Generation;
@property(nonatomic, assign) uint64_t h264Frames;
@property(nonatomic, assign) uint64_t h264EncodeSubmissions;
@property(nonatomic, assign) uint64_t h264EncodeInFlight;
@property(nonatomic, assign) uint64_t h264MaxEncodeInFlight;
@property(nonatomic, assign) uint64_t h264PixelBufferPoolCreates;
@property(nonatomic, assign) uint64_t h264PixelBufferPoolFailures;
@property(nonatomic, assign) uint64_t h264FrameEndWaits;
@property(nonatomic, assign) uint64_t h264FrameEndWaitTimeouts;
@property(nonatomic, assign) uint64_t h264FrameEndVideoDrops;
@property(nonatomic, assign) uint64_t h264Packets;
@property(nonatomic, assign) uint64_t h264Bytes;
@property(nonatomic, assign) uint64_t h264TargetBitrate;
@property(nonatomic, assign) uint64_t h264Keyframes;
@property(nonatomic, assign) uint64_t h264EncodeFailures;
@property(nonatomic, assign) uint64_t h264FeedbackPackets;
@property(nonatomic, assign) uint64_t h264FullFrameFeedbackIgnored;
@property(nonatomic, assign) uint64_t h264FullFrameKeyframeRequests;
@property(nonatomic, assign) uint64_t h264MissingGenerations;
@property(nonatomic, assign) uint64_t h264KeyframeRequests;
@property(nonatomic, assign) uint64_t h264VsliceNacks;
@property(nonatomic, assign) uint64_t h264RetransmitPackets;
@property(nonatomic, assign) uint64_t h264RetransmitBytes;
@property(nonatomic, assign) uint64_t h264RetransmitMisses;
@property(nonatomic, assign) uint64_t h264IdrRequests;
@property(nonatomic, assign) uint64_t h264IdrSent;
@property(nonatomic, assign) uint64_t h264MaxActiveRegions;
@property(nonatomic, assign) uint64_t h264Pframes;
@property(nonatomic, assign) uint64_t h264WarmupSkips;
@property(nonatomic, assign) uint64_t h264MotionCandidateTiles;
@property(nonatomic, assign) uint64_t h264MotionCoveredTiles;
@property(nonatomic, assign) uint64_t h264MotionFallbackLosslessTiles;
@property(nonatomic, assign) uint64_t h264LaneAdoptions;
@property(nonatomic, assign) uint64_t h264LaneBirths;
@property(nonatomic, assign) uint64_t h264LaneRetires;
@property(nonatomic, assign) BOOL fullFrameEnabled;
@property(nonatomic, assign) BOOL fullFrameDirectFeed;
@property(nonatomic, assign) BOOL motionMaskEnabled;
@property(nonatomic, assign) BOOL motionPrerollEnabled;
@property(nonatomic, assign) uint64_t motionPrerollHeldFrames;
@property(nonatomic, assign) uint64_t motionPrerollReleasedFrames;
@property(nonatomic, assign) uint64_t motionPrerollDiscardedFrames;
@property(nonatomic, assign) BOOL fullFrameActive;
@property(nonatomic, assign) BOOL fullFrameForceKeyframe;
@property(nonatomic, assign) BOOL fullFrameExitRefinePending;
@property(nonatomic, assign) uint64_t fullFrameMotionStartNs;
@property(nonatomic, assign) uint64_t fullFrameQuietStartNs;
@property(nonatomic, assign) uint64_t fullFrameEnteredNs;
@property(nonatomic, assign) uint64_t fullFrameLastExitNs;
@property(nonatomic, assign) uint64_t fullFrameEntries;
@property(nonatomic, assign) uint64_t fullFrameExits;
@property(nonatomic, assign) uint64_t fullFrameModeFrames;
@property(nonatomic, assign) uint64_t fullFrameH264Frames;
@property(nonatomic, assign) uint64_t fullFrameH264Bytes;
@property(nonatomic, assign) uint64_t fullFrameProcessedFrames;
@property(nonatomic, assign) uint64_t fullFrameEncodeSubmissions;
@property(nonatomic, assign) uint64_t fullFrameEncodeInFlight;
@property(nonatomic, assign) uint64_t fullFrameMaxEncodeInFlight;
@property(nonatomic, assign) uint64_t fullFrameSendDrops;
@property(nonatomic, assign) uint64_t fullFrameTraceUntilNs;
@property(nonatomic, assign) uint64_t fullFrameTraceSendDropsBase;
@property(nonatomic, assign) BOOL fullFrameTraceKeyframeAttempted;
@property(nonatomic, assign) uint64_t fullFrameFrameEndsFromCallback;
@property(nonatomic, assign) uint64_t fullFrameDirectSubmissions;
@property(nonatomic, assign) uint64_t fullFrameCopiedSubmissions;
@property(nonatomic, assign) uint64_t fullFrameDirectFallbacks;
@property(nonatomic, assign) uint64_t fullFrameAnalyzerSkippedFrames;
@property(nonatomic, assign) uint64_t fullFrameExitRefinementTiles;
@property(nonatomic, assign) uint64_t fullFrameEpisodeMaskTiles;
@property(nonatomic, assign) uint64_t fullFrameEpisodeMaskPeakTiles;
@property(nonatomic, assign) uint64_t fullFrameMotionCandidateTiles;
@property(nonatomic, assign) uint64_t fullFrameMotionCoveredTiles;
@property(nonatomic, assign) uint64_t fullFrameSuppressedLosslessTiles;
@property(nonatomic, assign) BOOL h264AdaptiveBitrateEnabled;
@property(nonatomic, assign) uint64_t h264AdaptiveBitrate;
@property(nonatomic, assign) uint64_t h264AdaptiveMinBitrate;
@property(nonatomic, assign) uint64_t h264AdaptiveMaxBitrate;
@property(nonatomic, assign) uint64_t h264AdaptiveLastAdjustNs;
@property(nonatomic, assign) uint64_t h264AdaptiveBackoffs;
@property(nonatomic, assign) uint64_t h264AdaptiveRamps;
@property(nonatomic, assign) uint64_t txFrames;
@property(nonatomic, assign) uint64_t txTiles;
@property(nonatomic, assign) uint64_t txFailures;
@property(nonatomic, assign) uint64_t txFrameEnds;
@property(nonatomic, assign) uint64_t txDroppedJobs;
@property(nonatomic, assign) uint64_t txDroppedTiles;
@property(nonatomic, assign) uint64_t txDroppedMotionFallbackTiles;
@property(nonatomic, assign) uint64_t txDroppedRefineTiles;
@property(nonatomic, assign) uint64_t txDroppedStaleFrames;
@property(nonatomic, assign) uint64_t txCoalescedJobs;
@property(nonatomic, assign) uint64_t txMaxPendingJobs;
@property(nonatomic, assign) uint64_t txMaxJobAgeMs;
@property(nonatomic, assign) uint64_t txEstimatedBytes;
@property(nonatomic, assign) uint64_t cleanupReplacedTiles;
@property(nonatomic, assign) uint64_t cleanupCoalescedTiles;
@property(nonatomic, assign) uint64_t cleanupCancelledTiles;
@property(nonatomic, assign) uint64_t cleanupSentTiles;
@property(nonatomic, assign) uint64_t cleanupProtectedTiles;
@property(nonatomic, assign) uint64_t cleanupObsoleteTiles;
@property(nonatomic, assign) uint64_t cleanupMaxLatencyMs;
@property(nonatomic, readonly) uint64_t tileDigestPackets;
@property(nonatomic, readonly) uint64_t tileDigestEntries;
@property(nonatomic, readonly) uint64_t tileDigestMismatches;
@property(nonatomic, readonly) uint64_t tileDigestRepairsQueued;
@property(nonatomic, assign) uint64_t txOldestCleanupAgeMs;
@property(nonatomic, assign) uint64_t txLatestSourceLagMaxFrames;
@property(nonatomic, assign) uint64_t h264InducedDrops;
@property(nonatomic, assign) uint64_t h264OriginalPackets;
@property(nonatomic, assign) uint64_t h264FecPackets;
@property(nonatomic, assign) uint64_t h264FecBytes;
@property(nonatomic, assign) uint64_t h264ResendEvictions;
@property(nonatomic, assign) uint64_t h264ResendRepairEvictions;
@property(nonatomic, assign) uint64_t h264FreshMotionSkippedForRepair;
@property(nonatomic, assign) uint64_t h264RepairPressureFrames;
@property(nonatomic, assign) uint64_t h264PostFrameRepairDrains;
@property(nonatomic, assign) uint32_t h264ResendTarget;
@property(nonatomic, assign) uint32_t h264ResendMaxActive;
@property(nonatomic, assign) uint16_t h264RequestedRegion;
@property(nonatomic, assign) BOOL h264HaveKeyframeRequest;
@property(nonatomic, assign) BOOL h264RequestIsIdr;
@property(nonatomic, assign) unsigned int vsliceDropEvery;
@property(nonatomic, assign) BOOL fecEnabled;
@property(nonatomic, assign) BOOL encodeTickEnabled;
@property(nonatomic, assign) BOOL tileBatchEnabled;
@property(nonatomic, assign) BOOL tileZstdEnabled;
@property(nonatomic, assign) uint64_t encodeTickFires;
@property(nonatomic, assign) uint64_t encodeTickIdleSkips;
@property(nonatomic, assign) BOOL phaseLockEnabled;
@property(nonatomic, assign) BOOL vtLowLatencyRequested;
@property(nonatomic, assign) BOOL vtLowLatencyActive;
@property(nonatomic, assign) uint64_t vtLowLatencyFallbacks;
@property(nonatomic, assign) BOOL vtSpeedPriorityActive;
@property(nonatomic, assign) BOOL vtFrameDelayBounded;
@property(nonatomic, assign) BOOL vtFastProfileRequested;
@property(nonatomic, assign) BOOL vtFastProfileActive;
@property(nonatomic, assign) BOOL vtReferenceBufferBounded;
@property(nonatomic, assign) BOOL vtHardwareEncoder;
@property(nonatomic, assign) BOOL vtNv12Requested;
@property(nonatomic, assign) BOOL vtNv12Active;
@property(nonatomic, assign) uint64_t vtPixelTransferFailures;
@property(nonatomic, assign) uint64_t phaseLockFeedbackReports;
@property(nonatomic, assign) uint64_t phaseLockTimerAdjustments;
@property(nonatomic, assign) uint64_t phaseLockTimerAdjustmentAbsNs;
@property(nonatomic, assign) uint64_t phaseLockLeadNs;
@property(nonatomic, assign) uint64_t phaseLockLastPeriodNs;
@property(nonatomic, assign) int64_t phaseLockLastErrorNs;
@property(nonatomic, assign) int64_t phaseLockLastAdjustmentNs;
@property(nonatomic, assign) uint64_t pacingNextNs;
@property(nonatomic, strong) dispatch_queue_t processingQueue;
@property(nonatomic, strong) dispatch_queue_t txQueue;
@property(nonatomic, strong) dispatch_queue_t h264OutputQueue;
- (instancetype)init;
- (void)dealloc;
- (sharp_tile_sender_codec_t)tileCodec;
- (BOOL)ensureTileZstdContext;
- (int)ensureFrameScratchCapacity:(uint32_t)tileCount;
- (int)ensureFullFrameEpisodeMaskCapacity:(uint32_t)tileCount;
- (void)beginFullFrameEpisodeForTileCount:(uint32_t)tileCount;
- (void)clearCurrentMotionMask;
- (void)addMotionMaskTile:(uint16_t)tileId;
- (void)addMotionMaskRects:(const sharp_dirty_rect_t *)rects
                     count:(size_t)rectCount
                 tileCount:(uint32_t)tileCount;
- (uint64_t)countMotionMaskTiles:(uint32_t)tileCount;
- (BOOL)hotPathRectsContainOnlyMotion:(const sharp_dirty_rect_t *)rects
                                count:(size_t)rectCount
                            tileCount:(uint32_t)tileCount;
- (void)destroyFrameScratch;
- (int)ensureCleanupCapacity:(uint32_t)tileCount;
- (void)destroyCleanupState;
- (int)ensureLatestFrameCapacityWithStride:(uint32_t)stride;
- (void)destroyLatestFrame;
- (int)copyLatestFrameTileForRecord:(screen_tx_cleanup_record_t *)record;
- (int)setupDirtyMap;
- (void)destroyDirtyMap;
- (int)setupM2ClassifierWithFps:(uint32_t)fps;
- (void)destroyM2Classifier;
- (void)destroyH264ResendRing;
@end

@interface SharpScreenSender (Motion)
- (h264_region_stream_t *)h264StreamForRegion:(uint16_t)regionId
                                        create:(BOOL)create
                                       frameId:(uint32_t)frameId;
- (void)retireH264StreamForRegion:(uint16_t)regionId;
- (void)observeH264Region:(const sharp_m2_region_t *)region
                  frameId:(uint32_t)frameId;
- (uint16_t)laneIdForRegion:(const sharp_m2_region_t *)region
                    frameId:(uint32_t)frameId
                     create:(BOOL)create;
- (void)observeH264LaneRegion:(const sharp_m2_region_t *)region
                        laneId:(uint16_t)laneId
                       frameId:(uint32_t)frameId;
- (void)updateFullFrameModeWithMotionTiles:(uint32_t)motionTiles
                            activityTiles:(uint32_t)activityTiles
                     sustainedMotionTiles:(uint32_t)sustainedMotionTiles
                            uncoveredTiles:(uint32_t)uncoveredTiles
                             motionRegions:(uint32_t)motionRegions
                                  tileCount:(uint32_t)tileCount
                                  forceFull:(BOOL)forceFull;
- (void)logFullFrameEvent:(const char *)event
                    reason:(const char *)reason
              motionTiles:(uint32_t)motionTiles
      sustainedMotionTiles:(uint32_t)sustainedMotionTiles
              motionRegions:(uint32_t)motionRegions
                 tileCount:(uint32_t)tileCount
                    heldNs:(uint64_t)heldNs
                   quietNs:(uint64_t)quietNs;
- (void)traceFullFrameFrameId:(uint32_t)frameId
                 preSubmitted:(BOOL)preSubmitted
                    submitted:(BOOL)submitted
                  forceKeyframe:(BOOL)forceKeyframe;
- (void)retransmitH264Region:(uint16_t)regionId
                  generation:(uint32_t)generation
                  firstChunk:(uint16_t)firstChunk
                  chunkCount:(uint16_t)chunkCount;
@end

@interface SharpScreenSender (Feedback)
- (void)sendClockPing;
- (void)handleClockPong:(const shtp_header_t *)sh payload:(const uint8_t *)payload;
- (void)recordCaptureTimestampForFrameId:(uint32_t)frameId
                              timestampNs:(uint64_t)timestampNs;
- (void)recordFrameTimingFrameId:(uint32_t)frameId
                         sourceNs:(uint64_t)sourceNs
                       callbackNs:(uint64_t)callbackNs
                       analyzerNs:(uint64_t)analyzerNs;
- (void)recordAnalyzerDoneForFrameId:(uint32_t)frameId
                           timestamp:(uint64_t)timestampNs;
- (void)recordVtSubmitForFrameId:(uint32_t)frameId timestamp:(uint64_t)timestampNs;
- (void)recordVtCallbackForFrameId:(uint32_t)frameId timestamp:(uint64_t)timestampNs;
- (void)recordFinalPacketSendForFrameId:(uint32_t)frameId
                              timestamp:(uint64_t)timestampNs;
- (uint64_t)rollingPercentileForMetric:(const sharp_rolling_metric_t *)metric
                                  nowNs:(uint64_t)nowNs
                             percentile:(double)percentile
                                  count:(uint32_t *)countOut;
- (double)rollingRateForMetric:(const sharp_rolling_metric_t *)metric
                          nowNs:(uint64_t)nowNs;
- (uint64_t)rollingSourceToPresentPercentileNs:(double)percentile
                                           nowNs:(uint64_t)nowNs;
- (double)rollingReceiverFreshFpsNowNs:(uint64_t)nowNs;
- (void)writeRollingStageTelemetryNowNs:(uint64_t)nowNs toFile:(FILE *)file;
- (uint64_t)captureTimestampForFrameId:(uint32_t)frameId;
- (void)handlePresentReport:(const sharp_video_feedback_t *)feedback
                    frameId:(uint32_t)frameId;
- (void)updatePhaseLockFromFeedback:(const sharp_video_feedback_t *)feedback;
- (uint64_t)g2gPercentileNs:(double)percentile;
- (void)freshnessHistogramString:(char *)buffer size:(size_t)size;
- (void)handleTileDigestPayload:(const uint8_t *)payload length:(size_t)length;
- (void)drainFeedback;
- (void)paceAfterBytes:(size_t)bytes;
- (int)sendFrameEndFrameId:(uint32_t)frameId
             expectedPatches:(uint16_t)expectedPatches
              videoRegionMask:(uint16_t)videoRegionMask
                    motionMask:(const uint8_t *)motionMask
               motionMaskBytes:(uint16_t)motionMaskBytes;
@end

@interface SharpScreenSender (Encoder)
- (void)destroyH264Encoder;
- (void)flushH264Encoders;
- (void)destroyH264EncoderAtIndex:(size_t)index;
- (int)ensureH264EncoderWidth:(uint32_t)width height:(uint32_t)height;
- (VTCompressionSessionRef)ensureH264EncoderForRegion:(uint16_t)regionId
                                                width:(uint32_t)width
                                               height:(uint32_t)height;
- (h264_encoder_slot_t *)h264EncoderSlotForRegion:(uint16_t)regionId;
- (void)applyH264Bitrate:(uint64_t)bitrate toRegion:(uint16_t)regionId;
- (void)noteFullFrameVideoLossFeedback;
- (void)maybeRampFullFrameBitrate;
- (int)sendH264Blob:(const uint8_t *)blob
             length:(size_t)blobLen
            context:(const h264_sample_context_t *)context
              flags:(uint32_t)flags;
- (void)handleEncodedSample:(CMSampleBufferRef)sampleBuffer context:(void *)rawContext;
- (void)finishFullFrameEncodeSendForContext:(const h264_sample_context_t *)context;
- (BOOL)encodeH264FullFrame:(CVPixelBufferRef)pixelBuffer
                    frameId:(uint32_t)frameId
              forceKeyframe:(BOOL)forceKeyframe
                     direct:(BOOL)direct
               sourceLocked:(BOOL)sourceLocked
               emitFrameEnd:(BOOL)emitFrameEnd;
- (void)encodeH264Region:(const sharp_m2_region_t *)region
                    bgra:(const uint8_t *)bgra
                  stride:(uint32_t)stride
                 frameId:(uint32_t)frameId
            forceKeyframe:(BOOL)forceKeyframe;
@end

@interface SharpScreenSender (Transport)
- (void)sendBye;
- (void)sendCursorPositionX:(int32_t)x
                          y:(int32_t)y
                        seq:(uint32_t)cursorSeq
               sampleTimeNs:(uint64_t)sampleTimeNs
                    imageId:(uint32_t)imageId
                    visible:(BOOL)visible;
- (screen_tx_frame_job_t *)mergeMotionPrerollJob:(screen_tx_frame_job_t *)held
                                         withJob:(screen_tx_frame_job_t *)current
                                            bgra:(const uint8_t *)bgra
                                          stride:(uint32_t)stride
                                       tileCount:(uint32_t)tileCount;
- (void)enqueueTxFrameJob:(screen_tx_frame_job_t *)job;
- (BOOL)txJobClosesMotionMask:(const screen_tx_frame_job_t *)job;
- (void)coalesceQueuedJobToCleanup:(screen_tx_frame_job_t *)job
                              nowNs:(uint64_t)nowNs;
- (void)compactCleanupFromTxJob:(screen_tx_frame_job_t **)jobPtr
                           nowNs:(uint64_t)nowNs;
- (void)storeCleanupTile:(const screen_tx_tile_t *)tile
                 frameId:(uint32_t)frameId
               enqueueNs:(uint64_t)enqueueNs;
- (uint16_t)sendCleanupBatch;
- (void)sendFinalLatestFrameRefresh;
- (void)stopTxAndSendFinal;
- (void)requestTxStop;
- (uint32_t)cleanupPendingTileCount;
- (uint64_t)cleanupLatencyPercentile:(double)percentile;
- (uint64_t)txLatestSourceLagPercentile:(double)percentile;
- (uint64_t)h264FrameBytesPercentile:(double)percentile;
- (uint64_t)callbackToProcessLatencyPercentileNs:(double)percentile;
- (uint64_t)processDurationPercentileNs:(double)percentile;
- (uint64_t)fullFrameProcessDurationPercentileNs:(double)percentile;
- (uint64_t)fullFrameEncodeSubmitDurationPercentileNs:(double)percentile;
- (uint64_t)fullFrameCopyDurationPercentileNs:(double)percentile;
- (uint64_t)fullFrameConvertDurationPercentileNs:(double)percentile;
- (uint64_t)h264CallbackLatencyPercentileNs:(double)percentile;
- (uint64_t)sckStatusCountAtIndex:(unsigned int)index;
- (uint64_t)sckStatusOtherCount;
- (uint64_t)h264EncoderResetCount;
- (void)markH264EmittedRegion:(uint16_t)regionId frameId:(uint32_t)frameId;
- (uint16_t)emittedH264MaskForFrame:(uint32_t)frameId;
- (uint16_t)waitForH264Frame:(uint32_t)frameId
                         mask:(uint16_t)mask
                    timeoutNs:(uint64_t)timeoutNs;
- (void)dropTxJob:(screen_tx_frame_job_t *)job;
- (uint64_t)txScoreForJob:(const screen_tx_frame_job_t *)job
                    nowNs:(uint64_t)nowNs;
- (screen_tx_frame_job_t *)takeNextTxJob;
- (void)txPump;
- (void)paceAfterTile:(uint16_t)tileId;
@end

@interface SharpScreenSender (Capture)
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error;
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type;
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
                  callbackNs:(uint64_t)callbackNs
                    sourceNs:(uint64_t)sourceNs;
- (BOOL)shouldEnqueueCaptureSample:(CMSampleBufferRef)sampleBuffer;
- (void)noteCaptureIdleAtTime:(uint64_t)nowNs;
- (void)finishCaptureIdleSince:(uint64_t)idleSinceNs;
- (void)scheduleMotionPrerollDeadline;
- (BOOL)processOnePendingSample;
- (void)processPendingSamples;
- (void)startEncodeTick;
- (void)stopEncodeTick;
- (BOOL)processFullFrameHotPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                  info:(NSDictionary *)info
                            callbackNs:(uint64_t)callbackNs
                             forceFull:(BOOL)forceFull
                              tileCount:(uint32_t)tileCount
                preSubmittedFullFrame:(BOOL)preSubmittedFullFrame;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer
                  callbackNs:(uint64_t)callbackNs
                    sourceNs:(uint64_t)sourceNs;
@end

@interface SharpScreenSender (Hybrid)
- (void)sendVerifiedMessage:(sharp_hybrid_message_t *)message;
- (void)startVerifiedHybrid;
- (void)handleVerifiedMessage:(NSData *)data;
- (void)submitVerifiedVideo:(CVPixelBufferRef)pixels;
- (void)processVerifiedPixels:(CVPixelBufferRef)pixels now:(uint64_t)now;
- (void)verifiedMaintenance;
@end

@interface SharpScreenSender (Metrics)
- (void)writeH264RegionSummaryToFile:(FILE *)file;
@end

// Shared platform helpers.
void set_h264_709_color_attachments(CVPixelBufferRef pixelBuffer);
void h264_resend_generation_clear(h264_resend_generation_t *gen);
void h264_resend_ring_clear(h264_resend_generation_t *ring, size_t cap);
h264_resend_generation_t *h264_resend_find_generation(
    h264_resend_generation_t *ring, size_t cap, uint16_t region_id,
    uint32_t generation);
size_t h264_resend_count_active(const h264_resend_generation_t *ring,
                                       size_t cap);
size_t h264_resend_choose_slot(h264_resend_generation_t *ring, size_t cap,
                                      size_t target, uint64_t now_ns);
h264_resend_generation_t *h264_resend_begin_generation(
    h264_resend_generation_t *ring, size_t cap, size_t target,
    uint16_t region_id, uint32_t generation, uint16_t chunk_count,
    int *evicted_repair_out);
int h264_resend_store_packet(h264_resend_generation_t *gen,
                                    uint16_t chunk_id,
                                    const uint8_t *packet, size_t len);
void sharp_screen_send_signal_handler(int signo);
void h264_snap_large_envelope(sharp_m2_region_t *region,
                                     uint32_t stream_width,
                                     uint32_t stream_height);
int32_t h264_target_bitrate(uint32_t width, uint32_t height,
                                   uint32_t fps);
int env_flag_enabled(const char *name);
int env_flag_disabled(const char *name);
uint8_t sharp_fec_group_count(uint16_t chunk_count);
uint8_t sharp_fec_group_for_chunk(uint16_t chunk_id,
                                         uint16_t chunk_count,
                                         uint8_t fec_g);
double env_double_or_default(const char *name, double default_value);
void usage(FILE *stream);
int parse_args(int argc, char **argv, screen_config_t *config);
void h264_output_callback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer);
void write_be32(uint8_t *p, uint32_t value);
int compare_u64(const void *a, const void *b);
uint64_t percentile_u64(const uint64_t *samples, uint32_t count,
                               double percentile);
uint64_t sharp_mach_absolute_to_ns(uint64_t ticks);
uint64_t sharp_screen_source_time_ns(CMSampleBufferRef sampleBuffer,
                                            uint64_t callbackNs);
void rolling_metric_add(sharp_rolling_metric_t *metric,
                               uint64_t observedNs, uint64_t valueNs);
uint64_t rolling_metric_percentile(const sharp_rolling_metric_t *metric,
                                          uint64_t nowNs, uint64_t windowNs,
                                          double percentile,
                                          uint32_t *countOut);
double rolling_metric_rate(const sharp_rolling_metric_t *metric,
                                  uint64_t nowNs, uint64_t windowNs);
unsigned int sck_status_bucket(NSInteger status);
int region_contains_tile(const sharp_m2_region_t *region, uint32_t width,
                                uint32_t height, uint16_t tile_id);
uint64_t rect_intersection_area_u64(uint32_t ax, uint32_t ay,
                                           uint32_t aw, uint32_t ah,
                                           uint32_t bx, uint32_t by,
                                           uint32_t bw, uint32_t bh);
uint64_t rect_center_distance2_u64(uint32_t ax, uint32_t ay,
                                          uint32_t aw, uint32_t ah,
                                          uint32_t bx, uint32_t by,
                                          uint32_t bw, uint32_t bh);
void h264_region_envelope(const sharp_m2_region_t *region,
                                 uint32_t stream_width, uint32_t stream_height,
                                 sharp_m2_region_t *out);
void insert_selected_region(sharp_m2_region_t *selected,
                                   uint64_t *selected_scores,
                                   size_t *selected_count,
                                   const sharp_m2_region_t *candidate,
                                   uint64_t score);
int rect_from_metadata_value(id value, NSRect *rect_out);
NSRect rect_from_info(NSDictionary *info, SCStreamFrameInfo key);
size_t collect_dirty_rects(NSDictionary *info, uint32_t width, uint32_t height,
                                  sharp_dirty_rect_t *out, size_t out_cap,
                                  int *metadata_present, int *scaled_out,
                                  uint64_t *clipped_out);
SCDisplay *find_main_display(SCShareableContent *content);
SCDisplay *find_display_with_id(SCShareableContent *content,
                                       CGDirectDisplayID displayID);
SCShareableContent *sharp_copy_shareable_content(NSError **errorOut);
NSRect sharp_appkit_frame_for_display(CGDirectDisplayID displayID);
size_t sharp_cursor_shapes_prepare(void);
uint32_t sharp_cursor_image_id(NSCursor *cursor);
int sharp_virtual_display_api_available(void);
id sharp_create_virtual_display(uint32_t width,
                                       uint32_t height,
                                       double refreshRate,
                                       CGDirectDisplayID *displayIdOut);
int sharp_mirror_physical_display_from_virtual(
    CGDirectDisplayID physicalDisplayID,
    CGDirectDisplayID virtualDisplayID);
int sharp_select_display_mode(CGDirectDisplayID displayID,
                              uint32_t width,
                              uint32_t height);
int sharp_probe_virtual_display_creation(CGDirectDisplayID *displayIdOut);
