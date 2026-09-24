#import "Internal.h"

@implementation SharpScreenSender (Encoder)
- (void)destroyH264Encoder {
    for (size_t i = 0; i < SHARP_H264_ENCODER_SLOTS; i++) {
        [self destroyH264EncoderAtIndex:i];
    }
    _h264Width = 0;
    _h264Height = 0;
    _h264RegionId = 0;
    if (_vtPixelTransferSession != NULL) {
        VTPixelTransferSessionInvalidate(_vtPixelTransferSession);
        CFRelease(_vtPixelTransferSession);
        _vtPixelTransferSession = NULL;
    }
}

- (void)flushH264Encoders {
    for (size_t i = 0; i < SHARP_H264_ENCODER_SLOTS; i++) {
        if (_h264Encoders[i].session != NULL) {
            VTCompressionSessionCompleteFrames(_h264Encoders[i].session,
                                               kCMTimeInvalid);
        }
    }
}

- (void)destroyH264EncoderAtIndex:(size_t)index {
    if (index >= SHARP_H264_ENCODER_SLOTS) {
        return;
    }
    uint16_t evictedRegionId = _h264Encoders[index].active
                                   ? _h264Encoders[index].region_id
                                   : 0u;
    if (_h264Encoders[index].session != NULL) {
        VTCompressionSessionCompleteFrames(_h264Encoders[index].session,
                                           kCMTimeInvalid);
        if (_h264OutputQueue != nil) {
            dispatch_sync(_h264OutputQueue, ^{
            });
        }
        VTCompressionSessionInvalidate(_h264Encoders[index].session);
        CFRelease(_h264Encoders[index].session);
    }
    if (_h264Encoders[index].pixel_buffer_pool != NULL) {
        CVPixelBufferPoolRelease(_h264Encoders[index].pixel_buffer_pool);
    }
    if (evictedRegionId != 0) {
        h264_region_stream_t *stream =
            [self h264StreamForRegion:evictedRegionId create:NO frameId:_frameId];
        if (stream != NULL) {
            stream->has_keyframe = 0u;
            stream->need_keyframe = 1u;
            stream->encoder_resets++;
        }
    }
    memset(&_h264Encoders[index], 0, sizeof(_h264Encoders[index]));
}

- (int)ensureH264EncoderWidth:(uint32_t)width height:(uint32_t)height {
    VTCompressionSessionRef session =
        [self ensureH264EncoderForRegion:0 width:width height:height];
    return session != NULL ? 0 : -1;
}

