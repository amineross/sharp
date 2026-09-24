#include "sharp/video_region.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

#define SHARP_VIDEO_REASSEMBLER_SLOTS 64u

typedef struct sharp_video_region_slot {
    uint8_t *data;
    uint8_t *seen;
    uint8_t *nacked;
    uint8_t *parity_seen;
    uint8_t *parity_data;
    size_t data_cap;
    size_t parity_cap;
    uint32_t total_len;
    uint32_t checksum;
    uint16_t region_id;
    uint16_t chunk_count;
    uint16_t chunks_seen;
    uint16_t highest_chunk_seen;
    uint16_t parity_count;
    uint32_t parity_chunk_len;
    uint8_t fec_g;
    uint8_t complete;
    uint8_t delivered;
    uint8_t have_highest_chunk;
    uint8_t had_repair;
    sharp_video_region_chunk_header_t header;
} sharp_video_region_slot_t;

struct sharp_video_region_reassembler {
    uint32_t width;
    uint32_t height;
    uint64_t fec_recovered_chunks;
    uint64_t fec_unrecovered_generations;
    sharp_video_region_slot_t slots[SHARP_VIDEO_REASSEMBLER_SLOTS];
};

uint32_t sharp_video_region_checksum(const uint8_t *data, size_t len) {
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= 16777619u;
    }
    return hash;
}

static int sharp_video_region_checksum_enabled(void) {
    const char *value = getenv("SHARP_SKIP_H264_CHECKSUM");
    return value == NULL || value[0] == '\0' || strcmp(value, "0") == 0;
}

void sharp_video_region_chunk_header_host_to_wire(
    sharp_video_region_chunk_header_t *header) {
    header->region_id = htons(header->region_id);
    header->x = htons(header->x);
    header->y = htons(header->y);
    header->w = htons(header->w);
    header->h = htons(header->h);
    header->generation = htonl(header->generation);
    header->total_len = htonl(header->total_len);
    header->offset = htonl(header->offset);
    header->chunk_len = htonl(header->chunk_len);
    header->flags = htonl(header->flags);
    header->checksum = htonl(header->checksum);
}

void sharp_video_region_chunk_header_wire_to_host(
    sharp_video_region_chunk_header_t *header) {
    header->region_id = ntohs(header->region_id);
    header->x = ntohs(header->x);
    header->y = ntohs(header->y);
    header->w = ntohs(header->w);
    header->h = ntohs(header->h);
    header->generation = ntohl(header->generation);
    header->total_len = ntohl(header->total_len);
    header->offset = ntohl(header->offset);
    header->chunk_len = ntohl(header->chunk_len);
    header->flags = ntohl(header->flags);
    header->checksum = ntohl(header->checksum);
}

int sharp_video_region_chunk_header_is_valid(
    const sharp_video_region_chunk_header_t *header, uint32_t width,
    uint32_t height) {
    if (header == NULL || header->w == 0 || header->h == 0 ||
        header->total_len == 0 || header->chunk_len == 0 ||
        header->total_len > 16u * 1024u * 1024u ||
        header->chunk_len > header->total_len ||
        header->offset > header->total_len ||
        header->offset + header->chunk_len < header->offset ||
        header->offset + header->chunk_len > header->total_len) {
        return 0;
    }
    if (header->x >= width || header->y >= height ||
        (uint32_t)header->x + header->w > width ||
        (uint32_t)header->y + header->h > height) {
        return 0;
    }
    return 1;
}

sharp_video_region_reassembler_t *sharp_video_region_reassembler_create(
    uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) {
        return NULL;
    }
    sharp_video_region_reassembler_t *r = calloc(1, sizeof(*r));
    if (r != NULL) {
        r->width = width;
        r->height = height;
    }
    return r;
}

