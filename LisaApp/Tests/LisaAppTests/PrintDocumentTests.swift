import CoreGraphics
import Foundation
import Testing
@testable import LisaApp
@testable import LisaShell

/// Unit-pins the **pure** print-job assembly (`PrintDocument`): pages → PDF
/// `Data`, page point-sizing from DPI, and the 1bpp raster → `CGImage` step.
/// The panel presentation (`NSPrintOperation`) is UI and not exercised here;
/// this is the "pages→PDF-data assembly gets a unit test" deliverable.
///
/// Not part of this session's `swift test` (root Package.swift excludes
/// LisaApp); run via the LisaApp xcodebuild validation step.
@Suite
struct PrintDocumentTests {
    /// A distinct page: `w`×`h` at the given DPI, one inked byte so `cgImage`
    /// has real content.
    static func page(w: Int = 1280, h: Int = 1584, dpiH: Int = 160, dpiV: Int = 144) -> PrinterPage {
        var bits = [UInt8](repeating: 0, count: ((w + 7) / 8) * h)
        if !bits.isEmpty { bits[0] = 0x80 }   // top-left ink dot
        return PrinterPage(width: w, height: h, bits: bits, dpi: PrinterPage.DPI(h: dpiH, v: dpiV))
    }

    @Test
    func pointSizeConvertsDotsThroughDPIToPoints() {
        // 1280 dots / 160 dpi × 72 = 576 pt; 1584 / 144 × 72 = 792 pt (8"×11").
        let size = PrintDocument.pointSize(for: Self.page())
        #expect(abs(size.width - 576) < 0.001)
        #expect(abs(size.height - 792) < 0.001)
    }

    @Test
    func cgImageMatchesPagePixelDimensions() throws {
        let image = try #require(PrintDocument.cgImage(for: Self.page(w: 768, h: 792, dpiH: 96, dpiV: 72)))
        #expect(image.width == 768)
        #expect(image.height == 792)
        #expect(image.bitsPerPixel == 1)
    }

    @Test
    func makePDFDataProducesOnePDFPagePerPrinterPageAtTheRightSize() throws {
        let pages = [Self.page(), Self.page(w: 768, h: 792, dpiH: 96, dpiV: 72)]
        let data = try #require(PrintDocument.makePDFData(pages: pages))
        #expect(data.starts(with: Array("%PDF".utf8)), "PDF magic header")

        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        #expect(pdf.numberOfPages == 2, "one PDF page per PrinterPage")

        // Page 1 is the Portrait Hi-Res page: 576×792 pt MediaBox.
        let pdfPage1 = try #require(pdf.page(at: 1))
        let box1 = pdfPage1.getBoxRect(.mediaBox)
        #expect(abs(box1.width - 576) < 0.5)
        #expect(abs(box1.height - 792) < 0.5)
        // Page 2 is the Lo-Res page: 768/96×72 = 576 pt wide, 792/72×72... 792 pt tall.
        let pdfPage2 = try #require(pdf.page(at: 2))
        let box2 = pdfPage2.getBoxRect(.mediaBox)
        #expect(abs(box2.width - 576) < 0.5)
        #expect(abs(box2.height - 792) < 0.5)
    }

    @Test
    func emptyJobProducesNoPDF() {
        #expect(PrintDocument.makePDFData(pages: []) == nil)
    }
}
