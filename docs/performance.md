# Hardware observations

Recorded 23–24 October 2026 on a first-generation Apple TV 4K (A10X), tvOS 26.6.
These observations do not establish a general production or NDI performance claim.

## Current candidate: 1.0.0 (5)

Build 5 adds a compact source strip while retaining one receive/playback session.
Browsing leaves the active connection alone; reselecting the current live source
does not reconnect. On 24 October, a physical Siri Remote automation completed
40 consecutive switches between two independent SDK 1080p30 sources, including
browsing cancellation, current-source reselection, favourite changes and settings
navigation. The Mac sender used Wi-Fi. The suite passed 95 unit tests and two
ordinary simulator UI tests; three sender-dependent checks are opt-in. The new
reselection regression also passed ten repetitions after its fixture was made to
wait for both initial media lanes.

A short Release 1080p60 smoke check collected 95.0 seconds in one app process and
one connection attempt, at 60.002 admitted fps. Its separate 90.0-second native
window recorded 5 drops in 5,400 frames (0.0926%), zero corruption, no late audio,
no decoder-pool stalls and nominal thermal state. This confirms the collection
path and basic playback, not sustained performance or physical audible/panel
continuity. The coordinated eucaly results below use its real output path and
supplied video files. Earlier sustained figures below belong to build 2.

### Eucaly dual-output stability investigation

The real eucaly OutputCoordinator, shared player/audio pipeline and independent
network helpers fed this Apple TV and a native NDI receiver on the separate
monitor Mac. The sender used Wi-Fi and the remote receiver used Ethernet.
Output was 1080p30 Medium VMX, stereo 48 kHz FPA1. The host was an isolated,
optimized Debug test product. GUI rendering, physical speaker output and
source-to-panel latency were not measured.

A real NDI helper SIGPIPE crash on receiver attachment was reproduced and fixed
by eucaly's agent. The closed-socket regression and subsequent real receiver
attachment/reconnection passed. Content changes, Preview, Hide/Show, workspace
transfers and deliberate helper crash/Retry were exercised separately; recovery
retained the companion helper. Fault-phase interruptions remain separate from
the clean measurements.

OMT loss was associated with a full 64 KiB TCP send buffer and SDK pool
rejections. Matched upstream builds retained the four-slot pool and image
quality. The 64 KiB arm admitted 3,523 frames / 184.999 seconds (19.043 fps),
with two audio timestamp gaps. The 256 KiB arm admitted 5,346 / 180.003 seconds
(29.700 fps), with no audio timestamp gaps; it still missed the 29.9 fps target.
Common source positions 100–210 seconds improved SDK enqueue cadence from
16.371 to 29.564 fps, with 1,496 versus 34 rejections. Producer replacements
are not subtractable frame losses because a publisher can reuse its current
picture. A separate 256 KiB trace found the video socket full in 321 of 1,199
samples, motivating the bounded 512 KiB candidate.

The final candidate also repairs a rented socket-send slot leak when submission
fails synchronously. The original pool failed both failure-path regressions;
all four bounded real-socket regressions passed after repair. The tested release
and current-upstream fork branches passed managed builds with zero diagnostics.
Source patches, original and normalized patch hashes, byte-identical patch
verification, build provenance and read-only socket diagnostics are retained in
[Upstream/libomtnet](../Upstream/libomtnet/README.md). The fork is cloned under
`~/github/openmediatransport/libomtnet`. No OMT repair commits were pushed and
no PR was opened.

The clean 512 KiB run lasted 1,254.999 seconds: 37,522 admitted frames at
29.898023 fps, one attempt, zero freeze/reconnect/failure, late audio, timestamp
or timeline resets, or decoder-pool stalls. There were 14 playback coalescences
and zero ingress coalescences. The separate 1,250.001-second native window had
5 drops / 37,372 frames (0.013379%) and zero corruption. Post-warmup memory was
48.67–53.78 MiB, with early/late means rising 0.52 MiB; thermal state stayed
nominal. Video lead did not grow; audio early/late lead rose 27.95 ms, within
the existing one-frame stability screen.

**The strict combined screen still failed:** 29.898023 fps is below the
unchanged 29.9 fps target, and two audio admissions crossed the conservative
route horizon. Neither was late by its timestamp. Physical audible continuity
and overall production readiness remain unestablished.

