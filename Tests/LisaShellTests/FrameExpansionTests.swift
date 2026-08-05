import Testing
@testable import LisaShell

/// Tests for `expand1bppRow(_:into:)` -- the pure-Swift 1bpp-packed ->
/// 8bpp-grayscale bit-unpacking math that backs `LisaApp`'s CGImage blit
/// (`docs/superpowers/plans/2026-08-05-m1c-app-shell.md` Task 3
/// "Interfaces": kept out of `LisaApp` and in this Foundation-only target
/// specifically so it's unit-testable without CoreGraphics/vImage).
///
/// Bit order and polarity match the established M1b/M1c convention: MSB
/// first within each packed byte (bit 7 is that byte's leftmost pixel),
/// set bit = black. See `Sources/lisadbg/main.swift`'s
/// `writeScreenshotPNG`/`asciiPreview` (byteIndex/bit math) and
/// `Tests/LisaCoreTests/ROMBootTests.swift`'s `blackPixels` computation
/// via `UInt8.nonzeroBitCount`, both of which this function's expansion
/// must agree with pixel-for-pixel.
@Suite
struct FrameExpansionTests {
    @Test
    func allClearBitsProduceWhite() {
        var output = [UInt8](repeating: 0, count: 16)
        expand1bppRow([0x00, 0x00], into: &output)
        #expect(output == [UInt8](repeating: 255, count: 16))
    }

    @Test
    func allSetBitsProduceBlack() {
        var output = [UInt8](repeating: 0, count: 16)
        expand1bppRow([0xFF, 0xFF], into: &output)
        #expect(output == [UInt8](repeating: 0, count: 16))
    }

    @Test
    func msbFirstBitOrderMatchesEstablishedConvention() {
        // 0b1011_0000: bit7 (MSB, leftmost pixel) = 1 -> black(0), bit6 = 0
        // -> white(255), bit5 = 1 -> black(0), bit4 = 1 -> black(0), bits
        // 3..0 = 0 -> white(255).
        var output = [UInt8](repeating: 0, count: 8)
        expand1bppRow([0b1011_0000], into: &output)
        #expect(output == [0, 255, 0, 0, 255, 255, 255, 255])
    }

    @Test
    func partialByteWidthOnlyExpandsRequestedPixelCount() {
        // `output.count` (not the packed byte count * 8) governs how many
        // pixels get expanded -- exercised here with a width narrower than
        // one full packed byte's 8 pixels. A real 720px-wide frame row
        // (90 bytes) never needs this, but the function must not assume
        // width is a multiple of 8.
        var output = [UInt8](repeating: 0, count: 3)
        expand1bppRow([0b101_00000], into: &output)
        #expect(output == [0, 255, 0])
    }

    @Test
    func multiByteRowExpandsInByteOrder() {
        var output = [UInt8](repeating: 0, count: 24)
        expand1bppRow([0xFF, 0x00, 0b1000_0001], into: &output)
        #expect(Array(output[0..<8]) == [UInt8](repeating: 0, count: 8))
        #expect(Array(output[8..<16]) == [UInt8](repeating: 255, count: 8))
        #expect(output[16] == 0)
        #expect(Array(output[17..<23]) == [UInt8](repeating: 255, count: 6))
        #expect(output[23] == 0)
    }
}
