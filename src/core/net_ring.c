#include "sharp/net_ring.h"

#include <stdlib.h>
#include <string.h>

static int is_power_of_two(uint32_t value) {
    return value != 0 && (value & (value - 1u)) == 0;
}

int sharp_net_ring_init(sharp_net_ring_t *r, uint32_t capacity) {
    if (r == NULL || !is_power_of_two(capacity) || capacity < 2u) {
        return -1;
    }
    memset(r, 0, sizeof(*r));
    r->slots = calloc(capacity, sizeof(r->slots[0]));
    if (r->slots == NULL) {
        return -1;
    }
    r->mask = capacity - 1u;
    atomic_init(&r->head, 0u);
    atomic_init(&r->tail, 0u);
    return 0;
}

void sharp_net_ring_destroy(sharp_net_ring_t *r) {
    if (r == NULL) {
        return;
    }
    free(r->slots);
    memset(r, 0, sizeof(*r));
}

sharp_net_slot_t *sharp_net_ring_acquire(sharp_net_ring_t *r) {
    if (r == NULL || r->slots == NULL) {
        return NULL;
    }
    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (head - tail > r->mask) {
        return NULL;
    }
    return &r->slots[head & r->mask];
}

void sharp_net_ring_commit(sharp_net_ring_t *r) {
    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    atomic_store_explicit(&r->head, head + 1u, memory_order_release);
}

sharp_net_slot_t *sharp_net_ring_peek(sharp_net_ring_t *r) {
    if (r == NULL || r->slots == NULL) {
        return NULL;
    }
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    if (tail == head) {
        return NULL;
    }
    return &r->slots[tail & r->mask];
}

void sharp_net_ring_release(sharp_net_ring_t *r) {
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    atomic_store_explicit(&r->tail, tail + 1u, memory_order_release);
}