static void reset_slot(sharp_video_region_slot_t *slot,
                       const sharp_video_region_chunk_header_t *header,
                       uint16_t chunk_count) {
    if (slot->data_cap < header->total_len) {
        free(slot->data);
        slot->data = malloc(header->total_len);
        slot->data_cap = slot->data != NULL ? header->total_len : 0;
    }
    free(slot->seen);
    slot->seen = calloc(chunk_count, sizeof(slot->seen[0]));
    free(slot->nacked);
    slot->nacked = calloc(chunk_count, sizeof(slot->nacked[0]));
    free(slot->parity_seen);
    slot->parity_seen = NULL;
    free(slot->parity_data);
    slot->parity_data = NULL;
    slot->parity_cap = 0;
    slot->region_id = header->region_id;
    slot->total_len = header->total_len;
    slot->checksum = header->checksum;
    slot->chunk_count = chunk_count;
    slot->chunks_seen = 0;
    slot->highest_chunk_seen = 0;
    slot->parity_count = 0;
    slot->parity_chunk_len = 0;
    slot->fec_g = 0;
    slot->complete = 0;
    slot->delivered = 0;
    slot->have_highest_chunk = 0;
    slot->had_repair = 0;
    slot->header = *header;
}

void sharp_video_region_reassembler_destroy(
    sharp_video_region_reassembler_t *reassembler) {
    if (reassembler != NULL) {
        for (size_t i = 0; i < SHARP_VIDEO_REASSEMBLER_SLOTS; i++) {
            free(reassembler->slots[i].data);
            free(reassembler->slots[i].seen);
            free(reassembler->slots[i].nacked);
            free(reassembler->slots[i].parity_seen);
            free(reassembler->slots[i].parity_data);
        }
        free(reassembler);
    }
}

static void mark_seen(sharp_video_region_slot_t *slot, uint16_t chunk_id,
                      const uint8_t *chunk_data, size_t chunk_len,
                      uint32_t offset);

static uint32_t true_chunk_len(const sharp_video_region_slot_t *slot,
                               uint16_t chunk_id) {
    if (slot == NULL || slot->chunk_count == 0 ||
        chunk_id >= slot->chunk_count || slot->header.chunk_len == 0) {
        return 0;
    }
    uint64_t offset = (uint64_t)chunk_id * slot->header.chunk_len;
    if (offset >= slot->total_len) {
        return 0;
    }
    uint64_t remaining = slot->total_len - offset;
    return remaining < slot->header.chunk_len ? (uint32_t)remaining
                                              : slot->header.chunk_len;
}

static void fec_group_bounds(uint16_t chunk_count, uint8_t fec_g, uint8_t group,
                             uint16_t *start_out, uint16_t *end_out) {
    uint32_t start = ((uint32_t)chunk_count * group) / fec_g;
    uint32_t end = ((uint32_t)chunk_count * (uint32_t)(group + 1u)) / fec_g;
    if (start_out != NULL) {
        *start_out = (uint16_t)start;
    }
    if (end_out != NULL) {
        *end_out = (uint16_t)end;
    }
}

static int ensure_parity_storage(sharp_video_region_slot_t *slot, uint8_t fec_g,
                                 uint32_t parity_chunk_len) {
    if (slot == NULL || fec_g == 0 || parity_chunk_len == 0) {
        return -1;
    }
    size_t parity_cap = (size_t)fec_g * parity_chunk_len;
    if (slot->parity_seen != NULL && slot->parity_data != NULL &&
        slot->fec_g == fec_g && slot->parity_chunk_len == parity_chunk_len &&
        slot->parity_cap >= parity_cap) {
        return 0;
    }
    free(slot->parity_seen);
    slot->parity_seen = calloc(fec_g, sizeof(slot->parity_seen[0]));
    free(slot->parity_data);
    slot->parity_data = calloc(parity_cap, 1u);
    slot->parity_cap = slot->parity_data != NULL ? parity_cap : 0;
    slot->parity_count = 0;
    slot->fec_g = fec_g;
    slot->parity_chunk_len = parity_chunk_len;
    return slot->parity_seen != NULL && slot->parity_data != NULL ? 0 : -1;
}

static int slot_checksum_complete(sharp_video_region_slot_t *slot) {
    if (slot == NULL || slot->chunks_seen != slot->chunk_count) {
        return 0;
    }
    if (sharp_video_region_checksum_enabled() &&
        sharp_video_region_checksum(slot->data, slot->total_len) !=
            slot->checksum) {
        return -1;
    }
    slot->complete = 1u;
    return 1;
}

