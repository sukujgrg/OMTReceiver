# App Review notes — draft

OMT Receiver is an independent receiver for the published Open Media Transport
protocol. It requires an OMT source on a network reachable by the Apple TV. It
has no accounts, subscriptions, purchase flow or supplied content. No sign-in
credentials are needed, and all app controls work with the Siri Remote.

## Reproduce reception

1. Start a compatible sender on another computer on the same reachable network.
   Public sender tools are listed at
   https://github.com/openmediatransport/.github/blob/main/DOWNLOADS.md .
2. Use progressive SDR 1920×1080, 8-bit, initially 30 fps, with stereo audio.
3. Launch OMT Receiver, allow local-network access if prompted, and select the
   sender in Sources. If Bonjour is unavailable, use Enter Address with that
   sender's actual `omt://HOST:PORT`; no developer-specific address is needed.
4. The source appears full screen. Press Back or Play/Pause to reveal controls,
   use mute/reconnect/quality, then return to full screen. Disconnect stops it.
5. About opens Getting Started, Privacy Policy and bundled third-party licences.

The app does not provide a hosted stream or connect to a developer backend.
A sender and network access are required to review reception. Before submission,
attach a current physical-device demonstration video and explain how to obtain
any sender resource needed by App Review. Do not submit private LAN addresses,
credentials, an inaccessible private-repository link or a nonexistent demo URL.

The implementation accepts up to 1080p60. Build 2 passed a 30.33-minute
instrumented screening run at 1080p SDR 60 Hz HDMI output and recovered from
controlled video-delay and source-restart faults. A post-repair operator
picture/audio confirmation remains pending. This is one SDK-generated pattern,
not a general production qualification. 4K HDMI scaling does not enable 4K input
decoding.

Copy the final review contact details from the private Submission.local.json into
App Store Connect. Review and replace this draft before submitting.
