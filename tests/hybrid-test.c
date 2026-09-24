#include "sharp/hybrid.h"
#include "sharp/tile_sender.h"
#include "sharp/tile_receiver.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static sharp_hybrid_receiver_t receiver;
static void test_maps(void) {
    assert(sharp_hybrid_receiver_init(&receiver,42,2560,1440)==0);
    sharp_hybrid_message_t m={.session=42,.kind=SHARP_HYBRID_MAP,.width=2560,.height=1440,
                              .total=920,.frame=100,.flags=SHARP_HYBRID_STATIC};
    uint32_t cached[SHARP_HYBRID_MAX_TILES];
    for(unsigned i=0;i<920;i++) cached[i]=100;
    unsigned order[]={768,256,0,512};
    for(unsigned i=0;i<4;i++) {
        m.first=order[i];m.count=(uint16_t)(920-m.first>256?256:920-m.first);
        for(unsigned j=0;j<m.count;j++) m.versions[j]=80;
        uint8_t packet[1200];size_t n=sharp_hybrid_encode(packet,sizeof(packet),&m);
        assert(n && n+48<=1472);
        sharp_hybrid_message_t parsed;
        assert(sharp_hybrid_decode(&parsed,packet,n)==0);
        packet[n-1]^=1;assert(sharp_hybrid_decode(&parsed,packet,n)==-1);packet[n-1]^=1;
        assert(sharp_hybrid_decode(&parsed,packet,n)==0);
        assert(sharp_hybrid_accept_map(&receiver,&parsed)==(i==3));
        assert((sharp_hybrid_find_map(&receiver,100)!=NULL)==(i==3));
    }
    const sharp_hybrid_map_t *map=sharp_hybrid_find_map(&receiver,100);
    assert(sharp_hybrid_static_ready(&receiver,map,cached));
    cached[5]=79; assert(!sharp_hybrid_static_ready(&receiver,map,cached));
    cached[5]=101; assert(!sharp_hybrid_static_ready(&receiver,map,cached));
    cached[5]=0; assert(!sharp_hybrid_static_ready(&receiver,map,cached));
    cached[5]=80; assert(sharp_hybrid_static_ready(&receiver,map,cached));
    uint8_t mask[512];assert(sharp_hybrid_video_mask(&receiver,map,cached,mask)==920);
    cached[5]=101;assert(sharp_hybrid_video_mask(&receiver,map,cached,mask)==916);
    assert(sharp_hybrid_video_mask(&receiver,NULL,cached,mask)==0);
    m.session=41;assert(sharp_hybrid_accept_map(&receiver,&m)==-1);m.session=42;
    /* A newer partial VIDEO manifest cancels a pending old STATIC decision. */
    m.frame=101;m.flags=0;
    assert(sharp_hybrid_accept_map(&receiver,&m)==0);
    cached[5]=100;assert(!sharp_hybrid_static_ready(&receiver,map,cached));
    /* Contradictory duplicates cannot mutate an already accepted fragment. */
    m.versions[0]=81;assert(sharp_hybrid_accept_map(&receiver,&m)==-1);
    assert(!sharp_hybrid_find_map(&receiver,101));
    /* Session reset discards every old manifest. */
    assert(sharp_hybrid_receiver_init(&receiver,99,2560,1440)==0);
    assert(sharp_hybrid_accept_map(&receiver,&m)==-1);
    assert(!sharp_hybrid_find_map(&receiver,100));
}

