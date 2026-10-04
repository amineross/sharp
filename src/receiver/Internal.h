#pragma once
// Internal engine state. Queue and lock ownership stays unchanged during extraction.
#include "sharp/hybrid.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/CGLIOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreVideo/CVPixelBufferIOSurface.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

#include "sharp/net_ring.h"
#include "sharp/shtp_net.h"
#include "sharp/shtp_time.h"
#include "sharp/tile_receiver.h"
#include "sharp/video_feedback.h"
#include "sharp/video_region.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach/mach_time.h>

typedef enum sharp_video_texture_mode {
    SHARP_VIDEO_TEXTURE_BGRA = 0,
    SHARP_VIDEO_TEXTURE_DECODER = 1,
    SHARP_VIDEO_TEXTURE_NV12 = 2,
} sharp_video_texture_mode_t;

typedef struct display_config {
    const char *bind_ip;
    unsigned int port;
    unsigned int width;
    unsigned int height;
    unsigned int rcvbuf;
    unsigned int scale;
    unsigned int window_width;
    unsigned int window_height;
    const char *snapshot_path;
    const char *presenter_snapshot_path;
    const char *presenter_snapshot_dir;
    unsigned int presenter_snapshot_every;
    unsigned int presenter_snapshot_max;
    const char *frame_log_path;
    const char *cursor_path;
    const char *cursor_dir;
    int fullscreen;
    int keep_open;
    int check_compatibility;
    int expect_synthetic;
    int bake_video_handoff;
    int net_threads;
    int recvmsg_x;
    unsigned int net_drain_packet_budget;
    uint64_t net_drain_time_budget_ns;
    sharp_video_texture_mode_t video_texture_mode;
} display_config_t;

#define SHARP_COMMIT_TRACK_SLOTS 512u
#define SHARP_MAX_VIDEO_REGIONS 3u
#define SHARP_H264_FULLFRAME_ID 3u
#define SHARP_MAX_H264_DECODERS 16u
#define SHARP_NET_DRAIN_PACKET_BUDGET_DEFAULT 2048u
#define SHARP_NET_DRAIN_TIME_BUDGET_NS_DEFAULT 2000000ULL
#define SHARP_VIDEO_LAYER_RETIRE_MISSES 8u
#define SHARP_PRESENT_INTERVAL_SAMPLES 8192u
#define SHARP_NET_RING_CAPACITY 4096u
#define SHARP_RECVMSG_X_BATCH 16u
#define SHARP_VSYNC_FEEDBACK_INTERVAL_NS 100000000ULL
#define SHARP_MOTION_MASK_MAX_BYTES 4096u

typedef enum sharp_nv12_matrix {
    SHARP_NV12_MATRIX_BT601 = 0,
    SHARP_NV12_MATRIX_BT709 = 1,
} sharp_nv12_matrix_t;

typedef struct sharp_msghdr_x {
    void *msg_name;
    socklen_t msg_namelen;
    struct iovec *msg_iov;
    int msg_iovlen;
    void *msg_control;
    socklen_t msg_controllen;
    int msg_flags;
    size_t msg_datalen;
} sharp_msghdr_x_t;



typedef struct sharp_dirty_bounds {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
    uint8_t valid;
} sharp_dirty_bounds_t;

typedef struct sharp_video_layer_snapshot {
    uint8_t active;
    uint8_t updated;
    uint8_t missed_commits;
    uint16_t region_id;
    sharp_video_region_chunk_header_t header;
    CVPixelBufferRef pixel_buffer;
    uint64_t final_packet_rx_ns;
    uint64_t decode_callback_ns;
} sharp_video_layer_snapshot_t;

typedef struct sharp_video_frame_regions {
    uint8_t count;
    uint16_t ids[SHARP_MAX_VIDEO_REGIONS];
} sharp_video_frame_regions_t;

typedef struct sharp_cursor_snapshot {
    uint8_t visible;
    int32_t x;
    int32_t y;
    uint32_t seq;
    uint16_t hotspot_x;
    uint16_t hotspot_y;
    uint32_t image_id;
} sharp_cursor_snapshot_t;

/* Cursor samples on the sender's clock, replayed slightly late so motion is
 * interpolated between real positions instead of guessed from arrival times. */
#define SHARP_CURSOR_HISTORY 32u
typedef struct sharp_cursor_sample {
    uint64_t sample_ns;
    int32_t x;
    int32_t y;
    uint32_t image_id;
    uint32_t visible;
} sharp_cursor_sample_t;

typedef struct sharp_cursor_texture_slot {
    GLuint texture;
    uint32_t width;
    uint32_t height;
    uint16_t hotspot_x;
    uint16_t hotspot_y;
} sharp_cursor_texture_slot_t;

typedef enum sharp_render_wait_reason {
    SHARP_RENDER_WAIT_NONE = 0,
    SHARP_RENDER_WAIT_NO_STAGING = 1,
    SHARP_RENDER_WAIT_NO_EXPECTED = 2,
    SHARP_RENDER_WAIT_NO_PATCH = 3,
    SHARP_RENDER_WAIT_NEWER_STAGED = 4,
    SHARP_RENDER_WAIT_MISSING_LOSSLESS = 5,
    SHARP_RENDER_WAIT_MISSING_VIDEO = 6
} sharp_render_wait_reason_t;