Parallel full-bandwidth NDI capture lasted 1,300.019 seconds: 38,927 video frames,
64,999 audio blocks, zero SDK drops, timestamp gaps, invalid PCM, capture errors
or metadata overflow. Sparse pixel fingerprints changed 37,630 times, with at
most five identical frames. Near-silence meant both channel RMS values below
1e-7, not exact-zero identity: 731 blocks / 14.62 seconds. Every interval aligned
with five EOF/rewind windows. Offline analysis found 2.773 seconds of authored
head/tail silence per wrap. The remaining small alignment/rewind difference
cannot be fully attributed; transport timestamps do not establish gapless
content fidelity.

An observer on/off/on comparison retained the same source/helpers/TV instance.
Pausing only the launcher's process/socket sampler gave essentially unchanged
rates: 29.938 / 29.938 / 29.931 fps in roughly 115-second interior windows.
Different content positions and network timing remain confounders. No observer
or pacing workaround was justified.

Eucaly integrated the two local SDK repairs at `23639de`. Its 1,010-test suite
(six expected skips), signed archive/export, deep/strict signatures and packaged
runtime-load checks passed. These checks do not erase the hardware screen
failure. Evidence is under ignored `build/QuickSwitcher-20261024/`, including
`Eucaly-Clean512k`, the buffer comparison/recovery runs, `Eucaly-ObserverABA512k`
and native `NDIRemote` metadata. The two audio warnings are investigated below.

### Audio route-margin investigation

The two clean-run counter increases occurred within the five-second report
intervals 18:00:37–18:00:42 and 18:01:17–18:01:22 UTC on 23 October. The route
reported 80.00 ms output latency plus a 21.33 ms I/O buffer: a 101.33 ms
conservative horizon. Their minimum admission leads were 101.030 and 93.685 ms,
crossing that horizon by 0.303 and 7.648 ms while remaining ahead of their PTS.
No audio timestamp discontinuity, timeline reset, late packet or pool stall
accompanied either event. Neither interval is an authored-silence/EOF window.