- (VTCompressionSessionRef)ensureH264EncoderForRegion:(uint16_t)regionId
                                                width:(uint32_t)width
                                               height:(uint32_t)height {
    h264_encoder_slot_t *slot = NULL;
    h264_encoder_slot_t *freeSlot = NULL;
    for (size_t i = 0; i < SHARP_H264_ENCODER_SLOTS; i++) {
        if (_h264Encoders[i].active && _h264Encoders[i].region_id == regionId) {
            slot = &_h264Encoders[i];
            break;
        }
        if (!_h264Encoders[i].active && freeSlot == NULL) {
            freeSlot = &_h264Encoders[i];
        }
    }
    if (slot == NULL) {
        slot = freeSlot;
    }
    if (slot == NULL) {
        [self destroyH264EncoderAtIndex:0];
        slot = &_h264Encoders[0];
    }
    if (slot->session != NULL && slot->width == width && slot->height == height) {
        _h264Width = width;
        _h264Height = height;
        _h264RegionId = regionId;
        _h264Session = slot->session;
        return slot->session;
    }
    if (slot->session != NULL) {
        VTCompressionSessionCompleteFrames(slot->session, kCMTimeInvalid);
        if (_h264OutputQueue != nil) {
            dispatch_sync(_h264OutputQueue, ^{
            });
        }
        VTCompressionSessionInvalidate(slot->session);
        CFRelease(slot->session);
        slot->session = NULL;
    }
    if (slot->pixel_buffer_pool != NULL) {
        CVPixelBufferPoolRelease(slot->pixel_buffer_pool);
        slot->pixel_buffer_pool = NULL;
    }
    slot->active = 1u;
    slot->region_id = regionId;
    slot->width = width;
    slot->height = height;
    OSType encoderPixelFormat =
        regionId == SHARP_H264_FULLFRAME_ID && _vtNv12Requested
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA;
    NSDictionary *sourceAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(encoderPixelFormat),
        (NSString *)kCVPixelBufferWidthKey : @(width),
        (NSString *)kCVPixelBufferHeightKey : @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CFMutableDictionaryRef encoderSpec = NULL;
    BOOL lowLatencyAttempted = NO;
    if (_vtLowLatencyRequested) {
        if (@available(macOS 11.3, *)) {
            encoderSpec = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            if (encoderSpec != NULL) {
                CFDictionarySetValue(
                    encoderSpec,
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
                    kCFBooleanTrue);
                lowLatencyAttempted = YES;
            }
        }
    }
    OSStatus status = VTCompressionSessionCreate(
        NULL, (int32_t)width, (int32_t)height, kCMVideoCodecType_H264,
        encoderSpec, (__bridge CFDictionaryRef)sourceAttributes, NULL,
        h264_output_callback, (__bridge void *)self,
        &slot->session);
    if (encoderSpec != NULL) {
        CFRelease(encoderSpec);
    }
    if ((status != noErr || slot->session == NULL) && lowLatencyAttempted) {
        _vtLowLatencyFallbacks++;
        slot->session = NULL;
        status = VTCompressionSessionCreate(
            NULL, (int32_t)width, (int32_t)height, kCMVideoCodecType_H264,
            NULL, (__bridge CFDictionaryRef)sourceAttributes, NULL,
            h264_output_callback, (__bridge void *)self,
            &slot->session);
    } else if (status == noErr && slot->session != NULL &&
               lowLatencyAttempted) {
        _vtLowLatencyActive = YES;
    }
    if (status != noErr || slot->session == NULL) {
        memset(slot, 0, sizeof(*slot));
        _h264EncodeFailures++;
        return NULL;
    }
    VTSessionSetProperty(slot->session, kVTCompressionPropertyKey_RealTime,
                         kCFBooleanTrue);
    VTSessionSetProperty(slot->session, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse);
    if (@available(macOS 11.0, *)) {
        if (VTSessionSetProperty(
                slot->session,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                kCFBooleanTrue) == noErr) {
            _vtSpeedPriorityActive = YES;
        }
    }
    int32_t maxFrameDelay = 1;
    CFNumberRef maxFrameDelayNumber =
        CFNumberCreate(NULL, kCFNumberSInt32Type, &maxFrameDelay);
    if (maxFrameDelayNumber != NULL) {
        if (VTSessionSetProperty(slot->session,
                                 kVTCompressionPropertyKey_MaxFrameDelayCount,
                                 maxFrameDelayNumber) == noErr) {
            _vtFrameDelayBounded = YES;
        }
        CFRelease(maxFrameDelayNumber);
    }
    CFStringRef profile = _vtFastProfileRequested
                              ? kVTProfileLevel_H264_Baseline_AutoLevel
                              : kVTProfileLevel_H264_High_AutoLevel;
    OSStatus profileStatus = VTSessionSetProperty(
        slot->session, kVTCompressionPropertyKey_ProfileLevel, profile);
    if (_vtFastProfileRequested) {
        OSStatus entropyStatus = VTSessionSetProperty(
            slot->session, kVTCompressionPropertyKey_H264EntropyMode,
            kVTH264EntropyMode_CAVLC);
        OSStatus openGopStatus = VTSessionSetProperty(
            slot->session, kVTCompressionPropertyKey_AllowOpenGOP,
            kCFBooleanFalse);
        _vtFastProfileActive = profileStatus == noErr && entropyStatus == noErr &&
                               openGopStatus == noErr;
        if (@available(macOS 13.0, *)) {
            int32_t referenceBuffers = 1;
            CFNumberRef referenceNumber = CFNumberCreate(
                NULL, kCFNumberSInt32Type, &referenceBuffers);
            if (referenceNumber != NULL) {
                _vtReferenceBufferBounded =
                    VTSessionSetProperty(
                        slot->session,
                        kVTCompressionPropertyKey_ReferenceBufferCount,
                        referenceNumber) == noErr;
                CFRelease(referenceNumber);
            }
        }
    }
    int32_t fps = _fps > 0 ? (int32_t)_fps : 60;
    CFNumberRef fpsNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &fps);
    if (fpsNumber != NULL) {
        VTSessionSetProperty(slot->session, kVTCompressionPropertyKey_ExpectedFrameRate,
                             fpsNumber);
        CFRelease(fpsNumber);
    }
    int32_t keyInterval =
        regionId == SHARP_H264_FULLFRAME_ID
            ? (int32_t)env_double_or_default(
                  "SHARP_H264_FULLFRAME_KEY_INTERVAL_FRAMES",
                  (double)fps * 600.0)
            : fps * 2;
    if (keyInterval < 1) {
        keyInterval = 1;
    }
    CFNumberRef keyNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &keyInterval);
    if (keyNumber != NULL) {
        VTSessionSetProperty(slot->session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             keyNumber);
        CFRelease(keyNumber);
    }
    double keyIntervalDuration =
        regionId == SHARP_H264_FULLFRAME_ID
            ? env_double_or_default("SHARP_H264_FULLFRAME_KEY_INTERVAL_SECONDS",
                                    600.0)
            : 2.0;
    if (keyIntervalDuration <= 0.0) {
        keyIntervalDuration = 1.0;
    }
    CFNumberRef keyDurationNumber =
        CFNumberCreate(NULL, kCFNumberDoubleType, &keyIntervalDuration);
    if (keyDurationNumber != NULL) {
        VTSessionSetProperty(slot->session,
                             kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             keyDurationNumber);
        CFRelease(keyDurationNumber);
    }
    uint64_t bitRate = (uint64_t)h264_target_bitrate(width, height, (uint32_t)fps);
    if (regionId == SHARP_H264_FULLFRAME_ID && _h264AdaptiveBitrateEnabled) {
        if (_h264AdaptiveMaxBitrate == 0) {
            _h264AdaptiveMaxBitrate = bitRate;
        }
        if (bitRate > _h264AdaptiveMaxBitrate) {
            bitRate = _h264AdaptiveMaxBitrate;
        }
        if (_h264AdaptiveMinBitrate == 0) {
            _h264AdaptiveMinBitrate =
                MIN(bitRate, (uint64_t)env_double_or_default(
                                 "SHARP_H264_ADAPTIVE_MIN", 60000000.0));
        }
        if (_h264AdaptiveMinBitrate > _h264AdaptiveMaxBitrate) {
            _h264AdaptiveMinBitrate = _h264AdaptiveMaxBitrate;
        }
        if (_h264AdaptiveBitrate == 0) {
            _h264AdaptiveBitrate = bitRate;
        }
        bitRate = _h264AdaptiveBitrate;
    }
    [self applyH264Bitrate:bitRate toRegion:regionId];
    NSDictionary *poolAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(encoderPixelFormat),
        (NSString *)kCVPixelBufferWidthKey : @(width),
        (NSString *)kCVPixelBufferHeightKey : @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    if (CVPixelBufferPoolCreate(NULL, NULL,
                                (__bridge CFDictionaryRef)poolAttrs,
                                &slot->pixel_buffer_pool) != kCVReturnSuccess ||
        slot->pixel_buffer_pool == NULL) {
        _h264PixelBufferPoolFailures++;
    } else {
        _h264PixelBufferPoolCreates++;
    }
    VTCompressionSessionPrepareToEncodeFrames(slot->session);
    CFTypeRef hardwareValue = NULL;
    if (VTSessionCopyProperty(
            slot->session,
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            NULL, &hardwareValue) == noErr && hardwareValue != NULL) {
        _vtHardwareEncoder = hardwareValue == kCFBooleanTrue;
        CFRelease(hardwareValue);
    }
    _h264Width = width;
    _h264Height = height;
    _h264RegionId = regionId;
    _h264Session = slot->session;
    return slot->session;
}