typedef struct sharp_video_texture_slot {
    uint8_t active;
    uint16_t region_id;
    GLuint bgra_texture;
    GLuint y_texture;
    GLuint uv_texture;
    GLenum texture_target;
    GLuint texture_name;
    uint32_t width;
    uint32_t height;
    CVOpenGLTextureRef cv_texture;
    int last_update_kind;
    sharp_nv12_matrix_t nv12_matrix;
} sharp_video_texture_slot_t;

typedef struct sharp_h264_decoder_slot {
    uint8_t active;
    uint16_t region_id;
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
} sharp_h264_decoder_slot_t;

typedef struct sharp_h264_decode_context {
    sharp_video_region_chunk_header_t header;
    uint64_t session_id;
    uint64_t submit_ns;
    uint64_t arrival_seq;
    uint64_t final_packet_rx_ns;
} sharp_h264_decode_context_t;

typedef struct sharp_h264_region_stats {
    uint8_t active;
    uint16_t region_id;
    uint64_t frames;
    uint64_t nacks_sent;
    uint64_t idr_requests_sent;
    uint64_t recovered_generations;
    uint64_t unrecovered_generations;
    uint64_t invalid;
} sharp_h264_region_stats_t;

@interface SharpFramebufferView : NSOpenGLView {
    sharp_video_texture_slot_t _videoSlots[SHARP_MAX_VIDEO_REGIONS];
    sharp_cursor_texture_slot_t _cursorSlots[SHARP_CURSOR_IMAGE_MAX];
    uint8_t _motionMaskTextureData[SHARP_MOTION_MASK_MAX_BYTES];
    uint32_t _motionMaskTextureBytes;
    GLuint _program;
    GLuint _rectProgram;
    GLuint _nv12Program;
    GLuint _colorProgram;
    GLuint _maskProgram;
    GLuint _texture;
    GLuint _motionMaskTexture;
    GLuint _vao;
    GLuint _vbo;
    GLuint _videoVbo;
    GLuint _cursorVbo;
    GLuint _cursorTexture;
    uint32_t _cursorTextureWidth;
    uint32_t _cursorTextureHeight;
    float _cursorScale;
    double _cursorHue;
    NSString * _cursorPath;
    NSString * _cursorDir;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CVOpenGLTextureCacheRef _videoTextureCache;
    int _lastVideoUpdateKind;
    NSData *_testVideoPPM; // Optional pre-overlay readback for paired quality experiments.
    sharp_video_texture_mode_t _videoTextureMode;
    float _videoSharpen;
}
@property(nonatomic, assign) GLuint program;
@property(nonatomic, assign) GLuint rectProgram;
@property(nonatomic, assign) GLuint nv12Program;
@property(nonatomic, assign) GLuint colorProgram;
@property(nonatomic, assign) GLuint maskProgram;
@property(nonatomic, assign) GLuint texture;
@property(nonatomic, assign) GLuint motionMaskTexture;
@property(nonatomic, assign) GLuint vao;
@property(nonatomic, assign) GLuint vbo;
@property(nonatomic, assign) GLuint videoVbo;
@property(nonatomic, assign) GLuint cursorVbo;
@property(nonatomic, assign) GLuint cursorTexture;
@property(nonatomic, assign) uint32_t cursorTextureWidth;
@property(nonatomic, assign) uint32_t cursorTextureHeight;
@property(nonatomic, assign) float cursorScale;
@property(nonatomic, copy) NSString *cursorPath;
@property(nonatomic, copy) NSString *cursorDir;
@property(nonatomic, assign) uint32_t textureWidth;
@property(nonatomic, assign) uint32_t textureHeight;
@property(nonatomic, assign) CVOpenGLTextureCacheRef videoTextureCache;
@property(nonatomic, assign) int lastVideoUpdateKind;
@property(nonatomic, assign) sharp_video_texture_mode_t videoTextureMode;
@property(nonatomic, assign) float videoSharpen;
- (instancetype)initWithFrame:(NSRect)frameRect;
- (void)prepareOpenGL;
- (void)updateCursorScale:(double)scale hue:(double)hue;
- (void)setDrawableViewportWidth:(uint32_t)drawableWidth
                   drawableHeight:(uint32_t)drawableHeight
                             clear:(BOOL)clear;
- (void)drawCurrentTextureInDrawableWidth:(uint32_t)drawableWidth
                           drawableHeight:(uint32_t)drawableHeight;
- (void)drawCurrentTextureMaskedInDrawableWidth:(uint32_t)drawableWidth
                                   drawableHeight:(uint32_t)drawableHeight
                                  motionMaskBytes:(uint32_t)motionMaskBytes;
- (void)drawCurrentTextureWithViewportWidth:(uint32_t)viewportWidth
                             viewportHeight:(uint32_t)viewportHeight;
- (sharp_video_texture_slot_t *)slotForRegion:(uint16_t)regionId create:(BOOL)create;
- (void)releaseVideoSlot:(sharp_video_texture_slot_t *)slot;
- (void)releaseVideoRegion:(uint16_t)regionId;
- (void)drawVideoLayer:(const sharp_video_layer_snapshot_t *)layer
                  slot:(const sharp_video_texture_slot_t *)slot;
