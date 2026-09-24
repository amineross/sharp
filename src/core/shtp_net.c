#include "sharp/shtp_net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int shtp_udp_socket(int recv_buffer_bytes, int send_buffer_bytes) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return -1;
    }

    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    if (recv_buffer_bytes > 0) {
        (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &recv_buffer_bytes,
                         sizeof(recv_buffer_bytes));
    }
    if (send_buffer_bytes > 0) {
        (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buffer_bytes,
                         sizeof(send_buffer_bytes));
    }

    return fd;
}

int shtp_bind_ipv4(int fd, const char *ip, unsigned short port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (ip == NULL || strcmp(ip, "0.0.0.0") == 0 || strcmp(ip, "*") == 0) {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        errno = EINVAL;
        return -1;
    }

    return bind(fd, (struct sockaddr *)&addr, sizeof(addr));
}

int shtp_make_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int shtp_parse_u32(const char *text, unsigned int min_value, unsigned int max_value,
                   unsigned int *out) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value > UINT_MAX ||
        value < min_value || value > max_value) {
        return -1;
    }
    *out = (unsigned int)value;
    return 0;
}

int shtp_parse_double(const char *text, double min_value, double max_value, double *out) {
    char *end = NULL;
    errno = 0;
    double value = strtod(text, &end);
    if (errno != 0 || end == text || *end != '\0' || value < min_value ||
        value > max_value) {
        return -1;
    }
    *out = value;
    return 0;
}
