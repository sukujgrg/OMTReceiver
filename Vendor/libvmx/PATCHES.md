# Local portability and worker-lifetime patches

`src/vmxcodec_arm.h`, Apple branch, replaces direct `__builtin_clzll`,
`__builtin_clz` and `__builtin_ctzll` macros with helpers defining zero as
64, 32 and 64 respectively. These match the zero-input results already
provided by the upstream Windows ARM implementation in the same header.

The VMX DC entropy reader legitimately counts leading zero bits across a
64-bit word boundary. A deterministic native corpus of 100 official-encoder
random frames and 5,000 mutated compressed frames, compiled with Clang
AddressSanitizer and UndefinedBehaviorSanitizer, reported a zero-input builtin
at `src/vmxcodec_arm.cpp:1605` through `GETZEROS` in `vmxcodec_common.h`.
Clang's count-zero builtins have undefined behavior on zero even though the
AArch64 CLZ instruction returns the expected bit width. The helpers evaluate
their input once and preserve nonzero behavior. No wire format or codec
algorithm changes are made.

Validation: repeat the same native corpus with
`-fsanitize=address,undefined -fno-sanitize=shift`; shift instrumentation is
excluded because the upstream SIMD bitstream implementation uses signed and
word-width shifts beyond this narrowly scoped count-zero repair. This check
must not be described as exhaustive undefined-behavior qualification.

`src/thread_tasks.h` confines `running`, queue and in-flight state to the
worker mutex. The worker waits on `!running || !queue.empty()` and drains
already admitted work before retiring. `Join` waits on both an empty queue
and no in-flight task, so a spurious condition-variable wake cannot return
while a slice still writes destination memory. Work executes outside the
admission mutex; `Push` rejects new tasks after Stop, and `Destroy` can close
admission while an admitted task finishes. The per-pool task-pointer array
is also released during destruction (the upstream implementation leaked it).

The original loop read `running` outside the mutex and could wait after
Destroy's final notification, permanently blocking codec teardown/reconnect.
Its unpredicated `Join` also permitted an early return on a spurious wake.
`ReceiverCodecThreadTests.mm` uses explicit promise gates to check nested
admission, joining in-flight work and stopping with accepted work still
running; it uses no timing sleeps. Immediate idle create/retire cycles
cover workers reaching the wait boundary during teardown.

The standalone regression compiled from that same test source fails against
the unmodified upstream header (exit 1). It passes against this patch under
ThreadSanitizer, including 250 create/retire/reinitialize cycles. The 100-frame /
5,000-mutation codec corpus also passes AddressSanitizer and the scoped
UndefinedBehaviorSanitizer configuration above after both local patches.

## Compiler-warning cleanup

`VMX_SaveTo` keeps stream lengths as signed pointer differences until checking
that the destination has space for both the four-byte length and payload. Only
then does it narrow to the 32-bit wire field. Its final `int` result is bounded
by the positive caller-supplied capacity. The old pointer-addition capacity macro
is removed. `ReceiverCodecSaveTests.mm` covers both header formats, all short
capacities with canaries, negative capacities and backward stream cursors.

`EncodeZeros` now writes the zero-run code without advancing the coefficient
cursor. The ARM, SSE and AVX callers advance that cursor explicitly when a
nonzero coefficient is about to be read. The final trailing-zero flush no longer
reads `nz`, which can be uninitialized for an all-zero AC plane. Remaining
coefficient differences are explicitly narrowed within their 64-coefficient
block. This preserves the encoded format and avoids initializing an unrelated
cursor count merely to silence the diagnostic.

The obsolete unconditional SSE2NEON optimization advisory is removed by
backporting the header hunk from [upstream PR 717](https://github.com/DLTcollab/sse2neon/pull/717),
merge `2e969594f58f103dd24e47395eb54583f82b7274`. No SIMD implementation is
updated and no compiler warning category is disabled. Header-defined task-pool
helpers are `static inline`, retaining internal linkage while allowing translation
units to include the header without using every helper.

The Apple Silicon native comparison covered 96 BGRX, BGRA and 10-bit P216 frames:
constant zero/gray/white, sparse and deterministic random content. Encoded lengths
and hashes matched the preserved pre-patch codec. ARM builds exercise the changed
paths; SSE/AVX call sites were updated consistently but were not executed on this
Apple Silicon host. Sanitizer and strict Debug/Release Xcode results are recorded in the
[preparation evidence](../../AppStore/VALIDATION.md).


## Interlaced aligned-stride ownership

Interlaced conversion doubles the row stride to address one field at a time.
For narrow images, that doubled stride can equal the temporary SIMD-aligned
stride even though the temporary and caller buffers are different allocations.
The previous helpers treated equal strides as proof of shared storage, skipping
copy-in/copy-back and release. This could encode uninitialized temporary data,
return blank pixels and leak the temporary buffer.

Copy and release decisions now use buffer identity. The release helper receives
the original source pointer, and all native SIMD callers pass it. A neighbouring
field's row is never treated as unused SIMD padding just because its address
falls inside the field stride. Native regressions check absolute source values,
field motion, aligned-tail canaries and the equal-stride/different-buffer case.
The wrapper continues to validate the complete compressed payload before native
decode. Interlaced inputs and progressive sources retain the same VMX wire format.