- (void)drawCursorTriangleX:(float)x
                          y:(float)y
                      width:(float)w
                     height:(float)h
                      colorR:(float)r
                           g:(float)g
                           b:(float)b;
- (void)drawCursor:(const sharp_cursor_snapshot_t *)cursor;
- (BOOL)loadCursorTexture;
- (BOOL)loadCursorTexturePath:(NSString *)path
                         slot:(sharp_cursor_texture_slot_t *)slot;
- (void)loadCursorThemeTextures;
- (int)bindDecoderTextureLayer:(const sharp_video_layer_snapshot_t *)layer
                          slot:(sharp_video_texture_slot_t *)slot;
- (int)bindNv12IOSurfaceLayer:(const sharp_video_layer_snapshot_t *)layer
                         slot:(sharp_video_texture_slot_t *)slot;
- (int)uploadVideoLayer:(const sharp_video_layer_snapshot_t *)layer
                   slot:(sharp_video_texture_slot_t *)slot;
- (int)uploadMotionMask:(const uint8_t *)motionMask bytes:(uint32_t)motionMaskBytes;
- (int)renderFramebuf:(const sharp_framebuf_t *)fb
        viewportWidth:(uint32_t)viewportWidth
       viewportHeight:(uint32_t)viewportHeight
          dirtyBounds:(const sharp_dirty_bounds_t *)dirtyBounds
          videoLayers:(const sharp_video_layer_snapshot_t *)videoLayers
       videoLayerCount:(size_t)videoLayerCount
     deactivateRegions:(const uint16_t *)deactivateRegions
 deactivateRegionCount:(size_t)deactivateRegionCount
            motionMask:(const uint8_t *)motionMask
       motionMaskBytes:(uint32_t)motionMaskBytes
               cursor:(const sharp_cursor_snapshot_t *)cursor;
- (void)drawRect:(NSRect)dirtyRect;
- (int)writePresenterSnapshotPath:(const char *)path;
- (void)dealloc;
@end