- (h264_encoder_slot_t *)h264EncoderSlotForRegion:(uint16_t)regionId {
    for (size_t i = 0; i < SHARP_H264_ENCODER_SLOTS; i++) {
        if (_h264Encoders[i].active && _h264Encoders[i].region_id == regionId) {
            return &_h264Encoders[i];
        }
    }
    return NULL;
}

- (void)applyH264Bitrate:(uint64_t)bitrate toRegion:(uint16_t)regionId {
    h264_encoder_slot_t *slot = [self h264EncoderSlotForRegion:regionId];
    if (slot == NULL || slot->session == NULL || bitrate == 0) {
        return;
    }
    if (bitrate > (uint64_t)INT32_MAX) {
        bitrate = (uint64_t)INT32_MAX;
    }
    int32_t bitRate32 = (int32_t)bitrate;
    CFNumberRef bitRateNumber =
        CFNumberCreate(NULL, kCFNumberSInt32Type, &bitRate32);
    if (bitRateNumber != NULL) {
        VTSessionSetProperty(slot->session, kVTCompressionPropertyKey_AverageBitRate,
                             bitRateNumber);
        CFRelease(bitRateNumber);
    }
    int32_t dataRateBytes =
        (int32_t)MIN(200000000.0, ((double)bitRate32 * 1.5) / 8.0);
    int32_t dataRateSeconds = 1;
    CFNumberRef dataRateNumbers[2];
    dataRateNumbers[0] =
        CFNumberCreate(NULL, kCFNumberSInt32Type, &dataRateBytes);
    dataRateNumbers[1] =
        CFNumberCreate(NULL, kCFNumberSInt32Type, &dataRateSeconds);
    if (dataRateNumbers[0] != NULL && dataRateNumbers[1] != NULL) {
        CFArrayRef limits =
            CFArrayCreate(NULL, (const void **)dataRateNumbers, 2,
                          &kCFTypeArrayCallBacks);
        if (limits != NULL) {
            VTSessionSetProperty(slot->session,
                                 kVTCompressionPropertyKey_DataRateLimits,
                                 limits);
            CFRelease(limits);
        }
    }
    if (dataRateNumbers[0] != NULL) {
        CFRelease(dataRateNumbers[0]);
    }
    if (dataRateNumbers[1] != NULL) {
        CFRelease(dataRateNumbers[1]);
    }
    _h264TargetBitrate = bitrate;
}

- (void)noteFullFrameVideoLossFeedback {
    if (!_h264AdaptiveBitrateEnabled || _h264AdaptiveBitrate == 0) {
        return;
    }
    uint64_t minRate = _h264AdaptiveMinBitrate > 0 ? _h264AdaptiveMinBitrate : 1;
    uint64_t nextRate = (uint64_t)((double)_h264AdaptiveBitrate * 0.80);
    if (nextRate < minRate) {
        nextRate = minRate;
    }
    if (nextRate < _h264AdaptiveBitrate) {
        _h264AdaptiveBitrate = nextRate;
        _h264AdaptiveBackoffs++;
        _h264AdaptiveLastAdjustNs = shtp_now_ns();
        [self applyH264Bitrate:_h264AdaptiveBitrate
                      toRegion:SHARP_H264_FULLFRAME_ID];
    }
}

- (void)maybeRampFullFrameBitrate {
    if (!_h264AdaptiveBitrateEnabled || !_fullFrameActive ||
        _h264AdaptiveBitrate == 0 || _h264AdaptiveMaxBitrate == 0 ||
        _h264AdaptiveBitrate >= _h264AdaptiveMaxBitrate) {
        return;
    }
    uint64_t now = shtp_now_ns();
    if (_h264AdaptiveLastAdjustNs != 0 &&
        now - _h264AdaptiveLastAdjustNs < 2000000000ULL) {
        return;
    }
    uint64_t nextRate =
        (uint64_t)((double)_h264AdaptiveBitrate * 1.05) + 1000000ULL;
    if (nextRate > _h264AdaptiveMaxBitrate) {
        nextRate = _h264AdaptiveMaxBitrate;
    }
    if (nextRate > _h264AdaptiveBitrate) {
        _h264AdaptiveBitrate = nextRate;
        _h264AdaptiveRamps++;
        _h264AdaptiveLastAdjustNs = now;
        [self applyH264Bitrate:_h264AdaptiveBitrate
                      toRegion:SHARP_H264_FULLFRAME_ID];
    }
}

