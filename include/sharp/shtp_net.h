#ifndef SHARP_SHTP_NET_H
#define SHARP_SHTP_NET_H

#include <stddef.h>

int shtp_udp_socket(int recv_buffer_bytes, int send_buffer_bytes);
int shtp_bind_ipv4(int fd, const char *ip, unsigned short port);
int shtp_make_nonblocking(int fd);
int shtp_parse_u32(const char *text, unsigned int min_value, unsigned int max_value,
                   unsigned int *out);
int shtp_parse_double(const char *text, double min_value, double max_value, double *out);

#endif