@interface SharpDisplayApp : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    pthread_mutex_t _stateLock;
    uint32_t _endFrameIds[SHARP_COMMIT_TRACK_SLOTS];
    sharp_video_frame_regions_t _endVideoRegions[SHARP_COMMIT_TRACK_SLOTS];
    sharp_video_frame_regions_t _observedVideoRegions[SHARP_COMMIT_TRACK_SLOTS];
    uint32_t _observedVideoFrameIds[SHARP_COMMIT_TRACK_SLOTS];
    uint8_t _observedVideoValid[SHARP_COMMIT_TRACK_SLOTS];
    uint8_t _endValid[SHARP_COMMIT_TRACK_SLOTS];
    uint8_t _endHasVideo[SHARP_COMMIT_TRACK_SLOTS];
    sharp_video_layer_snapshot_t _videoLayers[SHARP_MAX_VIDEO_REGIONS];
    sharp_hybrid_receiver_t *_verifiedReceiver;
    uint64_t _verifiedOfferSession, _verifiedOfferNonce, _verifiedActiveNonce, _verifiedLastAckNs;
    uint64_t _verifiedSharpTiles, _verifiedMissingMaps;
    uint32_t _verifiedDropCommitAcks, _verifiedDropTileEvery, _verifiedTilePackets, _verifiedLastSnapshotFrame;
    sharp_h264_decoder_slot_t _h264Decoders[SHARP_MAX_H264_DECODERS];
    sharp_h264_region_stats_t _h264RegionStats[SHARP_MAX_VIDEO_REGIONS];
    uint64_t _lastWaitFrameId;
    uint8_t _lastWaitReason;
    uint8_t _presentReady;
    uint32_t _presentFrame;
    uint64_t _presentFrameEndSendNs;
    uint64_t _presentCommittedFrames;
    uint64_t _presentDroppedFrameEnds;
    sharp_dirty_bounds_t _presentDirtyBounds;
    sharp_video_layer_snapshot_t _presentVideoLayers[SHARP_MAX_VIDEO_REGIONS];
    size_t _presentVideoLayerCount;
    uint16_t _presentDeactivateRegions[SHARP_MAX_VIDEO_REGIONS];
    size_t _presentDeactivateRegionCount;
    uint64_t _presentIntervalSamples[SHARP_PRESENT_INTERVAL_SAMPLES];
    size_t _presentIntervalCount;
    uint64_t _presentIntervalTotalCount;
    uint64_t _lastPresentNs;
    double _presentIntervalSumNs;
    double _presentIntervalSumSqNs;
    uint64_t _presentRepeatFrames;
    uint64_t _presentCurrentStall;
    uint64_t _presentLongestStall;
    uint64_t _idlePresentIntervalSamples[SHARP_PRESENT_INTERVAL_SAMPLES];
    size_t _idlePresentIntervalCount;
    uint64_t _idlePresentIntervalTotalCount;
    double _idlePresentIntervalSumNs;
    double _idlePresentIntervalSumSqNs;
    uint64_t _idlePresentRepeatFrames;
    uint64_t _idlePresentCurrentStall;
    uint64_t _idlePresentLongestStall;
    uint64_t _lastContentAdvanceNs;
    uint64_t _h264DecodeLatencySamples[SHARP_PRESENT_INTERVAL_SAMPLES];
    size_t _h264DecodeLatencyCount;
    uint64_t _contentSerial;
    uint32_t _contentFrameId;
    uint64_t _freshContentPresents;
    uint32_t _tileDigestNextTile;
    uint64_t _tileDigestPackets;
    uint64_t _tileDigestEntries;
    int32_t _testCorruptTileId;
    uint64_t _testCorruptNs;
    uint64_t _testRepairNs;
    uint64_t _contentFinalPacketRxNs;
    uint64_t _contentDecodeCallbackNs;
    uint64_t _lastPresentedContentSerial;
    uint64_t _liveStatsLastNs;
    uint64_t _liveStatsLastFreshPresents;
    uint64_t _liveStatsLastCursorPackets;
    uint64_t _liveStatsLastCursorPresents;
    uint8_t _pendingMotionMask[SHARP_MOTION_MASK_MAX_BYTES];
    uint8_t _desiredMotionMask[SHARP_MOTION_MASK_MAX_BYTES];
    uint8_t _activeMotionMask[SHARP_MOTION_MASK_MAX_BYTES];
    /*
     * Generation of the first mask boundary that asked each active tile to
     * return from video ownership to the lossless framebuffer.  This target
     * is deliberately per-tile and latched: newer video-only frame ends must
     * not move the goalpost while the matching lossless packet is in flight.
     */
    uint32_t
        _motionMaskReleaseGeneration[SHARP_MOTION_MASK_MAX_BYTES * 8u];
    uint32_t _motionMaskBytes;
    uint32_t _pendingMotionMaskFrameId;
    uint32_t _desiredMotionMaskFrameId;
    uint32_t _activeMotionMaskFrameId;
    uint32_t _motionMaskAtomicReleaseGeneration;
    uint8_t _pendingMotionMaskValid;
    uint8_t _desiredMotionMaskValid;
    uint8_t _activeMotionMaskValid;
    uint8_t _motionMaskAtomicReleasePending;
    uint64_t _motionMaskUpdates;
    uint64_t _motionMaskActiveTiles;
    sharp_net_ring_t _videoRing;
    sharp_net_ring_t _tileRing;
    pthread_mutex_t _videoRingLock;
    pthread_cond_t _videoRingCond;
    pthread_mutex_t _tileRingLock;
    pthread_cond_t _tileRingCond;
    pthread_t _socketThread;
    pthread_t _videoThread;
    pthread_t _tileThread;
    uint8_t _netThreadsStarted;
    _Atomic uint8_t _netThreadsRunning;
    _Atomic uint64_t _ringDropsVideo;
    _Atomic uint64_t _ringDropsTile;
    _Atomic uint64_t _ringPacketsVideo;
    _Atomic uint64_t _ringPacketsTile;
    _Atomic uint64_t _arrivalCounter;
    _Atomic uint64_t _videoProcessedThrough;
    _Atomic uint64_t _stageVDrainedThrough;
    _Atomic uint64_t _stageTDrainedThrough;
    _Atomic uint64_t _recvmsgXBatches;
    _Atomic uint64_t _recvmsgXPackets;
    _Atomic uint64_t _recvmsgXFallbacks;
    uint32_t _h264FullFrameUnrecoveredStreak;
    uint64_t _latestVsyncNs;
    uint64_t _latestVsyncPeriodNs;
    uint64_t _previousVsyncNs;
    uint64_t _lastVsyncFeedbackNs;
    uint64_t _vsyncFeedbackReports;
    uint64_t _latestFrameEndArrival;
    uint64_t _latestFrameEndSendNs;
    uint64_t _pendingVideoDecodeArrivals[SHARP_PRESENT_INTERVAL_SAMPLES];
    size_t _pendingVideoDecodeCount;
    display_config_t _config;
    sharp_tile_receiver_t _receiver;
    sharp_video_region_reassembler_t * _videoReassembler;
    sharp_framebuf_t _frontFb;
    int _fd;
    struct sockaddr_in _senderAddr;
    socklen_t _senderAddrLen;
    BOOL _haveSenderAddr;
    uint64_t _startNs;
    CVDisplayLinkRef _displayLink;
    dispatch_source_t _readSource;
    dispatch_queue_t _netQueue;
    dispatch_queue_t _renderQueue;
    BOOL _renderScheduled;
    BOOL _stagingDirty;
    sharp_dirty_bounds_t _stagingDirtyBounds;
    BOOL _frameReady;
    BOOL _terminateScheduled;
    uint32_t _latestFrameEnd;
    uint32_t _committedFrame;
    uint64_t _presentedFrames;
    uint64_t _committedFrames;
    uint64_t _droppedFrameEnds;
    uint64_t _presentSupersededCommits;
    uint64_t _lateLosslessCommits;
    uint64_t _frameEndSupersededDirty;
    uint64_t _frameEndSupersededNewerPatch;
    uint64_t _renderWaitMissingLossless;
    uint64_t _renderWaitMissingVideo;
    uint64_t _renderWaitNewerStaged;
    uint64_t _renderWaitNoPatchRecord;
    uint64_t _renderWaitNoExpectedRecord;
    uint64_t _renderWaitNoStagingDirty;
    uint64_t _videoDecodeFailedFrames;
    uint64_t _videoDecodeNoSessionFrames;
    uint64_t _videoDecodeStatusFailures;
    uint64_t _h264StaleVideoDrops;
    uint64_t _h264NoDecoderDrops;
    uint64_t _netDrainCalls;
    uint64_t _netDrainBudgetYields;
    uint64_t _netDrainMaxPackets;
    uint64_t _textureFullUploads;
    uint64_t _textureRegionUploads;
    uint64_t _textureRegionPixels;
    uint64_t _presenterSnapshotCount;
    uint64_t _videoMaxActiveRegions;
    uint64_t _videoTextureUploads;
    uint64_t _videoTextureFrames;
    uint64_t _videoDecoderTextureBinds;
    uint64_t _videoNv12TextureBinds;
    uint64_t _videoBgraTextureUploads;
    uint64_t _videoDecoderTextureFallbacks;
    uint64_t _videoCpuFramebufferPatches;
    uint64_t _videoLayerActivations;
    uint64_t _videoLayerDeactivations;
    uint64_t _videoLayerMoves;
    uint64_t _videoLayerResizes;
    uint64_t _videoOldFootprintCleanups;
    uint64_t _videoOldFootprintCleanupSkipped;
    uint32_t _videoOldFootprintLastMoveFrame;
    uint32_t _videoOldFootprintLastRedrawFrame;
    uint64_t _videoHandoffBakes;
    uint64_t _videoHandoffBakePixels;
    uint64_t _videoHandoffBakeFailures;
    uint64_t _staleRevealPixels;
    uint64_t _commitDeactivateNoVideoRegion;
    uint64_t _h264Packets;
    uint64_t _h264Chunks;
    uint64_t _h264Frames;
    uint64_t _h264DecodeCallbacks;
    uint64_t _h264HardwareDecoderSessions;
    uint64_t _h264SoftwareDecoderSessions;
    uint64_t _h264HardwareDecoderUnknownSessions;
    uint64_t _h264Bytes;
    uint64_t _h264Invalid;
    uint64_t _h264MissingGenerations;
    uint64_t _h264FeedbackSent;
    uint64_t _h264FeedbackFailed;
    uint64_t _h264VsliceNacksSent;
    uint64_t _h264IdrRequestsSent;
    uint64_t _h264KeyframeRequestsSent;
    uint64_t _h264FullFrameNacksSuppressed;
    uint64_t _h264FullFrameIdrSuppressed;
    uint64_t _h264FullFrameKeyframeRequestsSuppressed;
    uint64_t _h264FullFrameLastKeyframeRequestNs;
    uint64_t _cursorPackets;
    uint64_t _cursorPresents;
    uint64_t _cursorLastRxNs;
    uint32_t _cursorLastPresentedSeq;
    uint32_t _cursorSeq;
    int32_t _cursorX;
    int32_t _cursorY;
    int32_t _cursorPrevX;
    int32_t _cursorPrevY;
    uint64_t _cursorSampleNs;
    uint64_t _cursorPrevSampleNs;
    uint16_t _cursorHotspotX;
    uint16_t _cursorHotspotY;
    uint32_t _cursorImageId;
    sharp_cursor_sample_t _cursorHistory[SHARP_CURSOR_HISTORY];
    uint32_t _cursorHistoryCount;
    uint32_t _cursorHistoryNewest;
    int64_t _cursorClockOffsetNs;
    uint64_t _cursorClockUpdatedNs;
    uint64_t _cursorPlayoutNs;
    BOOL _cursorVisible;
    uint64_t _h264RecoveredGenerations;
    uint64_t _h264UnrecoveredGenerations;
    uint32_t _drawableWidth;
    uint32_t _drawableHeight;
    double _displayScale;
    NSSize _windowContentSize;
    FILE * _frameLog;
    NSWindow * _window;
    SharpFramebufferView * _frameView;
    BOOL _overlayMaskEnabled;
}
@property(nonatomic, assign) display_config_t config;
@property(nonatomic, assign) sharp_tile_receiver_t receiver;
@property(nonatomic, assign) sharp_video_region_reassembler_t *videoReassembler;
@property(nonatomic, assign) sharp_framebuf_t frontFb;
@property(nonatomic, assign) int fd;
@property(nonatomic, assign) struct sockaddr_in senderAddr;
@property(nonatomic, assign) socklen_t senderAddrLen;
@property(nonatomic, assign) BOOL haveSenderAddr;
@property(nonatomic, assign) uint64_t startNs;
@property(nonatomic, assign) CVDisplayLinkRef displayLink;
@property(nonatomic, strong) dispatch_source_t readSource;
@property(nonatomic, strong) dispatch_queue_t netQueue;
@property(nonatomic, strong) dispatch_queue_t renderQueue;
@property(nonatomic, assign) BOOL renderScheduled;
@property(nonatomic, assign) BOOL stagingDirty;
@property(nonatomic, assign) sharp_dirty_bounds_t stagingDirtyBounds;
@property(nonatomic, assign) BOOL frameReady;
@property(nonatomic, assign) BOOL terminateScheduled;
@property(nonatomic, assign) uint32_t latestFrameEnd;
@property(nonatomic, assign) uint32_t committedFrame;
@property(nonatomic, assign) uint64_t presentedFrames;
@property(nonatomic, assign) uint64_t committedFrames;
@property(nonatomic, assign) uint64_t droppedFrameEnds;
@property(nonatomic, assign) uint64_t presentSupersededCommits;
@property(nonatomic, assign) uint64_t lateLosslessCommits;
@property(nonatomic, assign) uint64_t frameEndSupersededDirty;
@property(nonatomic, assign) uint64_t frameEndSupersededNewerPatch;
@property(nonatomic, assign) uint64_t renderWaitMissingLossless;
@property(nonatomic, assign) uint64_t renderWaitMissingVideo;
@property(nonatomic, assign) uint64_t renderWaitNewerStaged;
@property(nonatomic, assign) uint64_t renderWaitNoPatchRecord;
@property(nonatomic, assign) uint64_t renderWaitNoExpectedRecord;
@property(nonatomic, assign) uint64_t renderWaitNoStagingDirty;
@property(nonatomic, assign) uint64_t videoDecodeFailedFrames;
@property(nonatomic, assign) uint64_t videoDecodeNoSessionFrames;
@property(nonatomic, assign) uint64_t videoDecodeStatusFailures;
@property(nonatomic, assign) uint64_t h264StaleVideoDrops;
@property(nonatomic, assign) uint64_t h264NoDecoderDrops;
@property(nonatomic, assign) uint64_t netDrainCalls;
@property(nonatomic, assign) uint64_t netDrainBudgetYields;
@property(nonatomic, assign) uint64_t netDrainMaxPackets;
@property(nonatomic, assign) uint64_t textureFullUploads;
@property(nonatomic, assign) uint64_t textureRegionUploads;
@property(nonatomic, assign) uint64_t textureRegionPixels;
@property(nonatomic, assign) uint64_t presenterSnapshotCount;
@property(nonatomic, assign) uint64_t videoMaxActiveRegions;
@property(nonatomic, assign) uint64_t videoTextureUploads;
@property(nonatomic, assign) uint64_t videoTextureFrames;
@property(nonatomic, assign) uint64_t videoDecoderTextureBinds;
@property(nonatomic, assign) uint64_t videoNv12TextureBinds;
@property(nonatomic, assign) uint64_t videoBgraTextureUploads;
@property(nonatomic, assign) uint64_t videoDecoderTextureFallbacks;
@property(nonatomic, assign) uint64_t videoCpuFramebufferPatches;
@property(nonatomic, assign) uint64_t videoLayerActivations;
@property(nonatomic, assign) uint64_t videoLayerDeactivations;
@property(nonatomic, assign) uint64_t videoLayerMoves;
@property(nonatomic, assign) uint64_t videoLayerResizes;
@property(nonatomic, assign) uint64_t videoOldFootprintCleanups;
@property(nonatomic, assign) uint64_t videoOldFootprintCleanupSkipped;
@property(nonatomic, assign) uint32_t videoOldFootprintLastMoveFrame;
@property(nonatomic, assign) uint32_t videoOldFootprintLastRedrawFrame;
@property(nonatomic, assign) uint64_t videoHandoffBakes;
@property(nonatomic, assign) uint64_t videoHandoffBakePixels;
@property(nonatomic, assign) uint64_t videoHandoffBakeFailures;
@property(nonatomic, assign) uint64_t staleRevealPixels;
@property(nonatomic, assign) uint64_t commitDeactivateNoVideoRegion;
@property(nonatomic, assign) uint64_t h264Packets;
@property(nonatomic, assign) uint64_t h264Chunks;
@property(nonatomic, assign) uint64_t h264Frames;
@property(nonatomic, assign) uint64_t h264DecodeCallbacks;
@property(nonatomic, assign) uint64_t h264HardwareDecoderSessions;
@property(nonatomic, assign) uint64_t h264SoftwareDecoderSessions;
@property(nonatomic, assign) uint64_t h264HardwareDecoderUnknownSessions;
@property(nonatomic, assign) uint64_t h264Bytes;
@property(nonatomic, assign) uint64_t h264Invalid;
@property(nonatomic, assign) uint64_t h264MissingGenerations;
@property(nonatomic, assign) uint64_t h264FeedbackSent;
@property(nonatomic, assign) uint64_t h264FeedbackFailed;
@property(nonatomic, assign) uint64_t h264VsliceNacksSent;
@property(nonatomic, assign) uint64_t h264IdrRequestsSent;
@property(nonatomic, assign) uint64_t h264KeyframeRequestsSent;
@property(nonatomic, assign) uint64_t h264FullFrameNacksSuppressed;
@property(nonatomic, assign) uint64_t h264FullFrameIdrSuppressed;
@property(nonatomic, assign) uint64_t h264FullFrameKeyframeRequestsSuppressed;
@property(nonatomic, assign) uint64_t h264FullFrameLastKeyframeRequestNs;
@property(nonatomic, assign) uint64_t cursorPackets;
@property(nonatomic, assign) uint64_t cursorPresents;
@property(nonatomic, assign) uint64_t cursorLastRxNs;
@property(nonatomic, assign) uint32_t cursorLastPresentedSeq;
@property(nonatomic, assign) uint32_t cursorSeq;
@property(nonatomic, assign) int32_t cursorX;
@property(nonatomic, assign) int32_t cursorY;
@property(nonatomic, assign) int32_t cursorPrevX;
@property(nonatomic, assign) int32_t cursorPrevY;
@property(nonatomic, assign) uint64_t cursorSampleNs;
@property(nonatomic, assign) uint64_t cursorPrevSampleNs;
@property(nonatomic, assign) uint16_t cursorHotspotX;
@property(nonatomic, assign) uint16_t cursorHotspotY;
@property(nonatomic, assign) uint32_t cursorImageId;
@property(nonatomic, assign) BOOL cursorVisible;
@property(nonatomic, assign) uint64_t h264RecoveredGenerations;
@property(nonatomic, assign) uint64_t h264UnrecoveredGenerations;
@property(nonatomic, assign) uint32_t drawableWidth;
@property(nonatomic, assign) uint32_t drawableHeight;
@property(nonatomic, assign) double displayScale;
@property(nonatomic, assign) NSSize windowContentSize;
@property(nonatomic, assign) FILE *frameLog;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) SharpFramebufferView *frameView;
@property(nonatomic, assign) BOOL overlayMaskEnabled;
- (instancetype)init;
- (void)updateDrawableSize;
- (void)windowDidResize:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)writeH264RegionSummaryToFile:(FILE *)file;
- (void)applicationWillTerminate:(NSNotification *)notification;
@end

