#include "sharp/shtp_protocol.h"

#include <arpa/inet.h>

uint64_t shtp_htonll(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return ((uint64_t)htonl((uint32_t)(value & 0xffffffffULL)) << 32) |
           (uint64_t)htonl((uint32_t)(value >> 32));
#else
    return value;
#endif
}

uint64_t shtp_ntohll(uint64_t value) {
    return shtp_htonll(value);
}

void shtp_header_host_to_wire(shtp_header_t *header) {
    header->magic = htonl(header->magic);
    header->sequence = htonl(header->sequence);
    header->frame_id = htonl(header->frame_id);
    header->chunk_id = htons(header->chunk_id);
    header->chunk_count = htons(header->chunk_count);
    header->payload_len = htonl(header->payload_len);
    header->send_time_ns = shtp_htonll(header->send_time_ns);
    header->aux_time_ns = shtp_htonll(header->aux_time_ns);
    header->flags = htonl(header->flags);
    header->header_crc = htonl(header->header_crc);
}

void shtp_header_wire_to_host(shtp_header_t *header) {
    header->magic = ntohl(header->magic);
    header->sequence = ntohl(header->sequence);
    header->frame_id = ntohl(header->frame_id);
    header->chunk_id = ntohs(header->chunk_id);
    header->chunk_count = ntohs(header->chunk_count);
    header->payload_len = ntohl(header->payload_len);
    header->send_time_ns = shtp_ntohll(header->send_time_ns);
    header->aux_time_ns = shtp_ntohll(header->aux_time_ns);
    header->flags = ntohl(header->flags);
    header->header_crc = ntohl(header->header_crc);
}

int shtp_header_is_valid(const shtp_header_t *header, size_t datagram_len) {
    if (datagram_len < sizeof(*header)) {
        return 0;
    }
    if (header->magic != SHTP_MAGIC ||
        header->version != SHTP_VERSION ||
        header->header_bytes != SHTP_HEADER_BYTES) {
        return 0;
    }
    if ((size_t)header->payload_len + sizeof(*header) != datagram_len) {
        return 0;
    }
    return 1;
}

void sharp_tile_digest_header_host_to_wire(sharp_tile_digest_header_t *header) {
    header->magic = htonl(header->magic);
    header->version = htons(header->version);
    header->entry_count = htons(header->entry_count);
}

void sharp_tile_digest_header_wire_to_host(sharp_tile_digest_header_t *header) {
    header->magic = ntohl(header->magic);
    header->version = ntohs(header->version);
    header->entry_count = ntohs(header->entry_count);
}

void sharp_tile_digest_entry_host_to_wire(sharp_tile_digest_entry_t *entry) {
    entry->tile_id = htons(entry->tile_id);
    entry->reserved = htons(entry->reserved);
    entry->hash = shtp_htonll(entry->hash);
}

void sharp_tile_digest_entry_wire_to_host(sharp_tile_digest_entry_t *entry) {
    entry->tile_id = ntohs(entry->tile_id);
    entry->reserved = ntohs(entry->reserved);
    entry->hash = shtp_ntohll(entry->hash);
}
