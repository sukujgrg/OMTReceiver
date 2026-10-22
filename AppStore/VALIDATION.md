# Preparation evidence — 23 October 2026

Version 1.0.0 (1). Local checks used Apple Silicon, Xcode 27.1 and the tvOS 27
SDK/simulator. These checks prepare a build; they do not establish App Store
acceptance or physical performance.

| Check | Result |
| --- | --- |
| App unit regressions | 61 passed, including protocol bounds, VMX decoding, audio samples, clocks, queues and lifecycle cancellation. |
| Normal simulator UI suite | Source picker and privacy/licence remote navigation passed; the optional external-sender test is skipped in this scheme. |
| Official-SDK interoperability | All 64 tests passed with a local official SDK 1.0.0.19 sender at 1080p30, including fullscreen video and Back/Play/Pause controls. This preceded the final document-only layout refinement. |
| Final document reader | Remote scrolling to the policy footer, licence access, Back and focus return passed again after the layout refinement; the screenshot was visually inspected. |
| Benchmark-tool regressions | All 5 passed. |
| Public source preflight | Licence, privacy manifest, metadata, icons and tracked-file pattern checks passed. Raw captures, credentials and developer signing overrides are excluded. |
| Device Release archive | Signed generic tvOS archive created; local bundle/resource/arm64/signature checks passed. |
| Local App Store IPA export | Export succeeded; the unpacked IPA passed the App Store profile, signature and no-debug-entitlement checks. Nothing was uploaded. |
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
- `build/AppStore/Ready-20261023/OMTReceiver.xcarchive` — final signed archive.
- `build/AppStore/Ready-20261023/Export/OMTReceiver.ipa` — final local export.

The PNGs in Screenshots/ are inspected draft store assets without private source
names. Editable Icon Composer artwork and native tvOS image stacks are checked
in under Design/AppIcon and the app's asset catalogue.

## Still outstanding

Physical Apple TV testing remains paused at the owner's request. Sustained
1080p60 qualification, the remaining 30/59.94 regressions, human picture/audio
checks and physical end-to-end latency are not established by these simulator
or signing results. See [hardware observations](../docs/performance.md).

Before submission, complete the publisher's App Store Connect record, private
review contact, pricing/age/content-rights/trader declarations, final screenshot
review, physical demo/review resources, and Apple's server-side validation.
No TestFlight upload or App Review submission has been performed.
