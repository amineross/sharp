#import "Internal.h"

@implementation SharpDisplayApp (Metrics)
- (void)recordDisplayLinkOutputTime:(const CVTimeStamp *)outputTime {
    if (outputTime == NULL || outputTime->hostTime == 0) {
        return;
    }
    uint64_t vsyncNs = sharp_mach_absolute_to_ns(outputTime->hostTime);
    uint64_t periodNs = 0;
    uint64_t previousNs = _latestVsyncNs;
    if (previousNs != 0 && vsyncNs > previousNs) {
        uint64_t deltaNs = vsyncNs - previousNs;
        if (deltaNs > 1000000ULL && deltaNs < 100000000ULL) {
            periodNs = deltaNs;
        }
    }
    if (periodNs == 0 && outputTime->videoTimeScale > 0 &&
        outputTime->videoRefreshPeriod > 0) {
        periodNs =
            (uint64_t)((double)outputTime->videoRefreshPeriod * 1000000000.0 /
                       (double)outputTime->videoTimeScale);
    }
    if (periodNs == 0) {
        periodNs = 16666667ULL;
    }
    _previousVsyncNs = previousNs;
    _latestVsyncNs = vsyncNs;
    _latestVsyncPeriodNs = periodNs;
}

- (BOOL)recordPresentNowNs:(uint64_t)nowNs contentSerial:(uint64_t)contentSerial {
    BOOL hadPreviousPresent = _lastPresentNs != 0;
    BOOL contentChanged = _lastPresentedContentSerial != contentSerial;
    if (contentChanged) {
        _lastContentAdvanceNs = nowNs;
    }
    BOOL motionRecent =
        _lastContentAdvanceNs != 0 && nowNs >= _lastContentAdvanceNs &&
        nowNs - _lastContentAdvanceNs <= 100000000ULL;
    if (_lastPresentNs != 0 && nowNs > _lastPresentNs) {
        uint64_t intervalNs = nowNs - _lastPresentNs;
        if (motionRecent) {
            _presentIntervalTotalCount++;
            if (_presentIntervalCount < SHARP_PRESENT_INTERVAL_SAMPLES) {
                _presentIntervalSamples[_presentIntervalCount++] = intervalNs;
            }
            _presentIntervalSumNs += (double)intervalNs;
            _presentIntervalSumSqNs += (double)intervalNs * (double)intervalNs;
        } else {
            _idlePresentIntervalTotalCount++;
            if (_idlePresentIntervalCount < SHARP_PRESENT_INTERVAL_SAMPLES) {
                _idlePresentIntervalSamples[_idlePresentIntervalCount++] = intervalNs;
            }
            _idlePresentIntervalSumNs += (double)intervalNs;
            _idlePresentIntervalSumSqNs +=
                (double)intervalNs * (double)intervalNs;
        }
    }
    _lastPresentNs = nowNs;

    if (hadPreviousPresent && _lastPresentedContentSerial == contentSerial) {
        if (motionRecent) {
            _presentRepeatFrames++;
            _presentCurrentStall++;
            if (_presentCurrentStall > _presentLongestStall) {
                _presentLongestStall = _presentCurrentStall;
            }
        } else {
            _idlePresentRepeatFrames++;
            _idlePresentCurrentStall++;
            if (_idlePresentCurrentStall > _idlePresentLongestStall) {
                _idlePresentLongestStall = _idlePresentCurrentStall;
            }
        }
    } else {
        _lastPresentedContentSerial = contentSerial;
        _presentCurrentStall = 0;
        _idlePresentCurrentStall = 0;
    }
    return contentChanged;
}

- (void)recordH264DecodeLatencySubmitNs:(uint64_t)submitNs {
    if (submitNs == 0 || _h264DecodeLatencyCount >= SHARP_PRESENT_INTERVAL_SAMPLES) {
        return;
    }
    uint64_t nowNs = shtp_now_ns();
    if (nowNs >= submitNs) {
        _h264DecodeLatencySamples[_h264DecodeLatencyCount++] = nowNs - submitNs;
    }
}