static void test_content_proof(void) {
    sharp_hybrid_source_t *s=calloc(1,sizeof(*s));assert(s);
    assert(sharp_hybrid_source_init(s,128,64)==0);
    uint8_t *pixels=calloc(128*64,4);assert(pixels);
    uint8_t history[32][2];uint32_t versions[32][2];
    for(uint32_t f=1;f<32;f++) {
        if(f%3==0) pixels[0]++;
        if(f%7==0) pixels[64*4]++;
        uint32_t repeated=0;
        sharp_hybrid_source_update(s,pixels,512,f,10000000ULL*f,&repeated);
        history[f][0]=pixels[0];history[f][1]=pixels[64*4];
        memcpy(versions[f],s->versions,sizeof(versions[f]));
    }
    /* Exhaust every displayed/cached capture pair, including future patches. */
    for(uint32_t f=1;f<32;f++) for(uint32_t c=1;c<32;c++) for(unsigned t=0;t<2;t++) {
        sharp_hybrid_map_t m={.complete=1,.frame=f};m.versions[t]=versions[f][t];
        if(sharp_hybrid_tile_matches(&m,t,c)) assert(history[f][t]==history[c][t]);
        if(c>f) assert(!sharp_hybrid_tile_matches(&m,t,c));
    }
    sharp_hybrid_source_destroy(s);free(s);free(pixels);
}
static void test_tile_capture_label(void) {
    int listener=socket(AF_INET,SOCK_DGRAM,0), sender=socket(AF_INET,SOCK_DGRAM,0);
    assert(listener>=0 && sender>=0);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(bind(listener,(struct sockaddr *)&addr,sizeof(addr))==0);
    socklen_t len=sizeof(addr);assert(getsockname(listener,(struct sockaddr *)&addr,&len)==0);
    assert(connect(sender,(struct sockaddr *)&addr,len)==0);
    struct timeval timeout={.tv_sec=2};setsockopt(listener,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    uint8_t pixels[SHARP_TILE_BYTES];for(unsigned i=0;i<sizeof(pixels);i++) pixels[i]=(uint8_t)(i*31u+i/17u);
    sharp_tile_rect_t rect;assert(sharp_tile_rect_for_id(64,64,0,&rect)==0);
    sharp_tile_sender_codec_t codec={.session=1234};uint32_t sequence=0;
    sharp_tile_sender_stats_t stats={0};
    assert(sharp_tile_sender_send_bgra_tile_pixels_generation(sender,20,10,&rect,pixels,256,
                                                            &sequence,1200,&stats,&codec)==0);
    sharp_tile_receiver_t tiles;assert(sharp_tile_receiver_init(&tiles,64,64)==0);
    for(uint64_t i=0;i<stats.packets;i++) {
        uint8_t packet[2048];ssize_t n=recv(listener,packet,sizeof(packet),0);assert(n>0);
        shtp_header_t sh;memcpy(&sh,packet,sizeof(sh));shtp_header_wire_to_host(&sh);
        assert(sh.frame_id==20 && sh.aux_time_ns==1234 && (sh.flags&SHTP_FLAG_VERIFIED_HYBRID));
        int patched=0;assert(sharp_tile_receiver_handle_datagram(&tiles,packet,(size_t)n,&patched,NULL)==0);
    }
    assert(tiles.tile_generations[0]==10);assert(memcmp(tiles.fb.pixels,pixels,sizeof(pixels))==0);
    sharp_tile_receiver_destroy(&tiles);close(listener);close(sender);
}
static void test_encode_once_batch_fallback(void) {
    int listener=socket(AF_INET,SOCK_DGRAM,0),sender=socket(AF_INET,SOCK_DGRAM,0);
    assert(listener>=0 && sender>=0);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(bind(listener,(struct sockaddr *)&addr,sizeof(addr))==0);
    socklen_t len=sizeof(addr);assert(getsockname(listener,(struct sockaddr *)&addr,&len)==0);
    assert(connect(sender,(struct sockaddr *)&addr,len)==0);
    struct timeval timeout={.tv_sec=2};setsockopt(listener,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    uint8_t pixels[5][SHARP_TILE_BYTES],packet[2048];
    memset(pixels[0],17,SHARP_TILE_BYTES);
    for(unsigned t=1;t<4;t++) for(unsigned i=0;i<SHARP_TILE_BYTES;i++)
        pixels[t][i]=(uint8_t)(((i/4)&1)?t*19:t*37);
    uint32_t random=43;
    for(unsigned i=0;i<SHARP_TILE_BYTES;i++) {random=random*1664525u+1013904223u;pixels[4][i]=(uint8_t)(random>>24);}
    sharp_tile_sender_codec_t codec={.session=1234};
    sharp_tile_batch_writer_t writer;
    assert(sharp_tile_batch_writer_begin_with_codec(&writer,packet,1200,&codec)==0);
    sharp_tile_sender_stats_t stats={0};uint32_t sequence=0;
    for(unsigned t=0;t<5;t++) {
        sharp_tile_rect_t rect;assert(sharp_tile_rect_for_id(320,64,t,&rect)==0);
        assert(sharp_tile_batch_writer_send_pixels(sender,&writer,100,10+t,&rect,pixels[t],256,&sequence,&stats)==0);
    }
    assert(sharp_tile_batch_writer_flush(sender,&writer,100,&sequence,&stats)==0);
    assert(stats.tiles==5 && stats.solid_tiles==1 && stats.twocolor_tiles==3 && stats.raw_tiles==1);
    assert(stats.batch_packets>=2);
    sharp_tile_receiver_t tiles;assert(sharp_tile_receiver_init(&tiles,320,64)==0);
    for(uint64_t i=0;i<stats.packets;i++) {
        uint8_t wire[2048];ssize_t n=recv(listener,wire,sizeof(wire),0);assert(n>0 && n<=1200+SHTP_HEADER_BYTES);
        shtp_header_t sh;memcpy(&sh,wire,sizeof(sh));shtp_header_wire_to_host(&sh);
        assert(sh.frame_id==100 && sh.aux_time_ns==1234);
        int patched=0;assert(sharp_tile_receiver_handle_datagram(&tiles,wire,n,&patched,NULL)==0);
    }
    for(unsigned t=0;t<5;t++) {
        assert(tiles.tile_generations[t]==10+t);
        for(unsigned y=0;y<64;y++)
            assert(memcmp(tiles.fb.pixels+y*tiles.fb.stride+t*256,pixels[t]+y*256,256)==0);
    }
    sharp_tile_receiver_destroy(&tiles);close(listener);close(sender);
}
int main(void) {test_maps();test_content_proof();test_tile_capture_label();test_encode_once_batch_fallback();puts("hybrid-test PASS");return 0;}
