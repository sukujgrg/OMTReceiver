# Hardware observations

Recorded 23 October 2026 on a first-generation Apple TV 4K (A10X), tvOS 26.6.
These observations do not establish a general production or NDI performance claim.

## Current candidate: 1.0.0 (3)

Build 3 contains compiler-warning repairs and OBS zero-aspect compatibility. Its
unit/UI tests and a live OBS 720p30 smoke check passed, and the operator confirmed
working picture and audio. The sustained screening figures below belong to build
2. Build 3 has not had a fresh 30-minute screening run. Sienna's interlaced preset
was correctly rejected; its Progressive setting still needs a playback check.
See [preparation evidence](../AppStore/VALIDATION.md).

## Build 2 sustained screening

Build 2 passed every instrumented runtime screening target in a **30.33-minute**
run on the first-generation Apple TV 4K, with **1080p SDR 60 Hz HDMI output**.
The sender was the unchanged original SDK fixture on Ethernet, using one opaque
1920×1080p60 Medium-quality pattern and stereo 48 kHz FPA1 audio. Its media sockets
were verified on Ethernet. A separate post-repair physical spot check confirmed
smooth motion and clean audio between the regular marker beeps. The sustained
run was instrumented, without continuous human observation.

| Metric | Build 2 normal sustained result |
| --- | --- |
| Receiver measurement | 1,820.00 s; 109,200 admitted frames; 59.999998 fps |
| Missing source positions in measured interval | 0 |
| Native renderer window | 1,815.00 s; 108,900 frames |
| Native drops / corruption | 1 (0.000918%); 0 corrupted |
| Native estimated cadence | 59.999479 fps |
| Audio deadline / route-horizon violations | 0 / 0 |
| Audio timestamp discontinuities / A/V timeline resets | 0 / 0 |
| Connection attempts / reported failures | 1 / 0 |
| Decode time, including startup | Mean 4.97 ms; p95 ≤8 ms; p99 ≤10 ms; maximum 43.96 ms |
| CPU | Mean 68.1% of one core |
| Post-warmup memory | 52.45–52.70 MiB; early/late means 52.64/52.54 MiB |
| Thermal state | Nominal throughout |
| Measured TV reports | 365; one process; largest report gap 5.037 s |

There were no measured ingress/playback coalescences, decoder-pool stalls,
reconnects or collection errors. One coalesced video arrival before the initial
playing baseline remains in the raw startup data. Sender logs reported no SDK
video drops or producer deadlines missed by a full video/audio period. Admission
and native statistics use separate windows. Decode extrema include startup.
The scheduling stability flag remained clear; physical panel cadence and
end-to-end latency were not measured.

### Freeze reproduction and repair

Hardware checks on build 1 exposed a video-only freeze after a transient delay.
The source and audio continued, but video admission stopped about 1,006 seconds
into the measurement. The operator confirmed that the remote was untouched and
that audio remained audible while the picture was frozen. That 30.42-minute run
failed qualification, despite recording zero native drops: an empty renderer
cannot establish successful playback. Admission averaged only 33.01 fps over
the full interval. The run recorded one video timeline reset, 37 late audio
packets and 75 audio route-horizon warnings. The source reported 123 SDK drops
near the incident; the underlying transient's cause is not established.

A delayed, still-monotonic video packet was incorrectly treated as a new clock
origin. Retiming that old queue head could leave every later frame beyond the
bounded queue's decode window indefinitely. Build 2 retains the common source
clock through monotonic transport delays. Independent first-lane origins,
backward timestamps and large future discontinuities still have their existing
recovery behavior. Background enqueue, readiness, status and flush operations
also now use AVSampleBufferVideoRenderer rather than the UI display layer.

The new controlled regression admitted **zero** recovered video frames over five
seconds before the repair. The repaired timing/queue suite passed all 19 tests.
The full ordinary suite passed 63 unit tests and two UI tests; the optional real
SDK fullscreen/Back/Play/Pause UI test also passed separately.

The same physical Apple TV then received a deliberately injected 600 ms
video-only producer pause, with audio and SDK transport left running:

| Receiver build | Post-pause admission | Video timeline resets | Connection attempts | Late audio packets |
| --- | --- | --- | --- | --- |
| 1 | 0 fps for the 65.00 s observation window | 1 | 1 | 0 |
| 2 | 59.9892 fps over 35.01 s | 0 | 1 | 0 |

This reproduces the original failure and verifies recovery on the device without
requiring a reconnect. It deliberately disturbs video deadlines and SDK queues;
it is **not** a sustained performance qualification. Its native counters are not
a new physical panel or listening measurement. The fixture's optional video-pause
arguments are documented in [the fixture guide](../Tools/README.md); normal runs inject no delay.

A separate orderly source shutdown/restart check also passed. The receiver
detected the socket closure, retried while the source was unavailable, and
resumed about 60 fps in the same process after the sender returned at the same
address. No remote input, audio deadline fault or timeline reset was needed.
This intentionally interrupted session is separate from sustained qualification.

Build 2's 4K HDMI output has not been requalified; the exact HDMI refresh periods
remain unmeasured. The current screened 60 fps configuration uses 1080p HDMI
output. In a separate **150.00-second** post-repair 1080p60 check, the receiver
admitted 9,001 frames at 60.006 fps, with no missing source positions or audio
timing faults. Its separate 145.00-second native window had 8,701 frames with
zero drops or corruption. There was one connection attempt and no reported
failure or timeline reset. The operator confirmed smooth picture and clean audio
between the marker beeps. This short regression and physical spot check does not
replace sustained qualification or continuous observation of the earlier run.

