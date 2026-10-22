# Hardware observations

Recorded 23 October 2026 on a first-generation Apple TV 4K (A10X), tvOS 26.6,
with one 1920×1080 opaque VMX test pattern, Medium quality and stereo 48 kHz FPA1.
These observations do not establish a general production or NDI performance claim.

| Trial | Duration | Receiver admission | Result |
| --- | --- | --- | --- |
| Different Mac over Wi-Fi to Ethernet TV | 30.33 min | 27.54 fps average | Degraded toward 20 fps; investigation remains open |
| Ethernet sender to Ethernet TV, earlier 30 fps implementation | 30.42 min | 29.99 fps average | Passed the then-current single-stream screening targets |
| Latest 60 fps queue/preroll comparison | 95 s, interrupted | 59.97 fps | Sustained qualification pending |

The wired 30 fps trial missed 19 of 54,751 source positions (0.0347%). Its
separate native-renderer window had six dropped and zero corrupted frames.
Audio was heard clean in early and near-end spot checks, and motion was reported
smooth near completion. That run predates the new compressed queue and preroll.

The latest short 60 fps comparison used an operator-confirmed 4K SDR 60 Hz HDMI
format while the OMT input stayed 1080p. Its separate 65-second native-renderer
window had 3,900 frames, four dropped and zero corrupted: an estimate of 59.94 fps.
The drop rate of 0.1026% is slightly above the existing strict 0.1% target. The
run was interrupted when the TV became unavailable, and is not a screening pass.
There were no playback coalescences, decoder-pool stalls, late audio packets or
timeline resets in the available interval. No new audio/picture spot check was
obtained. Fractional 59.94 and 30 fps regression checks and sustained 60 fps
qualification are still pending.

The common HDMI-aware schedule initially has about 221 ms lead on the tested
route. Time-based decoded preroll preserves 133 ms for native preparation within
that schedule. Neither number measures physical source-to-panel latency.

Raw captures, original photos, source addresses, hardware identifiers and local
build logs remain private. This repository publishes only these aggregate
observations. Physical end-to-end latency is deferred. 4K decoding, multiview,
complex-content qualification and a controlled NDI comparison are not established.