static int try_fec_repair(sharp_video_region_reassembler_t *reassembler,
                          sharp_video_region_slot_t *slot) {
    if (reassembler == NULL || slot == NULL || slot->complete ||
        slot->delivered ||
        slot->parity_seen == NULL || slot->parity_data == NULL ||
        slot->fec_g == 0 || slot->parity_chunk_len == 0 ||
        slot->header.chunk_len == 0 ||
        slot->parity_chunk_len < slot->header.chunk_len) {
        return 0;
    }
    int recovered = 0;
    for (uint8_t g = 0; g < slot->fec_g; g++) {
        if (!slot->parity_seen[g]) {
            continue;
        }
        uint16_t missing = UINT16_MAX;
        uint16_t missing_count = 0;
        uint16_t group_start = 0;
        uint16_t group_end = 0;
        fec_group_bounds(slot->chunk_count, slot->fec_g, g, &group_start,
                         &group_end);
        for (uint16_t i = group_start; i < group_end; i++) {
            if (!slot->seen[i]) {
                missing = i;
                missing_count++;
                if (missing_count > 1) {
                    break;
                }
            }
        }
        if (missing_count != 1 || missing == UINT16_MAX) {
            continue;
        }
        uint8_t *scratch = malloc(slot->parity_chunk_len);
        if (scratch == NULL) {
            return -1;
        }
        memcpy(scratch, slot->parity_data + (size_t)g * slot->parity_chunk_len,
               slot->parity_chunk_len);
        for (uint16_t i = group_start; i < group_end; i++) {
            if (i == missing || !slot->seen[i]) {
                continue;
            }
            uint32_t len = true_chunk_len(slot, i);
            uint64_t offset = (uint64_t)i * slot->header.chunk_len;
            for (uint32_t j = 0; j < slot->parity_chunk_len; j++) {
                uint8_t value = j < len ? slot->data[offset + j] : 0u;
                scratch[j] ^= value;
            }
        }
        uint32_t recovered_len = true_chunk_len(slot, missing);
        if (recovered_len == 0) {
            free(scratch);
            return -1;
        }
        mark_seen(slot, missing, scratch, recovered_len,
                  (uint32_t)((uint64_t)missing * slot->header.chunk_len));
        slot->had_repair = 1u;
        reassembler->fec_recovered_chunks++;
        recovered = 1;
        free(scratch);
    }
    int complete = slot_checksum_complete(slot);
    if (complete < 0) {
        return -1;
    }
    return recovered;
}

static void mark_seen(sharp_video_region_slot_t *slot, uint16_t chunk_id,
                      const uint8_t *chunk_data, size_t chunk_len,
                      uint32_t offset) {
    memcpy(slot->data + offset, chunk_data, chunk_len);
    slot->seen[chunk_id] = 1u;
    slot->chunks_seen++;
    if (!slot->have_highest_chunk || chunk_id > slot->highest_chunk_seen) {
        slot->highest_chunk_seen = chunk_id;
        slot->have_highest_chunk = 1u;
    }
    if (slot->nacked != NULL && slot->nacked[chunk_id]) {
        slot->had_repair = 1u;
    }
}