- (int)sendH264Blob:(const uint8_t *)blob
             length:(size_t)blobLen
            context:(const h264_sample_context_t *)context
              flags:(uint32_t)flags {
    if (blob == NULL || blobLen == 0 || context == NULL ||
        _payloadSize <= sizeof(sharp_video_region_chunk_header_t) ||
        _payloadSize > SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES) {
        return -1;
    }
    size_t maxChunkData = _payloadSize - sizeof(sharp_video_region_chunk_header_t);
    uint16_t chunkCount = (uint16_t)((blobLen + maxChunkData - 1u) / maxChunkData);
    if (chunkCount == 0 || chunkCount > SHARP_VIDEO_REGION_MAX_CHUNKS) {
        return -1;
    }
    BOOL fullFrameVideo = context->region_id == SHARP_H264_FULLFRAME_ID;
    int evictedRepair = 0;
    h264_resend_generation_t *resendGen = NULL;
    if (!fullFrameVideo) {
        resendGen = h264_resend_begin_generation(
            _h264Resend, SHARP_H264_RESEND_MAX_GENERATIONS,
            _h264ResendTarget > 0 ? _h264ResendTarget
                                  : SHARP_H264_RESEND_MIN_GENERATIONS,
            context->region_id, context->generation, chunkCount, &evictedRepair);
        if (evictedRepair) {
            _h264ResendRepairEvictions++;
            if (_h264ResendTarget < SHARP_H264_RESEND_MAX_GENERATIONS) {
                _h264ResendTarget += 4u;
                if (_h264ResendTarget > SHARP_H264_RESEND_MAX_GENERATIONS) {
                    _h264ResendTarget = SHARP_H264_RESEND_MAX_GENERATIONS;
                }
            }
        }
        if (resendGen != NULL) {
            size_t active =
                h264_resend_count_active(_h264Resend,
                                         SHARP_H264_RESEND_MAX_GENERATIONS);
            if (active > _h264ResendMaxActive) {
                _h264ResendMaxActive = (uint32_t)active;
            }
            if (active >= (_h264ResendTarget > 0
                               ? _h264ResendTarget
                               : SHARP_H264_RESEND_MIN_GENERATIONS)) {
                _h264ResendEvictions++;
            }
        }
        if (resendGen == NULL) {
            return -1;
        }
    }
    uint32_t checksum = sharp_video_region_checksum(blob, blobLen);
    uint8_t packet[SHTP_MAX_DATAGRAM];
    uint8_t fecG = fullFrameVideo && _fecEnabled
                       ? sharp_fec_group_count(chunkCount)
                       : 0u;
    size_t fecBytes = (size_t)fecG * maxChunkData;
    if (fecG > 0) {
        if (_h264FecParityScratchCap < fecBytes) {
            uint8_t *scratch = realloc(_h264FecParityScratch, fecBytes);
            if (scratch == NULL) {
                return -1;
            }
            _h264FecParityScratch = scratch;
            _h264FecParityScratchCap = fecBytes;
        }
        memset(_h264FecParityScratch, 0, fecBytes);
    }
    size_t offset = 0;
    [self drainFeedback];
    for (uint16_t chunkId = 0; chunkId < chunkCount; chunkId++) {
        size_t chunkLen = blobLen - offset < maxChunkData ? blobLen - offset
                                                          : maxChunkData;
        if (fecG > 0) {
            uint8_t group =
                sharp_fec_group_for_chunk(chunkId, chunkCount, fecG);
            uint8_t *parity =
                _h264FecParityScratch + (size_t)group * maxChunkData;
            for (size_t i = 0; i < maxChunkData; i++) {
                parity[i] ^= i < chunkLen ? blob[offset + i] : 0u;
            }
        }
        shtp_header_t sh;
        memset(&sh, 0, sizeof(sh));
        sh.magic = SHTP_MAGIC;
        sh.version = SHTP_VERSION;
        sh.header_bytes = SHTP_HEADER_BYTES;
        sh.type = SHTP_PACKET_DATA;
        sh.payload_type = SHTP_PAYLOAD_H264_REGION;
        if (_verifiedSession) { sh.flags |= SHTP_FLAG_VERIFIED_HYBRID; sh.aux_time_ns = _verifiedSession; }
        sh.frame_id = context->generation;
        sh.chunk_id = chunkId;
        sh.chunk_count = chunkCount;
        sh.payload_len = (uint32_t)(sizeof(sharp_video_region_chunk_header_t) +
                                    chunkLen);
        sh.send_time_ns = shtp_now_ns();

        sharp_video_region_chunk_header_t vh;
        memset(&vh, 0, sizeof(vh));
        vh.region_id = context->region_id;
        vh.x = context->x;
        vh.y = context->y;
        vh.w = context->w;
        vh.h = context->h;
        vh.generation = context->generation;
        vh.total_len = (uint32_t)blobLen;
        vh.offset = (uint32_t)offset;
        vh.chunk_len = (uint32_t)chunkLen;
        vh.flags = flags;
        vh.checksum = checksum;

        pthread_mutex_lock(&_sendLock);
        sh.sequence = _sequence++;
        shtp_header_host_to_wire(&sh);
        sharp_video_region_chunk_header_host_to_wire(&vh);
        memcpy(packet, &sh, sizeof(sh));
        memcpy(packet + sizeof(sh), &vh, sizeof(vh));
        memcpy(packet + sizeof(sh) + sizeof(vh), blob + offset, chunkLen);
        size_t packetLen = sizeof(sh) + sizeof(vh) + chunkLen;
        if (resendGen != NULL &&
            h264_resend_store_packet(resendGen, chunkId, packet, packetLen) != 0) {
            pthread_mutex_unlock(&_sendLock);
            return -1;
        }
        _h264OriginalPackets++;
        if (_vsliceDropEvery > 0 &&
            (_h264OriginalPackets % _vsliceDropEvery) == 0) {
            _h264InducedDrops++;
            pthread_mutex_unlock(&_sendLock);
            offset += chunkLen;
            continue;
        }
        if (send(_fd, packet, packetLen, 0) < 0) {
            pthread_mutex_unlock(&_sendLock);
            return -1;
        }
        pthread_mutex_unlock(&_sendLock);
        _h264Packets++;
        _h264Bytes += packetLen;
        if (context->region_id != SHARP_H264_FULLFRAME_ID) {
            [self paceAfterBytes:packetLen];
        }
        offset += chunkLen;
    }
    for (uint8_t g = 0; g < fecG; g++) {
        shtp_header_t sh;
        memset(&sh, 0, sizeof(sh));
        sh.magic = SHTP_MAGIC;
        sh.version = SHTP_VERSION;
        sh.header_bytes = SHTP_HEADER_BYTES;
        sh.type = SHTP_PACKET_DATA;
        sh.payload_type = SHTP_PAYLOAD_H264_REGION;
        if (_verifiedSession) { sh.flags |= SHTP_FLAG_VERIFIED_HYBRID; sh.aux_time_ns = _verifiedSession; }
        sh.frame_id = context->generation;
        sh.chunk_id = chunkCount + g;
        sh.chunk_count = chunkCount;
        sh.payload_len =
            (uint32_t)(sizeof(sharp_video_region_chunk_header_t) + maxChunkData);
        sh.send_time_ns = shtp_now_ns();

        sharp_video_region_chunk_header_t vh;
        memset(&vh, 0, sizeof(vh));
        vh.region_id = context->region_id;
        vh.x = context->x;
        vh.y = context->y;
        vh.w = context->w;
        vh.h = context->h;
        vh.generation = context->generation;
        vh.total_len = (uint32_t)blobLen;
        vh.offset = ((uint32_t)fecG << 16) | chunkCount;
        vh.chunk_len = (uint32_t)maxChunkData;
        vh.flags = flags | SHARP_VIDEO_REGION_FLAG_PARITY;
        vh.checksum = checksum;

        pthread_mutex_lock(&_sendLock);
        sh.sequence = _sequence++;
        shtp_header_host_to_wire(&sh);
        sharp_video_region_chunk_header_host_to_wire(&vh);
        memcpy(packet, &sh, sizeof(sh));
        memcpy(packet + sizeof(sh), &vh, sizeof(vh));
        memcpy(packet + sizeof(sh) + sizeof(vh),
               _h264FecParityScratch + (size_t)g * maxChunkData, maxChunkData);
        size_t packetLen = sizeof(sh) + sizeof(vh) + maxChunkData;
        if (send(_fd, packet, packetLen, 0) < 0) {
            pthread_mutex_unlock(&_sendLock);
            return -1;
        }
        pthread_mutex_unlock(&_sendLock);
        _h264Packets++;
        _h264Bytes += packetLen;
        _h264FecPackets++;
        _h264FecBytes += packetLen;
    }
    [self recordFinalPacketSendForFrameId:context->generation
                                timestamp:shtp_now_ns()];
    return 0;
}

