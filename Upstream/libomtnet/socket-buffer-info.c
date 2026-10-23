// Read-only macOS diagnostic for TCP sockets of a process owned by this user.
// Build: xcrun clang -Wall -Wextra -Werror -O2 socket-buffer-info.c -o socket-buffer-info
// Usage: socket-buffer-info PID LOCAL_TCP_PORT [SECONDS_AT_10HZ (1..120)]
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <time.h>

static long number(const char *text, long maximum) {
    char *end = NULL;
    errno = 0;
    long result = strtol(text, &end, 10);
    return errno || !text[0] || *end || result < 1 || result > maximum ? -1 : result;
}

static int snapshot(int pid, long port) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now)) return 1;
    double unixSeconds = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 1024 * 1024) { fprintf(stderr, "Cannot size bounded FD snapshot\n"); return 1; }
    bytes += 32 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = calloc(1, (size_t)bytes);
    if (!fds) return 1;
    int used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes), matched = 0;
    if (used <= 0 || used > bytes) { free(fds); fprintf(stderr, "Cannot read bounded FD snapshot\n"); return 1; }
    for (int i = 0; i < used / (int)sizeof(*fds); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo info;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.psi.soi_kind != SOCKINFO_TCP) continue;
        const struct tcp_sockinfo *tcp = &info.psi.soi_proto.pri_tcp;
        if (ntohs((uint16_t)tcp->tcpsi_ini.insi_lport) != port) continue;
        printf("{\"sampledAtUnixSeconds\":%.6f,\"pid\":%d,\"fd\":%d,\"localPort\":%ld,\"remotePort\":%u,\"tcpState\":%d,"
               "\"sendQueueBytes\":%u,\"sendHighWaterBytes\":%u,\"sendMBufMaxBytes\":%u,"
               "\"receiveQueueBytes\":%u,\"receiveHighWaterBytes\":%u}\n",
               unixSeconds, pid, fds[i].proc_fd, port, ntohs((uint16_t)tcp->tcpsi_ini.insi_fport), tcp->tcpsi_state,
               info.psi.soi_snd.sbi_cc, info.psi.soi_snd.sbi_hiwat, info.psi.soi_snd.sbi_mbmax,
               info.psi.soi_rcv.sbi_cc, info.psi.soi_rcv.sbi_hiwat);
        matched++;
    }
    free(fds);
    if (!matched) { fprintf(stderr, "No readable TCP sockets for the requested process/port\n"); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "Usage: %s PID LOCAL_TCP_PORT [SECONDS_AT_10HZ (1..120)]\n", argv[0]);
        return 2;
    }
    long requestedPID = number(argv[1], INT_MAX), port = number(argv[2], 65535);
    long seconds = argc == 4 ? number(argv[3], 120) : 0;
    if (requestedPID < 0 || port < 0 || seconds < 0) { fprintf(stderr, "Invalid PID, port or duration\n"); return 2; }
    int pid = (int)requestedPID;
    struct proc_bsdinfo owner;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &owner, sizeof(owner)) != sizeof(owner) || owner.pbi_uid != getuid()) {
        fprintf(stderr, "Process unavailable, unreadable, or owned by another user\n"); return 1;
    }
    long samples = seconds ? seconds * 10 : 1;
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started)) return 1;
    for (long i = 0; i < samples; i++) {
        if (snapshot(pid, port)) return 1;
        fflush(stdout);
        if (i + 1 < samples) {
            struct timespec now;
            if (clock_gettime(CLOCK_MONOTONIC, &now)) return 1;
            double elapsed = (double)(now.tv_sec - started.tv_sec) + (double)(now.tv_nsec - started.tv_nsec) / 1e9;
            if (elapsed >= seconds) break;
            double remaining = (double)(i + 1) / 10.0 - elapsed;
            if (remaining > 0) usleep((useconds_t)(remaining * 1e6));
        }
    }
    return 0;
}
