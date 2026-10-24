# OMT Receiver

A native **tvOS application** that receives Open Media Transport (OMT) video and
audio and displays it full screen on Apple TV. This is an independent receiver,
not an official OMT product. It has no dependency on eucaly or another host app.

![OMT Receiver icon](Design/AppIcon/tvOS-preview.png)

## Build and install

Set your development team in the ignored `Config/Signing.local.xcconfig` as
described in [the distribution guide](AppStore/README.md). Open
**OMTReceiver.xcodeproj** in Xcode and select the **OMTReceiver** scheme. Pair your
Apple TV using Xcode's Device Hub (or Devices and Simulators on older Xcode versions),
select it as the run destination and press Run. Allow local-network access if
prompted. The app targets **tvOS 17 or later**, arm64, including the first Apple
TV 4K's A10X. No package manager, .NET runtime or external tvOS SDK is needed.

```sh
make build   # unsigned Release build; no physical TV needed
make test    # unit tests and native simulator UI checks
make project # regenerate the checked-in native application/test project
```

The tvOS simulator and Apple TV SDK must be installed in Xcode. The project
contains application, unit-test and UI-test targets, with shared schemes.

## Connect a source

Start a compatible OMT sender on the same network. Use an official
[OMT tool](https://github.com/openmediatransport/.github/blob/main/DOWNLOADS.md)
or an [OBS OMT plugin](https://github.com/openmediatransport/omtplugin), then
choose its discovered source in the app. Ethernet is recommended. If discovery
is unavailable, choose **Enter Address…** and supply the sender's actual host
and TCP port. Hostnames and bracketed IPv6 addresses are supported.

The app preserves the video's aspect ratio, with black gutters where needed.
During playback, Back, Play/Pause or arrow navigation opens a compact source
strip. Browse without changing picture or audio, then press Select to switch.
Back dismisses the strip; reopening focuses the current source. Selecting the
current live source does not reconnect. Favourite the current source to keep it
near the front. A selected manual or temporarily undiscovered source stays in
the strip. Settings opens mute, requested quality, statistics, Reconnect and
Disconnect. Discovery never selects a source for you. Disconnect cancels retry;
suspension closes media connections and resources. Only the selected source is
received; the source strip does not open live previews.

## Supported media

- Progressive VMX1, 16×16 through **1920×1080**, up to **60 fps**, including 59.94.
- Interlaced 8-bit VMX at 480, 576 or 1080 lines, converted automatically for progressive display.
- 8-bit Rec.601/709 SDR, display aspect ratio, opaque and straight-alpha pictures.
  Alpha is composited over black for HDMI output.
- FPA1 planar Float32 audio, including sparse/silent channel masks, rendered
  through the active tvOS audio route with a shared audio/video schedule.
- Direct OMT 1.0 TCP reception, Bonjour discovery and bounded reconnects.

4K, source rates above 60, 10/16-bit and preview-only video are reported as
unsupported. Discovery servers, virtual-router redirects and multiview are not
implemented. The receiver/session/renderer boundaries leave room for future
independent view slots; this version shows one source.

A bounded compressed queue holds future video. Decoding begins near presentation,
with at most ten surfaces shared by decode, deinterlacing and display. Audio/video share 120 ms of
network/decode headroom plus the audio route's latency and I/O buffer duration.
This is a scheduling budget, not measured end-to-end latency. See the
[hardware observations](docs/performance.md) for actual results and limitations;
build 2 fixes a delayed-video clock stall and passed a 30-minute instrumented
1080p60 screening run at 1080p SDR 60 Hz HDMI output, with one native drop in
108,900 frames. Controlled video-delay and sender-restart recovery also passed;
a separate post-repair physical spot check confirmed smooth picture and
clean audio.

Build 3 also accepts the official OBS plugin's unspecified aspect ratio and
repairs the remaining compiler warnings. Build 4 adds automatic interlaced playback.

Interlaced output uses low-latency spatial (bob) interpolation, so fine vertical
detail can be softer than native progressive video. Up to 30 complete field pairs
per second, both fields are presented (for example 29.97 pairs → 59.94 pictures).
Above 30 pairs per second, the first field is presented at the source rate to
keep output within 60 fps. OMT supplies no field-dominance value: the default is
top-first, with a **Field order** control during interlaced playback for bottom-first
sources. Changing order reconnects the same source with fresh playback resources.
No temporal history or extra lookahead is retained. Progressive video keeps its
existing path. Hardware screening results for earlier builds do not qualify the
new interlaced path. Short device checks reached the expected output cadence,
but native drops and source timing disturbances mean sustained interlaced
performance still needs qualification; see the hardware observations.

## Development and distribution

The optional [Mac SDK fixture](Tools/README.md) and [benchmark collector](BENCHMARKING.md)
are separate from the app. Official Mac SDK binaries are not bundled with tvOS.
The VMX codec source is compiled directly for arm64 with bounded decoder threads.
The original [Icon Composer source](Design/AppIcon/README.md) and four-layer tvOS
Home Screen/App Store/Top Shelf artwork are checked in.

## App Store preparation

See [the distribution guide](AppStore/README.md) for versioning, privacy,
local archive/export commands and the remaining submission gates. The
[support site](https://sukujgrg.github.io/OMTReceiver/) contains public setup and
privacy information. No TestFlight upload or App Store submission is automatic.

## Licence

Original source and artwork are available under the [MIT licence](LICENSE).
The vendored VMX codec and sse2neon retain their upstream MIT notices; see
[third-party notices](THIRD_PARTY_NOTICES.md). Open Media Transport and associated
marks belong to their owners. This app's original icon does not use their logo.