@interface SharpDisplayApp (Metrics)
- (void)recordDisplayLinkOutputTime:(const CVTimeStamp *)outputTime;
- (BOOL)recordPresentNowNs:(uint64_t)nowNs contentSerial:(uint64_t)contentSerial;
- (void)recordH264DecodeLatencySubmitNs:(uint64_t)submitNs;
- (void)recordPendingVideoDecodeArrival:(uint64_t)arrivalSeq;
- (void)completeVideoDecodeArrival:(uint64_t)arrivalSeq;
- (void)recordH264DecodeCallbackSubmitNs:(uint64_t)submitNs;
- (double)presentIntervalMeanMs;
- (double)presentIntervalCov;
- (uint64_t)presentIntervalPercentileNs:(double)percentile;
- (uint64_t)h264DecodeLatencyPercentileNs:(double)percentile;
@end

@interface SharpDisplayApp (FrameState)
- (void)recordFrameEnd:(uint32_t)frameId
        videoRegionMask:(uint16_t)videoRegionMask
             arrivalSeq:(uint64_t)arrivalSeq
               sendNs:(uint64_t)sendNs;
- (void)recordMotionMask:(const uint8_t *)mask
                   bytes:(uint32_t)bytes
                 frameId:(uint32_t)frameId;
- (void)applyMotionMaskAtCommitLocked:(uint32_t)frameId;
- (void)copyActiveMotionMaskLocked:(uint8_t *)out bytes:(uint32_t)bytes;
- (uint16_t)videoRegionForFrame:(uint32_t)frameId valid:(BOOL *)valid;
- (sharp_video_frame_regions_t)videoRegionsForFrame:(uint32_t)frameId
                                              valid:(BOOL *)valid;
