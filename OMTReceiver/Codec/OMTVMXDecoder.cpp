#include "OMTVMXDecoder.h"
#include "vmxcodec.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>

namespace {
constexpr uint32_t interlacedFlag = 1;
constexpr uint32_t alphaFlag = 2;
constexpr uint32_t premultipliedFlag = 4;
constexpr uint32_t unsupportedFlags = ~uint32_t(7);
constexpr size_t maximumPacket = 16 * 1024 * 1024;

bool dimensionsValid(int width, int height) {
    return width >= 16 && width <= 1920 && height >= 16 && height <= 1080 && width % 2 == 0;
}

// VMX's optimized entropy reader intentionally reads ahead into guard bytes.
// Preflight the actual payload with a bounded reader, so malformed Exp-Golomb
// codes cannot produce negative bit counts or consume stale slice contents.
class Bits {
public:
    Bits(const uint8_t *data, size_t length) : data(data), count(length * 8) {}
    bool read(unsigned n, uint32_t &value) {
        if (n > 24 || n > count - position) return false;
        value = 0;
        for (unsigned i = 0; i < n; ++i) {
            value = (value << 1) | ((data[position >> 3] >> (7 - (position & 7))) & 1);
            ++position;
        }
        return true;
    }
    bool extended(uint32_t &value) {
        unsigned zeros = 0;
        uint32_t bit;
        while (true) {
            if (position == count || zeros > 14) return false;
            bit = (data[position >> 3] >> (7 - (position & 7))) & 1;
            if (bit) break;
            ++position; ++zeros;
        }
        return read(zeros + 2, value);
    }
    bool align() {
        uint32_t padding;
        unsigned n = unsigned((8 - (position & 7)) & 7);
        return read(n, padding) && padding == 0;
    }
    bool finished() const { return position == count; }
private:
    const uint8_t *data;
    size_t count;
    size_t position = 0;
};

bool validateEntropy(const uint8_t *data, size_t length, int width, bool alpha, bool dc, int &planes) {
    Bits bits(data, length);
    const std::array<int, 4> widths = { width, width / 2, width / 2, width };
    for (int plane = 0; plane < 4; ++plane) {
        if (plane == 3 && !alpha && bits.finished()) { planes = 3; return true; }
        const size_t blocks = size_t((widths[plane] + 7) / 8) * 2;
        const size_t terms = dc ? blocks : blocks * 64;
        size_t consumed = 0;
        while (consumed < terms) {
            uint32_t first, second, value;
            if (!bits.read(1, first)) return false;
            if (first) {
                if (!bits.read(1, second)) return false;
                if (second) { ++consumed; }
                else {
                    if (dc || !bits.extended(value) || value < 2 || value > terms - consumed) return false;
                    consumed += value;
                }
            } else {
                if (!bits.extended(value) || value < 2 || value > 65536) return false;
                ++consumed;
            }
        }
        if (!bits.align()) return false;
    }
    planes = 4;
    return bits.finished();
}
}

struct OMTVMXDecoder {
    VMX_INSTANCE *instance;
    int width;
    int height;
};

extern "C" OMTVMXDecoder *OMTVMXDecoderCreate(int width, int height, int colorSpace) {
    if (!dimensionsValid(width, height) || (colorSpace != 0 && colorSpace != 601 && colorSpace != 709)) return nullptr;
    VMX_INSTANCE *instance = VMX_Create({width, height}, VMX_PROFILE_OMT_SQ, VMX_COLORSPACE(colorSpace));
    if (!instance) return nullptr;
    // A10X has three performance cores. Bound each future multiview instance;
    // never spawn hardware_concurrency workers per channel.
    VMX_SetThreads(instance, height >= 720 ? 2 : 1);
    return new OMTVMXDecoder{instance, width, height};
}

extern "C" void OMTVMXDecoderDestroy(OMTVMXDecoder *decoder) {
    if (!decoder) return;
    VMX_Destroy(decoder->instance);
    delete decoder;
}

extern "C" int OMTVMXValidate(const uint8_t *source, size_t length, int width, int height, uint32_t flags) {
    if (!source || !dimensionsValid(width, height) || (flags & unsupportedFlags) || length < 5 || length > maximumPacket) return 1;
    if ((flags & premultipliedFlag) && !(flags & alphaFlag)) return 1;
    size_t cursor = 0;
    if (source[0] == 3) {
        if (source[1] > 3) return 2;
        cursor = 2;
    }
    const bool interlaced = (flags & interlacedFlag) != 0;
    // VMX's two field banks require these exact heights. In particular, do not
    // let VMX_ConfigureInterlaced silently fall back to progressive geometry.
    if (interlaced && height != 480 && height != 576 && height != 1080) return 2;
    if (source[cursor] != (interlaced ? 2 : 1) || source[cursor + 1] > 100) return 2;
    const int slices = (height + 15) / 16;
    if (source[cursor + 2] != slices) return 2;
    cursor += 3;
    const size_t alignedWidth = size_t((width + 7) & ~7);
    int encodedPlanes = 0;
    for (int kind = 0; kind < 2; ++kind) {
        const size_t maximumLength = kind == 0 ? alignedWidth * 16 * 2 - 16 : alignedWidth * 16 * 4 - alignedWidth * 8;
        for (int slice = 0; slice < slices; ++slice) {
            if (length - cursor < 4) return 3;
            uint32_t bytes = uint32_t(source[cursor]) | (uint32_t(source[cursor + 1]) << 8)
                | (uint32_t(source[cursor + 2]) << 16) | (uint32_t(source[cursor + 3]) << 24);
            cursor += 4;
            if (bytes == 0 || bytes > maximumLength || bytes > length - cursor) return 3;
            int planes = 0;
            if (!validateEntropy(source + cursor, bytes, width, (flags & alphaFlag) != 0, kind == 0, planes)) return 4;
            // The released SDK can encode BGRA's fourth plane while advertising
            // opaque OMT video. Alpha flags select how to render, not whether
            // the compressed frame necessarily omits that plane. Validate the
            // complete optional plane and require consistent DC/AC slice counts;
            // never accept arbitrary trailing data or missing advertised alpha.
            if (encodedPlanes == 0) encodedPlanes = planes;
            else if (encodedPlanes != planes) return 4;
            cursor += bytes;
        }
    }
    return cursor == length ? 0 : 3;
}

