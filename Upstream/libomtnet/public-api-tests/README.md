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
No persistent
capacity-loss failure was reproduced through the public APIs.

## Separate audio-metadata probe

Add `--audio-metadata-probe` with a different output directory to check whether
audio frame metadata preserves both its UTF-8 XML string and the PCM prefix.
This is separate from normal lifecycle cases because eucaly supplies no audio
frame metadata. Both stock versions currently fail it: `<epoch>00000001</epoch>`
arrives as zero bytes, and its first four bytes (`<epo`, `0x6f70653c`) overwrite
the first PCM sample. The probe deliberately returns a failing status and keeps
the observed/expected values. This does not explain the historical video drops
or establish a need for either rejected transport patch.