- (void)handleEncodedSample:(CMSampleBufferRef)sampleBuffer context:(void *)rawContext {
    if (_h264EncodeInFlight > 0) {
        _h264EncodeInFlight--;
    }
    h264_sample_context_t *context = (h264_sample_context_t *)rawContext;
    if (context == NULL) {
        _h264EncodeFailures++;
        return;
    }
    if (context->submit_ns != 0 && context->callback_ns > context->submit_ns &&
        _h264CallbackLatencyCount < SHARP_TX_LATENCY_SAMPLES) {
        _h264CallbackLatencySamples[_h264CallbackLatencyCount++] =
            context->callback_ns - context->submit_ns;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL keyframe = YES;
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        keyframe = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
    }
    if (keyframe && context->region_id == SHARP_H264_FULLFRAME_ID) {
        const char *reason = "periodic";
        if (context->keyframe_reason ==
            SHARP_H264_KEYFRAME_REASON_ENTRY) {
            reason = "entry";
        } else if (context->keyframe_reason ==
                   SHARP_H264_KEYFRAME_REASON_LOSS_ESCALATION) {
            reason = "loss-escalation";
        }
        uint64_t nowNs = shtp_now_ns();
        uint64_t activeNs = _fullFrameEnteredNs != 0 &&
                                    nowNs >= _fullFrameEnteredNs
                                ? nowNs - _fullFrameEnteredNs
                                : 0;
        [self logFullFrameEvent:"idr"
                          reason:reason
                    motionTiles:0
            sustainedMotionTiles:0
                    motionRegions:0
                       tileCount:0
                          heldNs:activeNs
                         quietNs:0];
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t sampleLen = block != NULL ? CMBlockBufferGetDataLength(block) : 0;
    if (sampleLen == 0 || sampleLen > 16u * 1024u * 1024u) {
        _h264EncodeFailures++;
        [self finishFullFrameEncodeSendForContext:context];
        return;
    }
    const uint8_t *sps = NULL;
    const uint8_t *pps = NULL;
    size_t spsLen = 0;
    size_t ppsLen = 0;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (keyframe && fmt != NULL) {
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, 0, &sps, &spsLen, NULL, NULL);
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, 1, &pps, &ppsLen, NULL, NULL);
    }
    size_t blobLen = 16u + spsLen + ppsLen + sampleLen;
    uint8_t *blob = malloc(blobLen);
    if (blob == NULL) {
        _h264EncodeFailures++;
        [self finishFullFrameEncodeSendForContext:context];
        return;
    }
    write_be32(blob, 0x53485631u);
    write_be32(blob + 4u, (uint32_t)spsLen);
    write_be32(blob + 8u, (uint32_t)ppsLen);
    write_be32(blob + 12u, (uint32_t)sampleLen);
    size_t pos = 16u;
    if (spsLen > 0) {
        memcpy(blob + pos, sps, spsLen);
        pos += spsLen;
    }
    if (ppsLen > 0) {
        memcpy(blob + pos, pps, ppsLen);
        pos += ppsLen;
    }
    if (CMBlockBufferCopyDataBytes(block, 0, sampleLen, blob + pos) != noErr) {
        free(blob);
        _h264EncodeFailures++;
        [self finishFullFrameEncodeSendForContext:context];
        return;
    }
    uint32_t flags = keyframe ? SHARP_VIDEO_REGION_FLAG_KEYFRAME : 0u;
    if (spsLen > 0 && ppsLen > 0) {
        flags |= SHARP_VIDEO_REGION_FLAG_HAS_CONFIG;
        _h264Keyframes++;
    }
    if ([self sendH264Blob:blob length:blobLen context:context flags:flags] == 0) {
        _h264Frames++;
        if (context->region_id == SHARP_H264_FULLFRAME_ID) {
            _fullFrameH264Frames++;
            _fullFrameH264Bytes += blobLen;
            if (context->emit_frame_end) {
                uint16_t mask = (uint16_t)(1u << SHARP_H264_FULLFRAME_ID);
                if ([self sendFrameEndFrameId:context->generation
                              expectedPatches:1u
                              videoRegionMask:mask
                                    motionMask:context->motion_mask
                               motionMaskBytes:context->motion_mask_bytes] == 0) {
                    _txFrameEnds++;
                    _fullFrameFrameEndsFromCallback++;
                    _txFrames++;
                } else {
                    _txFailures++;
                }
            }
        }
        [self markH264EmittedRegion:context->region_id
                              frameId:context->generation];
        if (_h264FrameBytesCount < SHARP_TX_LATENCY_SAMPLES) {
            _h264FrameBytesSamples[_h264FrameBytesCount++] = blobLen;
        }
        if (_firstH264Ns == 0) {
            _firstH264Ns = shtp_now_ns();
        }
        h264_region_stream_t *stream =
            [self h264StreamForRegion:context->region_id
                                create:NO
                               frameId:context->generation];
        if (stream != NULL) {
            stream->frames++;
            if ((flags & SHARP_VIDEO_REGION_FLAG_HAS_CONFIG) != 0) {
                stream->keyframes++;
                stream->has_keyframe = 1u;
                stream->need_keyframe = 0u;
                stream->force_idr = 0u;
            } else {
                stream->pframes++;
                _h264Pframes++;
            }
        } else if ((flags & SHARP_VIDEO_REGION_FLAG_HAS_CONFIG) == 0) {
            _h264Pframes++;
        }
    } else {
        _h264EncodeFailures++;
    }
    free(blob);
    [self finishFullFrameEncodeSendForContext:context];
}