- (BOOL)motionMaskCoversLayerLocked:(const sharp_video_layer_snapshot_t *)layer;
- (void)clearPendingPresentationLocked;
- (BOOL)commitFrameBoundaryLocked:(uint32_t)frameId
                    frameEndSendNs:(uint64_t)frameEndSendNs;
- (void)tryCommitArrivalWatermark;
- (void)publishVideoArrivalWatermark;
- (void)publishTileArrivalWatermark;
- (void)markDirtyRectX:(uint32_t)x y:(uint32_t)y w:(uint32_t)w h:(uint32_t)h;
- (void)bakeVideoLayerIntoBase:(const sharp_video_layer_snapshot_t *)layer
                              x:(uint32_t)x
                              y:(uint32_t)y
                              w:(uint32_t)w
                              h:(uint32_t)h;
- (void)clearVideoLayer;
- (void)clearVideoLayerAtIndex:(size_t)index;
- (void)clearH264DecoderAtIndex:(size_t)index;
- (void)clearH264DecoderForRegion:(uint16_t)regionId;
- (sharp_h264_region_stats_t *)h264RegionStatsForRegion:(uint16_t)regionId
                                                  create:(BOOL)create;
- (void)noteH264InvalidForRegion:(uint16_t)regionId;
- (sharp_h264_decoder_slot_t *)h264DecoderForRegion:(uint16_t)regionId
                                             create:(BOOL)create;
