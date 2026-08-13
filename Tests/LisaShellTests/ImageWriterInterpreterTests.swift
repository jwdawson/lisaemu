import Foundation
import Testing
@testable import LisaShell

/// Golden tests for `ImageWriterInterpreter`. Every input stream here is
/// **synthetic and authored in this file** — no Lisa/Apple data is used. The
/// escape-code semantics under test are the contract derived in
/// docs/hardware-notes.md §12 from `LibPr/CiDev`.
///
/// Raster identity is pinned two ways: (1) specific-pixel + geometry
/// assertions where an exact dot placement is the point, and (2) a 64-bit
/// FNV-1a fingerprint over `bits` (same shape as `ROMBootTests`/`GovernorTests`)
/// to catch any unintended change to a whole page. Fingerprints are values we
/// locked from a known-good run; they assert *stability*, not a hand-computed
/// truth.
@Suite
struct ImageWriterInterpreterTests {

    // MARK: - Helpers

    /// 64-bit FNV-1a over a page's packed bits — the repo's standard raster
    /// fingerprint shape.
    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// Collects every emitted page for a stream.
    static func run(_ config: ImageWriterInterpreter.Config = .imageWriterPortraitHiRes,
                    _ build: (ImageWriterInterpreter) -> Void) -> [PrinterPage] {
        let interp = ImageWriterInterpreter(config: config)
        var pages: [PrinterPage] = []
        interp.onPage = { pages.append($0) }
        build(interp)
        return pages
    }

    static let esc: UInt8 = 27
    static let lf: UInt8 = 10

    /// ASCII decimal digits, `count` wide, zero-padded (the operand format
    /// ciprint emits — §12.4).
    static func digits(_ value: Int, _ count: Int) -> [UInt8] {
        var s = String(value)
        while s.count < count { s = "0" + s }
        return Array(s.utf8.suffix(count))
    }

    /// A standard-graphics band: `ESC 'G' nnnn` + column bytes.
    static func stdBand(_ columns: [UInt8]) -> [UInt8] {
        [esc, UInt8(ascii: "G")] + digits(columns.count, 4) + columns
    }

    /// A fast-graphics band: `ESC 'g' nnn` + column bytes (count must be a
    /// multiple of 8, §12.4).
    static func fastBand(_ columns: [UInt8]) -> [UInt8] {
        [esc, UInt8(ascii: "g")] + digits(columns.count / 8, 3) + columns
    }

    static func setLineHeight(_ n: Int) -> [UInt8] {
        [esc, UInt8(ascii: "T")] + digits(n, 2)
    }

    static func tab(_ x: Int) -> [UInt8] { [esc, UInt8(ascii: "F")] + digits(x, 4) }

    /// True if the ink bit at (x, y) is set in a page.
    static func inked(_ page: PrinterPage, _ x: Int, _ y: Int) -> Bool {
        let idx = y * page.rowBytes + (x >> 3)
        return page.bits[idx] & (0x80 >> UInt8(x & 7)) != 0
    }

