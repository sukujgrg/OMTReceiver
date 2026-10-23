# Preparation evidence — 23 October 2026

Current candidate: version 1.0.0 (2). Local checks used Apple Silicon, Xcode 27.1 and the tvOS 27
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
- `build/AppStore/Recovery-20261023/Export/OMTReceiver.ipa` — current build 2 local export.

The PNGs in Screenshots/ are inspected draft store assets without private source
names. Editable Icon Composer artwork and native tvOS image stacks are checked
in under Design/AppIcon and the app's asset catalogue.

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