- (sharp_video_layer_snapshot_t *)videoLayerForRegion:(uint16_t)regionId
                                               create:(BOOL)create;
- (void)recordObservedVideoRegion:(uint16_t)regionId frameId:(uint32_t)frameId;
@end

@interface SharpDisplayApp (Feedback)
- (void)sendVideoFeedbackKind:(sharp_video_feedback_kind_t)kind
                     regionId:(uint16_t)regionId
                   generation:(uint32_t)generation
                    firstChunk:(uint16_t)firstChunk
                 missingChunks:(uint16_t)missingChunks;
- (void)sendNextTileDigest;
- (void)requestKeyframeForUndecodableVideoRegion:(uint16_t)regionId
                                      generation:(uint32_t)generation;
- (void)sendPresentReportFrameId:(uint32_t)frameId
                    contentSerial:(uint64_t)contentSerial
                    frameEndSendNs:(uint64_t)frameEndSendNs
                 finalPacketRxNs:(uint64_t)finalPacketRxNs
                decodeCallbackNs:(uint64_t)decodeCallbackNs
                         presentNs:(uint64_t)presentNs;
- (void)handlePingDatagram:(const shtp_header_t *)sh;
- (void)handleCursorDatagram:(const shtp_header_t *)sh
                     payload:(const uint8_t *)payload;
