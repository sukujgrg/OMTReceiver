# Official SDK interoperability sender

This optional **Mac command-line fixture** uses the official OMT SDK for video
compression, audio, TCP transport and Bonjour discovery. It is separate from the
tvOS application and is not an app build dependency.

1. Download and extract the binary SDK from the
   [official OMT releases](https://github.com/openmediatransport/libomtnet/releases).
2. From this project's root, run:

```sh
OMT_SDK_PATH='/path/to/extracted/OpenMediaTransport SDK' \
  Tools/run-official-sender.sh --seconds 120
```

`OMT_SDK_PATH` can point to the extracted SDK root or its `Libraries/MacOS`
directory. The wrapper compiles against `libomt.h`, `libomt.dylib` and
`libvmx.dylib` without installing them. SDK settings/log storage is isolated in a
temporary directory and removed on exit.

Keep the official SDK outside this repository. For example, after extracting it
to `~/Library/Developer/OMTSDK/1.0.0.19`, run a 20-minute test with:

```sh
cd /path/to/OMTReceiver
OMT_SDK_PATH="$HOME/Library/Developer/OMTSDK/1.0.0.19" \
  Tools/run-official-sender.sh --seconds 1200
```

Select **YOUR-MAC.LOCAL (OMTReceiver Test Pattern)** on the TV. If discovery is
unavailable, use `omt://YOUR-MAC-LAN-IP:6488`. This SDK installation is a Mac fixture
dependency only; the tvOS application does not bundle or load these libraries.

The source is **OMTReceiver Test Pattern**, using TCP port **6488** by default.
Choose it in the TV app, or connect manually to `omt://MAC-IP:6488`. On the tvOS
simulator running on the same Mac, `omt://127.0.0.1:6488` also works.

The pattern is 1920×1080, BT.709, fixed Medium SDK quality. It defaults to
30 fps; `--fps 60` sends 60 fps and `--fps 60000/1001` sends 59.94 fps. It includes
moving bars, a frame counter, and a synchronized visual square/audio marker at
each second. Audio is stereo Float32, 48 kHz, in 960-sample blocks. Background
tones are low-level 440 Hz left and 660 Hz right. Producer threads request
user-initiated QoS to avoid background-task timer coalescing during playback.

Useful options:

```sh
Tools/run-official-sender.sh --help
Tools/run-official-sender.sh --seconds 120 --alpha
Tools/run-official-sender.sh --seconds 120 --silent-channel right
Tools/run-official-sender.sh --seconds 120 --name 'Second test' --port 6489
```

The source runs for 60 seconds by default, exits on Ctrl+C and does not replace
another sender if its port is occupied. The optional simulator UI interoperability
test expects the default source name:

```sh
# In another terminal, while the sender is running:
xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiverInterop \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:OMTReceiverUITests/ReceiverInterfaceTests/testOfficialSourcePlaysFullscreenAndRemoteReturnsToControls test
```

This exercises official-SDK discovery and transport, native VMX decode, display
admission and remote focus. It cannot establish physical Apple TV HDMI latency,
audible quality or first-generation sustained performance.

## Opt-in physical audio diagnostics

Launching the app with `OMT_RECEIVER_DIAGNOSTICS=1` enables bounded audio timing
counters and an export every five seconds to the app cache
`Library/Caches/OMTHardwareAudio.json`. It records renderer admission, not audible
output. The probe is disabled in ordinary Home-screen launches. Cache contents
can survive app updates, so verify a fresh packet count and the current schema
(including `nominalLeadMs`) before using a file as evidence for a new build.

The explicit `--omt-benchmark-run` mode additionally records
`audioPipelineTiming`: fixed-size histograms, the first 32 route-horizon warnings
and the most recent 32 exceptional audio admissions, with source timestamps,
local uptime and event UTC. The first-warning history preserves a failure's
beginning even if a burst fills the recent ring before export. The stages
are parser completion, transport-mailbox delivery, main-actor ingress, playback
queue, sample construction and renderer enqueue. `playbackWaitMs` includes sample
construction and renderer enqueue; do not add those costs a second time.
`receiveGapMs` measures parser callbacks, not physical NIC arrival. All stage
durations use the same device's monotonic clock. UTC is only a correlation aid;
it cannot establish one-way latency between unsynchronized machines.

`routeHorizonMs` is output latency plus one I/O buffer. A route-horizon event can
still have positive lead before the packet's presentation timestamp. It is a
conservative margin violation, not proof of a physical audible dropout. These
diagnostics never increase the playback delay, alter timestamps or change the
screening thresholds. They are disabled during ordinary launches and retain no
PCM. Event storage is bounded, so use the exported series and cumulative counters
together when investigating a long run. The benchmark summary deduplicates
warning events and reports whether their coverage matches the authoritative
cumulative warning count; absence from bounded history cannot turn a fault
into a pass.

Explicit benchmark mode also exports `connectionEvents`: the last 128 attempt,
phase, failure and first-media events, with an authoritative
`connectionEventCount`. Each connection attempt records its first admitted video
and audio source timestamp once. Failure events retain the last old admission
times so a last-old → first-new gap can be measured on the TV's monotonic clock.
These are renderer admissions, not physical picture/speaker times. UTC is only
for correlating source journals. Merge the five-second series by event sequence
when a long test exceeds the ring capacity.

## Hardware benchmarking and portable Mac sender

See [BENCHMARKING.md](../BENCHMARKING.md) for the opt-in 30-minute TV collector,
external wired-sender mode, metric definitions and physical-latency procedure.
`build/OMT-LAN-Sender.zip` is the prepared universal Mac sender package; copy the
entire extracted folder to the other Mac and open its `.command` file.

The collector also takes `--fps RATE`; it rejects a source whose advertised rate
does not match. Summary frame counts, target cadence and plot frame budgets use
that rate rather than a fixed 30 fps value. Run tool regressions with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v
```

## Controlled video-delay recovery check

The fixture can pause only its video producer while audio and the SDK transport
keep running. For example, add `--video-pause-after 15 --video-pause-duration 0.6`
to a 60-second run. Source timestamps remain monotonic; video catches up after
the pause. Both options are required, and the pause must finish before the run's
end. The default is no injected pause.

This deliberately disturbs playback and producer deadlines. Keep its evidence
separate from sustained performance qualification. It tests whether a delayed
video lane recovers without shifting the common audio/video clock or freezing.


## Interlaced motion and format-switch checks

The fixture can generate genuine interlaced motion: alternating rows are sampled
at two different half-frame phases, then compressed by the official SDK. Its
`--fps` always describes complete field pairs per second when interlaced, rather
than the broadcast shorthand for fields per second.

```sh
Tools/run-official-sender.sh --seconds 120 --fps 30000/1001 --interlaced
Tools/run-official-sender.sh --seconds 120 --fps 60 --interlaced
Tools/run-official-sender.sh --seconds 120 --fps 30 --interlaced --bottom-field-first
Tools/run-official-sender.sh --seconds 120 --fps 30 --switch-scan-after 30
```

The default field order is top-first. For the bottom-first fixture, choose Bottom
first in the receiver's Field order control. `--switch-scan-after` reverses the
initial scan mode once, preserving timestamps and audio; it must occur before
`--seconds` ends. A progressive fixture still produces the original pattern.

The receiver doubles output cadence for interlaced sources up to 30 complete
pairs/sec. Higher pair rates use one field per packet to stay within 60 output
pictures/sec. Decoder/benchmark source counts and `windowVideoAdmissionFPS`
continue to count admitted compressed frames; `videoSamplesAdmitted` and
`windowVideoSampleFPS` count the progressive samples actually enqueued. Native
renderer counters have their separate observation window. The existing sustained
summary targets are for the progressive fixture; do not treat an interlaced run's
source-frame pass as proof that every second field was displayed.

For the opt-in field-order remote-navigation test, publish the default source
with `--interlaced`, select the OMTReceiverInterop scheme and pass
`OMT_RUN_INTERLACED_INTEROP=1` to `xcodebuild`. The ordinary suite skips this test.
