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

/// Returns zero on success. Validates complete progressive 8-bit streams before
/// entering the upstream SIMD decoder. Opaque output accepts fully validated
/// three- or four-plane input; advertised alpha requires four. Output is UYVY without alpha, BGRA with
/// alpha; BGRA is composited onto black with alpha forced opaque for HDMI.
int OMTVMXDecoderDecode(OMTVMXDecoder *decoder, const uint8_t *source,
                       size_t sourceLength, uint32_t flags,
                       uint8_t *destination, size_t destinationLength,
                       size_t destinationStride);

/// Same validation used by Decode; exposed for malformed-stream regressions.
int OMTVMXValidate(const uint8_t *source, size_t sourceLength,
                   int width, int height, uint32_t flags);

#ifdef __cplusplus
}
#endif
