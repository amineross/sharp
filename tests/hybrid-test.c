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
static void test_scene_change(void) {
    /* Caret on a 3200x1800 grid: 1450 tiles, threshold 181. */
    assert(sharp_hybrid_scene_change(2,1450)==0);
    assert(sharp_hybrid_scene_change(181,1450)==1);
    assert(sharp_hybrid_scene_change(180,1450)==0);
    assert(sharp_hybrid_scene_change(8,16)==1);
    assert(sharp_hybrid_scene_change(7,16)==0);
    assert(sharp_hybrid_scene_change(0,0)==0);
    /* Repeated-change trigger: a caret (1-2 tiles) stays on tiles, a
     * 480x270 windowed video (~40 tiles) enters video. */
    assert(sharp_hybrid_repeated_motion(1,0)==0);
    assert(sharp_hybrid_repeated_motion(2,0)==0);
    assert(sharp_hybrid_repeated_motion(7,0)==0);
    assert(sharp_hybrid_repeated_motion(8,0)==1);
    assert(sharp_hybrid_repeated_motion(40,0)==1);
    assert(sharp_hybrid_repeated_motion(3,4)==0);
    assert(sharp_hybrid_repeated_motion(4,4)==1);
}
static sharp_hybrid_dirty_t dirty;
static void test_repair_order(void) {
    /* 640x384: 10x6 tiles, 5x3 groups of 2x2. */
    uint16_t order[SHARP_HYBRID_MAX_TILES];
    sharp_hybrid_dirty_reset(&dirty);
    assert(sharp_hybrid_repair_order(&dirty,640,384,order)==0);
    /* Motion in the lower-right group (tiles 48,49,58,59) plus one far tile. */
    assert(sharp_hybrid_dirty_mark(&dirty,48,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,48,10)==0);
    assert(sharp_hybrid_dirty_mark(&dirty,49,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,58,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,59,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,0,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,SHARP_HYBRID_MAX_TILES,10)==0);
    assert(dirty.count==5 && sharp_hybrid_dirty_test(&dirty,59) && !sharp_hybrid_dirty_test(&dirty,1));
    uint32_t n=sharp_hybrid_repair_order(&dirty,640,384,order);
    assert(n==5);
    /* The whole nearest group comes first, in tile order, then the outlier. */
    assert(order[0]==48&&order[1]==49&&order[2]==58&&order[3]==59&&order[4]==0);
    /* Centered motion orders strictly by distance and visits every tile once. */
    sharp_hybrid_dirty_reset(&dirty);
    for (uint32_t t=0;t<60;t++) assert(sharp_hybrid_dirty_mark(&dirty,t,10)==1);
    n=sharp_hybrid_repair_order(&dirty,640,384,order);
    assert(n==60);
    uint8_t seen[60]={0};
    uint64_t last=0;
    for (uint32_t i=0;i<n;i++) {
        assert(order[i]<60 && !seen[order[i]]); seen[order[i]]=1;
        int64_t gx=(order[i]%10)/2,gy=(order[i]/10)/2;
        int64_t dx=4*gx+2-10,dy=4*gy+2-6; /* centroid = (5,3) tiles */
        uint64_t d2=(uint64_t)(dx*dx+dy*dy);
        assert(d2>=last); last=d2;
    }
    assert(order[0]==24); /* group (2,1): tiles 24,25,34,35 */
    assert(order[1]==25&&order[2]==34&&order[3]==35);
    /* Marking from a source frame picks exactly the tiles that frame changed. */
    sharp_hybrid_source_t *src=calloc(1,sizeof(*src));
    assert(src && sharp_hybrid_source_init(src,640,384)==0);
    src->versions[7]=9; src->versions[8]=10; src->versions[17]=10;
    sharp_hybrid_dirty_reset(&dirty);
    assert(sharp_hybrid_dirty_mark_frame(&dirty,src,10)==2);
    assert(sharp_hybrid_dirty_mark_frame(&dirty,src,10)==0);
    assert(sharp_hybrid_dirty_mark_frame(&dirty,src,0)==0);
    assert(sharp_hybrid_dirty_test(&dirty,8)&&sharp_hybrid_dirty_test(&dirty,17)&&!sharp_hybrid_dirty_test(&dirty,7));
    /* Tiles acknowledged at (or past) their current version are dropped;
     * stale or missing acks keep the tile dirty, and the centroid follows. */
    static uint32_t acked[SHARP_HYBRID_MAX_TILES];
    sharp_hybrid_dirty_reset(&dirty);
    src->versions[0]=5; src->versions[59]=12;
    assert(sharp_hybrid_dirty_mark(&dirty,0,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,8,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,17,10)==1);
    assert(sharp_hybrid_dirty_mark(&dirty,59,10)==1);
    acked[0]=5; acked[8]=9; acked[17]=0; acked[59]=13;
    assert(sharp_hybrid_dirty_prune_acked(&dirty,src,acked)==2);
    assert(dirty.count==2 && !sharp_hybrid_dirty_test(&dirty,0) &&
           sharp_hybrid_dirty_test(&dirty,8) && sharp_hybrid_dirty_test(&dirty,17) &&
           !sharp_hybrid_dirty_test(&dirty,59));
    assert(dirty.sum_x==8+7 && dirty.sum_y==0+1);
    assert(sharp_hybrid_dirty_prune_acked(&dirty,src,acked)==0);
    assert(sharp_hybrid_dirty_prune_acked(&dirty,src,NULL)==0);
    sharp_hybrid_source_destroy(src); free(src);
}
static void test_repair_generation(void) {
    /* A repair tile labelled with its source version is accepted by both the
     * last VIDEO manifest and the later STATIC one, so the receiver can
     * publish it over the video before the whole exit repair completes.
     * Labelling it with the exit frame would only satisfy the STATIC map. */
    static sharp_hybrid_receiver_t r;
    assert(sharp_hybrid_receiver_init(&r,7,640,384)==0);
    sharp_hybrid_message_t m={.session=7,.kind=SHARP_HYBRID_MAP,.width=640,.height=384,
                              .total=60,.frame=200,.first=0,.count=60};
    for (unsigned i=0;i<60;i++) m.versions[i]=150;
    m.versions[3]=198;
    assert(sharp_hybrid_accept_map(&r,&m)==1);
    m.frame=205; m.flags=SHARP_HYBRID_STATIC;
    assert(sharp_hybrid_accept_map(&r,&m)==1);
    const sharp_hybrid_map_t *video=sharp_hybrid_find_map(&r,200),*stat=sharp_hybrid_find_map(&r,205);
    assert(video && stat);
    assert(sharp_hybrid_tile_matches(video,3,198) && sharp_hybrid_tile_matches(stat,3,198));
    assert(!sharp_hybrid_tile_matches(video,3,205) && sharp_hybrid_tile_matches(stat,3,205));
}
int main(void) {test_maps();test_content_proof();test_tile_capture_label();test_encode_once_batch_fallback();test_scene_change();test_repair_order();test_repair_generation();puts("hybrid-test PASS");return 0;}
