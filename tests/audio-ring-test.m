// The actual realtime implementation is included to exercise queue ownership,
// underrun recovery and clock drift without needing an audio device.
#import "../app/SharpAudio.m"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        AudioRing *r=calloc(1,sizeof(*r));r->target=1440;
        float samples[CAPACITY*2],out[BLOCK*2];
        for(unsigned i=0;i<CAPACITY;i++) {samples[i*2]=0.25f;samples[i*2+1]=-0.5f;}
        renderFrames(r,out,BLOCK);
        for(unsigned i=0;i<BLOCK*2;i++) assert(out[i]==0);
        assert(putFrames(r,samples,1440)==1440);
        renderFrames(r,out,BLOCK);
        for(unsigned i=0;i<BLOCK;i++) { assert(out[2*i]==0.25f);assert(out[2*i+1]==-0.5f); }
        // A sender clock that runs 0.1% faster stays bounded over 100 seconds.
        double fractional=0;
        for(unsigned i=0;i<18750;i++) {
            fractional+=BLOCK*0.001;
            unsigned extra=(unsigned)fractional;fractional-=extra;
            assert(putFrames(r,samples,BLOCK+extra)==BLOCK+extra);
            renderFrames(r,out,BLOCK);
            assert(atomic_load(&r->written)-atomic_load(&r->read)<4000);
        }
        assert(atomic_load(&r->underruns)==0);
        for(unsigned i=0;i<32;i++) renderFrames(r,out,BLOCK);
        assert(!r->primed);for(unsigned i=0;i<BLOCK*2;i++) assert(out[i]==0);
        // Overflow never overwrites unread memory; resume discards stale backlog.
        unsigned n=putFrames(r,samples,CAPACITY);assert(n<=CAPACITY);
        assert(putFrames(r,samples,256)==0);
        renderFrames(r,out,BLOCK);
        assert(atomic_load(&r->written)-atomic_load(&r->read)<=1440);
        assert(r->primed);
        free(r);
        puts("audio-ring-test PASS: channel integrity, drift, underrun, overflow and bounded resume");
    }
    return 0;
}
