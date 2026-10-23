#include "../Vendor/libvmx/src/vmxcodec.h"
#include <algorithm>
#include <array>
#include <vector>

namespace {
struct SaveFixture {
    std::array<BYTE, 8> dc{{0x11, 0x22}};
    std::array<BYTE, 8> ac{{0x33, 0x44, 0x55}};
    VMX_SLICE_SET slice{};
    VMX_SLICE_SET *slices[1]{&slice};
    VMX_INSTANCE instance{};

    SaveFixture() {
        slice.DC.Stream = dc.data(); slice.DC.StreamPos = dc.data() + 2;
        slice.AC.Stream = ac.data(); slice.AC.StreamPos = ac.data() + 3;
        slice.DC.MaxStreamLength = int(dc.size()); slice.AC.MaxStreamLength = int(ac.size());
        instance.Slices = slices; instance.SliceCount = 1; instance.Quality = 80;
        instance.Format = VMX_FORMAT_PROGRESSIVE;
    }
};

bool preservesShortAndExtendedWireLengths() {
    for (int shift : {0, 3}) {
        SaveFixture fixture;
        fixture.instance.DCShift = shift;
        std::vector<BYTE> expected = shift ? std::vector<BYTE>{3, 3, 1, 80, 1}
                                          : std::vector<BYTE>{1, 80, 1};
        const std::vector<BYTE> body{2, 0, 0, 0, 0x11, 0x22, 3, 0, 0, 0, 0x33, 0x44, 0x55};
        expected.insert(expected.end(), body.begin(), body.end());
        std::array<BYTE, 64> output{};
        const int written = VMX_SaveTo(&fixture.instance, output.data(), int(output.size()));
        if (written != int(expected.size()) || !std::equal(expected.begin(), expected.end(), output.begin())) return false;
    }
    return true;
}

bool respectsEveryShortOutputCapacity() {
    for (int shift : {0, 3}) {
        const int encodedSize = shift ? 18 : 16;
        for (int capacity = 0; capacity <= encodedSize + 1; ++capacity) {
            SaveFixture fixture;
            fixture.instance.DCShift = shift;
            std::array<BYTE, 64> guarded;
            guarded.fill(0xcc);
            const int written = VMX_SaveTo(&fixture.instance, guarded.data() + 1, capacity);
            if (written != (capacity >= encodedSize ? encodedSize : 0) || guarded[0] != 0xcc) return false;
            if (!std::all_of(guarded.begin() + 1 + capacity, guarded.end(), [](BYTE b) { return b == 0xcc; })) return false;
        }
    }
    return true;
}

bool rejectsInvalidLengthAndBackwardStream() {
    SaveFixture fixture;
    std::array<BYTE, 64> output;
    output.fill(0xcc);
    if (VMX_SaveTo(&fixture.instance, output.data(), -1) != 0) return false;
    if (!std::all_of(output.begin(), output.end(), [](BYTE b) { return b == 0xcc; })) return false;
    fixture.slice.DC.Stream = fixture.dc.data() + 2;
    fixture.slice.DC.StreamPos = fixture.dc.data();
    return VMX_SaveTo(&fixture.instance, output.data(), int(output.size())) == 0;
}
}

#if defined(OMT_VMX_STANDALONE_TEST)
int main() {
    return preservesShortAndExtendedWireLengths() && respectsEveryShortOutputCapacity()
        && rejectsInvalidLengthAndBackwardStream() ? 0 : 1;
}
#else
#import <XCTest/XCTest.h>
@interface ReceiverCodecSaveTests : XCTestCase
@end
@implementation ReceiverCodecSaveTests
- (void)testPreservesShortAndExtendedWireLengths { XCTAssertTrue(preservesShortAndExtendedWireLengths()); }
- (void)testRespectsEveryShortOutputCapacity { XCTAssertTrue(respectsEveryShortOutputCapacity()); }
- (void)testRejectsInvalidLengthAndBackwardStream { XCTAssertTrue(rejectsInvalidLengthAndBackwardStream()); }
@end
#endif
