#include "sharp/shtp_protocol.h"
#include "sharp/tile_receiver.h"
#include "sharp/tile_sender.h"

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int make_batch_datagram(int send_fd, int receive_fd, uint32_t frame_id,
                               uint32_t color,
                               uint8_t *out, size_t out_cap, size_t *len_out) {
    uint8_t pixels[SHARP_TILE_BYTES];
    for (size_t i = 0; i < sizeof(pixels); i += sizeof(color)) {
        memcpy(pixels + i, &color, sizeof(color));
    }

    uint8_t packet[SHTP_MAX_DATAGRAM];
    sharp_tile_batch_writer_t writer;
    if (sharp_tile_batch_writer_begin(&writer, packet,
                                      SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES) != 0) {
        return -1;
    }
    for (uint16_t tile_id = 0; tile_id < 2; tile_id++) {
        sharp_tile_rect_t rect;
        if (sharp_tile_rect_for_id(128, 64, tile_id, &rect) != 0 ||
            sharp_tile_batch_writer_add(&writer, &rect, pixels, 64u * 4u) != 0) {
            return -1;
        }
    }
    uint32_t sequence = 1;
    if (sharp_tile_batch_writer_flush(send_fd, &writer, frame_id, &sequence, NULL) !=
        0) {
        return -1;
    }
    ssize_t received = recv(receive_fd, out, out_cap, 0);
    if (received <= 0) {
        return -1;
    }
    *len_out = (size_t)received;
    return 0;
}

static int make_mixed_generation_batch(int send_fd, int receive_fd,
                                       uint8_t *out, size_t out_cap,
                                       size_t *len_out) {
    uint8_t pixels[SHARP_TILE_BYTES];
    memset(pixels, 0x5a, sizeof(pixels));
    uint8_t packet[SHTP_MAX_DATAGRAM];
    sharp_tile_batch_writer_t writer;
    if (sharp_tile_batch_writer_begin(&writer, packet,
                                      SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES) != 0) {
        return -1;
    }
    for (uint16_t tile_id = 0; tile_id < 2; tile_id++) {
        sharp_tile_rect_t rect;
        uint32_t generation = tile_id == 0 ? 12u : 11u;
        if (sharp_tile_rect_for_id(128, 64, tile_id, &rect) != 0 ||
            sharp_tile_batch_writer_add_with_generation(
                &writer, generation, &rect, pixels, 64u * 4u) != 0) {
            return -1;
        }
    }
    uint32_t sequence = 1;
    if (sharp_tile_batch_writer_flush(send_fd, &writer, 99, &sequence, NULL) != 0) {
        return -1;
    }
    ssize_t received = recv(receive_fd, out, out_cap, 0);
    if (received <= 0) {
        return -1;
    }
    *len_out = (size_t)received;
    return 0;
}

static uint32_t batch_generation(const uint8_t *datagram, size_t len) {
    if (len < SHTP_HEADER_BYTES + sizeof(sharp_tile_chunk_header_t)) {
        return UINT32_MAX;
    }
    sharp_tile_chunk_header_t th;
    memcpy(&th, datagram + SHTP_HEADER_BYTES, sizeof(th));
    sharp_tile_chunk_header_wire_to_host(&th);
    return th.generation;
}

static uint32_t second_batch_generation(const uint8_t *datagram, size_t len) {
    if (len < SHTP_HEADER_BYTES + sizeof(sharp_tile_chunk_header_t)) {
        return UINT32_MAX;
    }
    sharp_tile_chunk_header_t first;
    memcpy(&first, datagram + SHTP_HEADER_BYTES, sizeof(first));
    sharp_tile_chunk_header_wire_to_host(&first);
    size_t second_offset = SHTP_HEADER_BYTES + sizeof(first) + first.chunk_len;
    if (len < second_offset + sizeof(sharp_tile_chunk_header_t)) {
        return UINT32_MAX;
    }
    sharp_tile_chunk_header_t second;
    memcpy(&second, datagram + second_offset, sizeof(second));
    sharp_tile_chunk_header_wire_to_host(&second);
    return second.generation;
}

