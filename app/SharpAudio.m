#import "SharpAudio.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <math.h>

#define AUDIO_PORT 49173
#define CAPACITY 16384u
#define MASK (CAPACITY-1u)
#define BLOCK 256u

// Single producer/consumer, preallocated. Core Audio callbacks never wait on a
// lock, allocate memory, or perform network IO. Samples on the wire are stereo
// float32 little endian; the header uses network byte order.
typedef struct {
    float samples[CAPACITY][2];
    _Atomic(uint64_t) written, read, callbacks, nonzero, played, underruns;
    double phase;
    uint32_t target;
    bool primed;
} AudioRing;

static uint64_t nowNS(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return mach_continuous_time()*tb.numer/tb.denom;
}
static uint32_t putFrames(AudioRing *r, const float *samples, uint32_t n) {
    uint64_t w=atomic_load_explicit(&r->written,memory_order_relaxed);
    uint64_t rd=atomic_load_explicit(&r->read,memory_order_acquire);
    n=(uint32_t)MIN(n,CAPACITY-(w-rd));
    for(uint32_t i=0;i<n;i++) memcpy(r->samples[(w+i)&MASK],samples+2*i,8);
    atomic_store_explicit(&r->written,w+n,memory_order_release);
    return n;
}
static void renderFrames(AudioRing *r, float *out, uint32_t n) {
    memset(out,0,n*8);
    uint64_t rd=atomic_load_explicit(&r->read,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&r->written,memory_order_acquire);
    uint64_t count=w-rd;
    if(count>r->target*3u) { rd=w-r->target; count=r->target; r->phase=0; }
    if(!r->primed && count>=r->target) r->primed=true;
    if(r->primed) {
        // Small continuous rate correction follows the two hardware clocks.
        // Keep a bounded jitter reserve without accumulating lip-sync drift.
        double step=1.0+fmax(-0.002,fmin(0.002,((double)count-r->target)/r->target*0.002));
        for(uint32_t i=0;i<n;i++) {
            if(w-rd<2) { r->primed=false; r->phase=0; atomic_fetch_add(&r->underruns,1); break; }
            for(int c=0;c<2;c++) out[i*2+c]=r->samples[rd&MASK][c]*(1.0-r->phase)+r->samples[(rd+1)&MASK][c]*r->phase;
            r->phase+=step; uint32_t advance=(uint32_t)r->phase; rd+=advance; r->phase-=advance;
        }
    }
    atomic_store_explicit(&r->read,rd,memory_order_release);
    for(uint32_t i=0;i<n*2;i++) if(fabsf(out[i])>0.00001f) { atomic_fetch_add(&r->played,1);break; }
    atomic_fetch_add(&r->callbacks,1);
}

@interface SharpAudio () {
@public
    AudioRing _ring;
    _Atomic(bool) _stopped;
    NSLock *_socketLock;
    int _socket, _listener;
    dispatch_queue_t _worker;
    void (^_status)(NSString *);
    AudioObjectID _tap, _aggregate;
    AudioDeviceIOProcID _io;
    AudioQueueRef _playback;
    AudioStreamBasicDescription _format;
}
@end

