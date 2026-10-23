# Preparation evidence — 24 October 2026

Current candidate: version 1.0.0 (5). Local checks used Apple Silicon, Xcode 27.1 and the tvOS 27
SDK/simulator. These checks prepare a build; they do not establish App Store
acceptance or physical performance.

| Check | Result |
| --- | --- |
| App unit regressions | Build 4: 91 passed, including the interlaced pixel/cadence/surface regressions and existing clock/queue checks. |
| Normal simulator UI suite | Build 4: source picker and privacy/licence remote navigation passed; two external-sender tests are skipped in this scheme. |
| Official-SDK interoperability | Build 4: progressive fullscreen/Back/Play/Pause and interlaced field-order/statistics/reconnect/disconnect tests passed separately at 1080 input lines. |
| Final document reader | Build 2 remote scrolling, licence access, Back and focus return passed. The unchanged layout was visually inspected before the playback repair. |
| Benchmark-tool regressions | All 5 passed. Recovery fixture built with warnings treated as errors; four invalid pause-argument cases rejected. |
| Public source preflight | Licence, privacy manifest, metadata, icons and tracked-file pattern checks passed. Raw captures, credentials and developer signing overrides are excluded. |
| Device Release archive | Build 4: signed generic tvOS archive completed with warnings as errors and zero diagnostics; bundle/resource/arm64/signature checks passed. |
| Local App Store IPA export | Build 4 export passed its App Store profile, signature and no-debug-entitlement checks. Nothing was uploaded. |
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
build-3 receiver rejected that format. Selecting Progressive in the generator,
keeping 1920×1080, 60 FPS and 4:2:2 8Bit, restored reception; the operator confirmed
that the signal works. No receiver validation was relaxed for that repair.
Build 4 adds the separate interlaced path described below. These checks are
functional interoperability spot checks, not sustained performance measurements.

Build 3 archive: `build/AppStore/Warnings-OBS-20261023/OMTReceiver.xcarchive`.
The signed Release archive also completed with zero warning/error diagnostics and
passed local bundle/resource/signing checks. The App Store-signed export at
`build/AppStore/Warnings-OBS-20261023/Export/OMTReceiver.ipa` passed distribution
profile, signature and no-debug-entitlement checks. Its SHA-256 is
`5bfffac4ec74ae98ae898442c59f45568d2a01f736619985f0b15155187ef33b`.
No TestFlight upload or App Review submission has been performed.

### Build 4 automatic interlaced reception

The full Debug simulator build, with compiler warnings treated as errors, passed
**91 unit tests and two normal UI tests**, with zero compiler warning/error
diagnostics. The two external-sender UI tests are opt-in and skipped by the
ordinary scheme. New regressions exercise actual interlaced VMX entropy,
absolute field pixel values, both field orders, alpha, 480/576/1080-line native
conversion, fractional cadence, overlapping timestamps, partial-batch accounting,
malformed/truncated entropy, and the global ten-surface bound across resets,
geometry and pixel-format changes. The decoder never relies on tvOS to infer
interlacing from the compressed VMX stream.

Full app testing exposed a pre-existing libvmx aligned-stride ownership bug: an
interlaced conversion could allocate a distinct padded buffer whose stride
happened to equal the caller's doubled field stride. Stride comparison skipped
copy-in, copy-back and release. Pointer-identity checks repair that ownership
boundary while preserving opposite-field rows and padding. The ARM native pixel
and canary checks passed AddressSanitizer and scoped UndefinedBehaviorSanitizer,
with the existing upstream shift-instrumentation exclusion. All 96 progressive
BGRX/BGRA/P216 corpus results retained the earlier compressed lengths and hashes.
The matching x86 call sites were updated but were not executed locally.

Two independent review findings were resolved: accounting now records each
sample when actually enqueued, including a first field whose second field is
later discarded; and surface lifetime accounting spans retired pools, so a
format switch cannot allocate ten new surfaces while old display buffers survive.
Final read-only reviews, including the in-place conversion and its preparation
window/buffer math, found no remaining actionable issue. The live,
official-SDK progressive fullscreen/Back/Play/Pause test passed separately. The
interlaced simulator test passed again after the preparation repair, including
field-order selection with actual
remote navigation, retained selection after reconnect, statistics, reconnect and
disconnect. The source and five benchmark-tool regressions also passed. Evidence is retained
under ignored `build/Interlaced-20261023/`, including
`Preroll-Final-Tests.xcresult`, `Preroll-Interlaced-Remote.xcresult`,
`Progressive-Interop.xcresult`, `Focused-Repair-2.xcresult`, and the progressive
wire comparison. The interlaced controls screenshot was visually inspected; all
controls fit, including statistics, reconnect and disconnect. Earlier failed runs are retained separately and are not passes.

The first physical interlaced prototype admitted the expected output samples and
had no audio timing faults, pool stalls or clock resets, but its 100 ms decoded
preparation window produced excessive native renderer drops. In a controlled
same-process 60-pair/s run, the native interlaced window dropped 274/3,600 frames
(7.61%). After the source switched to progressive at unchanged timestamps, the
stable progressive window dropped 2/2,400 (0.0833%), with approximately 125 ms
admission lead instead of 92 ms. The controlled run recorded four audio
route-horizon warnings, with no late audio packets, discontinuities or clock
resets; it is retained as diagnostic evidence, not a screening pass. The operator
reported smooth picture and clean
audio in the earlier 30-pair/s spot check; that observation does not turn the
native drop result into a screening pass. These failed preliminary captures are
retained under `Hardware-30-2/` and `Hardware-60-Switch/` inside the ignored evidence
folder. They use this Mac as the sender to the Ethernet-connected Apple TV and do not
repeat the earlier fully wired sustained qualification.

