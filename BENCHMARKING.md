# Apple TV receiver benchmarks

These tools test the standalone OMTReceiver app; eucaly is not involved.
The fixture supports one 1920×1080 opaque VMX stream at up to 60 fps and Medium SDK quality,
with stereo 48 kHz FPA1 audio. The default rate is 30; use `--fps 60` or
`--fps 60000/1001` to test higher rates. The collector checks the source’s
advertised rate against the requested rate. Use a signed Release build on physical hardware.

## Repeat the sustained test

Install the current OMTReceiver application on the paired Apple TV using Xcode.
The benchmark collector does not build or install it. Close any Xcode debug
session first. Keep the Apple TV and sending Mac on the same LAN; record whether
each connection uses Ethernet or Wi-Fi. Avoid builds or other heavy Mac work
during the measured interval, and retain sender timing reports to detect source
scheduling problems.

From the project root, set the installed SDK path, the paired TV name or device
identifier, and the Mac’s current LAN address:

```sh
OMT_SDK_PATH="$HOME/Library/Developer/OMTSDK/1.0.0.19" \
  python3 Tools/benchmark-apple-tv.py \
  --device 'YOUR_APPLE_TV' \
  --source omt://192.0.2.10:6488 \
  --seconds 1800 \
  --output /tmp/omt-benchmark-new-run
```

The output directory must be new. The source address must point back to this
Mac, on the fixture’s chosen port. The collector starts an isolated official-SDK
sender, launches the TV app with explicit opt-in arguments, waits for fresh video
reports, then measures at least 30 minutes from the baseline report. Source
selection in this mode is an explicit command-line action; ordinary Home-screen
launches and Bonjour discovery continue to wait for the operator’s selection.

The TV writes one latest report and a bounded series of five-second samples into
its cache directory. A fresh run UUID and process-instance UUID separate runs;
the Mac verifies advancing reports without assuming synchronized wall clocks.
The collector polls every 30 seconds and copies the full five-second series
before stopping. It then stops only its own sender and relaunches the receiver
normally at the source picker. The collector prevents idle sleep on the controlling Mac for its own lifetime;
a local or portable sender separately holds its own activity. `--seconds 60` is useful for a setup smoke check; it is not a sustained
performance qualification.

Summarize the collected evidence with:

```sh
python3 Tools/summarize-benchmark.py /tmp/omt-benchmark-new-run \
  --output /tmp/omt-benchmark-new-run/summary.json
```

Keep `manifest.json`, `receiver-baseline.json`, `receiver-latest.json`,
`receiver-series.jsonl`, `polls.jsonl`, `sender.log` and `summary.json`. The manifest
labels incomplete collection. Raw launch logs include local device identifiers;
share compact reports instead if those identifiers are unnecessary.

## Use the sender on another Ethernet-connected Mac

A portable universal package is available under `build/OMT-LAN-Sender.zip`.
Copy the complete extracted folder to the Ethernet-connected Mac and open
`Start OMT LAN Sender.command`. It includes the official SDK and requires no
Xcode or .NET installation there. It publishes **OMT LAN Test**, runs for at
most one hour, and stops on Control-C. Leave Terminal open. It is locally
ad-hoc signed; the Intel and Apple Silicon slices are included, with only the
Apple Silicon slice executed during the packaging smoke check.

Once its hostname or Ethernet IP is known, collect from this controlling Mac:

```sh
python3 Tools/benchmark-apple-tv.py --external-sender \
  --device 'YOUR_APPLE_TV' \
  --source omt://WIRED-MAC-IP:6488 \
  --seconds 1800 \
  --output /tmp/omt-wired-benchmark-new-run
```

The external-sender option starts and stops no sender on either Mac. It collects
receiver reports and returns the TV app to ordinary launch at the end. Add
`--fps 60` to the collector and sender for a 60 fps run; both sides must match. The remote
sender’s own timing reports remain in that Mac’s Terminal. This controlling Mac
can stay on Wi-Fi: media travels directly from the Ethernet Mac to the TV.

On a Mac with Ethernet and Wi-Fi active, use the Ethernet interface’s explicit
IP address. Its Bonjour name may resolve to Wi-Fi. Verify the actual established
media sockets on the sender (`lsof -nP -iTCP:6488`); an Ethernet default route or
the address used for SSH does not prove the media path. Leave source selection
unchanged during the run. A reconnect creates a new renderer lifetime and fails
the one-attempt screening target; the summary does not combine native counters
from different renderer lifetimes.

To rebuild the portable package locally, choose a new output directory:

```sh
OMT_SDK_PATH="$HOME/Library/Developer/OMTSDK/1.0.0.19" \
  Tools/package-mac-sender.sh /tmp/OMT-LAN-Sender-new
```