- (void)recordPendingVideoDecodeArrival:(uint64_t)arrivalSeq {
    if (arrivalSeq == 0) {
        return;
    }
    pthread_mutex_lock(&_stateLock);
    if (_pendingVideoDecodeCount < SHARP_PRESENT_INTERVAL_SAMPLES) {
        _pendingVideoDecodeArrivals[_pendingVideoDecodeCount++] = arrivalSeq;
    }
    pthread_mutex_unlock(&_stateLock);
}

- (void)completeVideoDecodeArrival:(uint64_t)arrivalSeq {
    if (arrivalSeq == 0) {
        return;
    }
    pthread_mutex_lock(&_stateLock);
    for (size_t i = 0; i < _pendingVideoDecodeCount; i++) {
        if (_pendingVideoDecodeArrivals[i] == arrivalSeq) {
            _pendingVideoDecodeArrivals[i] =
                _pendingVideoDecodeArrivals[_pendingVideoDecodeCount - 1u];
            _pendingVideoDecodeCount--;
            break;
        }
    }
    pthread_mutex_unlock(&_stateLock);
    [self publishVideoArrivalWatermark];
}

- (void)recordH264DecodeCallbackSubmitNs:(uint64_t)submitNs {
    pthread_mutex_lock(&_stateLock);
    _h264DecodeCallbacks++;
    [self recordH264DecodeLatencySubmitNs:submitNs];
    pthread_mutex_unlock(&_stateLock);
}

- (double)presentIntervalMeanMs {
    if (_presentIntervalTotalCount == 0) {
        return 0.0;
    }
    return (_presentIntervalSumNs / (double)_presentIntervalTotalCount) / 1000000.0;
}

- (double)presentIntervalCov {
    if (_presentIntervalTotalCount == 0 || _presentIntervalSumNs <= 0.0) {
        return 0.0;
    }
    double count = (double)_presentIntervalTotalCount;
    double mean = _presentIntervalSumNs / count;
    double variance = (_presentIntervalSumSqNs / count) - mean * mean;
    if (variance < 0.0) {
        variance = 0.0;
    }
    return sqrt(variance) / mean;
}

- (uint64_t)presentIntervalPercentileNs:(double)percentile {
    if (_presentIntervalCount == 0) {
        return 0;
    }
    size_t count = _presentIntervalCount;
    uint64_t *samples = malloc(count * sizeof(*samples));
    if (samples == NULL) {
        return 0;
    }
    memcpy(samples, _presentIntervalSamples, count * sizeof(*samples));
    qsort(samples, count, sizeof(*samples), compare_u64_values);
    if (percentile < 0.0) {
        percentile = 0.0;
    } else if (percentile > 1.0) {
        percentile = 1.0;
    }
    size_t rank = (size_t)ceil(percentile * (double)count);
    size_t index = rank > 0 ? rank - 1u : 0u;
    if (index >= count) {
        index = count - 1u;
    }
    uint64_t value = samples[index];
    free(samples);
    return value;
}

- (uint64_t)h264DecodeLatencyPercentileNs:(double)percentile {
    if (_h264DecodeLatencyCount == 0) {
        return 0;
    }
    size_t count = _h264DecodeLatencyCount;
    uint64_t *samples = malloc(count * sizeof(*samples));
    if (samples == NULL) {
        return 0;
    }
    memcpy(samples, _h264DecodeLatencySamples, count * sizeof(*samples));
    qsort(samples, count, sizeof(*samples), compare_u64_values);
    if (percentile < 0.0) {
        percentile = 0.0;
    } else if (percentile > 1.0) {
        percentile = 1.0;
    }
    size_t rank = (size_t)ceil(percentile * (double)count);
    size_t index = rank > 0 ? rank - 1u : 0u;
    if (index >= count) {
        index = count - 1u;
    }
    uint64_t value = samples[index];
    free(samples);
    return value;
}
@end