int sharp_video_region_reassembler_push(
    sharp_video_region_reassembler_t *reassembler,
    const sharp_video_region_chunk_header_t *header, uint16_t chunk_id,
    uint16_t chunk_count, const uint8_t *chunk_data, size_t chunk_len,
    sharp_video_region_chunk_header_t *missed_header_out,
    uint16_t *missed_chunks_out) {
    if (missed_header_out != NULL) {
        memset(missed_header_out, 0, sizeof(*missed_header_out));
    }
    if (missed_chunks_out != NULL) {
        *missed_chunks_out = 0;
    }
    int is_parity =
        header != NULL && (header->flags & SHARP_VIDEO_REGION_FLAG_PARITY) != 0;
    if (reassembler == NULL || header == NULL || chunk_data == NULL ||
        chunk_count == 0 || chunk_count > SHARP_VIDEO_REGION_MAX_CHUNKS ||
        chunk_len != header->chunk_len) {
        return -1;
    }
    if (!is_parity &&
        (chunk_id >= chunk_count ||
         !sharp_video_region_chunk_header_is_valid(header, reassembler->width,
                                                   reassembler->height))) {
        return -1;
    }
    if (is_parity) {
        uint8_t fec_g = (uint8_t)(header->offset >> 16);
        uint16_t data_chunk_count = (uint16_t)(header->offset & 0xffffu);
        if (header->region_id != SHARP_VIDEO_REGION_FULLFRAME_ID ||
            fec_g == 0 || fec_g > 32u ||
            data_chunk_count != chunk_count ||
            chunk_id < chunk_count || chunk_id >= chunk_count + fec_g ||
            header->chunk_len == 0 || header->total_len == 0 ||
            header->total_len > 16u * 1024u * 1024u ||
            header->x >= reassembler->width || header->y >= reassembler->height ||
            (uint32_t)header->x + header->w > reassembler->width ||
            (uint32_t)header->y + header->h > reassembler->height) {
            return -1;
        }
    }
    if (!is_parity && header->region_id == SHARP_VIDEO_REGION_FULLFRAME_ID &&
        header->chunk_len > header->total_len) {
        return -1;
    }
    sharp_video_region_slot_t *slot =
        &reassembler->slots[header->region_id % SHARP_VIDEO_REASSEMBLER_SLOTS];
    if (slot->data != NULL && slot->seen != NULL &&
        slot->region_id == header->region_id &&
        header->generation < slot->header.generation) {
        return 0;
    }
    if (slot->data != NULL && slot->seen != NULL &&
        slot->region_id == header->region_id &&
        header->generation == slot->header.generation && slot->delivered) {
        return 0;
    }
    if (is_parity && slot->data != NULL && slot->seen != NULL &&
        slot->region_id == header->region_id &&
        slot->header.generation == header->generation &&
        slot->total_len == header->total_len &&
        slot->checksum == header->checksum &&
        slot->chunk_count == chunk_count) {
        uint8_t fec_g = (uint8_t)(header->offset >> 16);
        uint8_t group = (uint8_t)(chunk_id - chunk_count);
        if (ensure_parity_storage(slot, fec_g, header->chunk_len) != 0) {
            return -1;
        }
        if (!slot->parity_seen[group]) {
            memcpy(slot->parity_data + (size_t)group * slot->parity_chunk_len,
                   chunk_data, chunk_len);
            slot->parity_seen[group] = 1u;
            slot->parity_count++;
        }
        return try_fec_repair(reassembler, slot) < 0 ? -1 : 0;
    }
    if (is_parity) {
        return 0;
    }
    if (slot->data == NULL || slot->seen == NULL ||
        slot->region_id != header->region_id ||
        slot->header.generation != header->generation ||
        slot->total_len != header->total_len ||
        slot->checksum != header->checksum ||
        slot->chunk_count != chunk_count) {
        int missed = slot->data != NULL && slot->seen != NULL &&
                     slot->region_id == header->region_id && !slot->complete &&
                     slot->chunk_count > slot->chunks_seen;
        if (missed) {
            reassembler->fec_unrecovered_generations++;
            if (missed_header_out != NULL) {
                *missed_header_out = slot->header;
            }
            if (missed_chunks_out != NULL) {
                *missed_chunks_out = slot->chunk_count - slot->chunks_seen;
            }
        }
        reset_slot(slot, header, chunk_count);
        if (slot->data == NULL || slot->seen == NULL || slot->nacked == NULL) {
            return -1;
        }
        if (missed) {
            /* Continue assembling the newer generation, but tell the caller that
               an older generation was superseded before all chunks arrived. */
            mark_seen(slot, chunk_id, chunk_data, chunk_len, header->offset);
            if (try_fec_repair(reassembler, slot) < 0 ||
                slot_checksum_complete(slot) < 0) {
                return -1;
            }
            return 1;
        }
    }
    if (slot->seen[chunk_id]) {
        return 0;
    }
    mark_seen(slot, chunk_id, chunk_data, chunk_len, header->offset);
    if (try_fec_repair(reassembler, slot) < 0 ||
        slot_checksum_complete(slot) < 0) {
        return -1;
    }
    return 0;
}

