import AppKit
import CoreGraphics
import Foundation
import LisaShell

/// Turns a closed print job (`[PrinterPage]` from `LisaShell`'s spooler) into
/// printable/PDF output for the macOS print panel.
///
/// The **pure** part — assembling the pages into PDF `Data` sized to each
/// page's DPI — is a static function with no AppKit UI, unit-tested directly
/// (`PrintDocumentTests`). The **presentation** part (running
/// `NSPrintOperation` with the standard panel) is a thin `@MainActor` wrapper
/// on top of it. "Save as PDF" from the panel therefore renders the exact same
/// geometry the pure assembler produces.
enum PrintDocument {
    /// Points per inch — the PDF/AppKit user-space unit.
    private static let pointsPerInch: CGFloat = 72

    /// A page's size in **points**: dots ÷ DPI × 72. E.g. Portrait Hi-Res
    /// (1280×1584 dots at 160×144 DPI) → 576×792 pt = the 8"×11" printable
    /// area (docs/hardware-notes.md §12.3).
    static func pointSize(for page: PrinterPage) -> CGSize {
        CGSize(width: CGFloat(page.width) / CGFloat(page.dpi.h) * pointsPerInch,
               height: CGFloat(page.height) / CGFloat(page.dpi.v) * pointsPerInch)
    }

    /// One `PrinterPage`'s 1bpp raster as a grayscale `CGImage`. **Set bit =
    /// ink = black** (docs/hardware-notes.md §12.4). Polarity is baked into the
    /// data (invert the bits, rely on CGImage's default 1bpp DeviceGray decode:
    /// component 0 → black) rather than a `decode:` array — the same approach
    /// and rationale as `lisadbg`'s `writePrinterPagePNG` / `expand1bppRow`
    /// (ImageIO does not honor a custom decode when encoding, and drawing into
    /// a PDF is likewise cleaner with the polarity in the samples).
    static func cgImage(for page: PrinterPage) -> CGImage? {
        let inverted = page.bits.map { ~$0 }
        guard let provider = CGDataProvider(data: Data(inverted) as CFData) else { return nil }
        return CGImage(
            width: page.width,
            height: page.height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: page.rowBytes,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Assemble the job into multi-page PDF `Data`, one PDF page per
    /// `PrinterPage`, each sized to its own DPI (`pointSize(for:)`). Returns
    /// `nil` for an empty job or if the PDF context can't be created. **Pure**
    /// — no panel, no main-actor requirement — so it is directly unit-testable
    /// and is also exactly what the panel's "Save as PDF" reproduces.
    static func makePDFData(pages: [PrinterPage]) -> Data? {
        guard let first = pages.first else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var firstBox = CGRect(origin: .zero, size: pointSize(for: first))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
        for page in pages {
            guard let image = cgImage(for: page) else { continue }
            var box = CGRect(origin: .zero, size: pointSize(for: page))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

/// A paginating `NSView` that draws each `PrinterPage` on its own printed page
/// for `NSPrintOperation(view:)`. The view's frame stacks every page top to
/// bottom (AppKit's multi-page `NSView` printing contract): `rectForPage(_:)`
/// returns each page's slice, `draw(_:)` renders whichever page the current
/// clip falls in. Each page is scaled to fill its point-size rect, so the
/// standard panel's preview and "Save as PDF" match `PrintDocument.makePDFData`.
final class RasterPrintView: NSView {
    private let pages: [PrinterPage]
    private let images: [CGImage?]
    private let pageSizes: [CGSize]
    /// Y origin (bottom) of each page rect within the stacked view.
    private let pageOrigins: [CGFloat]

    init(pages: [PrinterPage]) {
        self.pages = pages
        self.images = pages.map { PrintDocument.cgImage(for: $0) }
        self.pageSizes = pages.map { PrintDocument.pointSize(for: $0) }
        // Stack pages vertically; total height = sum of page heights, width =
        // the widest page.
        var origins: [CGFloat] = []
        var y: CGFloat = 0
        for size in pageSizes { origins.append(y); y += size.height }
        self.pageOrigins = origins
        let totalHeight = y
        let width = pageSizes.map(\.width).max() ?? 0
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: totalHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let index = page - 1                      // NSPrintOperation pages are 1-based
        guard pageSizes.indices.contains(index) else { return .zero }
        return NSRect(x: 0, y: pageOrigins[index],
                      width: pageSizes[index].width, height: pageSizes[index].height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (index, image) in images.enumerated() {
            guard let image else { continue }
            let rect = NSRect(x: 0, y: pageOrigins[index],
                              width: pageSizes[index].width, height: pageSizes[index].height)
            guard rect.intersects(dirtyRect) else { continue }
            ctx.draw(image, in: rect)
        }
    }
}

/// Presents a closed print job in the standard macOS print panel.
///
/// `@MainActor`: `NSPrintOperation`/panel are main-thread only. `AppModel`
/// hops to main (its single `DispatchQueue.main.async` boundary) before calling
/// this, matching how it already republishes frames/status.
@MainActor
enum PrintPresenter {
    /// Run `NSPrintOperation` for `pages` with the standard print panel shown.
    /// No-op for an empty job.
    static func present(_ pages: [PrinterPage]) {
        guard !pages.isEmpty else { return }
        let view = RasterPrintView(pages: pages)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        // The ImageWriter raster already carries the page margins as white
        // space; print edge-to-edge so the panel preview matches the raster.
        info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = "LisaEmu Printout"
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }
}
