# Stock SDK public-API lifecycle checks

This executable references the compiled SDK project. It does not link internal
sources, reflect on SDK internals, change socket buffers, or replace discovery
and logging. A private loopback discovery server and the real VMX/FPA1 codecs
exercise `OMTSend`/`OMTReceive` through their public APIs.

With .NET 8, Python 3, loopback permission, a pristine SDK checkout and the
matching native VMX library:

```sh
python3 Upstream/libomtnet/public-api-tests/run.py \
  --upstream /absolute/path/to/pristine/libomtnet \
  --commit 5395139d45cf47bf9f90364bf68f9960183e7638 \
  --codec /absolute/path/to/libvmx.dylib \
  --dotnet /absolute/path/to/dotnet \
  --output /tmp/omt-public-api-check --rounds 8
```

The output directory must be new. The runner verifies the exact commit and clean
checkout, records source/codec/harness hashes, builds an isolated product and
limits the test process group to three minutes. Existing `DOTNET_CLI_HOME` and
`NUGET_PACKAGES` values are respected; otherwise caches stay inside the output.

Each case repeats eight times by default:

- Dispose/recreate a receiver while the sender continues paced A/V.
- Terminate a receiver process, then receive fresh A/V with a replacement.
- Restart a sender while one receiver continues polling and reconnects by name.

Video has a valid XML epoch marker. Audio freshness uses the source's timestamp
boundary. Recovery requires fresh decoded video and audio with increasing
timestamps, the expected shape, and public connection cleanup. `report.json`
retains every bounded source-call observation and per-cycle SDK drop counters.
This is a small-frame lifecycle check (320×180 video at up to30 fps and stereo
48 kHz/960-sample audio), not throughput, physical playout or memory qualification.

On 24 October 2026 both pristine `5395139` (1.0.0.19) and `7d29031` (1.0.0.20)
passed all 24 cycles, with zero reported media-channel drops. No send/pool
exception log entries were observed, so rare failure races remain untested.
No persistent capacity-loss failure was reproduced through the public APIs.

## Separate video-only direct-URL restart probe

Add `--direct-video-restart-probe` with a new output directory to run the separate
`direct-video-restart/` project. It keeps one video-only receiver on a fixed
loopback URL while recreating sender objects on that exact listener. Real
1920×1080 UYVY/VMX is decoded to BGRA; audio and frame metadata are absent.
Freshness uses source timestamp boundaries. The first fresh frame must arrive
within four seconds; an eight-second diagnostic ceiling records late recovery
without turning it into a pass. Three fresh, increasing frames establish resumed
delivery. Add `--sender-processes` to replace the actual sender process each
cycle, with old-exit/new-ready barriers and absolute host-monotonic timestamps.
There are no receive calls between those barriers. Each mode passed eight
cycles on both stock versions; these are separate from the small-frame A/V cases.

This case was added after eucaly's native-helper sequence reproduced a retained
video receiver failing to reconnect on the third sender, with zero sender
subscriptions and four seconds of empty reads. The earlier 24-cycle results do
not cover this case. Keep its evidence separate from those results and from
steady-output physical tests.

## Separate native C-API restart diagnostic

On macOS, `run-native.py` builds `native-direct-restart.c` against the public
`libomt.h` header and loads an exact native library/codec pair. Its source build
manifest must identify unmodified sources and match the library hash. It keeps
one video-only receiver, replaces sender processes on one loopback URL, and
checks fresh decoded 1080p BGRA. Child descriptors are closed by default at spawn.
No NativeAOT module is unloaded. Children retire before storage is reused, and
the outer runner bounds the process group.

```sh
python3 Upstream/libomtnet/public-api-tests/run-native.py \
  --library /absolute/path/to/libomt.dylib \
  --codec /absolute/path/to/libvmx.dylib \
  --header /absolute/path/to/libomt/libomt.h \
  --source-manifest /absolute/path/to/stock19-build.json \
  --output /tmp/omt-native-restart --rounds 8 \
  --fresh-frames 1 --terminal-same --immediate-exit
```

The manifest schema used here is retained in the ignored native build evidence:
`sha256` identifies the library, `sourceBytesUnmodifiedAfterBuild` must be true,
and `commits` records the managed/native source identities. The runner records
the header, codec, library and harness hashes alongside commands and exit codes.

The command above sends the same opaque UYVY terminal picture before sender
destruction/SDK shutdown and `_exit(0)`, matching the tested helper sequence.
Without these flags the source exits normally without a terminal picture and
requires three fresh frames. `--terminal-alpha` is a separate exploratory arm;
it is mutually exclusive with `--terminal-same`.

The baseline three-frame arm passed eight cycles. The opaque/immediate-exit arm
reproduced a first fresh frame at 5.054 seconds on the fourth cycle, after three earlier
cycles at 10/1,074/998 ms. A previous arm without explicit descriptor closure
also recovered late at 5.139 seconds. These runs deliberately return failure for
the unchanged four-second diagnostic target, while retaining recovery within
the eight-second observation ceiling. The same receiver recovered without
recreation. The exact delay mechanism is not isolated; no persistent slot loss
or need for either historical transport patch is demonstrated. The four-second
target is an application diagnostic budget, not an upstream API guarantee.

A single-variable normal-exit comparison omitted only `--immediate-exit`.
Seven cycles recovered in 14–987 ms, then the eighth recovered at 5.105 seconds.
Normal process exit therefore does not prevent the observed delay. No helper
exit-path change or speculative SDK source patch was made.

## Separate audio-metadata probe

Add `--audio-metadata-probe` with a different output directory to check whether
audio frame metadata preserves both its UTF-8 XML string and the PCM prefix.
This is separate from normal lifecycle cases because eucaly supplies no audio
frame metadata. Both stock versions currently fail it: `<epoch>00000001</epoch>`
arrives as zero bytes, and its first four bytes (`<epo`, `0x6f70653c`) overwrite
the first PCM sample. The probe deliberately returns a failing status and keeps
the observed/expected values. This does not explain the historical video drops
or establish a need for either rejected transport patch.
