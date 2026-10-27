/* Independent receiver fixture: all transport/discovery/encoding uses libomt. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#include "libomt.h"
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { WIDTH = 1920, HEIGHT = 1080, SAMPLE_RATE = 48000, AUDIO_SAMPLES = 960 };
static const int64_t TICKS_PER_SECOND = 10000000;
static const double PI = 3.14159265358979323846;
static atomic_bool stop_requested = false;
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Signal-safe stop requires lock-free atomics");

typedef struct {
    const char *name;
    double seconds;
    double video_pause_after;
    double video_pause_duration;
    double switch_scan_after;
    int port;
    int frame_rate_n;
    int frame_rate_d;
    bool alpha;
    bool interlaced;
    bool bottom_field_first;
    bool benchmark;
    bool silent_left;
    bool silent_right;
} Options;

typedef struct {
    omt_send_t *sender;
    const Options *options;
    int64_t start_ns;
    float pcm[2 * AUDIO_SAMPLES];
    atomic_uint_fast64_t blocks;
    atomic_int_fast64_t maximum_lateness_ns;
    atomic_uint_fast64_t late_blocks;
    int scheduling_error;
} AudioContext;

static void interrupted(int signal_number) {
    (void)signal_number;
    atomic_store_explicit(&stop_requested, true, memory_order_relaxed);
}

static int64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
}

static void sleep_until(int64_t deadline) {
    while (!atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
        int64_t remaining = deadline - monotonic_ns();
        if (remaining <= 0) return;
        struct timespec delay = { (time_t)(remaining / 1000000000LL), (long)(remaining % 1000000000LL) };
        if (nanosleep(&delay, NULL) != 0 && errno != EINTR) {
            perror("nanosleep");
            atomic_store_explicit(&stop_requested, true, memory_order_relaxed);
        }
    }
}

static void usage(const char *program) {
    printf("Usage: %s [options]\n"
           "  --seconds N              Finite duration, 0.1–18000 (default 60).\n"
           "  --name NAME              Source name (default OMTReceiver Test Pattern).\n"
           "  --fps RATE               1–60 fps as N or N/D (default 30; e.g. 60 or 60000/1001).\n"
           "  --video-pause-after S    Inject one video-only producer pause after S seconds.\n"
           "  --video-pause-duration S  Pause for 0.001–5 seconds; audio keeps running.\n"
           "  --interlaced             Encode genuinely offset fields (rate is complete pairs/sec).\n"
           "  --bottom-field-first     Put the earlier field in odd rows (default top first).\n"
           "  --switch-scan-after S    Toggle progressive/interlaced once after S seconds.\n"
           "  --alpha                  Send straight-alpha BGRA gradients and text.\n"
           "  --benchmark              Print five-second sender timing reports as JSON.\n"
           "  --silent-channel SIDE    none, left, right, or both (default none).\n"
           "  --port N                 SDK listen port, 1–65535 (default 6488).\n"
           "  --help                   Show help without calling the SDK.\n\n"
           "1080 SDR BT.709 up to 60 complete frames/sec, fixed Medium quality. Stereo Float32 at\n"
           "48 kHz, exactly 960 samples/block. Both tracks use relative 100ns PTS.\n"
           "A white square and a short 1 kHz tone mark each whole second.\n"
           "Normal tones: left 440 Hz, right 660 Hz. Silent channels are exact zero.\n",
           program);
}

static bool parse_options(int argc, char **argv, Options *options) {
    *options = (Options){ .name = "OMTReceiver Test Pattern", .seconds = 60, .port = 6488, .frame_rate_n = 30, .frame_rate_d = 1 };
    for (int index = 1; index < argc; ++index) {
        const char *argument = argv[index];
        if (strcmp(argument, "--help") == 0 || strcmp(argument, "-h") == 0) {
            usage(argv[0]);
            exit(0);
        }
        if (strcmp(argument, "--benchmark") == 0) {
            options->benchmark = true;
            continue;
        }
        if (strcmp(argument, "--alpha") == 0) {
            options->alpha = true;
            continue;
        }
        if (strcmp(argument, "--interlaced") == 0) {
            options->interlaced = true;
            continue;
        }
        if (strcmp(argument, "--bottom-field-first") == 0) {
            options->bottom_field_first = true;
            continue;
        }
        if (index + 1 >= argc) {
            fprintf(stderr, "Missing value for %s\n", argument);
            return false;
        }
        const char *value = argv[++index];
        if (strcmp(argument, "--name") == 0) {
            if (!*value || strlen(value) > 200) {
                fprintf(stderr, "Source name must contain 1–200 UTF-8 bytes.\n");
                return false;
            }
            options->name = value;
        } else if (strcmp(argument, "--seconds") == 0) {
            char *end = NULL;
            errno = 0;
            double seconds = strtod(value, &end);
            if (errno || end == value || *end || !isfinite(seconds) || seconds < 0.1 || seconds > 18000) {
                fprintf(stderr, "--seconds must be between 0.1 and 18000.\n");
                return false;
            }
            options->seconds = seconds;
        } else if (strcmp(argument, "--switch-scan-after") == 0) {
            char *end = NULL;
            errno = 0;
            double seconds = strtod(value, &end);
            if (errno || end == value || *end || !isfinite(seconds) || seconds < 0.1 || seconds > 3600) {
                fprintf(stderr, "--switch-scan-after must be between 0.1 and 3600 seconds.\n");
                return false;
            }
            options->switch_scan_after = seconds;
        } else if (strcmp(argument, "--video-pause-after") == 0 || strcmp(argument, "--video-pause-duration") == 0) {
            char *end = NULL;
            errno = 0;
            double seconds = strtod(value, &end);
            bool duration = strcmp(argument, "--video-pause-duration") == 0;
            double minimum = duration ? 0.001 : 0.1;
            double maximum = duration ? 5.0 : 3600.0;
            if (errno || end == value || *end || !isfinite(seconds) || seconds < minimum || seconds > maximum) {
                fprintf(stderr, "%s must be between %.3f and %.0f seconds.\n", argument, minimum, maximum);
                return false;
            }
            if (duration) options->video_pause_duration = seconds;
            else options->video_pause_after = seconds;
        } else if (strcmp(argument, "--fps") == 0) {
            char *end = NULL;
            errno = 0;
            long numerator = strtol(value, &end, 10);
            long denominator = 1;
            bool valid = !errno && end != value;
            if (*end == '/') {
                const char *denominator_text = end + 1;
                denominator = strtol(denominator_text, &end, 10);
                valid = valid && !errno && end != denominator_text;
            }
            if (!valid || *end || numerator < 1 || numerator > INT32_MAX || denominator < 1
                || denominator > INT32_MAX || numerator > 60LL * denominator || numerator < denominator) {
                fprintf(stderr, "--fps must be 1–60 as an integer or N/D (e.g. 60000/1001).\n");
                return false;
            }
            options->frame_rate_n = (int)numerator;
            options->frame_rate_d = (int)denominator;
        } else if (strcmp(argument, "--port") == 0) {
            char *end = NULL;
            errno = 0;
            long port = strtol(value, &end, 10);
            if (errno || end == value || *end || port < 1 || port > 65535) {
                fprintf(stderr, "--port must be between 1 and 65535.\n");
                return false;
            }
            options->port = (int)port;
        } else if (strcmp(argument, "--silent-channel") == 0) {
            if (strcmp(value, "none") != 0 && strcmp(value, "left") != 0 && strcmp(value, "right") != 0 && strcmp(value, "both") != 0) {
                fprintf(stderr, "--silent-channel must be none, left, right, or both.\n");
                return false;
            }
            options->silent_left = strcmp(value, "left") == 0 || strcmp(value, "both") == 0;
            options->silent_right = strcmp(value, "right") == 0 || strcmp(value, "both") == 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argument);
            return false;
        }
    }
    if ((options->video_pause_after > 0) != (options->video_pause_duration > 0)
        || (options->video_pause_after > 0 && options->video_pause_after + options->video_pause_duration >= options->seconds)) {
        fprintf(stderr, "Video pause requires both options and must finish before --seconds.\n");
        return false;
    }
    if (options->switch_scan_after >= options->seconds
        || (options->bottom_field_first && !options->interlaced && options->switch_scan_after == 0)) {
        fprintf(stderr, "Scan switch must finish before --seconds; field order requires interlaced video.\n");
        return false;
    }
    return true;
}

static void rectangle(uint8_t *pixels, int x, int y, int width, int height, uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha) {
    for (int row = y; row < y + height && row < HEIGHT; ++row) {
        if (row < 0) continue;
        for (int column = x; column < x + width && column < WIDTH; ++column) {
            if (column < 0) continue;
            uint8_t *pixel = pixels + ((size_t)row * WIDTH + column) * 4;
            pixel[0] = blue; pixel[1] = green; pixel[2] = red; pixel[3] = alpha;
        }
    }
}

static void make_background(uint8_t *pixels, bool alpha) {
    static const uint8_t bars[8][3] = {
        {191,191,191}, {191,191,0}, {0,191,191}, {0,191,0},
        {191,0,191}, {191,0,0}, {0,0,191}, {0,0,0}
    };
    for (int y = 0; y < HEIGHT; ++y) {
        for (int x = 0; x < WIDTH; ++x) {
            const uint8_t *color = bars[x * 8 / WIDTH];
            uint8_t *pixel = pixels + ((size_t)y * WIDTH + x) * 4;
            pixel[0] = y < 720 ? color[2] : 24;
            pixel[1] = y < 720 ? color[1] : 24;
            pixel[2] = y < 720 ? color[0] : 24;
            pixel[3] = alpha ? (y < 720 ? (uint8_t)(x * 255 / (WIDTH - 1)) : 64) : 255;
        }
    }
}

static void draw_counter(uint8_t *pixels, uint64_t frame) {
    static const uint8_t digits[10][7] = {
        {14,17,19,21,25,17,14}, {4,12,4,4,4,4,14}, {14,17,1,2,4,8,31},
        {30,1,1,14,1,1,30}, {2,6,10,18,31,2,2}, {31,16,16,30,1,1,30},
        {14,16,16,30,17,17,14}, {31,1,2,4,8,8,8}, {14,17,17,14,17,17,14},
        {14,17,17,15,1,1,14}
    };
    char number[32];
    snprintf(number, sizeof(number), "%06" PRIu64, frame);
    rectangle(pixels, 40, 765, 680, 150, 0, 0, 0, 255);
    for (size_t index = 0; number[index]; ++index) {
        unsigned digit = (unsigned)(number[index] - '0');
        if (digit > 9) continue;
        for (int y = 0; y < 7; ++y) {
            for (int x = 0; x < 5; ++x) {
                if (digits[digit][y] & (1U << (4 - x))) {
                    rectangle(pixels, 64 + (int)index * 84 + x * 12, 798 + y * 12, 12, 12, 255, 255, 255, 255);
                }
            }
        }
    }
}

// A half-frame phase moves the pattern between fields, so this fixture tests
// actual interlaced motion rather than merely setting the transport flag.
static void make_picture(uint8_t *pixels, const uint8_t *background, uint64_t phase,
                         int64_t timestamp, bool alpha) {
    memcpy(pixels, background, (size_t)WIDTH * HEIGHT * 4);
    rectangle(pixels, (int)(phase * 11 / 2 % (WIDTH - 24)), 0, 24, 720, 255, 255, 255, 255);
    rectangle(pixels, 800 + (int)(phase * 7 / 2 % 800), 790, 128, 128, 0, 220, 255, alpha ? 160 : 255);
    uint8_t marker = timestamp % TICKS_PER_SECOND < TICKS_PER_SECOND / 20 ? 255 : 0;
    rectangle(pixels, 1710, 910, 140, 140, marker, marker, marker, 255);
    draw_counter(pixels, phase / 2);
}

static void *send_audio(void *opaque) {
    AudioContext *context = opaque;
    context->scheduling_error = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    if (context->scheduling_error) {
        fprintf(stderr, "Could not set audio scheduling priority: %s\n", strerror(context->scheduling_error));
        atomic_store_explicit(&stop_requested, true, memory_order_relaxed);
        return NULL;
    }
    const uint64_t count = (uint64_t)ceil(context->options->seconds * SAMPLE_RATE / AUDIO_SAMPLES);
    OMTMediaFrame frame = {0};
    frame.Type = OMTFrameType_Audio;
    frame.Codec = OMTCodec_FPA1;
    frame.SampleRate = SAMPLE_RATE;
    frame.SamplesPerChannel = AUDIO_SAMPLES;
    frame.Channels = 2;
    frame.Data = context->pcm;
    frame.DataLength = (int)sizeof(context->pcm);
    for (uint64_t block = 0; block < count && !atomic_load_explicit(&stop_requested, memory_order_relaxed); ++block) {
        uint64_t first_sample = block * AUDIO_SAMPLES;
        int64_t timestamp = (int64_t)(first_sample * (uint64_t)TICKS_PER_SECOND / SAMPLE_RATE);
        sleep_until(context->start_ns + timestamp * 100);
        if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) break;
        int64_t lateness = monotonic_ns() - (context->start_ns + timestamp * 100);
        if (lateness > 20000000) context->late_blocks++;
        if (lateness > context->maximum_lateness_ns) context->maximum_lateness_ns = lateness;
        for (int sample = 0; sample < AUDIO_SAMPLES; ++sample) {
            uint64_t position = first_sample + (uint64_t)sample;
            double time = (double)position / SAMPLE_RATE;
            double marker = position % SAMPLE_RATE < 2400 ? 0.10 * sin(2 * PI * 1000 * time) : 0;
            context->pcm[sample] = context->options->silent_left ? 0 : (float)(0.05 * sin(2 * PI * 440 * time) + marker);
            context->pcm[AUDIO_SAMPLES + sample] = context->options->silent_right ? 0 : (float)(0.05 * sin(2 * PI * 660 * time) + marker);
        }
        frame.Timestamp = timestamp;
        omt_send(context->sender, &frame);
        context->blocks++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    Options options;
    if (!parse_options(argc, argv, &options)) { usage(argv[0]); return 2; }
    // This is live media, including the SDK workers created by this thread.
    // Default-priority timer coalescing can outlast a receiver's playback lead.
    int scheduling_error = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    if (scheduling_error) {
        fprintf(stderr, "Could not set live sender scheduling priority: %s\n", strerror(scheduling_error));
        return 1;
    }

    // The wrapper sets this before process launch as well, protecting even SDK
    // library initialization. A direct invocation gets an isolated fallback.
    char storage_template[] = "/tmp/omt-official-sender-storage.XXXXXX";
    bool owns_storage = false;
    if (!getenv("OMT_STORAGE_PATH") || !*getenv("OMT_STORAGE_PATH")) {
        if (!mkdtemp(storage_template) || setenv("OMT_STORAGE_PATH", storage_template, 1) != 0) {
            perror("isolated OMT storage"); return 1;
        }
        owns_storage = true;
    }
    omt_setloggingfilename(NULL);
    omt_setloggingcallback(NULL);
    omt_settings_set_string("DiscoveryServer", "");
    omt_settings_set_integer("NetworkPortStart", options.port);
    omt_settings_set_integer("NetworkPortEnd", options.port);

    const size_t pixel_bytes = (size_t)WIDTH * HEIGHT * 4;
    uint8_t *background = malloc(pixel_bytes), *pixels = malloc(pixel_bytes);
    uint8_t *second_field = options.interlaced || options.switch_scan_after > 0 ? malloc(pixel_bytes) : NULL;
    if (!background || !pixels || ((options.interlaced || options.switch_scan_after > 0) && !second_field)) {
        fprintf(stderr, "Could not allocate test-pattern pixels.\n");
        free(background); free(pixels); free(second_field); omt_shutdown();
        if (owns_storage) rmdir(storage_template);
        return 1;
    }
    make_background(background, options.alpha);
    omt_send_t *sender = omt_send_create(options.name, OMTQuality_Medium);
    if (!sender) {
        fprintf(stderr, "Official SDK could not start the sender on port %d. Choose an unused --port.\n", options.port);
        free(background); free(pixels); free(second_field); omt_shutdown();
        if (owns_storage) rmdir(storage_template);
        return 1;
    }
    OMTSenderInfo info = {0};
    snprintf(info.ProductName, sizeof(info.ProductName), "%s", "OMTReceiver Independent SDK Fixture");
    snprintf(info.Manufacturer, sizeof(info.Manufacturer), "%s", "Local Test");
    snprintf(info.Version, sizeof(info.Version), "%s", "1");
    omt_send_setsenderinformation(sender, &info);
    signal(SIGINT, interrupted);
    signal(SIGTERM, interrupted);

    char address[OMT_MAX_STRING_LENGTH] = {0};
    omt_send_getaddress(sender, address, (int)sizeof(address));
    printf("Source: %s\nManual local address: omt://127.0.0.1:%d\n", address, options.port);
    printf("1080 %d/%d complete frames/s, %s, %s field first, BGRA%s, Medium, stereo48k/960; duration %.3fs; storage %s\n",
           options.frame_rate_n, options.frame_rate_d, options.interlaced ? "interlaced" : "progressive",
           options.bottom_field_first ? "bottom" : "top", options.alpha ? " straight alpha" : " opaque",
           options.seconds, getenv("OMT_STORAGE_PATH"));
    fflush(stdout);

    AudioContext audio = { .sender = sender, .options = &options, .start_ns = monotonic_ns() };
    pthread_t audio_thread;
    int thread_error = pthread_create(&audio_thread, NULL, send_audio, &audio);
    if (thread_error) {
        fprintf(stderr, "Audio thread failed: %s\n", strerror(thread_error));
        omt_send_destroy(sender); omt_shutdown(); free(background); free(pixels); free(second_field);
        if (owns_storage) rmdir(storage_template);
        return 1;
    }

    OMTMediaFrame frame = {0};
    frame.Type = OMTFrameType_Video;
    frame.Codec = OMTCodec_BGRA;
    frame.Width = WIDTH; frame.Height = HEIGHT; frame.Stride = WIDTH * 4;
    frame.FrameRateN = options.frame_rate_n; frame.FrameRateD = options.frame_rate_d;
    frame.AspectRatio = (float)WIDTH / HEIGHT;
    frame.ColorSpace = OMTColorSpace_BT709;
    frame.Flags = options.alpha ? OMTVideoFlags_Alpha : OMTVideoFlags_None;
    frame.Data = pixels; frame.DataLength = (int)pixel_bytes;
    uint64_t frames = 0;
    bool video_pause_applied = false;
    int64_t maximum_video_lateness_ns = 0;
    uint64_t video_late_frames = 0;
    int64_t next_report_ns = audio.start_ns + 5000000000LL;
    const uint64_t frame_count = (uint64_t)ceil(options.seconds * options.frame_rate_n / options.frame_rate_d);
    for (uint64_t index = 0; index < frame_count && !atomic_load_explicit(&stop_requested, memory_order_relaxed); ++index) {
        // Split before multiplying by ticks: full Int32 rate terms can overflow
        // index * ticks * denominator even during this bounded five-hour run.
        const uint64_t time_numerator = index * (uint64_t)options.frame_rate_d;
        const uint64_t rate_numerator = (uint64_t)options.frame_rate_n;
        int64_t timestamp = (int64_t)((time_numerator / rate_numerator) * (uint64_t)TICKS_PER_SECOND
            + (time_numerator % rate_numerator) * (uint64_t)TICKS_PER_SECOND / rate_numerator);
        sleep_until(audio.start_ns + timestamp * 100);
        if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) break;
        if (!video_pause_applied && options.video_pause_after > 0
            && (double)timestamp / TICKS_PER_SECOND >= options.video_pause_after) {
            video_pause_applied = true;
            int64_t pause_start = monotonic_ns();
            printf("{\"type\":\"fixture-video-pause\",\"phase\":\"began\",\"elapsedSeconds\":%.6f,\"requestedSeconds\":%.6f}\n",
                   (double)(pause_start - audio.start_ns) / 1000000000.0, options.video_pause_duration);
            fflush(stdout);
            // Only the video producer waits. The separate audio thread and SDK
            // transport continue, preserving monotonic PTS through the delay.
            sleep_until(pause_start + (int64_t)(options.video_pause_duration * 1000000000.0));
            printf("{\"type\":\"fixture-video-pause\",\"phase\":\"ended\",\"elapsedSeconds\":%.6f}\n",
                   (double)(monotonic_ns() - audio.start_ns) / 1000000000.0);
            fflush(stdout);
            if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) break;
        }
        int64_t lateness = monotonic_ns() - (audio.start_ns + timestamp * 100);
        if (lateness > 1000000000LL * options.frame_rate_d / options.frame_rate_n) video_late_frames++;
        if (lateness > maximum_video_lateness_ns) maximum_video_lateness_ns = lateness;
        make_picture(pixels, background, index * 2, timestamp, options.alpha);
        bool switched = options.switch_scan_after > 0 && (double)timestamp / TICKS_PER_SECOND >= options.switch_scan_after;
        bool interlaced = options.interlaced != switched;
        if (interlaced) {
            int64_t half_frame = TICKS_PER_SECOND * options.frame_rate_d / (2LL * options.frame_rate_n);
            make_picture(second_field, background, index * 2 + 1, timestamp + half_frame, options.alpha);
            // The first instant occupies one parity, the later instant the other.
            int later_parity = options.bottom_field_first ? 0 : 1;
            for (int row = later_parity; row < HEIGHT; row += 2) {
                memcpy(pixels + (size_t)row * WIDTH * 4,
                       second_field + (size_t)row * WIDTH * 4, (size_t)WIDTH * 4);
            }
        }
        frame.Flags = (options.alpha ? OMTVideoFlags_Alpha : OMTVideoFlags_None)
            | (interlaced ? OMTVideoFlags_Interlaced : OMTVideoFlags_None);
        frame.Timestamp = timestamp;
        // libomt consumes/encodes the caller's raw buffer synchronously and
        // retains its own encoded network buffers. Reuse only after return.
        omt_send(sender, &frame);
        frames++;
        int64_t report_now = monotonic_ns();
        if (options.benchmark && report_now >= next_report_ns) {
            OMTStatistics stats = {0};
            omt_send_getvideostatistics(sender, &stats);
            printf("{\"type\":\"sender\",\"elapsedSeconds\":%.6f,\"videoOffered\":%" PRIu64
                   ",\"audioBlocksOffered\":%" PRIuFAST64 ",\"maximumVideoLatenessMs\":%.3f,\"maximumAudioLatenessMs\":%.3f"
                   ",\"videoLateOverFramePeriod\":%" PRIu64 ",\"audioLateOverBlockPeriod\":%" PRIuFAST64
                   ",\"frameRateN\":%d,\"frameRateD\":%d"
                   ",\"sdkVideoFrames\":%" PRId64 ",\"sdkVideoDropped\":%" PRId64
                   ",\"sdkVideoCodecMilliseconds\":%" PRId64 ",\"connections\":%d}\n",
                   (double)(report_now - audio.start_ns) / 1000000000.0, frames,
                   atomic_load_explicit(&audio.blocks, memory_order_relaxed), maximum_video_lateness_ns / 1000000.0,
                   atomic_load_explicit(&audio.maximum_lateness_ns, memory_order_relaxed) / 1000000.0,
                   video_late_frames, atomic_load_explicit(&audio.late_blocks, memory_order_relaxed),
                   options.frame_rate_n, options.frame_rate_d, stats.Frames, stats.FramesDropped, stats.CodecTime, omt_send_connections(sender));
            fflush(stdout);
            next_report_ns = report_now + 5000000000LL;
        }
    }
    pthread_join(audio_thread, NULL);
    OMTStatistics video_stats = {0}, audio_stats = {0};
    omt_send_getvideostatistics(sender, &video_stats);
    omt_send_getaudiostatistics(sender, &audio_stats);
    printf("Finished: offered video=%" PRIu64 " audioBlocks=%" PRIu64 " connections=%d\n",
           frames, audio.blocks, omt_send_connections(sender));
    printf("Scheduler maximum lateness: video=%.3fms audio=%.3fms; video codec=%" PRId64 "ms; SDK bytes video=%" PRId64 " audio=%" PRId64 "\n",
           maximum_video_lateness_ns / 1000000.0, audio.maximum_lateness_ns / 1000000.0,
           video_stats.CodecTime, video_stats.BytesSent, audio_stats.BytesSent);
    fflush(stdout);
    // Both application threads have stopped before SDK destruction/shutdown.
    // Raw video buffers also remain allocated through destruction.
    omt_send_destroy(sender);
    omt_shutdown();
    free(background); free(pixels); free(second_field);
    if (owns_storage) rmdir(storage_template);
    return audio.scheduling_error ? 1 : 0;
}
