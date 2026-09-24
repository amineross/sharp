#ifndef SHARP_NET_RING_H
#define SHARP_NET_RING_H

#include <stdatomic.h>
#include <stdint.h>

#include "sharp/shtp_protocol.h"

#define SHARP_NET_SLOT_BYTES SHTP_MAX_DATAGRAM

typedef struct sharp_net_slot {
    uint16_t len;
    uint64_t arrival_seq;
    uint8_t data[SHARP_NET_SLOT_BYTES];
} sharp_net_slot_t;

typedef struct sharp_net_ring {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    uint32_t mask;
    sharp_net_slot_t *slots;
} sharp_net_ring_t;

int sharp_net_ring_init(sharp_net_ring_t *r, uint32_t capacity);
void sharp_net_ring_destroy(sharp_net_ring_t *r);
sharp_net_slot_t *sharp_net_ring_acquire(sharp_net_ring_t *r);
void sharp_net_ring_commit(sharp_net_ring_t *r);
sharp_net_slot_t *sharp_net_ring_peek(sharp_net_ring_t *r);
void sharp_net_ring_release(sharp_net_ring_t *r);

#endif