extern "C" int OMTVMXDecoderDecode(OMTVMXDecoder *decoder, const uint8_t *source, size_t length,
                                    uint32_t flags, uint8_t *destination, size_t capacity, size_t stride) {
    if (!decoder || !destination) return 1;
    const bool alpha = (flags & alphaFlag) != 0;
    // Upstream SIMD conversion works on padded vector-width rows. CoreVideo's
    // 64-byte alignment provides these tails; reject tightly packed foreign
    // buffers that could otherwise overflow at non-vector-aligned dimensions.
    const size_t minimumStride = size_t((decoder->width + 15) & ~15) * (alpha ? 4 : 2);
    if (stride < minimumStride || stride > size_t(std::numeric_limits<int>::max())
        || size_t(decoder->height) > capacity / stride) return 1;
    int validation = OMTVMXValidate(source, length, decoder->width, decoder->height, flags);
    if (validation) return validation;
    // VMX_LoadFrom copies the complete validated streams into owned slice data.
    auto status = VMX_LoadFrom(decoder->instance, const_cast<uint8_t *>(source), int(length));
    if (status != VMX_ERR_OK) return 5;
    for (int i = 0; i < decoder->instance->SliceCount; ++i) {
        auto *slice = decoder->instance->Slices[i];
        // Length preflight reserves the DC tail; AC already has an upstream
        // protection region. Replace read-ahead bytes after every shorter frame
        // rather than letting a previous picture affect the entropy lookup.
        std::memset(slice->DC.Stream + slice->DC.StreamLength, 0xff, 16);
        std::memset(slice->AC.Stream + slice->AC.StreamLength, 0xff, 16);
    }
    status = alpha ? VMX_DecodeBGRA(decoder->instance, destination, int(stride))
                   : VMX_DecodeUYVY(decoder->instance, destination, int(stride));
    if (status != VMX_ERR_OK) return 5;
    if (alpha) {
        const bool premultiplied = (flags & premultipliedFlag) != 0;
        for (int y = 0; y < decoder->height; ++y) {
            uint8_t *row = destination + size_t(y) * stride;
            for (int x = 0; x < decoder->width; ++x) {
                uint8_t *pixel = row + x * 4;
                if (!premultiplied) {
                    const unsigned a = pixel[3];
                    for (int channel = 0; channel < 3; ++channel) pixel[channel] = uint8_t((unsigned(pixel[channel]) * a + 127) / 255);
                }
                pixel[3] = 255;
            }
        }
    }
    return 0;
}

// Spatial bob uses only one field, never a line from its temporal neighbour.
// Copy the field's real lines and interpolate missing lines between adjacent
// lines of that same field, extending the first/last line at the image edges.
// Packed UYVY and opaque BGRA keep each byte's component position across rows.
extern "C" int OMTVMXBob(const uint8_t *source, size_t sourceCapacity, size_t sourceStride,
                         uint8_t *destination, size_t destinationCapacity, size_t destinationStride,
                         int width, int height, int bytesPerPixel, int field) {
    if (!source || !destination || !dimensionsValid(width, height)
        || height % 2 || (bytesPerPixel != 2 && bytesPerPixel != 4) || (field != 0 && field != 1)) return 1;
    const size_t rowBytes = size_t(width) * size_t(bytesPerPixel);
    if (sourceStride < rowBytes || destinationStride < rowBytes
        || size_t(height) > sourceCapacity / sourceStride
        || size_t(height) > destinationCapacity / destinationStride) return 1;
    const bool inPlace = source == destination;
    if (inPlace && sourceStride != destinationStride) return 1;
    if (!inPlace) {
        const uintptr_t a = reinterpret_cast<uintptr_t>(source);
        const uintptr_t b = reinterpret_cast<uintptr_t>(destination);
        const size_t sourceSpan = size_t(height) * sourceStride;
        const size_t destinationSpan = size_t(height) * destinationStride;
        if ((a < b && b - a < sourceSpan) || (b < a && a - b < destinationSpan)) return 1;
    }
    const int first = field;
    const int last = height - 2 + field;
    for (int y = 0; y < height; ++y) {
        uint8_t *output = destination + size_t(y) * destinationStride;
        if ((y & 1) == field) {
            // Exact in-place bob leaves this field's real lines untouched.
            // Its interpolated lines read only these still-original real lines.
            if (!inPlace) std::memcpy(output, source + size_t(y) * sourceStride, rowBytes);
        } else {
            const int above = std::max(first, y - 1);
            const int below = std::min(last, y + 1);
            const uint8_t *a = source + size_t(above) * sourceStride;
            const uint8_t *b = source + size_t(below) * sourceStride;
            for (size_t x = 0; x < rowBytes; ++x) output[x] = uint8_t((unsigned(a[x]) + unsigned(b[x]) + 1) >> 1);
        }
    }
    return 0;
}
