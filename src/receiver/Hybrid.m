#import "Internal.h"

@implementation SharpDisplayApp (Hybrid)
- (void)sendVerifiedMessageLocked:(sharp_hybrid_message_t *)message {
    if (!_haveSenderAddr) return;
    if (message->kind==SHARP_HYBRID_ACK && (message->flags&SHARP_HYBRID_COMMITTED) &&
        _verifiedReceiver && _verifiedReceiver->latest_video_frame && _verifiedDropCommitAcks) {
        _verifiedDropCommitAcks--;fprintf(stdout,"verified-test drop_commit_ack=1 remaining=%u\n",_verifiedDropCommitAcks);return;
    }
    uint8_t packet[1200];
    size_t len=sharp_hybrid_encode(packet+SHTP_HEADER_BYTES,sizeof(packet)-SHTP_HEADER_BYTES,message);
    if (!len) return;
    shtp_header_t sh={0}; sh.magic=SHTP_MAGIC;sh.version=SHTP_VERSION;
    sh.header_bytes=SHTP_HEADER_BYTES;sh.type=SHTP_PACKET_STATS;
    sh.payload_type=SHTP_PAYLOAD_HYBRID_STATE;sh.payload_len=(uint32_t)len;
    sh.frame_id=message->frame;sh.send_time_ns=shtp_now_ns();
    shtp_header_host_to_wire(&sh);memcpy(packet,&sh,sizeof(sh));
    (void)sendto(_fd,packet,sizeof(sh)+len,0,(struct sockaddr *)&_senderAddr,_senderAddrLen);
}

- (void)handleVerifiedStateLocked:(const uint8_t *)payload length:(size_t)length {
    sharp_hybrid_message_t m;
    if(sharp_hybrid_decode(&m,payload,length)!=0 || m.width!=_config.width || m.height!=_config.height) return;
    if (m.kind==SHARP_HYBRID_HELLO || (m.kind==SHARP_HYBRID_MAP && !_verifiedReceiver)) {
        m.count=0;m.first=0;m.flags=0;
        if (_verifiedReceiver && _verifiedReceiver->session==m.session) {
            m.kind=m.nonce==_verifiedActiveNonce?SHARP_HYBRID_READY:SHARP_HYBRID_OFFER;
            m.nonce=_verifiedActiveNonce;
        } else {
            if (_verifiedOfferSession!=m.session) {
                _verifiedOfferSession=m.session;
                arc4random_buf(&_verifiedOfferNonce,sizeof(_verifiedOfferNonce));
                if (!_verifiedOfferNonce) _verifiedOfferNonce=1;
            }
            m.kind=SHARP_HYBRID_OFFER;m.nonce=_verifiedOfferNonce;
        }
        [self sendVerifiedMessageLocked:&m];return;
    }
    if (m.kind==SHARP_HYBRID_CONFIRM) {
        BOOL current=_verifiedReceiver && _verifiedReceiver->session==m.session &&
                     _verifiedActiveNonce==m.nonce;
        if (!current) {
            if (m.session!=_verifiedOfferSession || m.nonce!=_verifiedOfferNonce || !m.nonce) return;
            sharp_hybrid_receiver_t *next=calloc(1,sizeof(*next));
            if (!next || sharp_hybrid_receiver_init(next,m.session,m.width,m.height)!=0) { free(next);return; }
            sharp_tile_receiver_t tiles;
            if (sharp_tile_receiver_init(&tiles,m.width,m.height)!=0) {free(next);return;}
            sharp_video_region_reassembler_t *video=sharp_video_region_reassembler_create(m.width,m.height);
            if (!video) {sharp_tile_receiver_destroy(&tiles);free(next);return;}
            sharp_tile_receiver_destroy(&_receiver);_receiver=tiles;
            sharp_video_region_reassembler_destroy(_videoReassembler);_videoReassembler=video;
            free(_verifiedReceiver);_verifiedReceiver=next;
            _verifiedActiveNonce=m.nonce;_verifiedOfferNonce=0;_verifiedOfferSession=0;
            const char *dropAcks=getenv("SHARP_TEST_HYBRID_DROP_COMMIT_ACKS");
            const char *dropTiles=getenv("SHARP_TEST_HYBRID_DROP_TILE_EVERY");
            _verifiedDropCommitAcks=dropAcks?(uint32_t)strtoul(dropAcks,NULL,10):0;
            _verifiedDropTileEvery=dropTiles?(uint32_t)strtoul(dropTiles,NULL,10):0;
            for(size_t i=0;i<SHARP_MAX_VIDEO_REGIONS;i++) [self clearVideoLayerAtIndex:i];
            [self clearPendingPresentationLocked];
            _frameReady=NO;_stagingDirty=NO;dirty_bounds_reset(&_stagingDirtyBounds);
            _committedFrame=0;_latestFrameEnd=0;_verifiedLastAckNs=0;
            _activeMotionMaskValid=NO;_pendingMotionMaskValid=NO;_desiredMotionMaskValid=NO;
            _motionMaskAtomicReleasePending=NO;
            fprintf(stdout,"verified-hybrid receiver_ready=1 session=%llu\n",m.session);fflush(stdout);
        }
        m.kind=SHARP_HYBRID_READY; m.count=0;m.first=0;m.flags=0;
        [self sendVerifiedMessageLocked:&m];return;
    }
    if (_verifiedReceiver && m.kind==SHARP_HYBRID_MAP)
        (void)sharp_hybrid_accept_map(_verifiedReceiver,&m);
}

- (void)sendVerifiedAckLocked {
    uint64_t now=shtp_now_ns();
    if (!_verifiedReceiver || now-_verifiedLastAckNs<25000000ULL) return;
    _verifiedLastAckNs=now;
    sharp_hybrid_message_t m={0};
    m.kind=SHARP_HYBRID_ACK;m.session=_verifiedReceiver->session;
    m.nonce=_verifiedActiveNonce;
    m.width=_config.width;m.height=_config.height;m.total=_receiver.tile_count;
    m.frame=_verifiedReceiver->committed_frame;
    m.flags=m.frame?SHARP_HYBRID_COMMITTED:0;
    for(uint32_t first=0;first<m.total;first+=SHARP_HYBRID_CHUNK_TILES) {
        m.first=(uint16_t)first;m.count=(uint16_t)MIN(SHARP_HYBRID_CHUNK_TILES,m.total-first);
        memcpy(m.versions,_receiver.tile_generations+first,4u*m.count);
        [self sendVerifiedMessageLocked:&m];
    }
}
@end
