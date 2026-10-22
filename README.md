# OMT Receiver

A native **tvOS application** that receives Open Media Transport (OMT) video and
audio and displays it full screen on Apple TV. This is an independent receiver,
not an official OMT product. It has no dependency on eucaly or another host app.

![OMT Receiver icon](Design/AppIcon/tvOS-preview.png)

## Build and install

Open **OMTReceiver.xcodeproj** in Xcode, select the **OMTReceiver** scheme and
choose your development team under Signing & Capabilities. Pair your Apple TV
using Xcode's Device Hub (or Devices and Simulators on older Xcode versions),
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
Controls hide after playback starts. Back or Play/Pause reveals or hides them;
arrow navigation also returns to controls. Mute, requested quality, statistics,
Reconnect and Disconnect are available. Discovery never selects a source for
you. Disconnect cancels retry; suspension closes media connections and resources.

## Supported media

- Progressive VMX1, 16×16 through **1920×1080**, up to **60 fps**, including 59.94.
- 8-bit Rec.601/709 SDR, display aspect ratio, opaque and straight-alpha pictures.
  Alpha is composited over black for HDMI output.
- FPA1 planar Float32 audio, including sparse/silent channel masks, rendered
  through the active tvOS audio route with a shared audio/video schedule.
- Direct OMT 1.0 TCP reception, Bonjour discovery and bounded reconnects.

4K, rates above 60, interlaced, 10/16-bit and preview-only video are reported as
unsupported. Discovery servers, virtual-router redirects and multiview are not
implemented. The receiver/session/renderer boundaries leave room for future
independent view slots; this version shows one source.

A bounded compressed queue holds future video. Decoding begins within 133 ms of
presentation, with at most ten decoded surfaces. Audio/video share 120 ms of
network/decode headroom plus the audio route's latency and I/O buffer duration.
This is a scheduling budget, not measured end-to-end latency. See the
[hardware observations](docs/performance.md) for actual results and limitations;
sustained 1080p60 qualification remains pending.

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