- (void)finishFullFrameEncodeSendForContext:(const h264_sample_context_t *)context {
    if (context != NULL && context->region_id == SHARP_H264_FULLFRAME_ID &&
        _fullFrameEncodeInFlight > 0) {
        _fullFrameEncodeInFlight--;
    }
    if (context != NULL) {
        if (context->retained_pixel_buffer != NULL) {
            CVPixelBufferRelease(context->retained_pixel_buffer);
        }
        free(context->motion_mask);
        free((void *)context);
    }
}

- (BOOL)encodeH264FullFrame:(CVPixelBufferRef)pixelBuffer
                    frameId:(uint32_t)frameId
              forceKeyframe:(BOOL)forceKeyframe
                     direct:(BOOL)direct
               sourceLocked:(BOOL)sourceLocked
               emitFrameEnd:(BOOL)emitFrameEnd {
    if (pixelBuffer == NULL || _width == 0 || _height == 0 ||
        CVPixelBufferGetWidth(pixelBuffer) != _width ||
        CVPixelBufferGetHeight(pixelBuffer) != _height) {
        return NO;
    }
    _fullFrameTraceKeyframeAttempted =
        _fullFrameTraceKeyframeAttempted || forceKeyframe;
    if (_fullFrameEncodeInFlight >= 2u && !forceKeyframe) {
        _fullFrameSendDrops++;
        return NO;
    }
    [self maybeRampFullFrameBitrate];
    VTCompressionSessionRef session =
        [self ensureH264EncoderForRegion:SHARP_H264_FULLFRAME_ID
                                    width:_width
                                   height:_height];
    if (session == NULL) {
        return NO;
    }
    CVPixelBufferRef encodeBuffer = pixelBuffer;
    BOOL useNv12Input = _vtNv12Requested ? YES : NO;
    BOOL usingDirectBuffer =
        !useNv12Input && direct && CVPixelBufferGetIOSurface(pixelBuffer) != NULL
            ? YES
            : NO;
    if (direct && !usingDirectBuffer && !useNv12Input) {
        _fullFrameDirectFallbacks++;
    }
    if (!usingDirectBuffer) {
        h264_encoder_slot_t *slot =
            [self h264EncoderSlotForRegion:SHARP_H264_FULLFRAME_ID];
        CVReturn pixelStatus = kCVReturnError;
        encodeBuffer = NULL;
        if (slot != NULL && slot->pixel_buffer_pool != NULL) {
            pixelStatus =
                CVPixelBufferPoolCreatePixelBuffer(NULL, slot->pixel_buffer_pool,
                                                   &encodeBuffer);
        }
        if (pixelStatus != kCVReturnSuccess || encodeBuffer == NULL) {
            _h264EncodeFailures++;
            _h264PixelBufferPoolFailures++;
            return NO;
        }
        if (useNv12Input) {
            if (_vtPixelTransferSession == NULL &&
                VTPixelTransferSessionCreate(
                    NULL, &_vtPixelTransferSession) != noErr) {
                _vtPixelTransferSession = NULL;
            }
            if (_vtPixelTransferSession == NULL) {
                CVPixelBufferRelease(encodeBuffer);
                _vtPixelTransferFailures++;
                _h264EncodeFailures++;
                return NO;
            }
            set_h264_709_color_attachments(pixelBuffer);
            uint64_t convertStartNs = shtp_now_ns();
            OSStatus transferStatus = VTPixelTransferSessionTransferImage(
                _vtPixelTransferSession, pixelBuffer, encodeBuffer);
            uint64_t convertDoneNs = shtp_now_ns();
            if (convertDoneNs >= convertStartNs &&
                _fullFrameConvertCount < SHARP_TX_LATENCY_SAMPLES) {
                _fullFrameConvertSamples[_fullFrameConvertCount++] =
                    convertDoneNs - convertStartNs;
            }
            if (transferStatus != noErr) {
                CVPixelBufferRelease(encodeBuffer);
                _vtPixelTransferFailures++;
                _h264EncodeFailures++;
                return NO;
            }
            _vtNv12Active = YES;
        } else {
            if (!sourceLocked &&
                CVPixelBufferLockBaseAddress(pixelBuffer,
                                             kCVPixelBufferLock_ReadOnly) !=
                    kCVReturnSuccess) {
                CVPixelBufferRelease(encodeBuffer);
                _h264EncodeFailures++;
                return NO;
            }
            uint64_t copyStartNs = shtp_now_ns();
            CVPixelBufferLockBaseAddress(encodeBuffer, 0);
            uint8_t *dst = CVPixelBufferGetBaseAddress(encodeBuffer);
            size_t dstStride = CVPixelBufferGetBytesPerRow(encodeBuffer);
            const uint8_t *src = CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
            size_t rowBytes = (size_t)_width * 4u;
            for (uint32_t row = 0; row < _height; row++) {
                memcpy(dst + (size_t)row * dstStride,
                       src + (size_t)row * srcStride, rowBytes);
            }
            CVPixelBufferUnlockBaseAddress(encodeBuffer, 0);
            if (!sourceLocked) {
                CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                               kCVPixelBufferLock_ReadOnly);
            }
            uint64_t copyDoneNs = shtp_now_ns();
            if (copyDoneNs >= copyStartNs &&
                _fullFrameCopyCount < SHARP_TX_LATENCY_SAMPLES) {
                _fullFrameCopySamples[_fullFrameCopyCount++] =
                    copyDoneNs - copyStartNs;
            }
        }
    }

    h264_sample_context_t *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        if (!usingDirectBuffer && encodeBuffer != NULL) {
            CVPixelBufferRelease(encodeBuffer);
        }
        _h264EncodeFailures++;
        return NO;
    }
    context->region_id = SHARP_H264_FULLFRAME_ID;
    context->x = 0;
    context->y = 0;
    context->w = (uint16_t)_width;
    context->h = (uint16_t)_height;
    context->generation = frameId;
    context->full_frame_direct = usingDirectBuffer ? 1u : 0u;
    context->emit_frame_end = emitFrameEnd ? 1u : 0u;
    if (forceKeyframe) {
        if (_h264HaveKeyframeRequest &&
            _h264RequestedRegion == SHARP_H264_FULLFRAME_ID) {
            context->keyframe_reason =
                SHARP_H264_KEYFRAME_REASON_LOSS_ESCALATION;
        } else if (_fullFrameForceKeyframe) {
            context->keyframe_reason = SHARP_H264_KEYFRAME_REASON_ENTRY;
        } else {
            context->keyframe_reason = SHARP_H264_KEYFRAME_REASON_PERIODIC;
        }
    }
    if (context->emit_frame_end && _motionMaskEnabled &&
        _fullFrameCurrentMask != NULL && _fullFrameEpisodeMaskCap > 0) {
        context->motion_mask = malloc(_fullFrameEpisodeMaskCap);
        if (context->motion_mask == NULL) {
            if (usingDirectBuffer && context->retained_pixel_buffer != NULL) {
                CVPixelBufferRelease(context->retained_pixel_buffer);
            }
            free(context);
            if (!usingDirectBuffer && encodeBuffer != NULL) {
                CVPixelBufferRelease(encodeBuffer);
            }
            _h264EncodeFailures++;
            return NO;
        }
        memcpy(context->motion_mask, _fullFrameCurrentMask,
               _fullFrameEpisodeMaskCap);
        context->motion_mask_bytes = (uint16_t)_fullFrameEpisodeMaskCap;
    }
    if (usingDirectBuffer) {
        CVPixelBufferRetain(pixelBuffer);
        context->retained_pixel_buffer = pixelBuffer;
    }
    set_h264_709_color_attachments(encodeBuffer);
    _h264Generation = frameId;

    NSDictionary *options = forceKeyframe ? @{
        (NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES,
    } : nil;
    CMTime pts = CMTimeMake((int64_t)frameId, (int32_t)(_fps > 0 ? _fps : 60));
    uint64_t submitStartNs = shtp_now_ns();
    context->submit_ns = submitStartNs;
    [self recordVtSubmitForFrameId:frameId timestamp:submitStartNs];
    OSStatus status = VTCompressionSessionEncodeFrame(
        session, encodeBuffer, pts, kCMTimeInvalid,
        (__bridge CFDictionaryRef)options, context, NULL);
    uint64_t submitDoneNs = shtp_now_ns();
    if (submitDoneNs >= submitStartNs &&
        _fullFrameEncodeSubmitCount < SHARP_TX_LATENCY_SAMPLES) {
        _fullFrameEncodeSubmitSamples[_fullFrameEncodeSubmitCount++] =
            submitDoneNs - submitStartNs;
    }
    if (!usingDirectBuffer && encodeBuffer != NULL) {
        CVPixelBufferRelease(encodeBuffer);
    }
    if (status != noErr) {
        if (context->retained_pixel_buffer != NULL) {
            CVPixelBufferRelease(context->retained_pixel_buffer);
        }
        free(context->motion_mask);
        free(context);
        _h264EncodeFailures++;
        return NO;
    }
    _h264EncodeSubmissions++;
    _fullFrameEncodeSubmissions++;
    if (usingDirectBuffer) {
        _fullFrameDirectSubmissions++;
    } else {
        _fullFrameCopiedSubmissions++;
    }
    _h264EncodeInFlight++;
    _fullFrameEncodeInFlight++;
    if (_h264EncodeInFlight > _h264MaxEncodeInFlight) {
        _h264MaxEncodeInFlight = _h264EncodeInFlight;
    }
    if (_fullFrameEncodeInFlight > _fullFrameMaxEncodeInFlight) {
        _fullFrameMaxEncodeInFlight = _fullFrameEncodeInFlight;
    }
    return YES;
}