## Release 1.0.0 (1) pre-TestFlight checks

The signed Release build was installed without a debugger. One Ethernet-connected
Mac sent a 1920×1080 opaque VMX test pattern using official OMT SDK 1.0.0.19,
Medium quality and stereo 48 kHz FPA1 audio. The sender link was 100 Mb/s full
duplex. Media sockets were verified to use its Ethernet address. The receiver
was also on Ethernet. The operator initially confirmed a 4K SDR 60 Hz HDMI
format, then selected 1080p SDR 60 Hz for an output-format comparison. The stream
itself remained 1080p throughout. The exact HDMI refresh periods were not measured.

| Source rate | HDMI format label | Measured interval | Admission fps | Missing source positions | Native renderer drops / frames | Native estimate |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | 4K SDR 60 Hz | 120.00 s | 29.9995 | 0 / 3,600 | 0 / 3,450 (0%) | 29.9983 fps |
| 60000/1001 | 4K SDR 60 Hz | 120.00 s | 59.9395 | 0 / 7,193 | 4 / 6,893 (0.0580%) | 59.9035 fps |
| 60 | 4K SDR 60 Hz | 1,820.00 s (30.33 min) | 60.0000 | 0 / 109,200 | 119 / 108,900 (0.1093%) | 59.9341 fps |
| 60 | 1080p SDR 60 Hz | 120.00 s | 59.9904 | 0 / 7,199 | 0 / 6,900 (0%) | 60.0008 fps |

Admission and native renderer counters have separate windows. The native windows
were 115.01 s, 115.00 s, 1,815.01 s and 115.00 s respectively. Native estimates are renderer
statistics, not independently measured physical panel cadence or HDMI latency.
The two-minute trials are regression checks, not sustained qualifications.

The 60 fps trial with 4K HDMI output completed the requested interval with one connection attempt,
no receiver failures, no missed source positions, no playback coalescences or
decoder-pool stalls, no audio deadline or route-horizon violations, and no audio
or video timeline resets. All 365 measured five-second reports were retained.
One controlling-Mac copy poll failed and recovered; the complete TV series had
no gap beyond its normal five-second interval. Sender logs reported zero SDK
video drops and no video/audio producer deadlines missed by a full block period.

Decode time, including startup, averaged 5.60 ms; p95 was at most 8.75 ms and
p99 at most 10.00 ms. The exact maximum was 55.71 ms. CPU averaged 72.5% of one
core. Thermal state remained nominal. After warmup, memory ranged from 53.03 to
53.24 MiB; the early/late means were 53.14/53.13 MiB. Scheduled lead did not trip
the stability flag. None of these figures measures source-to-panel latency.

The operator reported smooth motion and clean audio for the 30 fps check and
in early and near-end 60 fps spot checks. This is physical listening/viewing
evidence at those points, not a continuous recording.

**The sustained 60 fps trial with 4K HDMI output did not pass every screening target.** The native renderer's
0.1093% drop rate exceeded the existing strict 0.1% target. This was the only
failed runtime target. Admission remained at 60 fps while the native estimate
stayed near 59.94 fps. Switching to 1080p SDR 60 Hz eliminated native drops in
the two-minute comparison, with no audio timing faults or receiver retries. This
points to an output-format dependency; it does not distinguish a fractional
refresh mismatch from scaling or other native presentation behavior. The short
comparison is not a sustained qualification. The existing target remains in place.

The operator also confirmed that mute/unmute, the About/privacy reader and Back,
Reconnect, Disconnect/reselection, and actual sleep/wake recovery worked with the
physical remote. Audio stopped during sleep and resumed cleanly. The mixed
interaction run recorded a suspended state and a successful new receive attempt
in the same process, with memory falling to about 19 MiB while suspended. It also
recorded coalesced video and one audio route-horizon warning during the interaction
window. It is retained as lifecycle evidence and excluded from sustained metrics.

The first automatic benchmark launch immediately after the format change
exported only an initial idle report and was marked incomplete. A separate fresh
launch completed the comparison above. The initial startup cause is unconfirmed;
its incomplete evidence is retained separately.

## Earlier prototype trials

| Trial | Duration | Receiver admission | Result |
| --- | --- | --- | --- |
| Different Mac over Wi-Fi to Ethernet TV | 30.33 min | 27.54 fps average | Degraded toward 20 fps; investigation remains open |
| Ethernet sender to Ethernet TV, earlier 30 fps implementation | 30.42 min | 29.99 fps average | Passed the then-current single-stream screening targets |
| 60 fps queue/preroll comparison | 95 s, interrupted | 59.97 fps | Sustained qualification was pending |

The earlier wired 30 fps trial missed 19 of 54,751 source positions (0.0347%). Its
native-renderer window had six dropped and zero corrupted frames. Audio was
heard clean in early and near-end spot checks. That run predates the compressed
queue and time-based preroll used in the Release checks above.

The interrupted 60 fps comparison had a separate 65-second native window with
3,900 frames and four drops (0.1026%). It was not a screening pass.

## Limits

The HDMI-aware schedule initially has about 221 ms lead on the tested route.
Time-based decoded preroll preserves 133 ms for native preparation within that
schedule. Neither number measures physical source-to-panel latency.

Raw captures, source addresses, hardware identifiers, original photos and local
build logs remain private. This repository publishes aggregate observations.
Physical end-to-end latency, 4K decoding, multiview, complex-content qualification,
other audio routes and a controlled NDI comparison are not established. The
current build-2 instrumented result is a screening pass, accompanied by a
separate successful operator picture/audio spot check.
