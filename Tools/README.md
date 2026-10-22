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