Eucaly's source-side cumulative audio submission-age and SDK-call maxima did not
increase across either interval. The remote NDI capture had 120.990 and
126.681 ms capture-return gaps near the corresponding source blocks, despite
regular sender SDK timestamp steps. The legacy CSV column `receiver_timestamp`
is misleadingly named: it copies NDI's sender-generated SDK submission time,
not receiver arrival time. This is confirmed by the bundled vendor header and
[NDI's frame documentation](https://docs.ndi.video/all/developing-with-ndi/sdk/frame-types).
The probe's monotonic host clock measures capture return on a single A/V capture
thread, so those gaps alone cannot distinguish vendor transport, network,
receiver decoding or capture-thread scheduling. The original TV reports retain
five-second warning brackets rather than exact affected packet identities.

The follow-up adds bounded, opt-in per-event receiver stage timing and uses
eucaly's per-block source/IPC/SDK trace. Scheduling, quality, playback delay and
screening thresholds remain unchanged. The signed Release build and all 99 app
unit tests passed, including transport-versus-main-queue attribution and storage
bounds. The physical Home/source-picker preflight also passed. Its diagnostic
capture is retained under `build/QuickSwitcher-20261024/AudioTiming-20261024/`.


A later real failure began when the operator's remote NDI Monitor joined the
existing native receiver. Source SDK connection count increased from one to
three; this count does not equal the number of media flows. The TV changed from
zero steady audio warnings to late audio and bounded-queue reconnects. The
20-minute collector completed with 2,309 margin events, 1,524 late packets,
13 within-attempt timestamp discontinuities and 15 connection attempts, at
26.474 admitted fps. One latest-report copy command also failed; the full series
was subsequently retained. This is a failed screening capture.

Stopping only the owned native NDI probe reduced the SDK connection count to two.
The TV recovered and its fault counters stopped increasing. The operator
confirmed that audio in the remaining remote NDI Monitor was now clean. A
bounded 30-second reattachment reproduced the failure and recovered after its
automatic exit. This comparison kept source quality, media, buffers and playback
margins unchanged. Actual NDI UDP media flows were one/two/one:

| Phase | OMT TCP mean RTT | Maximum RTT | TV behavior |
| --- | --- | --- | --- |
| GUI-only baseline | 12.55 ms | 19.69 ms | One startup margin event; no late audio |
| Additional native NDI receiver | 108.30 ms | 168.56 ms | Late audio and reconnects |
| Native receiver removed | 10.48 ms | 15.12 ms | Playback recovered; fault counters stopped |

The 185.002-second comparison recorded 273 additional margin events, 206 late
packets, three timestamp discontinuities and three attempts. Its parallel native
probe recorded 16 audio timecode gaps despite zero SDK dequeue-drop counters.
The first longer native probe had 76 timecode gaps and a 1,671.965 ms maximum
capture-return pause. Zero SDK-reported drops therefore did not establish
continuity. These deliberate load transitions remain separate from the earlier
unchanged-load run.

Exact source-block matching found regular 960-sample PCM, prompt application/IPC
handoff and synchronous SDK calls through the failure. Key packets spent about
1–6 ms between receiver parser completion and renderer admission. Source API
calls alone did not prove enqueue acceptance, because the original sender ignored
audio return codes. Eucaly's agent added raw OMT audio return bytes, bounded
per-block trace fields and first-audio-channel enqueue/drop counters, with 26
focused real-SDK/helper tests and independent review. Zero remains legitimate
without an audio subscriber; positive bytes mean at least one matching channel
enqueue, not delivery to every receiver. NDI's void audio API stays explicitly
unknown. No retry, quality, buffer, clock or latency-margin change was made.

A second 30-second load repeat with the new diagnostics again failed: 482 new
margin events, 407 late packets and six attempts over 185.002 seconds. There
were no within-attempt timestamp discontinuities. The first retained steady
margin event had 86.520 ms lead, an 80.593 ms parser-callback gap and only
0.647 ms local processing; a nearby packet had a 202.361 ms parser gap and
0.633 ms local processing. All 32 retained first margin warnings matched
7,720-byte OMT enqueue returns: five startup events and 27 load events. The
startup events had 60–214 ms receiver playback waits and are a different timing
pattern from the load onset. For the first three load-warning source timestamps
192393200000, 192393400000 and 192394000000, the SDK calls took
0.098, 0.055 and 0.058 ms; their return ages were 36.664, 35.268 and 35.426 ms.
These initial affected blocks were accepted promptly, rather than rejected by
the SDK. Positive enqueue does not establish asynchronous socket completion,
wire delivery or physical playback.

The first subsequent zero return came 1.22 seconds of source time after the
first load warning and coincided with channel removal after receiver failure.
Later reconnected first-audio-channel reports showed separate `FramesDropped`
observations of one and twelve, with additional zero returns. These are later
admission-pressure observations, not a globally monotonic loss count or proof
that every later affected packet was accepted. Across the 205-block onset
window, source/IPC stages were complete with regular 960-sample steps and no
trace overflow. SDK return to local ACK trace, including the new statistics
getter and reporting, stayed below 0.009 ms. Exact joins, input hashes and
limits are retained in eucaly's `audio-warning-trace-02/analysis-transport/`.

Eucaly committed these diagnostics at `97d4009`. Its full checks passed:
1,011 XCTest cases with six expected opt-in skips, one Swift Testing case,
seven update-feed tests and 103 release-workflow tests. Signed archive/export,
deep/strict signatures and finite packaged OMT/NDI runtime-load checks also
passed. Its SDK binary and playback settings were unchanged in this follow-up.

The 512 KiB constant applies to audio as well as video. Normal/recovery socket
samples showed small audio backlog, but the load sampler missed the failure
interval. An attempted aligned repeat stayed idle without starting transport
or the added NDI receiver; it is incomplete setup evidence. It cannot justify
another buffer size. The receiver now retains the first 32 margin events as well
as 32 recent exceptional events, and its summary reports missing event coverage
without weakening cumulative warning counters. All 99 app unit tests, 14 Python
regressions and the final signed Release build passed; build warnings were errors.

The confirmed finding is a reproducible load-triggered delay beyond timely
source enqueue and before receiver parser completion on this Wi-Fi sender path.
Parser callbacks are not physical NIC-arrival measurements: SDK queues, sender
and receiver OS scheduling, the access point and radio path remain unisolated.
The RTT increase supports transport pressure, not a Wi-Fi-only diagnosis.
A matched wired comparison has not been performed; the operator has no cable
for this sender Mac. Further saturation repeats cannot resolve that attribution.
The original two small warnings fit part of this pattern but lack exact
affected-packet records, so their cause remains unproven. Existing short
loopback regressions do not reproduce this full source workload, and no matched
full-pipeline loopback trial was run. The next useful path investigation needs
aligned sender/receiver packet sequence and ACK timing plus queue measurements,
with clock uncertainty and host-capture limitations retained. The send-pool
ownership and SIGPIPE repairs address independent code defects; 512 KiB remains
a bounded performance candidate, not an Ethernet or production qualification. No further
buffer or network-priority tuning was applied.

Hardware collectors, sources and helpers exited; the ordinary receiver launch
was restored and the operator's NDI Monitor was left open. The final failed
alignment and all successful/failing load evidence remain separate under
`AudioTiming-20261024/`. No OMT upstream repair or documentation commit was pushed.

## Build 4 scope

Build 3 contains compiler-warning repairs and OBS zero-aspect compatibility. Its
unit/UI tests and a live OBS 720p30 smoke check passed, and the operator confirmed
working picture and audio. The sustained screening figures below belong to build
2. Builds 3 and 4 have not had a fresh 30-minute screening run. Build 3 rejected
Sienna's interlaced preset; after selecting Progressive, the operator confirmed
that its signal works. Build 4 adds automatic spatial deinterlacing with an
explicit field-order control. Up to 30 complete field pairs per second it emits
both fields; higher pair rates use the selected first field to stay within
60 output pictures per second. Fine vertical detail can be softer. See
[preparation evidence](../AppStore/VALIDATION.md).

## Build 4 interlaced functional checks

The final build automatically received real interlaced VMX from the official
Mac SDK on the same first-generation Apple TV. The low-latency spatial converter
uses both fields at up to 30 complete pairs/s, and the selected first field at
higher pair rates. The first attempt shortened native preparation to 100 ms and
showed excessive native drops despite healthy admission. Reusing the woven
buffer for the first output restored the original 133.33 ms preparation window
within the ten-surface cap.

| Final build-4 check | Receiver measurement | Native renderer measurement |
| --- | --- | --- |
| 30 complete interlaced pairs/s, both fields | 90.002 s; 2,701 input frames / 5,402 output samples; 60.021 submitted fps | 85.005 s; 26 drops / 5,102 frames (0.510%); zero corruption |
| 60 complete interlaced pairs/s, first field; then progressive60 | 120.003 s; 7,199 input frames / output samples; 59.990 submitted fps | Interlaced: 22 / 3,599 drops (0.611%) over 60.000 s; stable progressive: 2 / 2,400 (0.0833%) over 39.996 s; zero corruption |

Each final run used one connection attempt, with no receiver failures, decoder
pool stalls, audio deadline/route-horizon violations, timestamp discontinuities
or timeline resets. The scan switch preserved the same connection, process,
timestamps and audio schedule. Its run recorded three ingress coalescences and
one playback coalescence. The two-field run's final mean decode was 6.90 ms,
p95 ≤11.25 ms; the mixed first-field/progressive run averaged 4.43 ms, p95
≤7.25 ms. These are decode/admission and native counters, not physical panel
cadence or source-to-panel latency.

**These short interlaced runs are not performance qualification passes.** Their
native drop rates exceed the existing 0.1% screening target. The controlling Mac
also missed source-producer deadlines: maximum video lateness reached about
329 ms during the two-field check and 350 ms during the mixed run. During active reception, the SDK's frame count advanced and its dropped-frame
counter stayed at zero. The producer separately reported 41 and 57 video calls
more than one frame interval late in the respective runs. Zero SDK-reported
frame loss does not establish steady production or zero native receiver drops.
Native drop
bursts occurred in these disturbed runs; the remaining drops cannot be assigned
to the receiver alone. They used this Mac as sender to the Ethernet-connected
TV, rather than repeating the earlier fully wired qualification. A clean-source,
fully wired sustained interlaced run remains pending. Source and renderer
windows are separate; the reported drop bursts have not been excluded.

After these instrumented checks, the operator selected Sienna OMT Signal
Generator with 1920×1080, 60 FPS, Interlaced and 4:2:2 8 Bit, and confirmed working
picture and audio on the final installed build. This is a physical spot check
and direct interoperability evidence, separate from the timed SDK runs.

The independent unit/native/remote tests cover both field orders, field-pixel
correctness, fractional cadence, alias/canary safety, scan transitions and the
global surface budget. Earlier preliminary prototypes and failed captures remain
preserved. See [preparation evidence](../AppStore/VALIDATION.md) for artifact
locations and review results.

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
