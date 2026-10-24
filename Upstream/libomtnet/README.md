# Local OMT upstream investigations

These patches apply to `openmediatransport/libomtnet` v1.0.0.19, commit
`5395139d45cf47bf9f90364bf68f9960183e7638`. They are local work authorized for the
OMTReceiver/eucaly stability investigation. The two focused upstream PRs were
closed by the maintainer. The retained experimental patches below are historical
investigation evidence, not demonstrated production requirements.
The tvOS receiver does not link this managed sender implementation; these files
are not an app build dependency.

## Upstream pull requests (24 October 2026)

Both PRs are closed. The maintainer asked for a public-API failure reproduction
for #62 and identified application pacing and the deliberate 64 KiB burst bound
for #63. Our internal pool tests demonstrated an isolated slot invariant, not
persistent loss of capacity after normal channel disposal. Earlier conclusions
that either patch was required were too strong.

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

## Stock SDK reassessment

The [public-API harness](public-api-tests/README.md) references the compiled,
pristine SDK, uses real VMX/FPA1 codecs and a private loopback discovery server,
and retains complete bounded call traces. SDK 1.0.0.19 (`5395139`) and 1.0.0.20
(`7d29031`) each passed 24 cycles: eight receiver disposals/recreations, eight
receiver process terminations/replacements and eight sender restarts with the
receiver reconnecting by name. Fresh decoded A/V, public connection cleanup
and zero media-channel drops were observed. No send/pool exceptions occurred;
these tests do not exhaust rare synchronous-failure races or qualify throughput.
No persistent public-API capacity-loss failure was reproduced.

Eucaly's old repeating timer could submit closely spaced frames after owner-queue
stalls. A finite 95 ms stall produced a 5.626459 ms interval between real stock-SDK
entries. Eucaly's agent replaced it with guarded one-shot scheduling on a nominal
30 Hz phase, retaining source timestamps and the audio clock. Calls respect the
existing 32.333333 ms actual-entry floor (one period minus the unchanged 1 ms
jitter allowance), and obsolete opportunities are skipped. Eleven focused
checks passed; a separate local stock-SDK check delivered 29.949955 fps with
minimum spacing 32.365042 ms. The historical eight rejection
calls had immediate predecessor intervals of 33.26–33.40 ms, so this finding
does not establish their cause.

The fresh gigabit native/NDI/OMT comparison kept the SDK unmodified. The old
timer admitted 29.936023 fps over 184.995 seconds; the initial strict one-shot
repair admitted 29.845752 fps over 484.994 seconds and failed the unchanged
29.9 fps screen. The final phase policy admitted 29.910716 fps over 605.001
seconds and passed all 23 applicable runtime targets. It had zero SDK video
drops, audio timing warnings, timeline resets, decoder-pool stalls or reconnects;
the separate TV renderer dropped 1/17,946 frames with no corruption and memory
was stable. The earlier strict policy accumulated ordinary timer wake lateness;
long individual synchronous send stalls are separate and their component cause
is not isolated. Neither historical transport patch is established as necessary.
The remote Mac now negotiates gigabit, so these runs are not matched repeats of
the historical 100 Mbps buffer comparison. See
[the detailed physical results](../../docs/performance.md#stock-sdk-and-application-pacing-reassessment).

Separate direct-URL managed tests passed eight sender-object and eight sender-
process replacements on each stock version with one retained video receiver.
A minimal public native C-API probe also reproduced a delayed reconnect: after
an opaque terminal picture, sender destruction, SDK shutdown and immediate
process exit, the same receiver recovered at 5.054 seconds. That misses the
four-second DEBUG probe target, but does not reproduce permanent capacity loss.
The SDK's five-second keepalive and connection retry timing inform a separate
functional recovery budget; they do not establish the exact cause of the delay.
The reproducer retains its failing four-second target and eight-second
diagnostic ceiling. No SDK source patch was added for this finding.
The corresponding normal-process-exit arm also recovered late at 5.105 seconds;
changing the helper's exit path is not supported by this comparison.

A separate public-API audio-metadata probe fails on both stock versions: valid
XML overwrites the PCM prefix and the metadata tail is zero. Eucaly supplies
no audio frame metadata; this is unrelated to the rejection and warning
investigation. The failing probe is retained separately, without changing the
stock SDK or opening another upstream report.

### OBS plugin reference

The upstream [OBS output implementation](https://github.com/openmediatransport/omtplugin/blob/b6356ee5adeb1be7ab2c6257ae588447cc99fbf8/src/OBSOutput.cs#L457)
at `b6356ee` forwards OBS raw audio/video callbacks through public `OMTSend.Send`.
It preserves callback timestamps (`timestamp / 100`) and the OBS output frame
rate, with no independent output timer or resend queue. Its normal stop path
ends OBS data capture before disposing the sender. The
[receiver worker](https://github.com/openmediatransport/omtplugin/blob/b6356ee5adeb1be7ab2c6257ae588447cc99fbf8/src/OBSReceiveInstance.cs#L331)
continues polling the same public receiver across receive timeouts; it stops the
worker before disposal. These are useful media-clock and lifetime references,
not performance measurements or proof of the SDK version in a shipped plugin.
Eucaly keeps its independent audio worker and NDI borrowed-buffer contracts.

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
In these direct internal-source tests, the unmodified pool retained one slot in
each failure case. This does not demonstrate persistent public-API capacity
loss after channel cleanup. Async socket error completion already returned its
slot and is not the defect exercised by those tests.

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
size or priority change. The internal pool regression alone does not establish
that its proposed ownership change is needed by callers of the public API.
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

That investigation recommended retaining the ownership and buffer patches.
The stock-SDK reassessment above supersedes that recommendation: neither patch
is established as a requirement. The earlier larger-buffer result is retained
as a scoped observation, with application pacing and network topology requiring
separate evaluation.
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
