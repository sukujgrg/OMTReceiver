# App Store preparation

The app is prepared as a standalone tvOS application. This repository and its
original artwork are MIT-licensed. No upload, TestFlight invitation, App Store
submission, pricing decision or legal account declaration is performed by these
tools. Build 4 adds automatic interlaced playback; build 3 contains the OBS
compatibility and compiler-warning repairs. Build 2
passed the instrumented 1080p60 screening run at 1080p SDR 60 Hz
HDMI output; a separate post-repair operator spot check confirmed smooth picture
and clean audio. See [recorded preparation evidence](VALIDATION.md) for
completed local checks and artifact locations.

## Source and local checks

`VERSION` is the marketing-version source; `BUILD_NUMBER` is the default numeric
build. Version 1.0.0 (5) has been uploaded for internal TestFlight testing.
Advance the build number for the next App Store Connect upload; do not reuse a
previously uploaded version/build.

```sh
make project site check
make test
make archive-unsigned
python3 scripts/validate_distribution.py --archive build/AppStore/ARCHIVE/OMTReceiver.xcarchive
```

`make project` regenerates the native Xcode app/test targets. `make site` builds
public pages from the same policy/help text bundled in the app. Checked-in tvOS
icons do not require design tools to build. The .icon design companion remains
editable in Icon Composer; tvOS compiles the four rectangular image-stack layers.

The local validator checks licences, privacy declarations, store field lengths,
icon dimensions and compiled bundle resources. It verifies a device tvOS app,
arm64-only executable, SDK 26 or later, matching version, and absence of a linked
Mac OMT/NDI runtime. These are local checks, not Apple's validation or review.
The minimum SDK guidance was checked against [Apple's current requirements](https://developer.apple.com/news/upcoming-requirements/).

## Signing and local IPA export

Set your development team in the ignored file `Config/Signing.local.xcconfig`
with `DEVELOPMENT_TEAM =` followed by your own team identifier. The checked-in
Signing.xcconfig includes this local override for both Debug and Release.
Keep team assignments out of the generated project so `make project` preserves
reproducible public settings. Keep certificates, private keys, provisioning
profiles and App Store Connect authentication keys outside Git.

```sh
make archive
python3 scripts/archive.py export build/AppStore/ARCHIVE/OMTReceiver.xcarchive \
  --output build/AppStore/IPA
```

Archives use generic tvOS, Release optimisation and dSYMs. They never launch the
physical TV. Xcode may use development signing for the intermediate archive;
App Store export must apply distribution signing and the appropriate profile.
The export options explicitly use `destination = export`; the script rejects
upload options. It may contact Apple for signing/provisioning, but does not
upload a build. Use a signed-in, eligible Developer Program account with the
required distribution permissions. Keep signing material in Keychain.

For an exported IPA, unpack it into an ignored build directory and run:

```sh
python3 scripts/validate_distribution.py --app build/AppStore/unpacked/Payload/OMTReceiver.app \
  --require-distribution-signing
```

The additional check rejects a debug/ad hoc/enterprise profile and an enabled
get-task-allow entitlement. Use Xcode Organizer's Validate App before an actual
upload. [Apple's archive/export guidance](https://help.apple.com/xcode/mac/current/en.lproj/deva1f2ab5a2.html)
describes the signing and distribution stages.

## App Store Connect inputs

Metadata.json contains the proposed listing and public GitHub Pages URLs. It is
a draft, not a submitted record. Create the tvOS record for com.suku.OMTReceiver
under the intended publisher. Complete the age-rating questionnaire, content
rights, pricing, territories and trader status using the publisher's own answers.
No rating, price or content-rights declaration has been invented by the tooling.

Copy Submission.example.json to ignored Submission.local.json for the app ID,
private review contact and owner decisions. Never publish that local file.
ReviewNotes.md explains the independent LAN source requirement and public sender
resources. Supply a current physical demonstration and review resources before
submission; the app has no account or developer-hosted stream.

The intended privacy answer is **Data Not Collected**, based on the current
implementation: local discovery/reception, app-local preferences and statistics,
no ads/analytics/account service, and no automatic diagnostic uploads. Recheck
this answer if adding telemetry, accounts or another SDK. The manifest declares
CA92.1 for the app's saved source address and 35F9.1/8FFB.1 for elapsed timing and
app-event timestamps in opt-in developer benchmarks. Reports are cached locally;
normal launches do not enable benchmarks. See [Apple's required-reason API list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
and [privacy-label definitions](https://developer.apple.com/app-store/app-privacy-details/).

ITSAppUsesNonExemptEncryption is false for this unencrypted OMT implementation.
This declaration must be revisited if application-level encryption is added.
App Store releases contain the full MIT notices for the app, VMX and sse2neon.
About makes Getting Started, Privacy Policy and Third-Party Licences available
without external browsing or an OMT source.

## Public site and screenshots

The support and privacy pages are published only from docs/, with no application
source, private hardware captures or signing files in the Pages payload. The site is live at
https://sukujgrg.github.io/OMTReceiver/ with support.html and privacy.html. Recheck
those public URLs before supplying them to Apple.

App Store screenshots must come from the current app, use 1920×1080 or 3840×2160,
and have no alpha channel. The source-picker, full-screen reception and About UI
can be captured in the simulator with the public Mac fixture. Never upload a
shot showing an operator's network names or stream content without permission.
See [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Remaining submission gates

The screened playback configuration uses 1080p SDR 60 Hz HDMI output. Physical
end-to-end latency and build-2 4K HDMI performance remain unmeasured; see
[hardware observations](../docs/performance.md).

- Review the captured draft screenshots and obtain a physical demo video for App Review.
- Complete publisher-owned account declarations and private review contact.
- Validate distribution signing, create/select the App Store Connect record,
  and explicitly authorise any TestFlight upload or App Review submission.

App Store acceptance is decided by Apple. The [review guidelines](https://developer.apple.com/app-store/review/guidelines/)
require accessible privacy information and enough resources to review dependent
functionality. The separate OMT sender requirement is stated in the listing.
