import Foundation

/// Expands one packed 1bpp framebuffer row into 8bpp grayscale pixel
/// samples (one `UInt8` per pixel).
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
/// `output.count` determines how many pixels are expanded -- it must
/// already be sized to the row's pixel width, which need not be a
/// multiple of 8 (though every real Lisa framebuffer row, 720px = 90
/// bytes, is). `packedRow` must hold at least `ceil(output.count / 8)`
/// bytes.
public func expand1bppRow(_ packedRow: [UInt8], into output: inout [UInt8]) {
    let width = output.count
    for x in 0..<width {
        let byteIndex = x / 8
        let bit = 7 - (x % 8)
        let isSet = (packedRow[byteIndex] >> bit) & 1 != 0
        output[x] = isSet ? 0 : 255
    }
}
