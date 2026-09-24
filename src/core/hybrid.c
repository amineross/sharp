#include "sharp/hybrid.h"
#include "sharp/shtp_protocol.h"
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

#define WIRE_BYTES 44u
static void put16(uint8_t *p, uint16_t v) { v=htons(v); memcpy(p,&v,2); }
static void put32(uint8_t *p, uint32_t v) { v=htonl(v); memcpy(p,&v,4); }
static void put64(uint8_t *p, uint64_t v) { v=shtp_htonll(v); memcpy(p,&v,8); }
static uint16_t get16(const uint8_t *p) { uint16_t v; memcpy(&v,p,2); return ntohs(v); }
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return ntohl(v); }
static uint64_t get64(const uint8_t *p) { uint64_t v; memcpy(&v,p,8); return shtp_ntohll(v); }
static int newer(uint32_t a, uint32_t b) { return (int32_t)(a-b)>0; }
static int valid(const sharp_hybrid_message_t *m) {
    if (!m->session || m->kind<SHARP_HYBRID_HELLO || m->kind>SHARP_HYBRID_ACK ||
        !m->width || !m->height || !m->total || m->total>SHARP_HYBRID_MAX_TILES ||
        m->total!=sharp_tile_count(m->width,m->height) ||
        (m->flags & ~(SHARP_HYBRID_STATIC|SHARP_HYBRID_COMMITTED))) return 0;
    if (m->kind!=SHARP_HYBRID_MAP && m->kind!=SHARP_HYBRID_ACK)
        return m->count==0 && m->first==0 && m->flags==0;
    if ((m->kind==SHARP_HYBRID_MAP && (m->flags & ~SHARP_HYBRID_STATIC)) ||
        (m->kind==SHARP_HYBRID_ACK && (m->flags & ~SHARP_HYBRID_COMMITTED))) return 0;
    uint32_t count=m->total-m->first;
    if (count>SHARP_HYBRID_CHUNK_TILES) count=SHARP_HYBRID_CHUNK_TILES;
    return m->first<m->total && m->first%SHARP_HYBRID_CHUNK_TILES==0 &&
        m->count==count && (m->kind!=SHARP_HYBRID_MAP || m->frame!=0);
}
size_t sharp_hybrid_encode(uint8_t *p, size_t cap, const sharp_hybrid_message_t *m) {
    size_t len=WIRE_BYTES+4u*m->count;
    if (!valid(m) || cap<len) return 0;
    memset(p,0,WIRE_BYTES);
    put32(p,SHARP_HYBRID_MAGIC); put16(p+4,1); put16(p+6,m->kind);
    put64(p+8,m->session); put64(p+16,m->nonce); put32(p+24,m->frame);
    put16(p+28,m->width); put16(p+30,m->height); put16(p+32,m->total);
    put16(p+34,m->first); put16(p+36,m->count); put16(p+38,m->flags);
    for (uint16_t i=0;i<m->count;i++) put32(p+WIRE_BYTES+4u*i,m->versions[i]);
    put32(p+40,sharp_tile_checksum(p,len));
    return len;
}
int sharp_hybrid_decode(sharp_hybrid_message_t *m,const uint8_t *p,size_t len) {
    if (len<WIRE_BYTES || len>WIRE_BYTES+4*SHARP_HYBRID_CHUNK_TILES ||
        get32(p)!=SHARP_HYBRID_MAGIC || get16(p+4)!=1) return -1;
    uint8_t copy[WIRE_BYTES+4*SHARP_HYBRID_CHUNK_TILES];
    memcpy(copy,p,len); memset(copy+40,0,4);
    if (sharp_tile_checksum(copy,len)!=get32(p+40)) return -1;
    memset(m,0,sizeof(*m));
    m->kind=get16(p+6); m->session=get64(p+8); m->nonce=get64(p+16); m->frame=get32(p+24);
    m->width=get16(p+28); m->height=get16(p+30); m->total=get16(p+32);
    m->first=get16(p+34); m->count=get16(p+36); m->flags=get16(p+38);
    if (!valid(m) || len!=WIRE_BYTES+4u*m->count) return -1;
    for (uint16_t i=0;i<m->count;i++) m->versions[i]=get32(p+WIRE_BYTES+4u*i);
    return 0;
}
int sharp_hybrid_receiver_init(sharp_hybrid_receiver_t *r,uint64_t session,uint16_t w,uint16_t h) {
    uint32_t total=sharp_tile_count(w,h);
    if (!session || !w || !h || total>SHARP_HYBRID_MAX_TILES) return -1;
    memset(r,0,sizeof(*r)); r->session=session;r->width=w;r->height=h;r->total=(uint16_t)total;
    return 0;
}
int sharp_hybrid_accept_map(sharp_hybrid_receiver_t *r,const sharp_hybrid_message_t *m) {
    if (!valid(m) || m->kind!=SHARP_HYBRID_MAP || m->session!=r->session ||
        m->width!=r->width || m->height!=r->height) return -1;
    if (r->latest_frame && (int32_t)(r->latest_frame-m->frame)>=(int32_t)SHARP_HYBRID_MAP_SLOTS) return -1;
    sharp_hybrid_map_t *map=&r->maps[m->frame%SHARP_HYBRID_MAP_SLOTS];
    if (map->valid && map->frame!=m->frame && !newer(m->frame,map->frame)) return -1;
    if (!map->valid || map->frame!=m->frame) {
        memset(map,0,sizeof(*map));map->valid=1;map->frame=m->frame;map->flags=m->flags;
    }
    if (map->flags!=m->flags) return -1;
    uint16_t bit=(uint16_t)(1u<<(m->first/SHARP_HYBRID_CHUNK_TILES));
    for (uint16_t i=0;i<m->count;i++) {
        if (!m->versions[i] || newer(m->versions[i],m->frame)) return -1;
        if ((map->received&bit) && map->versions[m->first+i]!=m->versions[i]) return -1;
    }
    memcpy(map->versions+m->first,m->versions,4u*m->count);map->received|=bit;
    uint32_t chunks=(r->total+SHARP_HYBRID_CHUNK_TILES-1)/SHARP_HYBRID_CHUNK_TILES;
    map->complete=map->received==((1u<<chunks)-1u);
    if (!r->latest_frame || newer(m->frame,r->latest_frame)) r->latest_frame=m->frame;
    if (!(m->flags&SHARP_HYBRID_STATIC) &&
        (!r->latest_video_frame || newer(m->frame,r->latest_video_frame))) r->latest_video_frame=m->frame;
    return map->complete ? 1 : 0;
}
const sharp_hybrid_map_t *sharp_hybrid_find_map(const sharp_hybrid_receiver_t *r,uint32_t frame) {
    const sharp_hybrid_map_t *m=&r->maps[frame%SHARP_HYBRID_MAP_SLOTS];
    return m->valid && m->complete && m->frame==frame ? m : NULL;
}
int sharp_hybrid_tile_matches(const sharp_hybrid_map_t *m,uint32_t tile,uint32_t captured) {
    return m && m->complete && captured && tile<SHARP_HYBRID_MAX_TILES &&
        (int32_t)(captured-m->versions[tile])>=0 && (int32_t)(m->frame-captured)>=0;
}
uint32_t sharp_hybrid_video_mask(const sharp_hybrid_receiver_t *r,const sharp_hybrid_map_t *m,
                                const uint32_t *cached,uint8_t *mask) {
    memset(mask,0xff,(r->total+7u)/8u);
    uint32_t sharp=0,cols=sharp_tile_cols(r->width),rows=sharp_tile_rows(r->height);
    /* Publish a 128x128 neighborhood together, never a partially ready group. */
    for (uint32_t y=0;y<rows;y+=2) for (uint32_t x=0;x<cols;x+=2) {
        int ready=1;
        for (uint32_t dy=0;dy<2 && y+dy<rows;dy++) for(uint32_t dx=0;dx<2 && x+dx<cols;dx++) {
            uint32_t t=(y+dy)*cols+x+dx;
            if (!sharp_hybrid_tile_matches(m,t,cached[t])) ready=0;
        }
        if (ready) for (uint32_t dy=0;dy<2 && y+dy<rows;dy++) for(uint32_t dx=0;dx<2 && x+dx<cols;dx++) {
            uint32_t t=(y+dy)*cols+x+dx; mask[t>>3]&=(uint8_t)~(1u<<(t&7)); sharp++;
        }
    }
    return sharp;
}
int sharp_hybrid_static_ready(const sharp_hybrid_receiver_t *r,const sharp_hybrid_map_t *m,
                             const uint32_t *cached) {
    if (!m || !(m->flags&SHARP_HYBRID_STATIC) || m->frame!=r->latest_frame ||
        (r->latest_video_frame && newer(r->latest_video_frame,m->frame))) return 0;
    for (uint32_t t=0;t<r->total;t++) if (!sharp_hybrid_tile_matches(m,t,cached[t])) return 0;
    return 1;
}
int sharp_hybrid_source_init(sharp_hybrid_source_t *s,uint16_t w,uint16_t h) {
    uint32_t total=sharp_tile_count(w,h);
    if (!w || !h || total>SHARP_HYBRID_MAX_TILES) return -1;
    memset(s,0,sizeof(*s));s->width=w;s->height=h;s->total=(uint16_t)total;
    s->pixels=malloc((size_t)w*h*4u);return s->pixels?0:-1;
}
void sharp_hybrid_source_destroy(sharp_hybrid_source_t *s) { free(s->pixels);s->pixels=NULL; }
uint32_t sharp_hybrid_source_update(sharp_hybrid_source_t *s,const uint8_t *pixels,
                                  uint32_t stride,uint32_t frame,uint64_t now,uint32_t *repeated) {
    uint32_t changed=0;*repeated=0;
    for (uint32_t t=0;t<s->total;t++) {
        sharp_tile_rect_t rect;sharp_tile_rect_for_id(s->width,s->height,(uint16_t)t,&rect);
        int same=s->frame!=0;
        for(uint32_t y=0;same && y<rect.h;y++)
            same=memcmp(pixels+(size_t)(rect.y+y)*stride+rect.x*4u,
                        s->pixels+((size_t)(rect.y+y)*s->width+rect.x)*4u,rect.w*4u)==0;
        if (same) continue;
        s->streak[t]=(s->versions[t] && now-s->changed_ns[t]<100000000ULL)
            ? (uint8_t)(s->streak[t]<255?s->streak[t]+1:255) : 1;
        if(s->streak[t]>=3) (*repeated)++;
        s->versions[t]=frame;s->changed_ns[t]=now;changed++;
        for(uint32_t y=0;y<rect.h;y++)
            memcpy(s->pixels+((size_t)(rect.y+y)*s->width+rect.x)*4u,
                   pixels+(size_t)(rect.y+y)*stride+rect.x*4u,rect.w*4u);
    }
    s->frame=frame;return changed;
}