The native chart renderer uses Apple Charts; after collecting a run:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -framework AppKit -framework SwiftUI -framework Charts \
  Tools/plot-benchmark.swift -o /tmp/omt-benchmark-plot
/tmp/omt-benchmark-plot /tmp/omt-wired-benchmark-new-run /tmp/performance.png
```

Compile chart tools and source packages outside the measured interval to avoid
adding build load to the sending Mac.

## What the reports establish

| Measurement | Meaning |
| --- | --- |
| Video admission fps and source timestamp advance | Decoded frames admitted to the display renderer, compared with this fixture’s requested source sequence. |
| Native renderer dropped/corrupted frames | AVFoundation’s renderer statistics; separate from frames coalesced before admission. |
| Decode duration | CPU decode and sample preparation, with 0.25 ms upper-bound percentiles and exact extrema. |
| Audio lead and admission gaps | Whether PCM arrived before its PTS and before the reported audio-route rendering horizon. These counters do not detect every possible audible defect. |
| Timeline resets, attempts and failures | Discontinuities or recovery that would otherwise be hidden by reconnecting. |
| Physical memory footprint | The receiver process’s memory footprint over time, with the first two measured minutes excluded from steady-memory comparison. |
| CPU | Receiver-process CPU time as a percentage of one core; values above 100% are possible with multiple threads. |
| Thermal state | tvOS’s nominal/fair/serious/critical state, reported as 0/1/2/3. |
| Sender timing | Source scheduling spikes and SDK encoder/drop counters, so source starvation can be distinguished from receiver work. |

The JSON summary evaluates explicit runtime targets: the requested interval,
one connection attempt, no failures/resets or audio deadline violations, at least
the requested fps minus 0.1 (29.9 at 30 fps; 59.9 at 60 fps), fewer than 0.1% missing source or native-renderer frames,
no serious/critical thermal state, and less than 20 MiB growth between early and
late post-warmup memory means. These are prototype screening targets, not a
promise of visible or audible perfection. Raw samples and extrema remain part of
the result. The separate `latencyStabilityFlagged` field calls out growth greater
than one frame at the requested rate (33.3 ms at 30 fps; 16.7 ms at 60 fps) between early and late post-warmup scheduling-lead
means. This can reveal source/receiver clock mismatch even with healthy fps.
Decode and audio-gap histograms include startup; steady-rate counters
are differences from the baseline report.

## Physical end-to-end latency — separate measurement

The 120 ms network/decode budget plus the route’s output and I/O durations is a
scheduling configuration. It is not a measurement of source-to-TV latency. The
renderer counters also exclude HDMI transport and the TV panel’s processing.

When physical observation is convenient, compare the same source frame counter
on a direct local reference display and the TV in one camera exposure or a
high-frame-rate recording. At 30 fps each counter step is 33.333 ms. Take several
samples, including after warmup and near the end of a long run, and retain the
camera rate, TV display mode and picture-processing settings. Align the counters
vertically in the shot to reduce rolling-shutter differences.

The counter difference measures the TV’s delay relative to the reference
screen. Report the reference screen’s own delay and frame/camera uncertainty
before calling that an absolute source-to-panel result. A portable display using
uncalibrated network mirroring adds its own unknown delay and cannot be treated
as a zero-latency reference. Alternatively use a suitable HDMI capture or
hardware timing setup and account for its capture delay. Physical latency and
current-run audible continuity stay explicitly unverified until those
observations are made.

## Diagnostic implementation

Only a launch with both `--omt-benchmark-run UUID` and
`--omt-benchmark-source omt://host:port` enables collection. Reusing an existing
run UUID is rejected. Reporting runs on its own serial queue, with bounded
counters and histograms; playback workers perform no benchmark file writes.
The per-run series is capped at 720 samples (one hour), while the latest report
continues updating. The collector rejects non-advancing reports. Copy cache data
while the application is active because tvOS may purge it between launches.
Apple documents the tvOS cache-storage requirement in
[Discover Continuity Camera for tvOS](https://developer.apple.com/videos/play/wwdc2023/10256/?time=969).

## Output refresh and compressed staging

For a 60 fps physical test, select a 60 Hz SDR output format in Apple TV Settings
→ Video and Audio → Format. A 1080p source can still be shown through a 4K HDMI
output format; that does not mean the source or VMX decoder is 4K. A 50 Hz HDMI
mode cannot display all sixty unique pictures each second.

The receiver stages compressed future pictures and decodes within four frame
periods of presentation. Its video admission lead is consequently shorter than
its audio admission lead. Both retain the same presentation timestamps. A lower
video admission lead after this change is not evidence of lower end-to-end
latency. Compare source-frame counts and native renderer drops separately.
