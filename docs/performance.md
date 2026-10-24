# Hardware observations

Recorded 23–25 October 2026 on a first-generation Apple TV 4K (A10X), tvOS 26.6.
Application validation was followed up on 25 October 2026.
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

### Stock SDK and application pacing reassessment

The maintainer closed libomtnet PRs
[#62](https://github.com/openmediatransport/libomtnet/pull/62) and
[#63](https://github.com/openmediatransport/libomtnet/pull/63), questioning the
public-API impact of the slot test and recommending investigation of sender
pacing. The earlier recommendation below to retain both transport patches is
superseded by this reassessment. No push or upstream reply was made during it.

Pristine SDK 1.0.0.19 (`5395139`) and 1.0.0.20 (`7d29031`) each passed 24
public-API recovery cycles: eight receiver disposals/recreations, eight receiver
process kills/replacements and eight sender restarts with a persistent receiver
reconnecting by name. The harness uses the compiled library, real VMX/FPA1,
private loopback discovery and decoded A/V freshness checks. There were zero
media-channel drops and no omitted call records. No send/pool exception occurred;
the runs do not exhaust rare synchronous-failure races, qualify memory or test
full-rate transport. No persistent capacity-loss failure was reproduced.
See [the reproducible harness](../Upstream/libomtnet/public-api-tests/README.md).

Eucaly's actual submission worker had a separate pacing bug: a delayed repeating
timer could issue closely spaced SDK calls while catching up. A bounded 95 ms
owner-queue stall reproduced a 5.626459 ms interval between real stock-SDK video
entries. Recording adapters also reproduced sub-frame intervals while preserving
the synchronous and borrowed-buffer contracts. Eucaly's agent replaced the
repeating timer with guarded one-shot scheduling. The final policy preserves a
nominal 30 Hz phase while enforcing the existing 32.333333 ms actual-entry floor
(one frame period minus the unchanged 1 ms jitter allowance). It skips obsolete
opportunities after stalls. Actual host timestamps, the audio clock, queue bounds
and NDI buffer leases are preserved.

The initial strict entry-anchored repair passed a short local check but failed
the longer physical cadence screen below. A valid actual-worker regression then
showed ordinary sub-millisecond wake lateness accumulating to 29.365847 fps.
The final phase policy passes that unchanged 29.9 fps gate and all 11 focused
cases; its separate local stock-SDK check recorded 1,797 calls at 29.949955 fps,
with 32.365042–78.131542 ms spacing and complete positive-return traces. The historical
eight rejection calls had immediate-predecessor spacing of 33.26–33.40 ms; the new
finding does not establish their cause.

Managed public-API direct-URL tests with both sender-object and sender-process
replacement passed eight cycles per SDK version. A separate native-helper
sequence missed its four-second DEBUG probe budget after rapid source restarts.
A minimal program using only the public native C API reproduced delayed recovery
at 5.139 seconds, then 5.054 seconds with child descriptor inheritance excluded.
The latter run's preceding cycles recovered at 10/1,074/998 ms. One persistent
receiver resumed fresh decoded video without recreation; there is no reproduced
permanent capacity loss. These arms send the same opaque terminal picture,
destroy the sender, shut down the SDK and immediately exit the source process.
A single-variable comparison with normal process exit also recovered late at
5.105 seconds on its eighth cycle, after seven recoveries in 14–987 ms. Changing
the helper's exit path is not supported by these results.

The existing four-second loopback budget is a DEBUG diagnostic, not an SDK
reconnect guarantee or a production incoming-receiver timeout (eucaly currently
ships an OMT sender). Eucaly's new functional retained-receiver fixture uses a
separate eight-second recovery budget based on the SDK's five-second keepalive,
one-second connect retry and slack, while reporting first-frame timing against
the original four-second target separately. Ordinary probes retain their
original budget. This does not turn the observed four-second misses into passes,
identify the precise delay mechanism, or qualify all disconnect races. No sender
linger, receiver recreation workaround or speculative SDK patch was added.

The final scoped verification passed 34 executions with one opt-in skip; it
retained two first-frame observations at 5.211/5.235 seconds as four-second
diagnostic misses. The initial full app run executed 1,071 cases with seven
skips and four failure assertions in two pre-existing keyboard-focus test setups. Both
failed to activate the app/make its window key before their behavior checks;
read-only session inspection confirmed the local Mac was screen-locked with
loginwindow in front. All network suites passed, including retained-receiver
recovery at 5.266 seconds, explicitly marked beyond the four-second target.
That locked-session run is retained as a failure. No unrelated test or activation
behavior was changed to bypass that condition.

On 25 October, after the user unlocked the local Mac, both unchanged focus tests
passed individually and in the full suite's normal order. The new full
`make test` run passed: 1,071 XCTest cases executed, seven opt-in skips and zero
failures, plus the separate one-test Swift Testing suite. Retained-receiver
first-frame times were 236.219/914.150/5,244.965 ms; the final observation is still
explicitly a four-second diagnostic miss while meeting the separate eight-second
functional budget. No source or runtime changes were needed. This closes the
keyboard-focus validation gap; the reconnect and broader qualification limits
above remain unchanged.
Eucaly committed the validation-only follow-up locally as `4b28e73`; its
application code remains `6ec6155`. Neither commit was pushed.

Eucaly saved the integrated work locally as `6ec6155` (no push). Its final
`make build` archive/export, finite OMT/NDI runtime checks, deep/strict signatures,
vendor hashes/notices and stock-SDK executable-text comparison all passed after
the DEBUG recovery-budget change. The application working tree is clean. Root
reproducers are committed separately; this investigation does not change the
OMTReceiver runtime. Neither the SDK fork nor upstream received a new push or
reply during this reassessment.

A separate audio-frame-metadata probe fails on both stock SDK versions: XML
metadata overwrites the first PCM words, and the advertised metadata tail is
zero. Eucaly supplies no audio frame metadata, so this does not affect its
current output path or explain the historical warnings/rejections. The separate
failing probe is retained; the stock source remains unchanged.

The fresh wired comparison used gigabit Ethernet at both Macs (the remote Mac
had previously negotiated 100 Mbps), one GUI NDI Monitor, one native Dell window
and this OMT TV. All arms used the same unmodified 1.0.0.19 build, codec, movie
and optimized Debug application path, with different submission-worker timers.
This topology is not a matched repeat of the historical buffer comparison.
The first pair's preserved helpers still label the runtime `+eucaly.1`; identical
stock runtime SHA-256 values and product manifests establish its actual identity.
The final helper has the corrected stock version label.

The full source traces captured natural old-timer OMT gaps as short as 9.788 ms;
the initial strict repair's minimum was 33.348 ms. In approximate first-pass
movie ranges 140–210 seconds, the old timer had 2,067 positive SDK calls at
29.927338 fps, versus 2,066 at 29.861124 fps after the initial repair. The actual
checkpoint boundaries differ slightly; these are source entry rates, not TV or
native presentation counts.

| Receiver observation | Repeating timer | Initial strict one-shot | Final phase clock |
| --- | ---: | ---: | ---: |
| Measured interval | 184.995 s | 484.994 s | 605.001 s |
| Video admission | 29.936023 fps | 29.845752 fps | 29.910716 fps |
| Admitted audio blocks | 9,250 | 24,250 | 30,251 |
| Route warnings / late audio / timestamp gaps | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Connection attempts / failures | 1 / 0 | 1 / 0 | 1 / 0 |
| Post-warmup memory mean change | +0.026 MiB; 13 samples | +0.043 MiB; 74 samples | −1.637 MiB; 97 samples |
| Separate TV renderer drops / frames | 1 / 5,388 | 0 / 14,325 | 1 / 17,946 |
| Applicable runtime targets met | 22 / 23 | 21 / 23 | 23 / 23 |

The short control lacks the required 24 memory samples; its memory target is
unestablished. The longer initial repair fails both video admission and output
sample cadence targets at the unchanged 29.9 fps threshold. It does not pass the
combined screen. Sender counters place the cadence deficit before delivery,
with zero observed SDK video drops. The strict deadline can accumulate timer
wake delays. The largest source entry gap, 223.269 ms, includes 223.235 ms inside
the preceding synchronous video-send boundary; it is not primarily timer wait.
The bridge, SDK, codec or OS origin of that stall is not isolated. The final phase
run passes all 23 runtime targets with the same stock runtime. Its complete source
trace has 23,889 live OMT calls, minimum spacing 32.354125 ms and zero entries below
the unchanged floor. The first actual post-seek common range has 2,049 positive
OMT calls at 29.965227 fps. Its checkpoint boundaries differ from the first pair.
None of the arms has audio timeline resets or decoder pool stalls; the final
renderer has zero corrupted frames. These are bounded steady-output results,
not a reconnect pass or general production sign-off.
Native-window readiness and shared-player progress do not measure
native scanout cadence; continuous listening and physical latency were not
measured.

Both first-pass movie regions around 140–210 seconds fall inside the retained TV
intervals. The seek ACKs occur after the TV baselines (09:37:39Z for the control,
09:42:45Z for the initial repair), so these are not intervals starting exactly
at movie position 100. All owned source windows/helpers and physical keep-awake
jobs stopped normally by 09:50:29Z, before the 09:54:27Z device deadline; the TV
was restored to the ordinary app and Monitor was set to None.

The newly authorized final run's seek ACK is 10:31:12Z, after its 10:30:38Z TV
baseline. Its first actual post-seek common checkpoints cover movie positions
140.775–209.153 seconds. Physical keep-awake jobs and Monitor subscription were
released by 10:41:00Z; source windows/helpers retired normally at their authorized
automatic cutoff of 10:41:06Z, before the 10:41:36Z hard deadline. The explicit
finish request was not acknowledged before automatic retirement.

Evidence is under ignored `build/StockSDK-20261024/` and eucaly's
`build/OMTStockSDK-20261024/`. The remaining historical observations retain their
original runtime, network and measurement scope.

### Restart delay investigation, 25 October

The five-second native Mac wait was reproduced with pristine SDK 1.0.0.19 and
TCP-header capture on one isolated loopback port. The two probes first decoded
fresh video after 4.972 and 4.989 seconds. Exact child retirement completed
before replacement; there was no application sleep of that length.

The full trace shows the first abortive reset at `1792863668.812086`, followed
by a receiver ACK at `1792863668.812119`. The receiver kept the connection until
a probe at `1792863673.817892` elicited a second reset; reconnect began
immediately afterward. The 5.006-second interval matches the SDK's configured
five-second keepalive idle. The dominant delay is therefore TCP disconnect
recognition, rather than an eucaly teardown wait or SDK callback backlog.
The installed Mac kernel is Darwin 27.0.0, xnu-13432.1.9.

This packet pattern is consistent with the publicly reproduced
[BSD/macOS reset-validation issue](https://github.com/graingert/asyncio-macos-loopback-rst-hang).
[Apple's published TCP input code](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_input.c#L4185)
uses the last acknowledged sequence for this reset check; the
[TCP specification](https://www.rfc-editor.org/rfc/rfc5961.html#section-3.2)
requires accepting the next expected sequence. This is a source-and-wire
inference about that kernel mechanism, not a trace of the installed kernel's
internal control block. No kernel settings or SDK sources were changed.
Neither earlier transport patch addresses this mechanism.

The physical Apple TV then received real eucaly video/audio over gigabit
Ethernet with the same stock SDK. An optimized Release build added only opt-in,
bounded connection-event diagnostics. The TV app remained in one process within
each run; eucaly retired the exact old helper and immediately started its
replacement on the same address. Eight immediate restart recoveries were fully
observed across two runs: three individually controlled and five from the early
part of an automated batch.

| TV measurement across those eight restarts | Result |
| --- | ---: |
| Last old → first new video admission | 1.233–1.361 s |
| Last old → first new audio admission | 1.120–1.234 s |
| Median video admission gap | 1.285 s |
| Late audio / decoder-pool stalls | 0 / 0 |
| TV process changes within either run | 0 |

Those gaps include the existing one-second application retry and media startup.
If repeated attempts fail during a longer outage, the application's retry
schedule backs off through 1, 2, 4, 8 and 10 seconds; the immediate-restart figures
do not qualify that separate case.
The five-second native Mac branch was not observed in these eight TV recoveries.
The native Mac probe is video-only loopback using the managed SDK receiver;
the TV has its own Network.framework receiver with audio/video lanes. These
are different paths, and the measurements do not guarantee every future
restart or measure physical HDMI/audio interruption.

The attempted longer-outage sample is censored: the first collector's final
snapshot was `17:57:26Z`, just before its next scheduled retry. The later rapid
batch tail and intended two-second outage also fell after the second
collector's final snapshot (`18:02:21Z`). A final fresh-source setup used the
old port 6401 after the SDK selected 6400, so it received no media and is retained
as a setup failure. The corrected synchronized outage did not run before the
device cutoff. None of these samples is counted as a TV pass or failure.

Eucaly tightened its test harness's deadline, graceful-shutdown and readiness
checks; no production sender/receiver retry delay or SDK runtime was changed.
Its local commit `c87e3b7` passes 24 offline readiness checks, four final offline
Swift fixture cases and the network-architecture check, with independent review
cleared. Readiness derives the actual listener and verifies process/run/generation,
capture budget and watcher state; outage commands recheck generation at execution.
After that tested commit, an unknown writer changed the stress-test file at
18:29:21Z, removing the generation fence and result-generation ACK. The owner and
reviewer did not make that edit. Its diff is preserved untouched; the validated
harness results apply to `c87e3b7`, while the subsequent working copy is unverified.
The production runtime is unaffected by this test-only edit.
Root added the benchmark's first-media event history and fixed-port/native
process timing markers. Eleven focused timing tests, all 101 receiver unit
tests, and the optimized device build/install passed. The TV was restored to
an ordinary launch and all owned sources were stopped before the `18:10Z`
(05:10 Sydney) cutoff. Nothing was pushed or posted upstream.

Ignored evidence: `build/RestartDelay-20261025/`, especially
`TCP-AllHeaders/tcp-analysis.json`, `tv-recovery-analysis.json`, and the raw TV
series; eucaly retains exact source-generation, shutdown/exit and command
journals under its restart-delay investigation directory.

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
A matched wired comparison had not been performed at this point; the operator
had no cable for this sender Mac. Further saturation repeats could not resolve
that attribution. The later wired normal-use result below has its own scope.
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

### Wired one-NDI/one-OMT follow-up

On 24 October, the sender was connected at `192.168.1.27` through `en0`,
negotiated at 1000baseT full-duplex. Its Wi-Fi interface was inactive and had
no IPv4 address. Both OMT lanes to TV address `192.168.1.5` and the NDI media
flow to remote Mac `192.168.1.25` were observed on sender `en0`. The remote
Mac's route used Ethernet `en6`, but its link negotiated at **100baseTX
full-duplex**, including after the operator reseated its cable. The adapter
advertised gigabit or faster support. This is a downstream capacity constraint;
a cable's Cat6 label does not establish a gigabit negotiated link.

The restored 4K test asset was byte-identical to the earlier input:
SHA-256 `1578bc4ae077a81fad6492a6c0b34d024f77d3870e11045a253b58df443e5507`,
328,913,440 bytes, 313.003 seconds, H.264 3840×2160 at 30 fps with stereo
48 kHz AAC. The output stayed 1080p30 Medium VMX/stereo 48 kHz FPA1, with the
same local SDK repair, 512 KiB setting and playback margins. The TV used the
exact previous signed build-5 Release binary. Eucaly exercised its real
OutputCoordinator/shared player/audio helpers through an optimized Debug (`-O`)
test host, rather than a signed Release GUI qualification. A distinct NDI test
name prevented the already-open Monitor from
silently attaching alongside the owned probe. No additional receiver load was
added. The operator confirmed that one NDI receiver and one OMT receiver were
the intended normal configuration.

The initial automated Home preflight timed out before playback while the TV
showed its screensaver. The exact previously tested signed Release app was
restored; the operator dismissed the screensaver, and a fresh screenshot showed
the source picker. This setup failure is retained separately. A short wired
readiness collector then completed 94.995 measured seconds without audio faults.
The first native-NDI/TV baseline was deliberately interrupted at the operator's
request for audible Mac playback. The native probe uses no audio device; it was
stopped before selecting the new source in NDI Video Monitor. Its interrupted
collector remains incomplete with an explicit planned-client-change record.

The fresh audible-Monitor/TV collector launched around 12:00:52 Sydney time.
Its first/last measured playing reports were at 12:00:59 and 12:21:04, spanning
**1,205.001 seconds** in one TV process and connection attempt. All **23
applicable runtime gates passed**, without changing their thresholds:

| Observation | Result |
| --- | --- |
| Admitted video | 36,123 frames, 29.977561 fps |
| Native renderer window | 1,200.007 s; 4 drops / 35,973 frames (0.011119%); zero corruption |
| Audio admitted in measured interval | 60,251 blocks |
| Route-horizon warnings / late audio / timestamp gaps | 0 / 0 / 0 |
| Reconnects, failures, pool stalls, timeline resets | Zero |
| Minimum audio lead, including warmup | 137.531 ms, above the unchanged 101.333 ms route horizon |
| Post-warmup memory | 48.20–53.33 MiB; early-to-late mean change −0.286 MiB |
| Thermal state | Nominal |
| Collection errors | Zero; full series retained and ordinary launch restored |

The operator twice confirmed clean audio from NDI Monitor through the remote
MacBook Pro speakers, with mute off and the existing system volume at 44%.
The follow-up wording was “Clean throughout the time I listened.” Listening
duration was not quantified. This is NDI physical-listening evidence, not a
continuous observation of every minute or proof of Apple TV audible continuity.
The TV summary deliberately retains `audibleContinuityVerifiedForThisRun=false`.

All 60,251 measured source audio blocks paired through application/IPC/helper
stages. OMT returned a positive enqueue result for every block: 59,815 returns
of 7,720 bytes and 436 valid 40-byte silent-channel frames. There were no
audio-channel SDK drop observations. Full source traces had regular 960-sample
steps, no malformed rows, duplicate stages or trace overflow. This establishes
recorded enqueue/processing continuity, not physical delivery of every block.

One video SDK rejection first appeared at 12:19:07 and remained a cumulative
count of one. It is retained even though the receiver's aggregate gates passed.
A separate 29.254 fps five-second interval near an EOF/rewind had four additional
playback coalescences; both SDKs continued submitting 30 frames across the source
checkpoint interval and the video drop count was still zero there. That counter
can include compressed-queue skips or a decoded batch producing no admitted
samples, so it does not identify one replacement site. No source reset or audio
fault accompanied either observation.

In a stable interior window, 1,168 network snapshots each showed exactly one
NDI UDP media flow. Its accounted send rate averaged 67.68 Mbps and peaked at
90.42 Mbps in the sampled intervals; these are flow counters, not physical
wire-delivery or link-capacity measurements. OMT mean TCP RTT was 4.30 ms for
video and 7.03 ms for audio, with maxima of 31.28 and 11.28 ms. Socket send-buffer
occupancy was sampled 11,629 times per lane: video reached its 512 KiB high-water
in 12 samples; audio never did and its maximum was 23,160 bytes. Sample batches
had gaps up to 0.858 seconds, and shorter unseen peaks remain possible. TCP
retransmitted-byte counters also increased; the wired path was not pressure-free.
The header trace retained TCP push/control packets only, with zero capture-kernel
drops. It is not a complete ACK history or a receiver-NIC arrival trace.

The receiver retained all 33 exceptional timing events across its exported
series without any route-horizon event. Its maximum parser-callback gap was
81.724 ms: that packet matched a positive OMT return, a 0.099 ms instrumented SDK span and
27.518 ms source return age. The largest playback wait was 64.093 ms, with
148.043 ms lead still remaining at admission. The whole source trace's largest
instrumented OMT call was 10.479 ms, so selected sub-millisecond calls are not
the whole-run maximum. These joins distinguish source submission from later
processing variation, including receiver-local waiting. They do not prove that
the original two small warning packets had the same cause. No new
socket-buffer, playback-delay, quality or timestamp change was justified.

The stopped native probe separately retained 425.889 seconds: zero audio
timecode gaps, SDK dequeue drops, invalid blocks or capture errors, but a
323.619 ms maximum capture-return pause. Its output contains no PCM and no
speaker playback. That pause is not a NIC-arrival measurement or proof of an
audible gap. Its four metadata files were fetched only after the test source
stopped, avoiding a bulk transfer competing on the remote 100 Mbps link.

Evidence is under ignored `build/WiredAudio-20261024/`, with matching source
traces in eucaly's `wired-20261024/source-01/analysis-transport/`. Source, helpers,
owned samplers and keep-awake processes exited; the TV returned to ordinary
launch and NDI Monitor was left open. The collector now names an empty-message
interruption as `KeyboardInterrupt` instead of leaving its error reason blank.
Its 14 Python tooling regressions passed. Eucaly committed the fixture and
evidence follow-up at `2ffcabb`; its optimized build, seven relevant offline
tests, controlled source run, syntax checks and final independent review passed.

This supports the tested one-NDI/one-OMT normal-use configuration. It is a
20-minute 1080p30 result, not a new 30-minute/60 fps or complete production
qualification. The original warnings did not recur. Their exact cause remains
unproven: the old packets lacked stage traces, and the full audible run used
GUI Monitor rather than the native NDI client used for the original two events.
The remote 100 Mbps limit also remains explicit. No OMT fork/upstream change
was pushed and no further runtime tuning was applied.

### SDK rejection and parallel native-output follow-up

The single video-channel drop in the earlier wired run was bracketed by sender
checkpoints at 01:19:06–01:19:07 UTC. Those dates omit fractions; they do not
identify an exact rejecting call. Four 10 Hz video-socket samples near that
interval reached the 512 KiB high-water, and a 302.824 ms gap between outgoing
video TCP push headers occurred there. Audio occupancy stayed at or below one
7,720-byte block. No disconnect, socket exception or encoding failure was
logged. Push headers are neither a complete ACK trace nor frame-arrival times.

Code review distinguishes the SDK's drop paths. This receiver sends only
metadata controls, so it does not normally exhaust a sender's incoming AV
frame pool. Eucaly's helper canvas is fixed at 1920×1080, with no frame metadata;
its largest possible raw format is 8,294,400-byte BGRA (the recorded movie uses
4,147,200-byte UYVY). The managed codec passes the actual output-buffer capacity
to `VMX_SaveTo`. Inspection of the **bundled arm64 codec binary** confirmed
capacity checks before each copy, zero on insufficient capacity, and a successful
return equal to bytes written. Even the largest allowed buffer plus the 48-byte
video header is 8,294,448 bytes, below the channel's 10 MiB rejection limit.
These facts point to unavailable asynchronous send slots under temporary
backpressure. The exact old rejected frame and the underlying SDK/OS/network
cause of the pressure cannot be reconstructed from the retained old trace.

New bounded loopback regressions compile the actual SDK channel/protocol/pool.
They distinguish unsubscribed zero returns from oversized rejection, then pause
the peer to occupy all four send slots. The fifth frame is rejected once;
resuming reads delivers all accepted bytes intact, returns all slots, and lets
the next frame succeed. All three cases pass on original and repaired SDK
1.0.0.19, and on the repaired 1.0.0.20 PR branch. This is existing bounded
admission policy. The independent null/disposed-socket ownership regression
still fails in original code and passes with the repair; Ethernet cannot fix
that defect. See [the reproducible tests](../Upstream/libomtnet/README.md).

The next hardware comparison added eucaly's actual native output on the
auxiliary Dell P2721Q, alongside one NDI Monitor and one OMT TV. All three shared
one player/item and video sampler. The operator confirmed the native countdown
was “Visible and smooth”; this is a scoped visual observation, not a physical
frame counter. Native output retained its ordinary local-audio policy. The
sender still used gigabit Ethernet with Wi-Fi inactive; the remote NDI Mac still
negotiated 100 Mbps. Media, quality, output dimensions, codec and TV Release
binary were unchanged.

A fresh 64 KiB control retained the ownership repair and matched the pinned
1.0.0.19 source, native wrapper, .NET 8.0.426 toolchain and NativeAOT package
versions/hashes. Only the buffer constant differed from the retained 512 KiB
runtime. It was loaded in an isolated optimized Debug app copy; eucaly's vendor
512 KiB library was preserved. Both arms exercised the real native/network
output paths through the optimized Debug test host, rather than a Release GUI
workflow.

| Receiver observation | 64 KiB control | Retained 512 KiB |
| --- | --- | --- |
| Measured interval | 184.989 s | 605.000 s |
| Video admissions / fps | 5,527 / 29.877380 | 18,107 / 29.928946 |
| Audio admissions | 9,251 | 30,250 |
| Late / route-horizon / timestamp-discontinuous audio | 0 / 0 / 0 | 0 / 0 / 0 |
| Attempts / failures / timeline resets / pool stalls | 1 / 0 / 0 / 0 | 1 / 0 / 0 / 0 |
| Video SDK rejections while connected | 8 | 0 |
| TV native renderer | 0 drops / 5,377 frames; zero corruption | 3 drops / 17,957 frames (0.016707%); zero corruption |
| Minimum audio lead, including warmup | 147.257 ms | 140.684 ms |
| Runtime gates | Cadence gates failed; insufficient memory evidence | All 23 passed |

The short control had only 13 post-warmup memory samples, below the unchanged
24-sample requirement; its memory gate is not evidence of growing memory.
The 512 KiB arm had 97 such samples, 48.89–53.84 MiB footprint and −0.132 MiB
early-to-late mean change, with nominal thermal state. Its two movie rewinds
caused no audio timing fault or SDK rejection. The audio route horizon remained
101.333 ms; no playback margin or timing threshold changed.

The first-pass common movie region, approximately 140–210 seconds, had 2,056
64 KiB SDK calls with 2,048 enqueues and eight zero/drop increments, versus
2,057 calls/enqueues and no rejection at 512 KiB. New bounded per-call diagnostics
retained all eight connected zero returns, each paired with one drop and no
enqueue/byte increment; calls took 3.260–4.650 ms. SDK/producer identities,
epoch, sampler and format stayed unchanged. The calls preceded unexpected
Bonjour discovery records for unit-test source names. Those later records alone
do not prove active competing tests; their earlier owner was not established.
The comparison is nominally matched, with this retrospective isolation limit.
Prospective process records in the later arm identified only a read-only tool
lookup, rather than another observed eucaly test/helper workload.

In retained network windows, every snapshot had one active NDI UDP media flow.
Video occupancy reached 65,536 bytes in 99/875 samples of the control, versus
524,288 bytes in 12/5,902 samples at 512 KiB. Both audio lanes peaked at 15,440
bytes and had no full sample. The control's network monitor ended early after
the delayed setup, so its coverage is explicitly partial. These are sampled
queued/outstanding bytes, not unsent-delay measurements or proof of a defective
physical link. The larger buffer remains useful local resilience evidence on
Ethernet, rather than an optimization justified only by Wi-Fi.

During setup, Monitor initially negotiated audio/control without video. Selecting
None and reselecting the same source restored 1080p30 reception without changing
eucaly, native output or helper generations. This preflight issue is retained
separately; no speculative application/SDK repair was made for it.

At that stage the recommendation was to retain the ownership repair and bounded
512 KiB runtime. The stock-SDK reassessment above supersedes that recommendation:
the internal slot invariant does not demonstrate persistent public-API capacity
loss, and application pacing requires correction before attributing a need for
larger buffers.
The tested wired 1080p30 configuration supports a monitored production trial.
Full Release GUI operation, broader formats/routes, continuous physical audio,
source-to-panel latency and longer combined-output qualification remain open.
No new rejection-related runtime fix, buffer/quality/priority change or OMT
push was made. Both sources/native windows/helpers and all owned telemetry and
keep-awake jobs stopped; the TV source picker was visually confirmed and Monitor
was left open with no test source selected.

Evidence is retained under ignored `build/WiredThreeOutput-20261024/`, with source
records under eucaly's `three-output-20261024/arm-64k` and `arm-512k` directories.

Eucaly committed the bounded diagnostics, opt-in native fixture and assessment
at `5935f45`. Its full suite passed 1,020 XCTest cases with six expected opt-in
skips and zero failures, one Swift Testing case, seven feed tests and 103 release
workflow checks. The signed Release archive/export and packaged runtime/signature
checks passed with zero compiler warnings. Those packaging checks are separate
from a sustained Release GUI test. Local OMT fork commit `c52634a` adds the three
channel-policy regressions and assessment; it changes no SDK runtime code and
has not been pushed.

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
