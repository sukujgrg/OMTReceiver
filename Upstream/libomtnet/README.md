# Local OMT upstream investigations

These patches apply to `openmediatransport/libomtnet` v1.0.0.19, commit
`5395139d45cf47bf9f90364bf68f9960183e7638`. They are local work authorized for the
OMTReceiver/eucaly stability investigation. Nothing has been pushed upstream.
The tvOS receiver does not link this managed sender implementation; these files
are not an app build dependency.

## Independent repairs and buffer candidates

`0001-increase-bounded-tcp-send-buffer.patch` changes the TCP send-buffer request
from 64 KiB to 256 KiB. It preserves the four-slot async pool, codec quality and
protocol. This is the retained first experimental performance candidate from the matched
physical-receiver comparison. During the real dual NDI/OMT run, the video socket
had `Send-Q = shiwat = 65536` and the SDK reported 872 dropped/zero-return sends
in a 61-second interval. The TV admitted roughly 14–15 fps despite a 30 fps
producer. These observations motivated a controlled test; they alone do not
prove that increasing a queue improves end-to-end latency.

`0002-return-socket-slot-on-synchronous-failure.patch` returns a rented event to
the pool when its socket is null or `Socket.SendAsync` throws synchronously.
The exception is rethrown. Existing successful synchronous and asynchronous
completion paths still return the event once. The catch only surrounds the
socket call, avoiding a double return if a completion callback itself throws.
The unmodified implementation leaked one slot in each failure case. Async
socket error completion already returned its slot and is not the defect.

## Reproduce the ownership regression

Use .NET 8 and a separate upstream checkout. No external test packages are
needed. Apply patch 0002 to that checkout and run:

```sh
dotnet run --project Upstream/libomtnet/tests/SocketPoolRegression.csproj \
  -c Release -p:OMTUpstreamRoot=/absolute/path/to/libomtnet
```

The tests compile the actual upstream pool/base sources. They repeat null and
disposed-socket sends beyond the pool size, check byte-identical transfers at
1, 17, 131072 and 262144 bytes, and check a peer reset. Network waits are bounded.
Before the patch, the two failure tests failed (`expected 4 slots, got 3`) and
the normal-transfer/reset tests passed. After the patch all four passed on this
Mac. Loopback socket permission is required; a restricted sandbox initially
rejected the two network tests, and the permitted rerun passed.

Local evidence: `build/QuickSwitcher-20261024/Upstream-SocketPool-Before.log`
and `Upstream-SocketPool-After.log` (ignored machine artifacts).

## Matched native runtime builds

The comparison uses .NET SDK 8.0.426 arm64 and `libomt` commit
`bb4b67be8e5964f1017592b9fc5406495e704e5d` (project version 1.0.0.19).
Both runtimes were built with the same toolchain and these commands in their
respective project directories:

```sh
dotnet build libomtnet.csproj -c Release -f netstandard2.0 \
  -p:TargetFrameworks=netstandard2.0
dotnet publish libomt.csproj -c Release -r osx-arm64
```

`DOTNET_CLI_HOME` and `NUGET_PACKAGES` were scoped under `/tmp`; telemetry was
disabled. Managed builds had zero warnings/errors. Native builds succeeded with
the toolchain's warning that `-ld_classic` is ignored. Both comparison artifacts
are arm64 only, with linker ad-hoc signatures. They are diagnostic runtimes, not
a universal release package. The 256 KiB artifact contains only patch 0001;
patch 0002 was applied after preserving both artifacts. Adjacent provenance
JSON files record exact source versions and pre-integration library hashes.
The two buffer patches omit their final blank context line for clean repository
whitespace checks. Provenance retains the original build-patch hashes and verifies
that each normalized patch produces byte-identical source.
Eucaly owns installation/signing of isolated Debug product copies. Its original
vendor SDK and installed signed application remain separate.

The matched 256 KiB arm improved TV admission from 19.043 to 29.700 fps, with
no audio timestamp gaps or growth in measured playback lead/memory. It still
failed the unchanged 29.9 fps cadence target. Common countdown positions
100–210 seconds independently showed SDK enqueue rates 16.371 versus
29.564 fps (1496 versus 34 rejections). Pending producer replacements are not
subtractable frame losses: the publisher can reuse the current picture.

A separate 120-second exploratory trace followed a seek to countdown position
100. Its first 448 established-video samples at 10 Hz showed the 256 KiB socket
full in 156 samples, with 23 SDK video rejections reported by then. This supports
another bounded candidate while keeping the four-slot pool and image quality.

`0003-increase-bounded-tcp-send-buffer-to-512k.patch` is an **alternative** to
patch 0001; both apply directly to the pinned upstream base. It requests 512 KiB.
Do not apply both buffer patches. The final candidate uses 0003 plus the
independent ownership repair 0002. Eucaly integrated these locally after ABI,
loopback and package checks; the 64/256 KiB artifacts remain unchanged.
The final 1,254.999-second TV run admitted 29.898023 fps with no freeze, reconnect,
late audio, timestamp/timeline resets or pool stalls, and stable memory. It still
failed the unchanged 29.9 fps target and recorded two route-margin warnings.
Native drops were 5 / 37,372 (0.013379%), with zero corruption. The parallel NDI
capture had zero SDK drops or audio timestamp gaps. Physical latency, audible
continuity, gapless content fidelity and overall production qualification remain
unestablished. See [hardware observations](../../docs/performance.md).

## Persistent fork and local branches

The requested fork is [sukujgrg/libomtnet](https://github.com/sukujgrg/libomtnet),
cloned to `~/github/openmediatransport/libomtnet`. The unchanged native wrapper
is cloned beside it as `libomt`, at the native commit recorded above.

- `codex/omt-sdk-1.0.0.19-stability` retains the tested release base and two local
  repair commits.
- `codex/omt-send-stability` contains the same repairs on upstream master
  `7d29031` (SDK project 1.0.0.20) for later PR review. The pool bug was unchanged
  there. That full newer SDK tree has not had the hardware qualification above.

Both branches passed the four real-socket regressions; managed SDK builds had
zero warnings/errors. The tested release's two runtime source files match the
original build byte-for-byte. Test sources are excluded from the SDK compile.
`STABILITY_NOTES.md` in the fork records limits and rebuild instructions.
**No repair commits were pushed to the fork or upstream, and no PR was opened.**

## Read actual macOS socket buffers

`socket-buffer-info.c` is a read-only public `libproc` diagnostic. It enumerates
only TCP sockets matching the requested local port for a process owned by the
current user. Compile it with the command in its header and run it with the
test helper's PID and port (6400 in this experiment). An optional third
argument samples at 10 Hz for 1–120 seconds, with UNIX timestamps. Its JSON distinguishes
queued bytes (`sbi_cc`), the effective high-water (`sbi_hiwat`, identified as
SO_SNDBUF in Apple's SDK header), and mbuf memory reservation (`sbi_mbmax`).
The baseline established video socket reported 65536 queued/high-water bytes.

Darwin lsof labels the mbuf reservation as SNDBUF; its
[implementation](https://github.com/lsof-org/lsof/blob/master/lib/dialects/darwin/dsock.c)
reads `sbi_mbmax` for that field. Do not interpret that value as `sbi_hiwat`.
This diagnostic was added when netstat stopped exposing the TCP table in the
agent environment; it does not alter sockets or the running application.