The repair preserves the original 133.33 ms preparation window while keeping
one global ten-surface budget per decoder. For two-field output, it constructs
the alternate field in the second output first, then reconstructs the selected
first field in place in the woven buffer. One-field output needs only that first
buffer. The native helper permits only exact same-base/same-stride aliasing,
leaves the selected field's real rows intact, and rejects mismatched aliasing or
partial overlap. Native alias, both-order, pixel and canary regressions passed
AddressSanitizer and scoped UndefinedBehaviorSanitizer. No source timestamp,
audio schedule or extra lookahead is added by this repair.

The final physical checks are retained as `Preroll-Hardware-30/` and
`Preroll-Hardware-60-Switch/`. The first admitted 2,701 input frames and 5,402
output samples over 90.002 seconds (60.021 submitted fps). Its separate 85.005 s
native window recorded 26/5,102 drops (0.510%) and no corruption. The mixed
60-pair/s-to-progressive check admitted 7,199 input/output samples over
120.003 s (59.990 fps). Its separate interlaced window had 22/3,599 native drops
(0.611%); the stable progressive window had 2/2,400 (0.0833%). Each run used one
attempt with no failures, pool stalls, audio timing faults or clock resets. The
scan switch retained the same process, connection, source timestamps and audio;
its run recorded three ingress and one playback coalescence.

The controlling Mac's source producer also missed deadlines (maximum video
lateness about 329 ms in the two-field capture and 350 ms in the mixed capture).
The active sender SDK frame counters advanced while their dropped-frame
counters remained zero; separate producer timing counters recorded 41 and 57
video calls more than one frame interval late in the respective runs. Late
production and SDK-reported dropped frames are distinct measurements.
These disturbed, short local-sender runs do not pass the existing 0.1% native
drop target and do not qualify sustained interlaced performance. The remaining
drops cannot be attributed to the receiver alone. All measured bursts are kept;
a clean-source, fully wired sustained interlaced check remains pending. The
older build-2 qualification does not establish build-4 interlaced performance.
See [hardware observations](../docs/performance.md) for separate windows and scope.

The operator then selected Sienna OMT Signal Generator on the final installed
build and confirmed that picture and audio work with Interlaced selected. The
Mac generator's native controls showed 1920×1080, 60 FPS, Interlaced and 4:2:2
8 Bit. This is direct sender interoperability and a physical picture/audio spot
check; it does not replace the pending sustained interlaced qualification.

[GitHub validation](https://github.com/sukujgrg/OMTReceiver/actions/runs/39906315510)
passed for feature commit `66afc1c`, including generated-file checks, source/tool
checks, unit/remote-navigation tests, an unsigned device archive and packaging
validation on the runner. The public pages deployment also succeeded.

Current local archive: `build/AppStore/Interlaced-Preroll-20261023/OMTReceiver.xcarchive`.
Its signed Release build completed with zero warning/error diagnostics and passed
local bundle/resource/signing checks. The App Store-signed export at
`build/AppStore/Interlaced-Preroll-20261023/Export/OMTReceiver.ipa` passed distribution
profile, signature and no-debug-entitlement checks. Its SHA-256 is
`2d754368263d02c01829a20fd3803efa2d50a3dab866e1c48d24ee676acc84c1`.
The earlier `build/AppStore/Interlaced-20261023/` archive/export are preserved as
superseded preparation-window prototypes. The final build 4 is installed on the
paired first-generation Apple TV. No TestFlight upload
or App Review submission has been performed.

## Build 5 quick source switcher — 24 October 2026

The source strip preserves one receiving session, separates browsing from source
selection and keeps settings accessible through a native focus section. The
signed Release build is installed on the paired Apple TV; this is a development
installation, not a new App Store archive/export. The Release build completed
with compiler warnings treated as errors, and its local packaging/signature
checks passed.

The final suite passed 95 unit tests and two ordinary simulator UI tests. Three
external-sender tests remain opt-in. The new source-reselection test passed ten
repetitions after correcting its asynchronous initial socket-count baseline.
The physical Apple TV passed 40 real SDK source switches, browsing cancellation,
current-source reselection, favourite toggling/focus return and settings access.
The successful simulator interoperability checks and physical screenshot were
retained and visually inspected. A 95-second 1080p60 Release collection smoke
check completed; it is not a sustained qualification. See the current
[hardware observations](../docs/performance.md).

Evidence is under ignored `build/QuickSwitcher-20261024/`, including
`FinalTests-2.xcresult`, `ReselectionRepeated.xcresult`,
`HardwareRemote-2.xcresult`, `DeviceBuild-5.log`, and `ReleaseSmoke/`.
The earlier failed UI-focus attempts, sleeping-device launch and test-fixture
race remain preserved separately. Existing local Xcode formatting/signing-team
edits were retained; their signing-team value triggers the public-source identity
audit and must not be published. No new App Store publishing action was requested.

The benchmark-tool suite now has 12 passing regressions, including external
sources, expected audio/format checks and bounded recovery controls. The local
upstream socket-pool regression also passed all four real-socket cases against
the final candidate. The eucaly dual-output functional and sustained evidence is
recorded separately in [hardware observations](../docs/performance.md); it does
not replace an App Store archive/export or physical latency/audio observation.

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