- (void)encodeH264Region:(const sharp_m2_region_t *)region
                    bgra:(const uint8_t *)bgra
                  stride:(uint32_t)stride
                 frameId:(uint32_t)frameId
            forceKeyframe:(BOOL)forceKeyframe {
    if (region == NULL || bgra == NULL || region->w == 0 || region->h == 0) {
        return;
    }
    VTCompressionSessionRef session =
        [self ensureH264EncoderForRegion:(uint16_t)region->id
                                    width:region->w
                                   height:region->h];
    if (session == NULL) {
        return;
    }
    h264_encoder_slot_t *slot =
        [self h264EncoderSlotForRegion:(uint16_t)region->id];

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn pixelStatus = kCVReturnError;
    if (slot != NULL && slot->pixel_buffer_pool != NULL) {
        pixelStatus =
            CVPixelBufferPoolCreatePixelBuffer(NULL, slot->pixel_buffer_pool,
                                               &pixelBuffer);
    }
    if (pixelStatus != kCVReturnSuccess || pixelBuffer == NULL) {
        _h264EncodeFailures++;
        _h264PixelBufferPoolFailures++;
        return;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const uint8_t *src = bgra + (size_t)region->y * stride + (size_t)region->x * 4u;
    for (uint32_t row = 0; row < region->h; row++) {
        memcpy(dst + (size_t)row * dstStride, src + (size_t)row * stride,
               (size_t)region->w * 4u);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    set_h264_709_color_attachments(pixelBuffer);

    h264_sample_context_t *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        CVPixelBufferRelease(pixelBuffer);
        _h264EncodeFailures++;
        return;
    }
    context->region_id = (uint16_t)region->id;
    context->x = (uint16_t)region->x;
    context->y = (uint16_t)region->y;
    context->w = (uint16_t)region->w;
    context->h = (uint16_t)region->h;
    context->generation = frameId;
    _h264Generation = frameId;

    NSDictionary *options = forceKeyframe ? @{
        (NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES,
    } : nil;
    CMTime pts = CMTimeMake((int64_t)frameId, (int32_t)(_fps > 0 ? _fps : 30));
    context->submit_ns = shtp_now_ns();
    OSStatus status = VTCompressionSessionEncodeFrame(
        session, pixelBuffer, pts, kCMTimeInvalid,
        (__bridge CFDictionaryRef)options, context, NULL);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr) {
        free(context);
        _h264EncodeFailures++;
        return;
    }
    _h264EncodeSubmissions++;
    _h264EncodeInFlight++;
    if (_h264EncodeInFlight > _h264MaxEncodeInFlight) {
        _h264MaxEncodeInFlight = _h264EncodeInFlight;
    }
}
@end
