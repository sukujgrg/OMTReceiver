#include "../OMTReceiver/Codec/OMTVMXDecoder.h"
#include "../Vendor/libvmx/src/vmxcodec.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include "../Vendor/libvmx/src/vmxcodec_common.h"
#include <memory>
#include <vector>

namespace {
using Encoder = std::unique_ptr<VMX_INSTANCE, decltype(&VMX_Destroy)>;
using Decoder = std::unique_ptr<OMTVMXDecoder, decltype(&OMTVMXDecoderDestroy)>;

std::vector<uint8_t> encode(int height, bool interlaced, bool alpha = false) {
    Encoder encoder(VMX_Create({32, height}, VMX_PROFILE_OMT_SQ, VMX_COLORSPACE_BT709), VMX_Destroy);
    if (!encoder) return {};
    VMX_SetThreads(encoder.get(), 1); VMX_SetQuality(encoder.get(), 100);
    const int stride = alpha ? 128 : 64;
    std::vector<uint8_t> pixels(size_t(stride) * size_t(height));
    for (int y = 0; y < height; ++y) {
        const int start = (y & 1) ? 16 : 8;
        if (alpha) {
            for (int x = 0; x < 32; ++x) {
                uint8_t *p = pixels.data() + size_t(y) * size_t(stride) + size_t(x) * 4;
                p[0] = 20; p[1] = 40; p[2] = x >= start && x < start + 8 ? 220 : 32; p[3] = 128;
            }
        } else {
            for (int x = 0; x < 32; x += 2) {
                uint8_t *p = pixels.data() + size_t(y) * size_t(stride) + size_t(x) * 2;
                p[0] = 128; p[2] = 128;
                p[1] = x >= start && x < start + 8 ? 220 : 32;
                p[3] = x + 1 >= start && x + 1 < start + 8 ? 220 : 32;
            }
        }
    }
    VMX_ERR status = alpha ? VMX_EncodeBGRA(encoder.get(), pixels.data(), stride, interlaced)
                           : VMX_EncodeUYVY(encoder.get(), pixels.data(), stride, interlaced);
    if (status != VMX_ERR_OK) return {};
    std::vector<uint8_t> wire(1024 * 1024);
    int length = VMX_SaveTo(encoder.get(), wire.data(), int(wire.size()));
    if (length <= 0) return {};
    wire.resize(size_t(length));
    return wire;
}

bool acceptsActualFieldsAndRejectsContradictions() {
    for (int height : {480, 576, 1080}) {
        auto wire = encode(height, true);
        auto progressive = encode(height, false);
        if (wire.empty() || progressive.empty()) return false;
        if (OMTVMXValidate(wire.data(), wire.size(), 32, height, 1) != 0
            || OMTVMXValidate(progressive.data(), progressive.size(), 32, height, 0) != 0) return false;
        if (OMTVMXValidate(wire.data(), wire.size(), 32, height, 0) == 0
            || OMTVMXValidate(progressive.data(), progressive.size(), 32, height, 1) == 0
            || OMTVMXValidate(wire.data(), wire.size(), 32, height - 16, 1) == 0) return false;
        for (uint32_t flags : {4u, 8u, 9u, 16u, 17u, 0xffffffffu}) {
            if (OMTVMXValidate(wire.data(), wire.size(), 32, height, flags) == 0) return false;
        }
        auto alpha = encode(height, true, true);
        // Opaque advertisement can retain a fully validated optional alpha plane.
        if (alpha.empty() || OMTVMXValidate(alpha.data(), alpha.size(), 32, height, 3) != 0
            || OMTVMXValidate(alpha.data(), alpha.size(), 32, height, 7) != 0
            || OMTVMXValidate(alpha.data(), alpha.size(), 32, height, 1) != 0
            || OMTVMXValidate(wire.data(), wire.size(), 32, height, 3) == 0) return false;
        for (size_t length = 0; length < wire.size(); ++length) {
            if (OMTVMXValidate(wire.data(), length, 32, height, 1) == 0) return false;
        }
        const size_t header = wire[0] == 3 ? 5 : 3;
        const size_t count = size_t(wire[header]) | size_t(wire[header + 1]) << 8
            | size_t(wire[header + 2]) << 16 | size_t(wire[header + 3]) << 24;
        std::fill(wire.begin() + header + 4, wire.begin() + header + 4 + count, 0);
        if (OMTVMXValidate(wire.data(), wire.size(), 32, height, 1) == 0) return false;
    }
    return true;
}

bool decodedFieldPixelsAndPaddingAreCorrect() {
    for (int height : {480, 576, 1080}) for (bool alpha : {false, true}) {
        auto wire = encode(height, true, alpha);
        Decoder decoder(OMTVMXDecoderCreate(32, height, 709), OMTVMXDecoderDestroy);
        if (!decoder || wire.empty()) return false;
        const size_t bpp = alpha ? 4 : 2;
        const size_t stride = 32 * bpp;
        const size_t capacity = stride * size_t(height);
        std::vector<uint8_t> woven(capacity + 64, 0xcc), output(capacity + 64, 0xcc);
        if (OMTVMXDecoderDecode(decoder.get(), wire.data(), wire.size(), alpha ? 3 : 1,
                               woven.data(), capacity, stride) != 0) return false;
        // Absolute source expectations prevent a blank decoded image from
        // passing a comparison against another blank decoded image.
        for (int y = 0; y < height; ++y) {
            const int bright = (y & 1) ? 16 : 8;
            const int dark = (y & 1) ? 8 : 16;
            const int channel = alpha ? 2 : 1;
            const uint8_t *row = woven.data() + size_t(y) * stride;
            const int expectedBright = alpha ? 110 : 220, expectedDark = alpha ? 16 : 32;
            if (std::abs(int(row[size_t(bright) * bpp + size_t(channel)]) - expectedBright) > 5
                || std::abs(int(row[size_t(dark) * bpp + size_t(channel)]) - expectedDark) > 5) {
                std::printf("Field source mismatch: height%d alpha%d y%d bright%d expected%d dark%d expected%d\n",
                            height, alpha, y, row[size_t(bright) * bpp + size_t(channel)], expectedBright,
                            row[size_t(dark) * bpp + size_t(channel)], expectedDark);
                return false;
            }
        }
        for (int field : {0, 1}) {
            std::fill(output.begin(), output.end(), 0xcc);
            if (OMTVMXBob(woven.data(), capacity, stride, output.data(), capacity, stride,
                          32, height, int(bpp), field) != 0) return false;
            for (int y = 0; y < height; ++y) {
                // The decoder can quantize rows slightly differently. Compare
                // every output byte to the selected field's actual neighbouring
                // rows, never to the temporally different opposite field.
                const int above = (y & 1) == field ? y : std::max(field, y - 1);
                const int below = (y & 1) == field ? y : std::min(height - 2 + field, y + 1);
                for (size_t column = 0; column < stride; ++column) {
                    const unsigned a = woven[size_t(above) * stride + column];
                    const unsigned b = woven[size_t(below) * stride + column];
                    const uint8_t expected = uint8_t((a + b + 1) / 2);
                    if (output[size_t(y) * stride + column] != expected) {
                        std::printf("Bob reference mismatch: height%d alpha%d field%d y%d byte%zu expected%d actual%d\n",
                                    height, alpha, field, y, column, expected, output[size_t(y) * stride + column]);
                        return false;
                    }
                }
                if (alpha) for (size_t x = 3; x < stride; x += 4) {
                    if (output[size_t(y) * stride + x] != 255) return false;
                }
            }
            if (!std::all_of(output.begin() + capacity, output.end(), [](uint8_t b) { return b == 0xcc; })) return false;
        }
        if (!std::all_of(woven.begin() + capacity, woven.end(), [](uint8_t b) { return b == 0xcc; })) return false;
    }
    return true;
}

bool equalFieldAndPaddingStridesKeepPointerOwnership() {
    constexpr int stride = 128, height = 16;
    const VMX_SIZE fieldSize{32, height};
    // 32-pixel UYVY physical rows use 64 bytes. A field step is 128 bytes,
    // exactly the temporary stride chosen for 64-pixel padding. Keep the
    // opposite field and tail canaries unchanged during both copies.
    std::vector<BYTE> original(size_t(stride) * height + 1, 0xcc);
    for (int y = 0; y < height; ++y) std::fill_n(original.data() + size_t(y) * stride, 64, BYTE(10 + y));
    BYTE *aligned = nullptr;
    int alignedStride = 0;
    VMX_CreateAlignedStrideBuffer(original.data(), stride, fieldSize, &aligned, &alignedStride, 64, 2);
    if (!aligned) return false;
    if (aligned == original.data() || alignedStride != stride) {
        if (aligned != original.data()) std::free(aligned);
        return false;
    }
    std::memset(aligned, 0xee, size_t(alignedStride) * height);
    VMX_CopyToAlignedStrideBuffer(aligned, alignedStride, original.data(), stride, fieldSize, 2);
    for (int y = 0; y < height; ++y) {
        BYTE *row = aligned + size_t(y) * size_t(alignedStride);
        if (!std::all_of(row, row + 64, [y](BYTE b) { return b == 10 + y; })
            || !std::all_of(row + 64, row + stride, [](BYTE b) { return b == 0xee; })) {
            VMX_FreeAlignedStrideBuffer(aligned, original.data()); return false;
        }
        std::fill_n(row, 64, BYTE(40 + y));
    }
    VMX_CopyFromAlignedStrideBufferAndFree(aligned, alignedStride, original.data(), stride, fieldSize, 2);
    for (int y = 0; y < height; ++y) {
        const BYTE *row = original.data() + size_t(y) * stride;
        if (!std::all_of(row, row + 64, [y](BYTE b) { return b == 40 + y; })
            || !std::all_of(row + 64, row + stride, [](BYTE b) { return b == 0xcc; })) return false;
    }
    return original.back() == 0xcc;
}

bool bobInterpolatesWithinOneFieldAndChecksEveryBufferBound() {
    constexpr int width = 18, height = 16;
    for (int bpp : {2, 4}) {
        const size_t rowBytes = size_t(width) * size_t(bpp), stride = 128;
        const size_t capacity = stride * height;
        std::vector<uint8_t> source(capacity, 0xdd), target(capacity + 1, 0xcc);
        for (int y = 0; y < height; ++y) {
            std::fill_n(source.data() + size_t(y) * stride, rowBytes, uint8_t((y & 1) ? 200 - y * 3 : y * 5));
        }
        for (int field : {0, 1}) {
            if (OMTVMXBob(source.data(), capacity, stride, target.data(), capacity, stride, width, height, bpp, field)) return false;
            for (int y = 0; y < height; ++y) {
                int above = std::max(field, y - 1), below = std::min(height - 2 + field, y + 1);
                unsigned expected = (y & 1) == field ? source[size_t(y) * stride]
                    : (unsigned(source[size_t(above) * stride]) + unsigned(source[size_t(below) * stride]) + 1) / 2;
                const uint8_t *row = target.data() + size_t(y) * stride;
                if (!std::all_of(row, row + rowBytes, [expected](uint8_t b) { return b == expected; })
                    || !std::all_of(row + rowBytes, row + stride, [](uint8_t b) { return b == 0xcc; })) return false;
            }
        }
        if (OMTVMXBob(source.data(), capacity - 1, stride, target.data(), capacity, stride, width, height, bpp, 0) == 0
            || OMTVMXBob(source.data(), capacity, stride, target.data(), capacity - 1, stride, width, height, bpp, 0) == 0
            || OMTVMXBob(source.data(), capacity, rowBytes - 1, target.data(), capacity, stride, width, height, bpp, 0) == 0
            || OMTVMXBob(source.data(), capacity, stride, target.data(), capacity, rowBytes - 1, width, height, bpp, 0) == 0
            || OMTVMXBob(source.data(), capacity, stride, target.data(), capacity, stride, width, height, bpp, 2) == 0
            || target[capacity] != 0xcc) return false;
    }
    return true;
}

bool inPlaceBobMatchesSeparateBuffersAndPreservesBothFieldOrders() {
    constexpr int width = 18, height = 16;
    constexpr size_t stride = 128, capacity = stride * height;
    for (int bpp : {2, 4}) {
        std::vector<uint8_t> source(capacity + 64, 0xcc);
        for (int y = 0; y < height; ++y) for (int x = 0; x < width * bpp; ++x) {
            source[size_t(y) * stride + size_t(x)] = uint8_t(((y & 1) ? 180 - y * 3 : 20 + y * 5) + x % 7);
        }
        for (int first : {0, 1}) {
            auto firstReference = source, secondReference = source;
            if (OMTVMXBob(source.data(), capacity, stride, firstReference.data(), capacity, stride,
                          width, height, bpp, first) != 0
                || OMTVMXBob(source.data(), capacity, stride, secondReference.data(), capacity, stride,
                             width, height, bpp, 1 - first) != 0) return false;
            auto inPlaceSingle = source;
            if (OMTVMXBob(inPlaceSingle.data(), capacity, stride, inPlaceSingle.data(), capacity, stride,
                          width, height, bpp, first) != 0 || inPlaceSingle != firstReference) return false;
            auto inPlacePair = source, alternate = source;
            // Copy the alternate temporal field before overwriting its rows.
            if (OMTVMXBob(inPlacePair.data(), capacity, stride, alternate.data(), capacity, stride,
                          width, height, bpp, 1 - first) != 0
                || OMTVMXBob(inPlacePair.data(), capacity, stride, inPlacePair.data(), capacity, stride,
                             width, height, bpp, first) != 0
                || inPlacePair != firstReference || alternate != secondReference) return false;
        }
        auto overlapping = source;
        if (OMTVMXBob(overlapping.data(), capacity, stride, overlapping.data() + 1, capacity, stride,
                      width, height, bpp, 0) == 0) return false;
        std::vector<uint8_t> mismatched(capacity * 2, 0xcc);
        if (OMTVMXBob(mismatched.data(), mismatched.size(), stride, mismatched.data(), mismatched.size(), stride * 2,
                      width, height, bpp, 0) == 0) return false;
    }
    return true;
}

}

