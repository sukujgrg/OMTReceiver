# Validation

The app is a standalone native tvOS receiver. eucaly is not a dependency and was
not modified during its development. The deployment target is tvOS 17, arm64.

The most recent playback implementation passed 61 unit tests, including real
VMX 60/59.94 decoding, continued 4K/rate rejection, bounded surface-pool exhaustion
and recovery, packet framing, queue overflow/reset, stale callbacks and audio
session cancellation. One native source-picker UI test passed; the optional
independent-sender UI test was skipped in that run. The signed hardware build
and install succeeded. Five Python benchmark-tool regressions passed.

The icon work subsequently passed an unsigned Release build and asset compilation.
The original editable .icon document was opened and inspected in Icon Composer.
App Store preparation checks are recorded separately in AppStore/README.md as
they become available. No App Store approval or TestFlight upload is implied.

See [the hardware observations](docs/performance.md) for aggregate measurements
and limits. Raw hardware captures and developer/device/network identifiers are
kept outside public history. Reproduce automated checks with `make test`; use
BENCHMARKING.md for an explicitly configured independent sender and physical TV.
Do not use an operator's live source as a test fixture.
