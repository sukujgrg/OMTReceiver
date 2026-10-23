# Preparation evidence — 23 October 2026

Current candidate: version 1.0.0 (3). Local checks used Apple Silicon, Xcode 27.1 and the tvOS 27
SDK/simulator. These checks prepare a build; they do not establish App Store
acceptance or physical performance.

| Check | Result |
| --- | --- |
| App unit regressions | Build 2: 63 passed, including the new delayed-video queue liveness and common-clock regressions. |
| Normal simulator UI suite | Build 2: source picker and privacy/licence remote navigation passed; the optional external-sender test is skipped in this scheme. |
| Official-SDK interoperability | Build 2: the optional actual-SDK fullscreen/Back/Play/Pause UI test passed separately at 1080p30. |
| Final document reader | Build 2 remote scrolling, licence access, Back and focus return passed. The unchanged layout was visually inspected before the playback repair. |
| Benchmark-tool regressions | All 5 passed. Recovery fixture built with warnings treated as errors; four invalid pause-argument cases rejected. |
| Public source preflight | Licence, privacy manifest, metadata, icons and tracked-file pattern checks passed. Raw captures, credentials and developer signing overrides are excluded. |
| Device Release archive | Build 2: signed generic tvOS archive created; local bundle/resource/arm64/signature checks passed with normal signing trust access. |
| Local App Store IPA export | Build 2 export passed its App Store profile, signature and no-debug-entitlement checks. Nothing was uploaded. |
| Public website | Home, support and privacy pages opened successfully; home and policy layouts were visually inspected. |

