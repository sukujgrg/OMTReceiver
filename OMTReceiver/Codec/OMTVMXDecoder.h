#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OMTVMXDecoder OMTVMXDecoder;

/// Instances are confined to the owning playback worker. No global decoder.
OMTVMXDecoder *OMTVMXDecoderCreate(int width, int height, int colorSpace);
void OMTVMXDecoderDestroy(OMTVMXDecoder *decoder);

/// Returns zero on success. Validates complete progressive or interlaced 8-bit streams before
/// entering the upstream SIMD decoder. Opaque output accepts fully validated
/// three- or four-plane input; advertised alpha requires four. Output is UYVY without alpha, BGRA with
/// alpha; BGRA is composited onto black with alpha forced opaque for HDMI.
int OMTVMXDecoderDecode(OMTVMXDecoder *decoder, const uint8_t *source,
                       size_t sourceLength, uint32_t flags,
                       uint8_t *destination, size_t destinationLength,
                       size_t destinationStride);

/// One progressive image reconstructed from the selected spatial field (0 top,
/// 1 bottom). Full-height UYVY/BGRA buffers may be distinct or exactly aliased
/// with matching strides. Partial overlap is rejected. In-place bob preserves
/// real field rows and fills only missing rows from that field. To produce both
/// fields, copy the alternate field out before modifying the source in-place.
/// All row/capacity bounds are checked before access; no field history.
int OMTVMXBob(const uint8_t *source, size_t sourceLength, size_t sourceStride,
              uint8_t *destination, size_t destinationLength, size_t destinationStride,
              int width, int height, int bytesPerPixel, int field);

/// Same validation used by Decode; exposed for malformed-stream regressions.
int OMTVMXValidate(const uint8_t *source, size_t sourceLength,
                   int width, int height, uint32_t flags);

#ifdef __cplusplus
}
#endif
