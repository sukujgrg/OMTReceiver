// macOS public C-API check. No SDK internals are linked or inspected.
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "libomt.h"

extern char **environ;
static volatile sig_atomic_t stopping;
static void stop_signal(int value) { (void)value; stopping = 1; }
static void die(const char *text) { fprintf(stderr, "%s\n", text); exit(2); }
static uint64_t now(void) {
    static mach_timebase_info_data_t scale;
    if (!scale.denom) mach_timebase_info(&scale);
    return (uint64_t)((__uint128_t)mach_absolute_time() * scale.numer / scale.denom);
}
typedef struct {
    omt_send_t *(*create_send)(const char *, OMTQuality);
    void (*destroy_send)(omt_send_t *);
    int (*send)(omt_send_t *, OMTMediaFrame *);
    int (*connections)(omt_send_t *);
    void (*statistics)(omt_send_t *, OMTStatistics *);
    omt_receive_t *(*create_receive)(const char *, OMTFrameType, OMTPreferredVideoFormat, OMTReceiveFlags);
    void (*destroy_receive)(omt_receive_t *);
    OMTMediaFrame *(*receive)(omt_receive_t *, OMTFrameType, int);
    void (*setting)(const char *, int);
    void (*shutdown)(void);
} API;
static API load(const char *library, const char *codec, const char *storage) {
    if (setenv("OMT_STORAGE_PATH", storage, 1)) die("Storage environment failed");
    if (!dlopen(codec, RTLD_GLOBAL | RTLD_NOW)) die(dlerror());
    void *module = dlopen(library, RTLD_LOCAL | RTLD_NOW);
    if (!module) die(dlerror());
    API api = {0};
#define SYMBOL(member, symbol) do { *(void **)(&api.member) = dlsym(module, symbol); if (!api.member) die(symbol); } while (0)
    SYMBOL(create_send, "omt_send_create"); SYMBOL(destroy_send, "omt_send_destroy");
    SYMBOL(send, "omt_send"); SYMBOL(connections, "omt_send_connections");
    SYMBOL(statistics, "omt_send_getvideostatistics");
    SYMBOL(create_receive, "omt_receive_create"); SYMBOL(destroy_receive, "omt_receive_destroy");
    SYMBOL(receive, "omt_receive"); SYMBOL(setting, "omt_settings_set_integer");
    SYMBOL(shutdown, "omt_shutdown");
#undef SYMBOL
    // NativeAOT remains mapped until process exit. Never dlclose this module.
    return api;
}
static void path(char *out, const char *base, const char *leaf) {
    int size = snprintf(out, PATH_MAX, "%s/%s", base, leaf);
    if (size < 0 || size >= PATH_MAX) die("Evidence path too long");
}
static int available_port(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("Socket failed");
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (bind(fd, (struct sockaddr *)&address, sizeof(address))) die("Bind failed");
    socklen_t size = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &size)) die("Port lookup failed");
    close(fd); return ntohs(address.sin_port);
}
static int source(const char *library, const char *codec, const char *storage, int port, const char *name) {
    API api = load(library, codec, storage);
    signal(SIGTERM, stop_signal);
    api.setting("NetworkPortStart", port); api.setting("NetworkPortEnd", port);
    omt_send_t *sender = api.create_send(name, OMTQuality_Medium);
    if (!sender) die("Sender creation failed");
    size_t bytes = 1920 * 1080 * 2;
    unsigned char *pixels = malloc(bytes);
    if (!pixels) die("Allocation failed");
    for (size_t i = 0; i < bytes; i += 4) {
        pixels[i] = 110; pixels[i + 1] = (unsigned char)(48 + i / 4 % 150);
        pixels[i + 2] = 140; pixels[i + 3] = (unsigned char)(48 + i / 8 % 150);
    }
    OMTMediaFrame frame = {0};
    frame.Type = OMTFrameType_Video; frame.Codec = OMTCodec_UYVY;
    frame.Width = 1920; frame.Height = 1080; frame.Stride = 3840;
    frame.FrameRateN = 30; frame.FrameRateD = 1; frame.AspectRatio = 16.0f / 9;
    frame.ColorSpace = OMTColorSpace_BT709; frame.Data = pixels; frame.DataLength = (int)bytes;
    char file[PATH_MAX]; path(file, storage, "calls.jsonl");
    FILE *calls = fopen(file, "w"); if (!calls) die("Call trace failed");
    path(file, storage, "ready.txt");
    FILE *ready = fopen(file, "w"); if (!ready) die("Ready barrier failed");
    fprintf(ready, "%" PRIu64 "\n", now() / 100); fclose(ready);
    uint64_t next = now(); unsigned count = 0;
    while (!stopping && count < 20000) {
        uint64_t started = now();
        if (started < next) { usleep(1000); continue; }
        frame.Timestamp = (int64_t)(started / 100);
        int connections = api.connections(sender), returned = api.send(sender, &frame);
        fprintf(calls, "{\"startedNs\":%" PRIu64 ",\"finishedNs\":%" PRIu64 ",\"connections\":%d,\"returned\":%d}\n",
                started, now(), connections, returned);
        next = started + 33333334; count++;
    }
    if (getenv("OMT_PROBE_TERMINAL_SAME")) {
        uint64_t entered = now(); frame.Timestamp = (int64_t)(entered / 100);
        int returned = api.send(sender, &frame);
        fprintf(calls, "{\"kind\":\"terminalSame\",\"startedNs\":%" PRIu64 ",\"finishedNs\":%" PRIu64 ",\"returned\":%d}\n",
                entered, now(), returned);
    }
    if (getenv("OMT_PROBE_TERMINAL_ALPHA")) {
        size_t terminal_size = 1920 * 1080 * 3;
        unsigned char *terminal = calloc(1, terminal_size);
        if (!terminal) die("Terminal allocation failed");
        for (size_t i = 0; i < bytes; i += 4) {
            terminal[i] = 128; terminal[i + 1] = 16;
            terminal[i + 2] = 128; terminal[i + 3] = 16;
        }
        frame.Codec = OMTCodec_UYVA; frame.Flags = OMTVideoFlags_Alpha;
        frame.Data = terminal; frame.DataLength = (int)terminal_size;
        uint64_t entered = now(); frame.Timestamp = (int64_t)(entered / 100);
        int returned = api.send(sender, &frame);
        fprintf(calls, "{\"kind\":\"terminalAlpha0\",\"startedNs\":%" PRIu64 ",\"finishedNs\":%" PRIu64 ",\"returned\":%d}\n",
                entered, now(), returned);
        free(terminal); // Public synchronous send has consumed the raw picture.
    }
    OMTStatistics statistics = {0}; api.statistics(sender, &statistics);
    path(file, storage, "statistics.json");
    FILE *summary = fopen(file, "w"); if (!summary) die("Source summary failed");
    fprintf(summary, "{\"calls\":%u,\"frames\":%" PRId64 ",\"drops\":%" PRId64 "}\n",
            count, statistics.Frames, statistics.FramesDropped);
    fclose(summary); fclose(calls);
    api.destroy_send(sender); api.shutdown(); free(pixels);
    if (getenv("OMT_PROBE_IMMEDIATE_EXIT")) _exit(0);
    return 0;
}
static bool retire(pid_t *child) {
    if (*child <= 0) return true;
    kill(*child, SIGTERM);
    uint64_t deadline = now() + 5000000000ULL; int status = 0;
    while (now() < deadline) {
        pid_t result = waitpid(*child, &status, WNOHANG);
        if (result == *child) { *child = 0; return WIFEXITED(status) && WEXITSTATUS(status) == 0; }
        if (result < 0 && errno == ECHILD) { *child = 0; return false; }
        usleep(10000);
    }
    kill(*child, SIGKILL); waitpid(*child, &status, 0); *child = 0; return false;
}
static bool launch(pid_t *child, const char *binary, char **args, const char *storage, uint64_t *boundary) {
    if (mkdir(storage, 0700)) return false;
    char console[PATH_MAX], ready_path[PATH_MAX];
    path(console, storage, "console.log"); path(ready_path, storage, "ready.txt");
    posix_spawn_file_actions_t files; posix_spawn_file_actions_init(&files);
    posix_spawn_file_actions_addopen(&files, STDOUT_FILENO, console, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    posix_spawn_file_actions_adddup2(&files, STDOUT_FILENO, STDERR_FILENO);
    posix_spawnattr_t attributes; posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    int result = posix_spawn(child, binary, &files, &attributes, args, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&files);
    if (result) { *child = 0; return false; }
    uint64_t deadline = now() + 5000000000ULL;
    while (now() < deadline) {
        FILE *ready = fopen(ready_path, "r");
        if (ready) { bool valid = fscanf(ready, "%" SCNu64, boundary) == 1; fclose(ready); if (valid) return true; }
        int status;
        if (waitpid(*child, &status, WNOHANG) == *child) { *child = 0; return false; }
        usleep(10000);
    }
    retire(child); return false;
}
int main(int argc, char **argv) {
    if (argc == 7 && strcmp(argv[1], "--sender") == 0)
        return source(argv[2], argv[3], argv[4], atoi(argv[5]), argv[6]);
    if (argc != 5 && argc != 6) die("Usage: native-direct-restart LIBRARY CODEC NEW_OUTPUT ROUNDS [FRESH_FRAMES]");
    int rounds = atoi(argv[4]); if (rounds < 1 || rounds > 32) die("Rounds must be1..32");
    int required_frames = argc == 6 ? atoi(argv[5]) : 3;
    if (required_frames != 1 && required_frames != 3) die("Fresh frame count must be1 or3");
    if (mkdir(argv[3], 0700)) die("Output must be new");
    char binary[PATH_MAX]; if (!realpath(argv[0], binary)) die("Executable path failed");
    char storage[PATH_MAX]; path(storage, argv[3], "receiver");
    if (mkdir(storage, 0700)) die("Receiver storage failed");
    API api = load(argv[1], argv[2], storage);
    int port = available_port();
    const char *selected_port = getenv("OMT_PROBE_PORT");
    if (selected_port) {
        char *end = NULL; errno = 0;
        long value = strtol(selected_port, &end, 10);
        if (errno || !end || *end || value < 1024 || value > 65535) die("Invalid OMT_PROBE_PORT");
        port = (int)value;
    }
    char endpoint[80], name[80], number[16], report_path[PATH_MAX];
    snprintf(endpoint, sizeof(endpoint), "omt://127.0.0.1:%d", port);
    snprintf(name, sizeof(name), "Native direct probe %ld", (long)getpid());
    snprintf(number, sizeof(number), "%d", port);
    path(report_path, argv[3], "report.json");
    FILE *report = fopen(report_path, "w"); if (!report) die("Report failed");
    fprintf(report, "{\"scope\":\"Public native C API, persistent video-only receiver, new sender processes, fixedURL,4s target/8s diagnostics\",\"terminalAlpha\":%s,\"terminalSame\":%s,\"immediateChildExit\":%s,\"requiredFreshFrames\":%d,\"port\":%d,\"cycles\":[",
            getenv("OMT_PROBE_TERMINAL_ALPHA") ? "true" : "false",
            getenv("OMT_PROBE_TERMINAL_SAME") ? "true" : "false",
            getenv("OMT_PROBE_IMMEDIATE_EXIT") ? "true" : "false", required_frames, port);
    omt_receive_t *receiver = NULL; pid_t child = 0;
    int failures = 0, completed = 0; int64_t previous = -1;
    for (int cycle = 0; cycle < rounds; cycle++) {
        uint64_t stop_requested = now();
        if (!retire(&child)) { failures++; break; }
        uint64_t exit_observed = now();
        char leaf[40]; snprintf(leaf, sizeof(leaf), "sender-%d", cycle); path(storage, argv[3], leaf);
        char *arguments[] = {binary, "--sender", argv[1], argv[2], storage, number, name, NULL};
        uint64_t boundary = 0;
        if (!launch(&child, binary, arguments, storage, &boundary)) { failures++; break; }
        // Polling pauses across the exact old-exit/new-ready barriers.
        if (!receiver) receiver = api.create_receive(endpoint, OMTFrameType_Video, OMTPreferredVideoFormat_BGRA, OMTReceiveFlags_None);
        if (!receiver) { failures++; break; }
        uint64_t started = now(); int fresh = 0, pending = 0, stale = 0, invalid = 0; double first_ms = -1;
        while (now() - started < 8000000000ULL && fresh < required_frames) {
            OMTMediaFrame *frame = api.receive(receiver, OMTFrameType_Video, 100);
            if (!frame) { pending++; continue; }
            if (frame->Type != OMTFrameType_Video || frame->Width != 1920 || frame->Height != 1080 ||
                frame->Codec != OMTCodec_BGRA || !frame->Data || frame->Stride < 7680 ||
                frame->DataLength < (int64_t)frame->Stride * frame->Height) { invalid++; break; }
            if (frame->Timestamp < (int64_t)boundary) { stale++; continue; }
            if (frame->Timestamp <= previous) { invalid++; break; }
            previous = frame->Timestamp;
            if (first_ms < 0) first_ms = (double)(now() - started) / 1000000;
            fresh++;
        }
        bool passed = fresh >= required_frames && invalid == 0 && first_ms >= 0 && first_ms <= 4000;
        fprintf(report, "%s{\"cycle\":%d,\"senderPID\":%ld,\"stopRequestedNs\":%" PRIu64 ",\"exitObservedNs\":%" PRIu64 ",\"senderReadyBoundary100ns\":%" PRIu64 ",\"receiveStartedNs\":%" PRIu64 ",\"fresh\":%d,\"pending\":%d,\"stale\":%d,\"invalid\":%d,\"firstFreshMs\":%.6f,\"elapsedMs\":%.6f,\"passed\":%s}",
                completed ? "," : "", cycle, (long)child, stop_requested, exit_observed, boundary, started,
                fresh, pending, stale, invalid, first_ms,
                (double)(now() - started) / 1000000, passed ? "true" : "false");
        fflush(report); completed++;
        printf("native cycle=%d fresh=%d pending=%d firstMs=%.3f passed=%d\n", cycle, fresh, pending, first_ms, passed); fflush(stdout);
        if (!passed) { failures++; break; }
    }
    if (receiver) api.destroy_receive(receiver);
    if (!retire(&child)) failures++;
    api.shutdown();
    fprintf(report, "],\"completedCycles\":%d,\"failures\":%d,\"passed\":%s}\n", completed, failures, failures ? "false" : "true");
    fclose(report); return failures ? 1 : 0;
}