- (void)recordCursorSample:(uint64_t)sampleNs receivedNs:(uint64_t)rxNs;
- (void)interpolateCursorAt:(uint64_t)nowNs into:(sharp_cursor_snapshot_t *)cursor;
- (uint16_t)sendMissingVsliceNacksForRegion:(uint16_t)regionId
                                  generation:(uint32_t)generation
                                 includeTail:(BOOL)includeTail;
- (void)noteFullFrameUnrecoveredGeneration:(uint32_t)generation;
@end

@interface SharpDisplayApp (Hybrid)
- (void)sendVerifiedMessageLocked:(sharp_hybrid_message_t *)message;
- (void)handleVerifiedStateLocked:(const uint8_t *)payload length:(size_t)length;
- (void)sendVerifiedAckLocked;
@end

@interface SharpDisplayApp (Decoder)
- (void)handleVideoDatagram:(const shtp_header_t *)sh
                    payload:(const uint8_t *)payload
                arrivalSeq:(uint64_t)arrivalSeq;
- (void)copyDecodedPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        header:(const sharp_video_region_chunk_header_t *)header
              finalPacketRxNs:(uint64_t)finalPacketRxNs
             decodeCallbackNs:(uint64_t)decodeCallbackNs session:(uint64_t)session;
- (void)decodeVideoBlob:(const uint8_t *)blob
                 length:(size_t)blobLen
                 header:(const sharp_video_region_chunk_header_t *)header
             arrivalSeq:(uint64_t)arrivalSeq
       finalPacketRxNs:(uint64_t)finalPacketRxNs session:(uint64_t)session;
@end

@interface SharpDisplayApp (Transport)
- (int)startNetworkThreads;
- (void)stopNetworkThreads;
- (void)socketThreadMain;
- (void)handleNetworkDatagram:(const uint8_t *)buffer
                       length:(size_t)n
                         peer:(const struct sockaddr_in *)peer
                      peerLen:(socklen_t)peerLen;
- (void)videoThreadMain;
- (void)tileThreadMain;
- (void)handleTileDatagram:(const uint8_t *)buffer
                    length:(size_t)n
                arrivalSeq:(uint64_t)arrivalSeq;
- (void)drainSocket;
@end

@interface SharpDisplayApp (Presentation)
- (void)scheduleRenderTick;
- (void)renderTick;
@end

// Shared platform helpers.
uint64_t sharp_mach_absolute_to_ns(uint64_t ticks);
void dirty_bounds_reset(sharp_dirty_bounds_t *bounds);
void dirty_bounds_add(sharp_dirty_bounds_t *bounds, uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h, uint32_t limit_w,
                             uint32_t limit_h);
void framebuf_copy_rect(sharp_framebuf_t *dst, const sharp_framebuf_t *src,
                               const sharp_dirty_bounds_t *bounds);
int compare_u64_values(const void *a, const void *b);
void usage(FILE *stream);
const char *video_texture_mode_name(sharp_video_texture_mode_t mode);
int parse_video_texture_mode(const char *text,
                                    sharp_video_texture_mode_t *mode);
uint8_t clamp_u8_int(int value);
sharp_nv12_matrix_t nv12_matrix_for_pixel_buffer(CVPixelBufferRef pixelBuffer);
void nv12_video_range_to_bgra(uint8_t y, uint8_t u, uint8_t v,
                                     sharp_nv12_matrix_t matrix,
                                     uint8_t *bgra);
NSSize fit_size_preserving_aspect(NSSize streamSize, NSSize maxSize);
GLuint compile_shader(GLenum type, const char *source);
CVReturn sharp_display_link_callback(CVDisplayLinkRef displayLink,
                                            const CVTimeStamp *now,
                                            const CVTimeStamp *outputTime,
                                            CVOptionFlags flagsIn,
                                            CVOptionFlags *flagsOut,
                                            void *displayLinkContext);
uint32_t read_be32(const uint8_t *p);
void h264_decode_callback(void *decompressionOutputRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTDecodeInfoFlags infoFlags,
                                 CVImageBufferRef imageBuffer,
                                 CMTime presentationTimeStamp,
                                 CMTime presentationDuration);
void *sharp_socket_thread_main(void *arg);
void *sharp_video_thread_main(void *arg);
void *sharp_tile_thread_main(void *arg);
int parse_args(int argc, char **argv, display_config_t *config);
