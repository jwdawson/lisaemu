import Testing
@testable import LisaShell

/// Tests for `expand1bppRow(_:rowByteOffset:into:outputOffset:width:)` --
/// the pure-Swift 1bpp-packed -> 8bpp-grayscale bit-unpacking math that
/// backs `LisaApp`'s CGImage blit (`docs/superpowers/plans/2026-08-05-
/// m1c-app-shell.md` Task 3 "Interfaces": kept out of `LisaApp` and in
/// this Foundation-only target specifically so it's unit-testable without
/// CoreGraphics/vImage). Offset-based shape (perf-fix round): both the
/// packed source and the pixel destination are borrowed slices of a
/// larger buffer, not fresh per-row copies -- see the function's own doc
/// comment.
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
    /// Runs `expand1bppRow` against a fresh `width`-pixel output buffer
    /// starting at offset 0, and returns the expanded pixels as a plain
    /// `Array` for easy `#expect` comparison -- most tests here don't care
    /// about offsets, just the bit math, so this keeps them close to their
    /// pre-offset-API shape.
    private func expandRow(_ packed: [UInt8], width: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width)
        output.withUnsafeMutableBufferPointer { buffer in
            expand1bppRow(packed, rowByteOffset: 0, into: buffer, outputOffset: 0, width: width)
        }
        return output
    }

    @Test
    func allClearBitsProduceWhite() {
        #expect(expandRow([0x00, 0x00], width: 16) == [UInt8](repeating: 255, count: 16))
    }

    @Test
    func allSetBitsProduceBlack() {
        #expect(expandRow([0xFF, 0xFF], width: 16) == [UInt8](repeating: 0, count: 16))
    }

    @Test
    func msbFirstBitOrderMatchesEstablishedConvention() {
        // 0b1011_0000: bit7 (MSB, leftmost pixel) = 1 -> black(0), bit6 = 0
        // -> white(255), bit5 = 1 -> black(0), bit4 = 1 -> black(0), bits
        // 3..0 = 0 -> white(255).
        #expect(expandRow([0b1011_0000], width: 8) == [0, 255, 0, 0, 255, 255, 255, 255])
    }

    @Test
    func partialByteWidthOnlyExpandsRequestedPixelCount() {
        // `width` (not the packed byte count * 8) governs how many pixels
        // get expanded -- exercised here with a width narrower than one
        // full packed byte's 8 pixels. A real 720px-wide frame row (90
        // bytes) never needs this, but the function must not assume width
        // is a multiple of 8.
        #expect(expandRow([0b101_00000], width: 3) == [0, 255, 0])
    }

    @Test
    func multiByteRowExpandsInByteOrder() {
        let output = expandRow([0xFF, 0x00, 0b1000_0001], width: 24)
        #expect(Array(output[0..<8]) == [UInt8](repeating: 0, count: 8))
        #expect(Array(output[8..<16]) == [UInt8](repeating: 255, count: 8))
        #expect(output[16] == 0)
        #expect(Array(output[17..<23]) == [UInt8](repeating: 255, count: 6))
        #expect(output[23] == 0)
    }

    /// The whole point of the offset-based signature: reads `packed`
    /// starting mid-buffer (a later row of a larger packed framebuffer)
    /// and writes into `output` starting mid-buffer (a later row of a
    /// larger pixel buffer, e.g. a `CGContext`'s backing store) -- without
    /// disturbing bytes/pixels outside the requested row on either side.
    @Test
    func rowByteOffsetAndOutputOffsetAddressALaterRowInPlace() {
        // Two packed rows back to back: row 0 = all-clear (white), row 1 =
        // all-set (black).
        let packed: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
        var output = [UInt8](repeating: 99, count: 32)  // sentinel outside both target rows
        output.withUnsafeMutableBufferPointer { buffer in
            // Row 1's pixels land at output offset 16 (row 0's slot, 0..<16,
            // is left untouched -- still the 99 sentinel).
            expand1bppRow(packed, rowByteOffset: 2, into: buffer, outputOffset: 16, width: 16)
        }
        #expect(Array(output[0..<16]) == [UInt8](repeating: 99, count: 16), "row 0's slot untouched")
        #expect(Array(output[16..<32]) == [UInt8](repeating: 0, count: 16), "row 1 (all-set) expanded to black")
    }

    /// A byte index that would fall outside `packed` (a malformed/
    /// truncated synthetic frame -- never happens for a real, fully-
    /// populated `Frame`) degrades to white instead of trapping.
    @Test
    func outOfRangeSourceByteExpandsToWhiteInsteadOfTrapping() {
        #expect(expandRow([0xFF], width: 16) == [0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255])
    }
}