int sharp_video_region_reassembler_next_missing(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    uint32_t generation, int include_tail,
    sharp_video_region_chunk_header_t *header_out, uint16_t *chunk_id_out,
    uint16_t *chunk_count_out) {
    if (header_out != NULL) {
        memset(header_out, 0, sizeof(*header_out));
    }
    if (chunk_id_out != NULL) {
        *chunk_id_out = 0;
    }
    if (chunk_count_out != NULL) {
        *chunk_count_out = 0;
    }
    if (reassembler == NULL) {
        return 0;
    }
    sharp_video_region_slot_t *slot =
        &reassembler->slots[region_id % SHARP_VIDEO_REASSEMBLER_SLOTS];
    if (slot->region_id != region_id || slot->header.generation != generation ||
        slot->complete || slot->seen == NULL || slot->nacked == NULL ||
        slot->chunk_count == 0 || !slot->have_highest_chunk) {
        return 0;
    }
    uint16_t limit = include_tail ? slot->chunk_count : slot->highest_chunk_seen;
    for (uint16_t i = 0; i < limit; i++) {
        if (!slot->seen[i] && !slot->nacked[i]) {
            uint16_t count = 0;
            for (uint16_t j = i; j < limit && !slot->seen[j] &&
                                 !slot->nacked[j]; j++) {
                slot->nacked[j] = 1u;
                count++;
            }
            if (header_out != NULL) {
                *header_out = slot->header;
            }
            if (chunk_id_out != NULL) {
                *chunk_id_out = i;
            }
            if (chunk_count_out != NULL) {
                *chunk_count_out = count;
            }
            return 1;
        }
    }
    return 0;
}

int sharp_video_region_reassembler_generation_incomplete(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    uint32_t generation) {
    if (reassembler == NULL) {
        return 0;
    }
    sharp_video_region_slot_t *slot =
        &reassembler->slots[region_id % SHARP_VIDEO_REASSEMBLER_SLOTS];
    return slot->region_id == region_id &&
           slot->header.generation == generation &&
           slot->seen != NULL &&
           slot->chunk_count > 0 &&
           !slot->complete &&
           slot->chunks_seen < slot->chunk_count;
}

uint64_t sharp_video_region_reassembler_fec_recovered_chunks(
    const sharp_video_region_reassembler_t *reassembler) {
    return reassembler != NULL ? reassembler->fec_recovered_chunks : 0;
}

uint64_t sharp_video_region_reassembler_fec_unrecovered_generations(
    const sharp_video_region_reassembler_t *reassembler) {
    return reassembler != NULL ? reassembler->fec_unrecovered_generations : 0;
}

int sharp_video_region_reassembler_take_complete_repair(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    sharp_video_region_chunk_header_t *header_out, const uint8_t **data_out,
    size_t *len_out, int *had_repair_out) {
    if (reassembler == NULL) {
        return 0;
    }
    sharp_video_region_slot_t *slot =
        &reassembler->slots[region_id % SHARP_VIDEO_REASSEMBLER_SLOTS];
    if (!slot->complete || slot->region_id != region_id) {
        return 0;
    }
    if (header_out != NULL) {
        *header_out = slot->header;
    }
    if (data_out != NULL) {
        *data_out = slot->data;
    }
    if (len_out != NULL) {
        *len_out = slot->total_len;
    }
    if (had_repair_out != NULL) {
        *had_repair_out = slot->had_repair ? 1 : 0;
    }
    slot->complete = 0u;
    slot->delivered = 1u;
    return 1;
}

int sharp_video_region_reassembler_take_complete(
    sharp_video_region_reassembler_t *reassembler, uint16_t region_id,
    sharp_video_region_chunk_header_t *header_out, const uint8_t **data_out,
    size_t *len_out) {
    return sharp_video_region_reassembler_take_complete_repair(
        reassembler, region_id, header_out, data_out, len_out, NULL);
}
