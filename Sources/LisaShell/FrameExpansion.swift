import Foundation

/// Expands one packed 1bpp framebuffer row into 8bpp grayscale pixel
/// samples (one `UInt8` per pixel), reading directly out of a larger
/// packed buffer (`packed`, at byte offset `rowByteOffset`) and writing
/// directly into a larger output buffer (`output`, at pixel offset
/// `outputOffset`) -- no per-row copy of either side. This is the whole
/// point of the offset-based shape (perf-fix round, "per-scanline array
/// elimination"): the old `packedRow: [UInt8]`/`output: inout [UInt8]`
/// pair required the caller to slice out a fresh `Array` per row before
/// calling in, and a `replaceSubrange` after -- at 60Hz and ~364 rows/
/// frame that was ~22k small allocations/sec. `AppModel.makeCGImage`
/// instead calls this once per row directly against `frame.bits` and a
/// `CGContext`'s raw backing buffer.
///
/// Pure-Swift bit-unpacking math, deliberately living here rather than in
/// `LisaApp`: `LisaShell` stays Foundation-only (no CoreGraphics/vImage,
/// per the plan's Global Constraints), which keeps this the one seam of
/// "1bpp -> pixels" math that's unit-testable headless. `LisaApp` wraps
/// the result in a `CGImage` (`AppModel.makeCGImage`); it does no bit math
/// of its own.
///
/// Bit order and polarity match the established M1b/M1c convention: MSB
/// first within each packed byte (bit 7 is that byte's leftmost pixel),
/// and a *set* bit is black. See `Sources/lisadbg/main.swift`'s
/// `writeScreenshotPNG`/`asciiPreview` (identical `byteIndex`/`bit` math)
/// and `FramePublisher`'s doc comment (`Bus.framebufferSnapshot`'s
/// producers/consumers use the same convention throughout). Here the
/// polarity is baked directly into the output sample values -- 0 = black,
/// 255 = white -- rather than expressed via a `CGImage` `decode` array
/// (that trick only works for 1bpp images; once expanded to 8bpp there is
/// no decode array, so correctness has to live in this function).
///
/// `width` determines how many pixels are expanded -- it need not be a
/// multiple of 8 (though every real Lisa framebuffer row, 720px = 90
/// bytes, is). `packed` need not hold a full `ceil(width / 8)` bytes past
/// `rowByteOffset` -- any pixel whose source byte would fall outside
/// `packed` expands to white (255), rather than trapping; a well-formed
/// caller (every real frame) never hits that path, but a malformed/
/// truncated synthetic frame degrades gracefully instead of crashing.
public func expand1bppRow(
    _ packed: [UInt8],
    rowByteOffset: Int,
    into output: UnsafeMutableBufferPointer<UInt8>,
    outputOffset: Int,
    width: Int
) {
    for x in 0..<width {
        let byteIndex = rowByteOffset + x / 8
        let bit = 7 - (x % 8)
        let isSet = byteIndex < packed.count && (packed[byteIndex] >> bit) & 1 != 0
        output[outputOffset + x] = isSet ? 0 : 255
    }
}
