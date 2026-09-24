#import "Internal.h"

@implementation SharpDisplayApp (Decoder)
- (void)handleVideoDatagram:(const shtp_header_t *)sh
                    payload:(const uint8_t *)payload
                arrivalSeq:(uint64_t)arrivalSeq {
    if (sh == NULL || payload == NULL ||
        sh->payload_len < sizeof(sharp_video_region_chunk_header_t)) {
        pthread_mutex_lock(&_stateLock);
        _h264Invalid++;
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    sharp_video_region_chunk_header_t decodeHeader;
    memset(&decodeHeader, 0, sizeof(decodeHeader));
    uint8_t *decodeBlob = NULL;
    size_t decodeBlobLen = 0;

    pthread_mutex_lock(&_stateLock);
    if ((_verifiedReceiver && (!(sh->flags&SHTP_FLAG_VERIFIED_HYBRID) ||
         sh->aux_time_ns!=_verifiedReceiver->session)) ||
        (!_verifiedReceiver && (sh->flags&SHTP_FLAG_VERIFIED_HYBRID))) {
        pthread_mutex_unlock(&_stateLock);return;
    }
    if (_verifiedReceiver && (!_verifiedReceiver->latest_video_frame ||
        (int32_t)(sh->frame_id-_verifiedReceiver->latest_video_frame)>0))
        _verifiedReceiver->latest_video_frame=sh->frame_id;
    sharp_video_region_chunk_header_t vh;
    memcpy(&vh, payload, sizeof(vh));
    sharp_video_region_chunk_header_wire_to_host(&vh);
    BOOL isParity = (vh.flags & SHARP_VIDEO_REGION_FLAG_PARITY) != 0;
    const uint8_t *chunk = payload + sizeof(vh);
    size_t chunkLen = sh->payload_len - sizeof(vh);
    sharp_video_region_chunk_header_t missedHeader;
    uint16_t missedChunks = 0;
    int pushStatus = sharp_video_region_reassembler_push(
        _videoReassembler, &vh, sh->chunk_id, sh->chunk_count, chunk, chunkLen,
        &missedHeader, &missedChunks);
    if (pushStatus < 0) {
        if (!isParity) {
            _h264Invalid++;
            [self noteH264InvalidForRegion:vh.region_id];
        }
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    if (pushStatus > 0) {
        if (missedHeader.region_id == SHARP_H264_FULLFRAME_ID &&
            missedChunks > 0) {
            [self noteFullFrameUnrecoveredGeneration:missedHeader.generation];
        }
    }
    if (!isParity) {
        [self recordObservedVideoRegion:vh.region_id frameId:vh.generation];
    }
    if (vh.region_id != SHARP_H264_FULLFRAME_ID) {
        (void)[self sendMissingVsliceNacksForRegion:vh.region_id
                                         generation:vh.generation
                                        includeTail:NO];
    }
    _h264Packets++;
    _h264Chunks++;
    _h264Bytes += sizeof(*sh) + sh->payload_len;

    sharp_video_region_chunk_header_t completeHeader;
    const uint8_t *blob = NULL;
    size_t blobLen = 0;
    int hadRepair = 0;
    if (sharp_video_region_reassembler_take_complete_repair(
            _videoReassembler, vh.region_id, &completeHeader, &blob, &blobLen,
            &hadRepair)) {
        if (hadRepair) {
            _h264RecoveredGenerations++;
            sharp_h264_region_stats_t *stats =
                [self h264RegionStatsForRegion:completeHeader.region_id create:YES];
            if (stats != NULL) {
                stats->recovered_generations++;
            }
        }
        if (completeHeader.region_id == SHARP_H264_FULLFRAME_ID) {
            _h264FullFrameUnrecoveredStreak = 0;
        }
        decodeBlob = malloc(blobLen);
        if (decodeBlob == NULL) {
            _h264Invalid++;
            [self noteH264InvalidForRegion:completeHeader.region_id];
        } else {
            memcpy(decodeBlob, blob, blobLen);
            decodeHeader = completeHeader;
            decodeBlobLen = blobLen;
        }
    }
    pthread_mutex_unlock(&_stateLock);
    if (decodeBlob != NULL) {
        uint64_t finalPacketRxNs = shtp_now_ns();
        [self decodeVideoBlob:decodeBlob
                        length:decodeBlobLen
                        header:&decodeHeader
                    arrivalSeq:arrivalSeq
              finalPacketRxNs:finalPacketRxNs session:sh->aux_time_ns];
        free(decodeBlob);
    }
}

- (void)copyDecodedPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        header:(const sharp_video_region_chunk_header_t *)header
              finalPacketRxNs:(uint64_t)finalPacketRxNs
             decodeCallbackNs:(uint64_t)decodeCallbackNs session:(uint64_t)session {
    pthread_mutex_lock(&_stateLock);
    if ((_verifiedReceiver && session!=_verifiedReceiver->session) ||
        (!_verifiedReceiver && session) ||
        (_verifiedReceiver && header && _verifiedReceiver->committed_frame &&
         (int32_t)(header->generation-_verifiedReceiver->committed_frame)<=0)) {
        pthread_mutex_unlock(&_stateLock);return;
    }
    if (pixelBuffer == NULL || header == NULL ||
        CVPixelBufferGetWidth(pixelBuffer) < header->w ||
        CVPixelBufferGetHeight(pixelBuffer) < header->h ||
        header->x + header->w > _receiver.fb.width ||
        header->y + header->h > _receiver.fb.height) {
        _h264Invalid++;
        if (header != NULL) {
            [self noteH264InvalidForRegion:header->region_id];
        }
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    sharp_video_layer_snapshot_t *currentLayer =
        [self videoLayerForRegion:header->region_id create:NO];
    if (currentLayer != NULL && currentLayer->active &&
        header->generation <= currentLayer->header.generation) {
        _h264StaleVideoDrops++;
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    OSType expectedFormat =
        _config.video_texture_mode == SHARP_VIDEO_TEXTURE_NV12
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA;
    if (format != expectedFormat) {
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    sharp_video_layer_snapshot_t *layer =
        [self videoLayerForRegion:header->region_id create:YES];
    if (layer == NULL) {
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    BOOL wasActive = layer->pixel_buffer != NULL;
    if (wasActive) {
        BOOL moved = layer->header.x != header->x || layer->header.y != header->y;
        BOOL resized = layer->header.w != header->w || layer->header.h != header->h;
        if (moved || resized) {
            [self bakeVideoLayerIntoBase:layer
                                       x:layer->header.x
                                       y:layer->header.y
                                       w:layer->header.w
                                       h:layer->header.h];
            dirty_bounds_add(&_stagingDirtyBounds, layer->header.x,
                             layer->header.y, layer->header.w, layer->header.h,
                             _receiver.fb.width, _receiver.fb.height);
            dirty_bounds_add(&_stagingDirtyBounds, header->x, header->y,
                             header->w, header->h, _receiver.fb.width,
                             _receiver.fb.height);
            _videoOldFootprintCleanups++;
            _videoOldFootprintLastMoveFrame = header->generation;
            _videoOldFootprintLastRedrawFrame = header->generation;
            if (moved) {
                _videoLayerMoves++;
            }
            if (resized) {
                _videoLayerResizes++;
            }
        }
    }
    if (layer->pixel_buffer != NULL) {
        CVPixelBufferRelease(layer->pixel_buffer);
    }
    CVPixelBufferRetain(pixelBuffer);
    if (!wasActive) {
        _videoLayerActivations++;
    }
    layer->pixel_buffer = pixelBuffer;
    layer->header = *header;
    layer->region_id = header->region_id;
    layer->active = 1u;
    layer->updated = 1u;
    layer->missed_commits = 0u;
    layer->final_packet_rx_ns = finalPacketRxNs;
    layer->decode_callback_ns = decodeCallbackNs;
    _stagingDirty = YES;
    _h264Frames++;
    _contentSerial++;
    _contentFrameId = header->generation;
    _contentFinalPacketRxNs = finalPacketRxNs;
    _contentDecodeCallbackNs = decodeCallbackNs;
    sharp_h264_region_stats_t *stats =
        [self h264RegionStatsForRegion:header->region_id create:YES];
    if (stats != NULL) {
        stats->frames++;
    }
    pthread_mutex_unlock(&_stateLock);
    const char *presentOnDecode=getenv("SHARP_PRESENT_ON_DECODE");
    if (session && (!presentOnDecode || strcmp(presentOnDecode,"0")!=0)) [self scheduleRenderTick];
}

- (void)decodeVideoBlob:(const uint8_t *)blob
                 length:(size_t)blobLen
                 header:(const sharp_video_region_chunk_header_t *)header
             arrivalSeq:(uint64_t)arrivalSeq
       finalPacketRxNs:(uint64_t)finalPacketRxNs session:(uint64_t)session {
    if (blob == NULL || header == NULL || blobLen < 16u ||
        read_be32(blob) != 0x53485631u) {
        _h264Invalid++;
        if (header != NULL) {
            [self noteH264InvalidForRegion:header->region_id];
        }
        return;
    }
    uint32_t spsLen = read_be32(blob + 4u);
    uint32_t ppsLen = read_be32(blob + 8u);
    uint32_t sampleLen = read_be32(blob + 12u);
    if ((uint64_t)16u + spsLen + ppsLen + sampleLen != blobLen ||
        sampleLen == 0) {
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        return;
    }
    const uint8_t *sps = blob + 16u;
    const uint8_t *pps = sps + spsLen;
    const uint8_t *sample = pps + ppsLen;
    BOOL hasConfig = spsLen > 0 && ppsLen > 0;
    sharp_h264_decoder_slot_t *decoder =
        [self h264DecoderForRegion:header->region_id create:hasConfig];
    if (decoder == NULL ||
        (!hasConfig && (decoder->session == NULL || decoder->format == NULL))) {
        _h264NoDecoderDrops++;
        if (!hasConfig) {
            [self requestKeyframeForUndecodableVideoRegion:header->region_id
                                                generation:header->generation];
        }
        return;
    }

    if (hasConfig) {
        if (decoder->session != NULL) {
            VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);
            VTDecompressionSessionInvalidate(decoder->session);
            CFRelease(decoder->session);
            decoder->session = NULL;
        }
        if (decoder->format != NULL) {
            CFRelease(decoder->format);
            decoder->format = NULL;
        }
        const uint8_t *parameterSets[2] = {sps, pps};
        size_t parameterSetSizes[2] = {spsLen, ppsLen};
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, 2, parameterSets, parameterSetSizes, 4,
            &decoder->format);
        if (status != noErr || decoder->format == NULL) {
            _h264Invalid++;
            [self noteH264InvalidForRegion:header->region_id];
            return;
        }
        OSType decodeFormat =
            _config.video_texture_mode == SHARP_VIDEO_TEXTURE_NV12
                ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                : kCVPixelFormatType_32BGRA;
        NSDictionary *attrs = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey : @(decodeFormat),
            (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferOpenGLTextureCacheCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        VTDecompressionOutputCallbackRecord callback;
        callback.decompressionOutputCallback = h264_decode_callback;
        callback.decompressionOutputRefCon = (__bridge void *)self;
        status = VTDecompressionSessionCreate(kCFAllocatorDefault, decoder->format, NULL,
                                              (__bridge CFDictionaryRef)attrs,
                                              &callback, &decoder->session);
        if (status != noErr || decoder->session == NULL) {
            _h264Invalid++;
            [self noteH264InvalidForRegion:header->region_id];
            return;
        }
        CFTypeRef hardwareDecode = NULL;
        status = VTSessionCopyProperty(
            decoder->session,
            kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            kCFAllocatorDefault, &hardwareDecode);
        if (status == noErr && hardwareDecode != NULL &&
            CFGetTypeID(hardwareDecode) == CFBooleanGetTypeID()) {
            if (CFBooleanGetValue((CFBooleanRef)hardwareDecode)) {
                _h264HardwareDecoderSessions++;
            } else {
                _h264SoftwareDecoderSessions++;
            }
        } else {
            _h264HardwareDecoderUnknownSessions++;
        }
        if (hardwareDecode != NULL) {
            CFRelease(hardwareDecode);
        }
    }
    if (decoder->session == NULL || decoder->format == NULL) {
        _h264Invalid++;
        _videoDecodeFailedFrames++;
        _videoDecodeNoSessionFrames++;
        [self noteH264InvalidForRegion:header->region_id];
        sharp_video_feedback_kind_t kind =
            header->region_id == SHARP_H264_FULLFRAME_ID
                ? SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST
                : SHARP_VIDEO_FEEDBACK_IDR_REQ;
        [self sendVideoFeedbackKind:kind
                           regionId:header->region_id
                         generation:header->generation
                         firstChunk:0
                       missingChunks:0];
        return;
    }

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, sampleLen, kCFAllocatorDefault, NULL, 0,
        sampleLen, 0, &block);
    if (status != noErr || block == NULL) {
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        return;
    }
    status = CMBlockBufferReplaceDataBytes(sample, block, 0, sampleLen);
    if (status != noErr) {
        CFRelease(block);
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        return;
    }
    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSizes[1] = {sampleLen};
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, decoder->format, 1,
                                       0, NULL, 1, sampleSizes, &sampleBuffer);
    CFRelease(block);
    if (status != noErr || sampleBuffer == NULL) {
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        return;
    }

    sharp_h264_decode_context_t *context = malloc(sizeof(*context));
    if (context == NULL) {
        CFRelease(sampleBuffer);
        _h264Invalid++;
        [self noteH264InvalidForRegion:header->region_id];
        return;
    }
    context->header = *header;
    context->session_id = session;
    context->submit_ns = shtp_now_ns();
    context->arrival_seq = arrivalSeq;
    context->final_packet_rx_ns = finalPacketRxNs;
    [self recordPendingVideoDecodeArrival:arrivalSeq];
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags infoFlags = 0;
    status = VTDecompressionSessionDecodeFrame(decoder->session, sampleBuffer, flags,
                                               context, &infoFlags);
    if (status != noErr) {
        [self completeVideoDecodeArrival:arrivalSeq];
        _h264Invalid++;
        _videoDecodeFailedFrames++;
        _videoDecodeStatusFailures++;
        [self noteH264InvalidForRegion:header->region_id];
        sharp_video_feedback_kind_t kind =
            header->region_id == SHARP_H264_FULLFRAME_ID
                ? SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST
                : SHARP_VIDEO_FEEDBACK_IDR_REQ;
        [self sendVideoFeedbackKind:kind
                           regionId:header->region_id
                           generation:header->generation
                         firstChunk:0
                       missingChunks:0];
        free(context);
    }
    CFRelease(sampleBuffer);
}
@end