The CI workflow also builds with GitHub's Xcode 26 runner. A Swift expression in
the existing audio byte reader exceeded that compiler's type-checking budget;
splitting the same little-endian assembly into explicit steps fixed it. The
workflow runs the source checks, unit/UI tests and unsigned device archive
validation. See the [validation history](https://github.com/sukujgrg/OMTReceiver/actions/workflows/validate.yml)
for the result on a particular commit.

Local build evidence remains in the ignored build directory:

- `build/StorePreparation-Clean-20261023.xcresult` — the full local SDK run.
- `build/Tests-20261023-103635.xcresult` — ordinary suite after the compiler fix.
- `build/DocumentReading-20261023.xcresult` — final reader navigation and image.
- `build/AppStore/Ready-20261023/OMTReceiver.xcarchive` — superseded build 1 archive.
- `build/Tests-20261023-124520.xcresult` — build 2 ordinary suite.
- `build/Build2-Interop-20261023.xcresult` — build 2 actual SDK/remote UI check.
- `build/DelayedVideo-AfterFix-20261023.xcresult` — 19 passing timing/queue tests.
- `build/DelayedVideo-BeforeFix-20261023.log` — expected regression assertions before repair; the old driver stalled during diagnostic cleanup and was stopped afterward.
- `build/AppStore/Recovery-20261023/OMTReceiver.xcarchive` — repaired build 2 archive.
- `build/AppStore/Ready-20261023/Export/OMTReceiver.ipa` — superseded build 1 export.
- `build/AppStore/Recovery-20261023/Export/OMTReceiver.ipa` — preserved build 2 local export.

The PNGs in Screenshots/ are inspected draft store assets without private source
names. Editable Icon Composer artwork and native tvOS image stacks are checked
in under Design/AppIcon and the app's asset catalogue.

## Project settings follow-up

The project generator now retains Xcode's recommended compiler diagnostics,
asset/string symbol generation, platform-selected architectures, Debug active-only
builds and Release whole-module Swift compilation. `make build` passed with the
whole-module compiler flag and an arm64 tvOS executable. `make test` passed all
63 unit tests and two simulator UI tests; the optional external-sender test was
skipped. The public-source audit and all five benchmark-tool tests also passed.
Logs remain under ignored `build/ProjectSettings-20261023/`.

The initial settings follow-up exposed additional codec/test diagnostics. Build 3
repairs those warnings and the subsequently reproduced OBS interoperability issue.
The older build-2 archive and IPA remain preserved with their recorded screening
results; those 30-minute results do not describe a new sustained test of build 3.

### Build 3 warning and interoperability repairs

A fresh Release device build and the full Debug simulator build completed with
compiler warnings treated as errors and **zero warning/error diagnostics**. The
integrated suite passed **70 unit tests and two normal UI tests**; the optional
external-sender UI test was skipped. This includes three new native serialization
boundary tests and four OBS/aspect-ratio regressions. The exact OBS-default test
failed against the old parser with the same invalid-geometry error shown on TV,
then passed after the repair. Logs and result bundles remain under ignored
`build/WarningCleanup-20261023/`.

The codec now checks signed lengths before narrowing to wire fields and avoids
reading an uninitialized coefficient count when flushing trailing zeros. The
worker-header helpers are inline, and the session lifetime test uses an immutable
weak capture. The obsolete SSE2NEON advisory is removed via its upstream patch;
compiler warning categories remain enabled. The generator skips unused App
Intents metadata extraction because no target declares an App Intent. Re-enable
that task when adding Siri or Shortcuts integration.

All 96 native BGRX/BGRA/10-bit P216 corpus results retained the original compressed
lengths and hashes. The focused serialization tests passed AddressSanitizer and
UndefinedBehaviorSanitizer. The corpus also passed AddressSanitizer and scoped
UndefinedBehaviorSanitizer with the upstream shift instrumentation excluded; this
is not exhaustive undefined-behavior qualification. See [vendor patches](../Vendor/libvmx/PATCHES.md).

The official OBS plugin leaves the wire display-aspect field at zero. Build 3
interprets that value as unspecified and derives square-pixel display geometry,
while preserving explicit ratios and rejecting invalid dimensions, negative,
non-finite and excessive ratios. The installed signed build reached live OBS
720p30 playback on the first-generation Apple TV, with one attempt and no reported
failure in the initial 50-second diagnostic check. It admitted about 30 fps, with
zero native video drops or audio timing faults in that check. The operator then
confirmed that both picture and audio work. This is a short interoperability and
physical spot check, not a sustained qualification. A read-only review of the
parser repair and its regressions found no actionable issue.

Sienna OMT Signal Generator was separately found to be set to Interlaced. Three
captured frames had the interlaced flag and an interlaced VMX payload, while their
1920×1080, 60/1 fps, 8-bit Rec.709 geometry otherwise fit the supported limits. The
receiver correctly rejects that format. Select Progressive in the generator,
keeping 1920×1080, 60 FPS and 4:2:2 8Bit, then reconnect. Playback after that sender
setting change has not yet been verified; no receiver validation was relaxed.

Current local archive: `build/AppStore/Warnings-OBS-20261023/OMTReceiver.xcarchive`.
The signed Release archive also completed with zero warning/error diagnostics and
passed local bundle/resource/signing checks. The App Store-signed export at
`build/AppStore/Warnings-OBS-20261023/Export/OMTReceiver.ipa` passed distribution
profile, signature and no-debug-entitlement checks. Its SHA-256 is
`5bfffac4ec74ae98ae898442c59f45568d2a01f736619985f0b15155187ef33b`.
No TestFlight upload or App Review submission has been performed.

## Hardware results and remaining checks

Physical testing resumed on 23 October. Build 1 completed the 30/59.94 cadence
checks and a 30-minute 60 fps trial with 4K HDMI output, narrowly missing the
native 0.1% drop target (0.1093%). Its short 1080p HDMI comparison had zero native
drops, but a subsequent sustained run froze video after about 17 minutes while
audio continued. That run is a failure, not a 60 fps qualification.

The freeze was reproduced in a controlled clock/queue regression and on the
actual Apple TV with a 600 ms video-only producer pause. Build 2 repairs the
monotonic-delay mapping and uses the dedicated background video renderer. Its
physical controlled test recovered to about 60 fps without a reconnect, timeline
reset or late audio packet. Its fresh, uninterrupted 30.33-minute run then
passed every instrumented runtime target: 109,200 frames admitted at 60.000 fps,
one native drop in 108,900 frames (0.000918%), no missing source positions or audio
timing faults, and stable memory around 53 MiB. The complete 365 measured samples
came from one process with no collection error. An orderly source shutdown and
restart also recovered automatically to about 60 fps in the same receiver process.

In a separate short post-repair 1080p60 run, the operator confirmed smooth
picture and clean audio between the regular marker beeps. This is a spot check,
not continuous observation of the earlier sustained run. Physical end-to-end
latency is unmeasured, and build 2's 4K HDMI output has not been requalified. See
[hardware observations](../docs/performance.md) for scope, counter windows and
the preserved failed build-1 evidence.

Physical mute/unmute, About/privacy reading and Back, reconnect,
disconnect/reselection and actual sleep/wake recovery were confirmed on build 1.
Their mixed interaction session is separate from sustained measurements; it also
recorded coalesced video and one audio route-horizon warning. Build 2's normal UI
and actual-SDK remote/fullscreen checks passed in the simulator.

Before submission, complete the publisher's App Store Connect record, private
review contact, pricing/age/content-rights/trader declarations, final screenshot
review, physical demo/review resources, and Apple's server-side validation.
No TestFlight upload or App Review submission has been performed.