#if defined(OMT_VMX_STANDALONE_TEST)
int main() {
    bool validation = acceptsActualFieldsAndRejectsContradictions();
    bool pixels = decodedFieldPixelsAndPaddingAreCorrect();
    bool bounds = bobInterpolatesWithinOneFieldAndChecksEveryBufferBound();
    bool strides = equalFieldAndPaddingStridesKeepPointerOwnership();
    bool inPlace = inPlaceBobMatchesSeparateBuffersAndPreservesBothFieldOrders();
    std::printf("Interlaced entropy/flags: %s; actual fields/alpha/padding: %s; bob interpolation/bounds: %s; equal-stride ownership: %s; in-place fields/order/alias: %s\n",
                validation ? "PASS" : "FAIL", pixels ? "PASS" : "FAIL", bounds ? "PASS" : "FAIL", strides ? "PASS" : "FAIL", inPlace ? "PASS" : "FAIL");
    return validation && pixels && bounds && strides && inPlace ? 0 : 1;
}
#else
#import <XCTest/XCTest.h>
@interface ReceiverInterlacedNativeTests : XCTestCase
@end
@implementation ReceiverInterlacedNativeTests
- (void)testActualInterlacedEntropyAndScanAgreement { XCTAssertTrue(acceptsActualFieldsAndRejectsContradictions()); }
- (void)testRealFieldsAlphaAnd1080PaddingStayInTheirOwnTemporalImage { XCTAssertTrue(decodedFieldPixelsAndPaddingAreCorrect()); }
- (void)testEqualFieldAndPaddingStridesPreserveCopiesAndOwnership { XCTAssertTrue(equalFieldAndPaddingStridesKeepPointerOwnership()); }
- (void)testInPlaceBobMatchesDistinctBuffersForBothFieldOrdersAndRejectsPartialOverlap { XCTAssertTrue(inPlaceBobMatchesSeparateBuffersAndPreservesBothFieldOrders()); }
- (void)testSpatialBobInterpolatesWithoutCrossingFieldsOrBufferBounds { XCTAssertTrue(bobInterpolatesWithinOneFieldAndChecksEveryBufferBound()); }
@end
#endif