static OSStatus capture(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,
                        const AudioTimeStamp *inTime,AudioBufferList *output,const AudioTimeStamp *outTime,void *context) {
    (void)device;(void)now;(void)inTime;(void)output;(void)outTime;
    SharpAudio *s=(__bridge SharpAudio *)context;
    if(atomic_load(&s->_stopped) || !input || !input->mNumberBuffers) return noErr;
    uint64_t w=atomic_load_explicit(&s->_ring.written,memory_order_relaxed);
    uint64_t rd=atomic_load_explicit(&s->_ring.read,memory_order_acquire);
    const AudioBuffer *b=&input->mBuffers[0];
    if(!b->mData || !b->mNumberChannels) return noErr;
    uint32_t n=b->mDataByteSize/(4*b->mNumberChannels);
    n=(uint32_t)MIN(n,CAPACITY-(w-rd));
    bool nonzero=false;
    for(uint32_t i=0;i<n;i++) {
        float l=((float *)b->mData)[i*b->mNumberChannels], r=l;
        if(b->mNumberChannels>=2) r=((float *)b->mData)[i*b->mNumberChannels+1];
        else if(input->mNumberBuffers>=2 && input->mBuffers[1].mData && input->mBuffers[1].mDataByteSize>=(i+1)*4)
            r=((float *)input->mBuffers[1].mData)[i];
        s->_ring.samples[(w+i)&MASK][0]=l;s->_ring.samples[(w+i)&MASK][1]=r;
        nonzero |= fabsf(l)>0.00001f || fabsf(r)>0.00001f;
    }
    atomic_store_explicit(&s->_ring.written,w+n,memory_order_release);
    atomic_fetch_add(&s->_ring.callbacks,1);
    if(nonzero) atomic_fetch_add(&s->_ring.nonzero,n);
    return noErr;
}
static void playback(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {
    SharpAudio *s=(__bridge SharpAudio *)context;
    if(atomic_load(&s->_stopped)) return;
    renderFrames(&s->_ring,buffer->mAudioData,BLOCK);
    buffer->mAudioDataByteSize=BLOCK*8;
    AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
}

@implementation SharpAudio
- (instancetype)initWithStatus:(void (^)(NSString *))status {
    if((self=[super init])) {
        _status=[status copy]; _socket=-1; _listener=-1; _socketLock=[NSLock new];
        static dispatch_queue_t routingQueue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ routingQueue=dispatch_queue_create("sh.sharp.audio",DISPATCH_QUEUE_SERIAL); });
        _worker=routingQueue;
    }
    return self;
}
- (void)report:(NSString *)state {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_status(state); });
}
- (void)stop {
    atomic_store(&_stopped,true);
    [_socketLock lock];
    if(_socket>=0) shutdown(_socket,SHUT_RDWR);
    if(_listener>=0) shutdown(_listener,SHUT_RDWR);
    [_socketLock unlock];
}
- (BOOL)installSocket:(int)fd listener:(BOOL)listener {
    [_socketLock lock];
    BOOL ok=!atomic_load(&_stopped);
    if(ok) { if(listener) _listener=fd; else _socket=fd; }
    else close(fd);
    [_socketLock unlock];
    return ok;
}
- (void)cleanup {
    if(_aggregate && _io) { AudioDeviceStop(_aggregate,_io); AudioDeviceDestroyIOProcID(_aggregate,_io); _io=NULL; }
    if(_aggregate) { AudioHardwareDestroyAggregateDevice(_aggregate); _aggregate=0; }
    if(@available(macOS 14.2,*)) { if(_tap) { AudioHardwareDestroyProcessTap(_tap); _tap=0; } }
    if(_playback) { AudioQueueStop(_playback,true); AudioQueueDispose(_playback,true); _playback=NULL; }
    [_socketLock lock];
    if(_socket>=0) { close(_socket); _socket=-1; }
    if(_listener>=0) { close(_listener); _listener=-1; }
    [_socketLock unlock];
    NSLog(@"Sharp audio stopped callbacks=%llu nonzero_frames=%llu played_buffers=%llu underruns=%llu",atomic_load(&_ring.callbacks),atomic_load(&_ring.nonzero),atomic_load(&_ring.played),atomic_load(&_ring.underruns));
}
static void configureSocket(int fd) {
    int one=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    struct timeval timeout={.tv_sec=1};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    timeout.tv_sec=0; timeout.tv_usec=100000;
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
}
static BOOL transfer(int fd,void *bytes,size_t count,BOOL sending) {
    uint8_t *p=bytes;
    while(count) {
        ssize_t n=sending?send(fd,p,count,0):recv(fd,p,count,0);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) return NO;
        p+=n;count-=n;
    }
    return YES;
}
static struct sockaddr_in addressFor(NSString *ip) {
    struct sockaddr_in addr={.sin_len=sizeof(addr),.sin_family=AF_INET,.sin_port=htons(AUDIO_PORT)};
    inet_pton(AF_INET,ip.UTF8String,&addr.sin_addr);return addr;
}
- (BOOL)createTapMuted:(BOOL)muted API_AVAILABLE(macos(14.2)) {
    CATapDescription *desc=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    desc.name=@"Sharp audio";desc.privateTap=YES;desc.muteBehavior=muted ? CATapMutedWhenTapped : CATapUnmuted;
    OSStatus err=AudioHardwareCreateProcessTap(desc,&_tap);
    if(err) { NSLog(@"Sharp create tap error=%d",(int)err); return NO; }
    AudioObjectPropertyAddress property={kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(_format);
    err=AudioObjectGetPropertyData(_tap,&property,0,NULL,&size,&_format);
    if(err || _format.mFormatID!=kAudioFormatLinearPCM || !(_format.mFormatFlags&kAudioFormatFlagIsFloat) || _format.mBitsPerChannel!=32 || _format.mChannelsPerFrame!=2 || _format.mSampleRate<8000 || _format.mSampleRate>192000) return NO;
    NSDictionary *description=@{@kAudioAggregateDeviceNameKey:@"Sharp private audio",
        @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey:@YES,
        @kAudioAggregateDeviceTapAutoStartKey:@NO,
        @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}]};
    err=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&_aggregate);
    if(err) { NSLog(@"Sharp aggregate error=%d",(int)err);return NO; }
    err=AudioDeviceCreateIOProcID(_aggregate,capture,(__bridge void *)self,&_io);
    return err==noErr;
}
// Starting the tap asks macOS for system-audio access. Silence is a valid
// recording, so sample amplitude cannot be used as a permission signal.
- (void)requestPermission {
    dispatch_async(_worker, ^{
        BOOL started=NO;
        if (@available(macOS 14.2, *)) {
            if ([self createTapMuted:NO]) {
                started=AudioDeviceStart(self->_aggregate, self->_io)==noErr;
                usleep(500000);
            }
        }
        [self cleanup];
        [self report:started ? @"permission-confirmed" : @"permission-unavailable"];
    });
}
- (void)sendFrom:(NSString *)source to:(NSString *)destination token:(NSString *)token {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            NSString *error=@"Audio connection failed. Sound stays on this Mac.";
            do {
                if(atomic_load(&self->_stopped)) break;
                if(@available(macOS 14.2,*)) {
                    [self report:@"preparing"];
                    if(![self createTapMuted:YES]) { error=@"Allow Sharp to capture system audio in Privacy & Security, then try again.";break; }
                } else { error=@"Sending audio needs macOS 14.2 or later."; break; }
                int fd=socket(AF_INET,SOCK_STREAM,0);
                if(fd<0 || ![self installSocket:fd listener:NO]) break;
                configureSocket(fd);
                struct sockaddr_in local=addressFor(source);local.sin_port=0;
                struct sockaddr_in remote=addressFor(destination);
                if(bind(fd,(struct sockaddr *)&local,sizeof(local)) || connect(fd,(struct sockaddr *)&remote,sizeof(remote))) break;
                uint8_t header[48]={0};memcpy(header,"SAA1",4);
                uint32_t rate=htonl((uint32_t)self->_format.mSampleRate);memcpy(header+4,&rate,4);
                NSData *key=[token dataUsingEncoding:NSUTF8StringEncoding];if(key.length!=36) break;
                memcpy(header+8,key.bytes,36);
                if(!transfer(fd,header,sizeof(header),YES)) break;
                char ready=0;if(!transfer(fd,&ready,1,NO)||ready!='R') break;
                if(atomic_load(&self->_stopped)) break;
                if(AudioDeviceStart(self->_aggregate,self->_io)!=noErr) {error=@"Could not start audio capture. Sound stays on this Mac.";break;}
                [self report:@"active"];
                uint64_t lastAck=nowNS();float packet[512*2]; BOOL permissionReported=NO;
                while(!atomic_load(&self->_stopped)) {
                    if (!permissionReported && atomic_load(&self->_ring.nonzero)>0) {
                        permissionReported=YES; [self report:@"permission-confirmed"];
                    }
                    char ack[32];ssize_t got=recv(fd,ack,sizeof(ack),MSG_DONTWAIT);
                    if(got>0) lastAck=nowNS();
                    else if(got==0 || (got<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) break;
                    if(nowNS()-lastAck>1000000000ULL) break;
                    uint64_t rd=atomic_load_explicit(&self->_ring.read,memory_order_relaxed);
                    uint64_t w=atomic_load_explicit(&self->_ring.written,memory_order_acquire);
                    if(w-rd>self->_format.mSampleRate*0.08) rd=w-(uint64_t)(self->_format.mSampleRate*0.02);
                    uint32_t n=(uint32_t)MIN(w-rd,512u);
                    if(!n) { usleep(2000); continue; }
                    for(uint32_t i=0;i<n;i++) memcpy(packet+i*2,self->_ring.samples[(rd+i)&MASK],8);
                    atomic_store_explicit(&self->_ring.read,rd+n,memory_order_release);
                    uint32_t length=htonl(n);
                    if(!transfer(fd,&length,4,YES)||!transfer(fd,packet,n*8,YES)) break;
                }
            } while(0);
            [self cleanup];
            if(!atomic_load(&self->_stopped)) [self report:error];
        }
    });
}
- (void)receiveOn:(NSString *)address token:(NSString *)token {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            do {
                int listener=socket(AF_INET,SOCK_STREAM,0);
                if(listener<0 || ![self installSocket:listener listener:YES]) break;
                int one=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
                struct sockaddr_in local=addressFor(address);
                if(bind(listener,(struct sockaddr *)&local,sizeof(local)) || listen(listener,1)) break;
                [self report:@"ready"];
                int fd=-1;
                // Bounded wait also makes cancelling an unused listener immediate.
                while(!atomic_load(&self->_stopped)) {
                    struct pollfd p={.fd=listener,.events=POLLIN};
                    if(poll(&p,1,100)>0) { fd=accept(listener,NULL,NULL);break; }
                }
                if(fd<0 || ![self installSocket:fd listener:NO]) break;
                configureSocket(fd);
                uint8_t header[48];if(!transfer(fd,header,sizeof(header),NO)) break;
                NSData *key=[token dataUsingEncoding:NSUTF8StringEncoding];
                if(key.length!=36 || memcmp(header,"SAA1",4) || memcmp(header+8,key.bytes,36)) break;
                uint32_t rate;memcpy(&rate,header+4,4);rate=ntohl(rate);
                if(rate<8000 || rate>192000) break;
                self->_ring.target=MAX(BLOCK*3,rate*30/1000);
                self->_format=(AudioStreamBasicDescription){.mSampleRate=rate,.mFormatID=kAudioFormatLinearPCM,
                    .mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,
                    .mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
                if(AudioQueueNewOutput(&self->_format,playback,(__bridge void *)self,NULL,NULL,0,&self->_playback)) break;
                BOOL ok=YES;
                for(int i=0;i<3;i++) {
                    AudioQueueBufferRef buffer=NULL;
                    if(AudioQueueAllocateBuffer(self->_playback,BLOCK*8,&buffer)) {ok=NO;break;}
                    memset(buffer->mAudioData,0,BLOCK*8);buffer->mAudioDataByteSize=BLOCK*8;
                    if(AudioQueueEnqueueBuffer(self->_playback,buffer,0,NULL)) {ok=NO;break;}
                }
                if(!ok || AudioQueueStart(self->_playback,NULL)) break;
                char ready='R';if(!transfer(fd,&ready,1,YES)) break;
                [self report:@"active"];
                uint64_t lastAck=nowNS(),previousCallbacks=0;
                float packet[512*2];
                while(!atomic_load(&self->_stopped)) {
                    struct pollfd incoming={.fd=fd,.events=POLLIN};
                    int available=poll(&incoming,1,50);
                    if(available<0 && errno!=EINTR) break;
                    if(available>0) {
                        uint32_t n;if(!transfer(fd,&n,4,NO)) break;n=ntohl(n);
                        if(!n || n>512 || !transfer(fd,packet,n*8,NO)) break;
                        BOOL valid=YES;BOOL nonzero=NO;
                        for(uint32_t i=0;i<n*2;i++) {if(!isfinite(packet[i])) {valid=NO;break;} nonzero|=fabsf(packet[i])>0.00001f;}
                        if(!valid) break;
                        putFrames(&self->_ring,packet,n);
                        if(nonzero) atomic_fetch_add(&self->_ring.nonzero,n);
                    }
                    if(nowNS()-lastAck>200000000ULL) {
                        uint64_t callbacks=atomic_load(&self->_ring.callbacks);
                        if(callbacks==previousCallbacks) break;
                        previousCallbacks=callbacks;
                        char ack='A';if(!transfer(fd,&ack,1,YES)) break;lastAck=nowNS();
                    }
                }
            } while(0);
            [self cleanup];
            if(!atomic_load(&self->_stopped)) [self report:@"Audio disconnected. Sound returns to the sender."];
        }
    });
}
@end
