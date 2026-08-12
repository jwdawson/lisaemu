import CoreGraphics
import Foundation
import Testing
@testable import LisaApp
@testable import LisaShell

/// Behavior-pin for the perf-fix round's "CGImage pipeline reuse" +
/// "per-scanline array elimination" + "rowBuffer promotion" fixes
/// (`AppModel.makeCGImage`): the NEW implementation writes rows directly
/// into a reused `CGContext`'s backing buffer instead of building a fresh
/// `Data`/`CGDataProvider` (and a fresh per-row `Array` slice/`rowBuffer`)
/// every call -- this suite keeps a frozen COPY of the OLD implementation
/// (as it stood before that fix) and asserts pixel-for-pixel identical
/// output against the new one, across the same synthetic framebuffer
/// patterns for both a reused-context ("hot path", `apply(_:)`-shaped) and
/// fresh-context ("cold path", screenshot-shaped) call sequence.
///
/// Not run as part of this session's `swift test` (root `Package.swift`
/// doesn't include `LisaApp` -- see `LisaApp/project.yml`'s doc comment);
/// exercised via the LisaApp xcodebuild validation step.
@Suite
struct FrameRenderingTests {
    // MARK: - Frozen copy of the OLD (pre-perf-fix) implementation

    /// Byte-for-byte copy of `expand1bppRow` as it stood before the
    /// perf-fix round (full-array in/out, no offsets) -- kept private to
    /// this test file so the behavior pin doesn't depend on (or get
    /// silently "fixed" by changes to) the real, now offset-based,
    /// `LisaShell.expand1bppRow`.
    private static func oldExpand1bppRow(_ packedRow: [UInt8], into output: inout [UInt8]) {
        let width = output.count
        for x in 0..<width {
            let byteIndex = x / 8
            let bit = 7 - (x % 8)
            let isSet = (packedRow[byteIndex] >> bit) & 1 != 0
            output[x] = isSet ? 0 : 255
        }
    }

    /// Byte-for-byte copy of `AppModel.makeCGImage` as it stood before the
    /// perf-fix round: fresh `rowBuffer`/`Array` slice per row, whole-frame
    /// `Data(scratch) as CFData` + `CGDataProvider` per call.
    private static func oldMakeCGImage(frame: Frame, scratch: inout [UInt8]) -> CGImage? {
        let width = frame.width
        let height = frame.height
        let bytesPerRow = (width + 7) / 8
        let pixelCount = width * height
        if scratch.count != pixelCount {
            scratch = [UInt8](repeating: 0, count: pixelCount)
        }
        var rowBuffer = [UInt8](repeating: 0, count: width)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            let rowEnd = min(rowStart + bytesPerRow, frame.bits.count)
            guard rowEnd > rowStart else { break }
            let packedRow = Array(frame.bits[rowStart..<rowEnd])
            oldExpand1bppRow(packedRow, into: &rowBuffer)
            scratch.replaceSubrange(y * width..<(y + 1) * width, with: rowBuffer)
        }
        guard let provider = CGDataProvider(data: Data(scratch) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Synthetic framebuffer patterns

    /// 720x8 (real Lisa width, a handful of rows -- enough to exercise
    /// multi-row behavior without a slow 364-row test): every packed byte
    /// is `fill`.
    private func solidFrame(fill: UInt8, height: Int = 8) -> Frame {
        let width = 720
        let bytesPerRow = (width + 7) / 8
        let bits = [UInt8](repeating: fill, count: bytesPerRow * height)
        return Frame(bits: bits, width: width, height: height, sequence: 1)
    }

    /// Alternating-bit pattern (`0xAA` / `0x55` on alternating rows) --
    /// exercises every bit position's MSB-first expansion, not just the
    /// uniform all-0/all-1 cases.
    private func alternatingFrame(height: Int = 8) -> Frame {
        let width = 720
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            let fill: UInt8 = y.isMultiple(of: 2) ? 0xAA : 0x55
            for b in 0..<bytesPerRow {
                bits[y * bytesPerRow + b] = fill
            }
        }
        return Frame(bits: bits, width: width, height: height, sequence: 2)
    }