static int test_canonical_tile_hash(void) {
    const uint32_t width = 70u;
    const uint32_t height = 66u;
    const uint32_t tight_stride = width * 4u;
    const uint32_t padded_stride = tight_stride + 32u;
    uint8_t *tight = calloc(height, tight_stride);
    uint8_t *padded = calloc(height, padded_stride);
    if (tight == NULL || padded == NULL) {
        free(tight);
        free(padded);
        return -1;
    }
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            uint32_t pixel = 0xff000000u | ((x * 17u) << 8u) | (y * 13u);
            memcpy(tight + (size_t)y * tight_stride + (size_t)x * 4u,
                   &pixel, sizeof(pixel));
            memcpy(padded + (size_t)y * padded_stride + (size_t)x * 4u,
                   &pixel, sizeof(pixel));
        }
        memset(padded + (size_t)y * padded_stride + tight_stride,
               (int)(0x40u + (y & 0x3fu)), padded_stride - tight_stride);
    }
    sharp_tile_rect_t edge;
    if (sharp_tile_rect_for_id(width, height, 3u, &edge) != 0) {
        free(tight);
        free(padded);
        return -1;
    }
    uint64_t tight_hash = sharp_tile_hash_bgra(tight, tight_stride, &edge);
    uint64_t padded_hash = sharp_tile_hash_bgra(padded, padded_stride, &edge);
    padded[(size_t)edge.y * padded_stride + (size_t)edge.x * 4u] ^= 0x5au;
    uint64_t changed_hash = sharp_tile_hash_bgra(padded, padded_stride, &edge);
    free(tight);
    free(padded);
    return tight_hash == padded_hash && changed_hash != tight_hash ? 0 : -1;
}

int main(void) {
    if (test_canonical_tile_hash() != 0) {
        fprintf(stderr, "canonical tile hash depends on stride or missed mutation\n");
        return 1;
    }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0) {
        perror("socketpair");
        return 1;
    }

    uint8_t newer[SHTP_MAX_DATAGRAM];
    uint8_t older[SHTP_MAX_DATAGRAM];
    uint8_t mixed[SHTP_MAX_DATAGRAM];
    size_t newer_len = 0;
    size_t older_len = 0;
    size_t mixed_len = 0;
    const uint32_t newer_color = 0xff3366ccu;
    const uint32_t older_color = 0xff112233u;
    if (make_batch_datagram(sockets[0], sockets[1], 10, newer_color, newer,
                            sizeof(newer), &newer_len) != 0 ||
        make_batch_datagram(sockets[0], sockets[1], 9, older_color, older,
                            sizeof(older), &older_len) != 0 ||
        make_mixed_generation_batch(sockets[0], sockets[1], mixed,
                                    sizeof(mixed), &mixed_len) != 0) {
        fprintf(stderr, "failed to create batch datagrams\n");
        return 1;
    }
    close(sockets[0]);
    close(sockets[1]);

    if (batch_generation(newer, newer_len) != 10 ||
        second_batch_generation(newer, newer_len) != 10 ||
        batch_generation(older, older_len) != 9 ||
        second_batch_generation(older, older_len) != 9) {
        fprintf(stderr, "batched tile generation was not stamped\n");
        return 1;
    }
    if (batch_generation(mixed, mixed_len) != 12 ||
        second_batch_generation(mixed, mixed_len) != 11) {
        fprintf(stderr, "per-record batch generations were overwritten\n");
        return 1;
    }

    sharp_tile_receiver_t receiver;
    if (sharp_tile_receiver_init(&receiver, 128, 64) != 0) {
        fprintf(stderr, "receiver init failed\n");
        return 1;
    }
    int patched = 0;
    sharp_tile_dirty_bounds_t dirty;
    if (sharp_tile_receiver_handle_datagram(&receiver, newer, newer_len, &patched,
                                            &dirty) != 0 ||
        !patched || !dirty.valid ||
        sharp_tile_receiver_tile_generation(&receiver, 0) != 10 ||
        sharp_tile_receiver_tile_generation(&receiver, 1) != 10) {
        fprintf(stderr, "newer tile was not applied\n");
        return 1;
    }
    patched = 0;
    if (sharp_tile_receiver_handle_datagram(&receiver, older, older_len, &patched,
                                            &dirty) != 0 ||
        patched || dirty.valid || receiver.stats.stale_tiles != 2 ||
        sharp_tile_receiver_tile_generation(&receiver, 0) != 10 ||
        sharp_tile_receiver_tile_generation(&receiver, 1) != 10) {
        fprintf(stderr, "stale tile was not rejected\n");
        return 1;
    }

    uint32_t actual;
    uint32_t second_actual;
    memcpy(&actual, receiver.fb.pixels, sizeof(actual));
    memcpy(&second_actual, receiver.fb.pixels + 64u * 4u,
           sizeof(second_actual));
    sharp_tile_receiver_destroy(&receiver);
    if (actual != newer_color || second_actual != newer_color) {
        fprintf(stderr, "stale tile overwrote newer pixels\n");
        return 1;
    }

    puts("tile-correctness-test ok");
    return 0;
}