    static func inkCount(_ page: PrinterPage) -> Int {
        page.bits.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    // MARK: - Geometry / construction

    @Test
    func hiResPageGeometryMatchesTheContract() {
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0xFF]))   // one column, top-left
            interp.flush()
        }
        #expect(pages.count == 1)
        let p = pages[0]
        #expect(p.width == 1280)
        #expect(p.height == 1584)
        #expect(p.rowBytes == 160)
        #expect(p.dpi.h == 160)
        #expect(p.dpi.v == 144)
    }

    @Test
    func loResPresetGeometry() {
        let pages = Self.run(.imageWriterPortraitLoRes) { interp in
            interp.feed(Self.esc); interp.feed(UInt8(ascii: "E"))  // 96 bpi
            interp.feed(Self.stdBand([0xFF]))
            interp.flush()
        }
        #expect(pages.count == 1)
        #expect(pages[0].width == 768)
        #expect(pages[0].height == 792)   // 11in * 72 spi
        #expect(pages[0].dpi == PrinterPage.DPI(h: 96, v: 72))
    }

    // MARK: - Graphics: exact dot placement + bit order

    @Test
    func standardGraphicsColumnBitOrderTopIsBit7() {
        // A single column 0x81 = bit7 (pin 0, top) + bit0 (pin 7, bottom). The
        // head is a 72-dpi 8-pin column, so on the 144-vpi canvas the pins sit
        // 2 rows apart (§12.5): pin 0 → row 0, pin 7 → row 14. (The intervening
        // odd rows are where the SECOND interlace half-band's pins land.)
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0x81]))
            interp.flush()
        }
        let p = pages[0]
        #expect(Self.inked(p, 0, 0))        // bit7 = top pin, row 0
        #expect(!Self.inked(p, 0, 1))       // 2/144 pitch — no dot on the interlace row
        #expect(!Self.inked(p, 0, 7))       // (was the bug's location under the 1/144 mapping)
        #expect(Self.inked(p, 0, 14))       // bit0 = bottom pin, 7 × 2 = row 14
        #expect(Self.inkCount(p) == 2)
    }

    @Test
    func columnsAdvanceHorizontally() {
        // Three columns → three adjacent inked dots on the top row.
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0x80, 0x80, 0x80]))
            interp.flush()
        }
        let p = pages[0]
        #expect(Self.inked(p, 0, 0))
        #expect(Self.inked(p, 1, 0))
        #expect(Self.inked(p, 2, 0))
        #expect(!Self.inked(p, 3, 0))
        #expect(Self.inkCount(p) == 3)
    }

    @Test
    func fastGraphicsEquivalentToStandardForSameColumns() {
        // ESC g nnn with count/8 must paint the same dots as ESC G nnnn.
        let columns: [UInt8] = (0..<8).map { UInt8(0x80 >> ($0 % 8)) }
        let std = Self.run { $0.feed(Self.stdBand(columns)); $0.flush() }[0]
        let fast = Self.run { $0.feed(Self.fastBand(columns)); $0.flush() }[0]
        #expect(Self.fnv(std.bits) == Self.fnv(fast.bits))
        #expect(Self.inkCount(std) == 8)
    }

    @Test
    func tabSetsAbsoluteColumn() {
        let pages = Self.run { interp in
            interp.feed(Self.tab(100))
            interp.feed(Self.stdBand([0x80]))
            interp.flush()
        }
        #expect(Self.inked(pages[0], 100, 0))
        #expect(Self.inkCount(pages[0]) == 1)
    }

    @Test
    func elongatedDoublesColumnsHorizontally() {
        let pages = Self.run { interp in
            interp.feed(14)                       // SO = wide on
            interp.feed(Self.stdBand([0x80]))     // one column → two dots
            interp.feed(15)                       // SI = wide off
            interp.flush()
        }
        let p = pages[0]
        #expect(Self.inked(p, 0, 0))
        #expect(Self.inked(p, 1, 0))
        #expect(Self.inkCount(p) == 2)
    }

    // MARK: - Two-pass interlace geometry (§12.5) — the regression that would
    // have caught the "double-struck comb" bug the user hit on real content.

    @Test
    func interlacedHalfBandsProduceASolidVerticalStroke() {
        // The driver prints a hi-res 144-vpi column as TWO 8-pin bands offset by
        // the half-pitch: band 1 at y, advance 1/144 (ESC T 01 + LF), band 2 at
        // y+1 (CiDeltaV 1-then-15, §12.5). Each band's pins are 2/144 apart, so
        // the two bands INTERLEAVE into 16 contiguous inked rows — a solid
        // vertical stroke. Under the old `y144+p` mapping the bands OVERLAPPED
        // (rows 0..7 then 1..8), leaving rows 9..15 blank: the comb/doubling.
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0xFF]))     // band 1: pins at rows 0,2,…,14
            interp.feed(Self.setLineHeight(1))    // half-pitch advance
            interp.feed(Self.lf)                  // y144 → 1
            interp.feed(Self.tab(0))              // LF is not CR (§12.5)
            interp.feed(Self.stdBand([0xFF]))     // band 2: pins at rows 1,3,…,15
            interp.flush()
        }
        let p = pages[0]
        // All 16 rows 0..15 in column 0 must be inked — a solid stroke, no comb.
        for y in 0...15 {
            #expect(Self.inked(p, 0, y), "interlaced stroke must be solid at row \(y)")
        }
        #expect(!Self.inked(p, 0, 16), "the stroke ends at row 15 (16/144 = one band pair)")
        #expect(Self.inkCount(p) == 16)
    }

    // MARK: - Density modes (each bpi ciprint uses, §12.2/§12.3)

    @Test
    func densityCodesSetReportedHorizontalDpi() {
        let cases: [(UInt8, Int)] = [
            (UInt8(ascii: "n"), 72), (UInt8(ascii: "N"), 80),
            (UInt8(ascii: "E"), 96), (UInt8(ascii: "q"), 120),
            (UInt8(ascii: "Q"), 136), (UInt8(ascii: "p"), 144),
            (UInt8(ascii: "P"), 160),
        ]
        for (code, dpi) in cases {
            let pages = Self.run { interp in
                interp.feed(Self.esc); interp.feed(code)
                interp.feed(Self.stdBand([0xFF]))
                interp.flush()
            }
            #expect(pages[0].dpi.h == dpi, "ESC \(Character(UnicodeScalar(code))) → \(dpi) bpi")
        }
    }

    @Test
    func densityMatchingCanvasIsNotLoggedButMismatchIs() {
        // Matching the canvas dpiH (default 160 = ESC P): no diagnostic.
        let matched = ImageWriterInterpreter()
        matched.feed(Self.esc); matched.feed(UInt8(ascii: "P"))
        #expect(matched.unknownLog.isEmpty)

        // Commanding a density that disagrees with the fixed canvas produces a
        // silently mis-scaled raster (§12.6.1), so it must be bounded-logged.
        let mismatched = ImageWriterInterpreter()   // canvas dpiH = 160
        mismatched.feed(Self.esc); mismatched.feed(UInt8(ascii: "E"))  // 96 ≠ 160
        #expect(mismatched.unknownLog.count == 1)
        #expect(mismatched.unknownLog[0].byte == UInt8(ascii: "E"))
    }

    @Test
    func densityMismatchLoggingIsBounded() {
        let interp = ImageWriterInterpreter()   // canvas dpiH = 160
        // 400 mismatched density commands (ESC E = 96) → capped at logLimit.
        for _ in 0..<400 { interp.feed(Self.esc); interp.feed(UInt8(ascii: "E")) }
        #expect(interp.unknownLog.count == 256)
        #expect(interp.unknownLogDropped == 400 - 256)
    }

    // MARK: - Line feeds / vertical placement

    @Test
    func lineFeedAdvancesByLineHeightOntoLaterRows() {
        // Bare LF advances paper but is NOT a carriage return (§12.5): the
        // driver always tabs before a band (CiDev:444), so we tab back to 0.
        let pages = Self.run { interp in
            interp.feed(Self.setLineHeight(72))   // 72/144 in = 72 rows at 144 dpi
            interp.feed(Self.stdBand([0x80]))     // row 0
            interp.feed(Self.lf)                  // advance 72
            interp.feed(Self.tab(0))
            interp.feed(Self.stdBand([0x80]))     // row 72
            interp.flush()
        }
        let p = pages[0]
        #expect(Self.inked(p, 0, 0))
        #expect(Self.inked(p, 0, 72))
        #expect(Self.inkCount(p) == 2)
    }

    @Test
    func reverseLineFeedMovesUp() {
        let pages = Self.run { interp in
            interp.feed(Self.setLineHeight(50))
            interp.feed(Self.lf)                              // down to 50
            interp.feed(Self.lf)                              // down to 100
            interp.feed(Self.stdBand([0x80]))                // row 100
            interp.feed(Self.esc); interp.feed(UInt8(ascii: "r"))  // reverse
            interp.feed(Self.lf)                              // up to 50
            interp.feed(Self.tab(0))                          // LF is not CR (§12.5)
            interp.feed(Self.stdBand([0x80]))                // row 50
            interp.flush()
        }
        let p = pages[0]
        #expect(Self.inked(p, 0, 50))
        #expect(Self.inked(p, 0, 100))
        #expect(Self.inkCount(p) == 2)
    }

    // MARK: - Page breaks (form feed via LF overflow, §12.5) + multi-page

    @Test
    func lineFeedOverflowEmitsPageAndWraps() {
        // pageLength144 = 1584. Line height 99 → 17 LFs = 1683 > 1584 crosses.
        let pages = Self.run { interp in
            interp.feed(Self.setLineHeight(99))
            interp.feed(Self.stdBand([0x80]))       // ink page 1
            for _ in 0..<17 { interp.feed(Self.lf) } // cross the page length
            interp.feed(Self.stdBand([0x80]))       // ink page 2 (wrapped)
            interp.flush()
        }
        #expect(pages.count == 2)
        #expect(Self.inked(pages[0], 0, 0))
        // 17*99 = 1683, wrapped = 1683-1584 = 99 → row 99 on page 2.
        #expect(Self.inked(pages[1], 0, 99))
    }

    @Test
    func explicitFormFeedByteEmitsPage() {
        // The driver never emits FF, but the interpreter honors it defensively.
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0x80]))
            interp.feed(12)                        // FF
            interp.feed(Self.stdBand([0x80]))
            interp.flush()
        }
        #expect(pages.count == 2)
    }

    @Test
    func multiPageThreeForms() {
        let pages = Self.run { interp in
            for _ in 0..<3 {
                interp.feed(Self.stdBand([0x80]))
                interp.feed(12)
            }
        }
        #expect(pages.count == 3)
    }

    @Test
    func flushEmitsPartialPageOnce() {
        let pages = Self.run { interp in
            interp.feed(Self.stdBand([0x80]))
            interp.flush()
            interp.flush()      // nothing dirty → no second page
        }
        #expect(pages.count == 1)
    }

    @Test
    func flushWithNoInkEmitsNothing() {
        let pages = Self.run { interp in
            interp.feed(Self.setLineHeight(30))   // state changes, no ink
            interp.flush()
        }
        #expect(pages.isEmpty)
    }

    // MARK: - Text (draft-mode synthetic font, §12.6.5)

    @Test
    func textBytesRenderThroughSyntheticFont() {
        let pages = Self.run { interp in
            interp.feed(Array("HI".utf8))
            interp.flush()
        }
        #expect(pages.count == 1)
        // 'H' and 'I' both have ink; total > 0 and the glyphs sit on rows 0..6.
        #expect(Self.inkCount(pages[0]) > 0)
        #expect(Self.inked(pages[0], 0, 0))   // 'H' top-left stem
        // Second glyph advanced by one 6-dot cell.
        #expect(Self.inked(pages[0], 6, 0) || Self.inked(pages[0], 7, 0))
    }

    @Test
    func unmappedHighByteRendersFallbackBox() {
        let pages = Self.run { interp in
            interp.feed(0xFF)     // no glyph → hollow box fallback
            interp.flush()
        }
        #expect(Self.inkCount(pages[0]) > 0)
    }

    // MARK: - Resilience: unknown codes never abort (§12.6.6)

    @Test
    func unknownEscapeIsLoggedAndNoOp() {
        let interp = ImageWriterInterpreter()
        var pages: [PrinterPage] = []
        interp.onPage = { pages.append($0) }
        interp.feed(Self.esc); interp.feed(UInt8(ascii: "V"))  // declared-but-unused
        interp.feed(Self.esc); interp.feed(0x00)               // garbage escape
        interp.feed(Self.stdBand([0x80]))                       // still works
        interp.flush()
        #expect(pages.count == 1)
        #expect(Self.inkCount(pages[0]) == 1)
        #expect(interp.unknownLog.count == 2)
        #expect(interp.unknownLog[0].byte == UInt8(ascii: "V"))
    }

    @Test
    func malformedDigitOperandDropsCommandButKeepsGoing() {
        let interp = ImageWriterInterpreter()
        var pages: [PrinterPage] = []
        interp.onPage = { pages.append($0) }
        // ESC T then a non-digit: corrupt line-height operand.
        interp.feed(Self.esc); interp.feed(UInt8(ascii: "T")); interp.feed(UInt8(ascii: "Z"))
        interp.feed(Self.stdBand([0x80]))
        interp.flush()
        #expect(pages.count == 1)
        #expect(interp.unknownLog.count == 1)
    }

    @Test
    func unknownLogIsBounded() {
        let interp = ImageWriterInterpreter()
        for _ in 0..<400 { interp.feed(0x01) }   // stray control byte, repeatedly
        #expect(interp.unknownLog.count == 256)  // logLimit
        #expect(interp.unknownLogDropped == 400 - 256)
    }

    @Test
    func dipSwitchEscapeConsumesTwoOperandBytes() {
        // ESC Z 07 00 (US country) must swallow the two masks, not ink them.
        let interp = ImageWriterInterpreter()
        var pages: [PrinterPage] = []
        interp.onPage = { pages.append($0) }
        interp.feed(Self.esc); interp.feed(UInt8(ascii: "Z"))
        interp.feed(7); interp.feed(0)
        interp.feed(Self.stdBand([0x80]))
        interp.flush()
        #expect(pages.count == 1)
        #expect(Self.inkCount(pages[0]) == 1)   // only the band, masks ignored
        #expect(interp.unknownLog.isEmpty)
    }

    // MARK: - Mixed stream + whole-page fingerprints (locked)

    @Test
    func mixedStreamGoldenFingerprint() {
        let pages = Self.run { interp in
            interp.feed(Self.esc); interp.feed(UInt8(ascii: "P"))   // 160 bpi
            interp.feed(Self.setLineHeight(16))
            interp.feed(Self.tab(32))
            interp.feed(Self.fastBand([0xFF, 0x81, 0x18, 0x24, 0x42, 0x81, 0x18, 0x24]))
            interp.feed(Self.lf)
            interp.feed(Array("Lisa 42".utf8))
            interp.feed(Self.lf)
            interp.feed(Self.stdBand([0xAA, 0x55, 0xAA, 0x55]))
            interp.flush()
        }
        #expect(pages.count == 1)
        // Locked fingerprint — asserts the whole raster is byte-stable.
        // SUPERSEDED (M7 Task 4 fix round 2): was 0x3371_688a_729d_0777 under the
        // 1/144 pin mapping; the corrected two-pass interlace geometry (§12.5 —
        // pins 2/144 apart) legitimately moves every hi-res multi-pin raster, so
        // the pin was re-locked from a known-good run of the fixed mapping.
        #expect(Self.fnv(pages[0].bits) == 0x3cf1_f467_7fef_02f7)
    }

    @Test
    func graphicsPageFingerprintPerDensity() {
        // The same diagonal ramp printed in each real Lisa density mode, each
        // with its matching page geometry (§12.3) — genuinely distinct rasters.
        func page(_ config: ImageWriterInterpreter.Config, _ code: UInt8) -> PrinterPage {
            Self.run(config) { interp in
                interp.feed(Self.esc); interp.feed(code)
                interp.feed(Self.stdBand((0..<32).map { UInt8(0x80 >> ($0 % 8)) }))
                interp.flush()
            }[0]
        }
        let hi = page(.imageWriterPortraitHiRes, UInt8(ascii: "P"))   // 160×144
        let lo = page(.imageWriterPortraitLoRes, UInt8(ascii: "E"))   // 96×72
        #expect(hi.dpi == PrinterPage.DPI(h: 160, v: 144))
        #expect(lo.dpi == PrinterPage.DPI(h: 96, v: 72))
        #expect(Self.fnv(hi.bits) != Self.fnv(lo.bits))   // distinct geometry ⇒ distinct raster
        // SUPERSEDED (M7 Task 4 fix round 2): the HI pin was 0xd58a_571e_f5ed_0189
        // under the 1/144 mapping and legitimately moves with the corrected
        // two-pass interlace (§12.5); re-locked from the fixed mapping. The LO
        // (72-vpi, single-pass, NOT interleaved) pin is UNCHANGED — proof the fix
        // only affects the 144-vpi interleaved path.
        #expect(Self.fnv(hi.bits) == 0xe6ff_27c5_9c36_d389)
        #expect(Self.fnv(lo.bits) == 0x543e_21ca_4839_3989)
    }
}