    /// A structured, non-uniform "menu-like" pattern: a solid top border
    /// row, alternating-column body rows, and a solid bottom border row --
    /// closer to real UI content (menu bar/window chrome) than a pure
    /// solid or alternating fill.
    private func menuLikeFrame() -> Frame {
        let width = 720
        let height = 12
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * height)
        for b in 0..<bytesPerRow { bits[b] = 0xFF }                          // row 0: solid black border
        for b in 0..<bytesPerRow { bits[(height - 1) * bytesPerRow + b] = 0xFF }  // last row: solid border
        for y in 1..<(height - 1) {
            for b in 0..<bytesPerRow {
                // A different byte pattern per row/column so the test
                // isn't just re-checking the alternating case.
                bits[y * bytesPerRow + b] = UInt8((y * 37 + b * 11) & 0xFF)
            }
        }
        return Frame(bits: bits, width: width, height: height, sequence: 3)
    }

    /// Extracts the raw 8bpp grayscale bytes backing a `CGImage` produced
    /// by either the old or new pipeline, for direct byte comparison.
    /// Both pipelines build their `CGImage` with `bytesPerRow == width` (no
    /// row padding), so this is a flat `width * height` byte buffer with
    /// no stride math needed.
    private func pixelBytes(_ image: CGImage?) -> [UInt8]? {
        guard let image, let data = image.dataProvider?.data else { return nil }
        return [UInt8](data as Data)
    }

    private func assertIdentical(_ frame: Frame, _ label: String) {
        var oldScratch: [UInt8] = []
        let oldImage = FrameRenderingTests.oldMakeCGImage(frame: frame, scratch: &oldScratch)

        // Hot-path shape: a reused context, as `apply(_:)` uses across
        // vsyncs (exercised here across two calls with the SAME frame, to
        // also confirm reuse doesn't corrupt output on a second pass).
        var reusedContext: CGContext?
        _ = AppModel.makeCGImage(frame: frame, context: &reusedContext)
        let hotImage = AppModel.makeCGImage(frame: frame, context: &reusedContext)

        // Cold-path shape: a fresh context per call, as the screenshot path
        // uses.
        var freshContext: CGContext?
        let coldImage = AppModel.makeCGImage(frame: frame, context: &freshContext)

        let oldBytes = pixelBytes(oldImage)
        #expect(oldBytes != nil, "\(label): old pipeline produced an image")
        #expect(pixelBytes(hotImage) == oldBytes, "\(label): reused-context (hot path) output diverges from the old pipeline")
        #expect(pixelBytes(coldImage) == oldBytes, "\(label): fresh-context (cold path) output diverges from the old pipeline")
    }

    @Test func allBlackFrameMatchesOldPipeline() {
        assertIdentical(solidFrame(fill: 0xFF), "all-black")
    }

    @Test func allWhiteFrameMatchesOldPipeline() {
        assertIdentical(solidFrame(fill: 0x00), "all-white")
    }

    @Test func alternatingBitsFrameMatchesOldPipeline() {
        assertIdentical(alternatingFrame(), "alternating-bits")
    }

    @Test func menuLikePatternFrameMatchesOldPipeline() {
        assertIdentical(menuLikeFrame(), "menu-like")
    }

    /// The `CGImage` dimensions/metadata themselves (not just pixel bytes)
    /// must also match -- a regression that e.g. silently produced a
    /// wrong-sized image would still pass a bytes-only comparison if the
    /// two images happened to have compatible flat lengths.
    @Test func dimensionsAndFormatMatchOldPipeline() {
        let frame = menuLikeFrame()
        var oldScratch: [UInt8] = []
        let oldImage = FrameRenderingTests.oldMakeCGImage(frame: frame, scratch: &oldScratch)
        var context: CGContext?
        let newImage = AppModel.makeCGImage(frame: frame, context: &context)

        #expect(newImage?.width == oldImage?.width)
        #expect(newImage?.height == oldImage?.height)
        #expect(newImage?.bitsPerComponent == oldImage?.bitsPerComponent)
        #expect(newImage?.bitsPerPixel == oldImage?.bitsPerPixel)
        #expect(newImage?.bytesPerRow == oldImage?.bytesPerRow)
    }

    /// `pixelContext`-shaped reuse across DIFFERENT frames in sequence
    /// (not just the same frame twice) -- the real `apply(_:)` call
    /// pattern -- to catch any stale-row-leftover bug from reusing one
    /// context's buffer across genuinely different content.
    @Test func reusedContextAcrossDifferentFramesMatchesOldPipelinePerFrame() {
        var reusedContext: CGContext?
        let frames = [solidFrame(fill: 0x00), solidFrame(fill: 0xFF), alternatingFrame(), menuLikeFrame()]
        for frame in frames {
            var oldScratch: [UInt8] = []
            let oldImage = FrameRenderingTests.oldMakeCGImage(frame: frame, scratch: &oldScratch)
            let newImage = AppModel.makeCGImage(frame: frame, context: &reusedContext)
            #expect(pixelBytes(newImage) == pixelBytes(oldImage), "sequence step for a \(frame.width)x\(frame.height) frame diverges")
        }
    }
}
