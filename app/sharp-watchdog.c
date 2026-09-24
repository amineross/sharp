#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int process_exists(pid_t pid) {
    return pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: SharpWatchdog PARENT_PID CHILD_PID\n");
        return 2;
    }
    pid_t parent = (pid_t)strtol(argv[1], NULL, 10);
    pid_t child = (pid_t)strtol(argv[2], NULL, 10);
    if (parent <= 1 || child <= 1) {
        return 2;
    }
    while (process_exists(parent) && process_exists(child)) {
        usleep(500000);
    }
    if (!process_exists(parent) && process_exists(child)) {
        (void)kill(child, SIGTERM);
        for (int i = 0; i < 20 && process_exists(child); i++) {
            usleep(100000);
        }
        if (process_exists(child)) {
            (void)kill(child, SIGKILL);
        }
    }
    return 0;
}
