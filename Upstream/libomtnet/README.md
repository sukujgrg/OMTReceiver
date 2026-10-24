# Local OMT upstream investigations

These patches apply to `openmediatransport/libomtnet` v1.0.0.19, commit
`5395139d45cf47bf9f90364bf68f9960183e7638`. They are local work authorized for the
OMTReceiver/eucaly stability investigation. Two focused upstream PRs are now open;
the retained experimental patches below remain investigation evidence.
The tvOS receiver does not link this managed sender implementation; these files
are not an app build dependency.

## Upstream pull requests (24 October 2026)

- [#62: Return send slots when socket submission fails](https://github.com/openmediatransport/libomtnet/pull/62).
  Independent ownership repair with four regression cases; original code fails
  the null/disposed-socket cases, patched code passes all four.
- [#63: Add a configurable TCP send buffer for new senders](https://github.com/openmediatransport/libomtnet/pull/63).
  Adds `NetworkSendBufferSize` through existing settings APIs, retains the 64 KiB
  default, and includes five settings regression cases. The PR cites the wired
  comparison as motivation for opt-in tuning, not a universal 512 KiB default.

Each PR is one independent commit against upstream `7d29031` (SDK 1.0.0.20).
Both build `netstandard2.0` and `net40` in Release with zero warnings/errors, and
pass the three bounded channel-pressure/recovery checks. Only these two focused
branches were pushed to the fork; the combined investigation branch remains
local. No packaged SDK or receiver runtime changed when opening the PRs.

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

## Distinguish backpressure from the ownership defect

The separate `channel-tests/ChannelBackpressure.csproj` compiles the actual
upstream channel, protocol and pool sources under .NET 8. It replaces file
logging with a no-op, opens loopback sockets only, and does not invoke the
native codec or discovery. Its synthetic compressed payload tests transport
byte identity, not video decoding or physical playback.

```sh
dotnet build Upstream/libomtnet/channel-tests/ChannelBackpressure.csproj \
  -c Release -p:OMTUpstreamRoot=/absolute/path/to/libomtnet \
  --artifacts-path /tmp/omt-channel-check
dotnet /tmp/omt-channel-check/bin/ChannelBackpressure/release/ChannelBackpressure.dll
```

The three cases verify that an unsubscribed zero return does not increment
`FramesDropped`; an oversized frame increments it without consuming a slot;
and a deliberately paused peer fills the four-slot send pool. The next video
frame is rejected once, all four accepted frames arrive byte-identically when
reading resumes, all four slots return, and a subsequent frame succeeds. The
test reads the private pool for assertions but does not mutate its state.
Socket waits are bounded. Run it with loopback socket permission.

All three cases passed on both the unmodified pinned 1.0.0.19 source and the
repaired 1.0.0.19 source, as well as the repaired 1.0.0.20 PR branch. Thus bounded
pressure rejection and recovery are existing SDK policy; they do not require
Wi-Fi and are distinct from leaking a slot on a null socket or synchronous
exception. Logs and source hashes are retained under
`build/WiredThreeOutput-20261024/`. Whole-source .NET 8 compilation reports the
upstream `Thread.Abort` and rethrow-stack warnings; neither path is invoked.

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
At the end of that initial investigation, no repair commits had been pushed and
no PR had been opened. The subsequent focused PRs are listed above.

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


## Additional receiver-load follow-up

A later extra NDI UDP media flow reproducibly triggered late OMT audio and
operator-heard NDI gaps on this Wi-Fi sender path. Removing only the diagnostic
receiver restored playback; a 30-second reattachment reproduced the failure.
OMT mean TCP RTT changed 12.55 → 108.30 → 10.48 ms. Source/receiver stage timing
places the large delay beyond prompt source processing and before parser
completion; exact SDK enqueue results are distinguished from raw call attempts.
The first 27 retained load-warning blocks all had positive 7,720-byte enqueue
returns; later channel rejections are separate observations during recovery.
Parser completion is not physical arrival, and a positive enqueue return is not
wire delivery. The specific SDK/OS/network component and matched wired behavior
remain unknown; no matched wired sender run was possible without a cable.
See [the retained failure evidence](../../docs/performance.md).

The larger constant also applies to audio. A theoretical buffer capacity is not
measured backlog; no valid load-period audio queue capture justified another
size or priority change. The independent pool ownership repair remains valid.
Local documentation-only follow-ups in the PR branch record these limits;
no runtime change, repair push or upstream PR was made in this follow-up.

The later wired sender with one audible NDI Monitor and one OMT TV passed all
23 applicable runtime gates over 1,205.001 seconds at 29.977561 fps, with zero
audio timing warnings. The remote NDI Ethernet link remained 100 Mbps. All
60,251 measured audio blocks had positive OMT enqueue results; one video SDK
rejection and occasional sampled full video send buffers remain recorded.
The larger buffer's necessity on Ethernet was not isolated. This normal-use
result does not prove the original two warning causes or justify further
buffer tuning; see [the full scope](../../docs/performance.md#wired-one-ndione-omt-follow-up).

## Rejection investigation and wired native/NDI/OMT comparison

The later investigation retained the old rejection's surrounding full-socket
samples and 302.824 ms outgoing video-push gap. Source and bundled-codec binary
review exclude the oversized-frame branch for the fixed 1080p helper; only
metadata controls return from this TV. Together with the channel regressions,
the evidence points to bounded send-pool admission under pressure, without a
demonstrated additional correctness defect. The old rejecting call itself and
the SDK/OS/network origin of that pressure were not retained.

A matched 64 KiB **plus ownership repair** runtime was built from the same
1.0.0.19/native-wrapper commits, .NET 8.0.426 and exact NativeAOT dependencies
as the retained 512 KiB runtime. It replaced the library only in an isolated
optimized Debug product copy. Eucaly's actual native display, one NDI Monitor
and one OMT TV ran together; the vendor 512 KiB library stayed unchanged.

The 184.989-second control admitted 29.877380 fps and recorded eight connected
video rejections. The 605.000-second 512 KiB arm admitted 29.928946 fps with
zero SDK video rejections and all 23 applicable TV runtime gates passing.
Both had zero audio route warnings, late packets, timestamp gaps, reconnects
or decoder-pool stalls. The larger arm's TV renderer separately dropped
3/17,957 frames (0.016707%) with zero corruption. The operator confirmed the
native countdown was visible and smooth; this is not a native frame counter.

In a first-pass common movie region around 140–210 seconds, the control had
2,056 calls/2,048 enqueues/eight rejections, versus 2,057 calls/enqueues and
zero rejections at 512 KiB. All eight zero returns paired with a one-drop
counter increase and stable connections. They preceded later unexpected
Bonjour unit-test-name discoveries; those records alone neither prove a
competing test nor establish complete historical isolation. The control's
network capture is partial. See [the detailed comparison](../../docs/performance.md#sdk-rejection-and-parallel-native-output-follow-up).

Retain the ownership repair independently of cable type. The bounded larger
buffer also has useful wired resilience evidence; Cat6 does not justify
discarding it as merely a Wi-Fi workaround. Keep its general upstream-default
proposal separate from the correctness repair and review wider platforms.
The evidence supports a monitored wired 1080p30 trial, not complete Release GUI,
all-format, physical-audio or latency qualification. No additional runtime
tuning, fork/upstream push or PR was made. Raw evidence is ignored under
`build/WiredThreeOutput-20261024/`.

Local fork commit `c52634a` retains a self-contained copy under
`tests/ChannelBackpressure/`, alongside the wired assessment. Its three cases
also passed from that checkout; `dotnet run --project
tests/ChannelBackpressure/ChannelBackpressure.csproj -c Release` uses its own
upstream sources by default. This adds tests/documentation, with no SDK runtime
change or push. Eucaly's follow-up is committed separately at `5935f45`; its
full test suite and signed Release package checks passed while the live
comparison remains an optimized Debug-host result.
