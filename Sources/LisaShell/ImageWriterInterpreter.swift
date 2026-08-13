import Foundation

/// One rendered printer page: a 1-bit-per-pixel raster.
///
/// `bits` is packed MSB-first per row (bit 7 of the first byte = leftmost
/// pixel of the row), `rowBytes = (width + 7) / 8` bytes per row, `height`
/// rows total. **A set bit means ink** (the opposite polarity of the
/// screen framebuffer, where the analogous convention is documented on
/// `Frame`; here "1 = mark on paper" reads more naturally for a printer).
///
/// `dpi` is the device resolution the page was rendered at: `h` is the
/// horizontal dots-per-inch commanded by the stream (see
/// docs/hardware-notes.md §12.2), `v` the vertical grid (§12.5). Geometry
/// and polarity rationale: §12.4, §12.6.
public struct PrinterPage: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int
    public let bits: [UInt8]
    public let dpi: DPI

    /// Device resolution in dots per inch. A 2-field struct (not a bare
    /// `(h:Int,v:Int)` tuple) so `PrinterPage` can synthesize
    /// `Equatable`/`Hashable` for downstream (Task 4) consumers.
    public struct DPI: Sendable, Equatable, Hashable {
        public let h: Int
        public let v: Int
        public init(h: Int, v: Int) { self.h = h; self.v = v }
    }

    public init(width: Int, height: Int, bits: [UInt8], dpi: DPI) {
        self.width = width
        self.height = height
        self.bits = bits
        self.dpi = dpi
    }

    /// Bytes per raster row (`ceil(width/8)`).
    public var rowBytes: Int { (width + 7) / 8 }
}

/// Pure, device-free state machine that turns the Lisa OS C.Itoh/ImageWriter
/// printer byte stream into 1-bit page rasters.
///
/// This is the software mirror of `LibPr/CiDev`: it consumes exactly the
/// escape-code wire contract that driver emits, derived and cited in
/// docs/hardware-notes.md §12. It has **no device/UI coupling** — bytes in
/// via `feed(_:)`, finished pages out via `onPage`. Task 4 wires it to the
/// SCC's Serial-B transmit path; this type stays in the Foundation-only
/// `LisaShell` target and is golden-tested in isolation.
///
/// Not thread-safe by itself: like the emulator's other per-stream state
/// machines it is expected to be driven from a single thread (the emulation
/// thread that owns the SCC). Cross-thread publication is the
/// `PrintJobSpooler`'s job (FramePublisher idiom).
public final class ImageWriterInterpreter {
    /// Fixed page geometry + resolution for a job. Real jobs command one
    /// density before any ink (docs/hardware-notes.md §12.6 decision 1), so
    /// a per-page fixed canvas is faithful.
    public struct Config: Sendable {
        /// Horizontal dots per inch the canvas is sized for (§12.2).
        public let dpiH: Int
        /// Vertical dots-per-inch grid the 144ths accumulator maps onto (§12.5).
        public let dpiV: Int
        /// Printable width in dots (the platen; = 8 × dpiH for the real modes).
        public let widthDots: Int
        /// Page length in 144ths of an inch (US Letter = 11 in = 1584, §12.5).
        public let pageLength144: Int

        public init(dpiH: Int, dpiV: Int, widthDots: Int, pageLength144: Int) {
            self.dpiH = dpiH
            self.dpiV = dpiV
            self.widthDots = widthDots
            self.pageLength144 = pageLength144
        }

        /// Page height in raster rows (`pageLength144 × dpiV ÷ 144`).
        public var heightDots: Int { pageLength144 * dpiV / 144 }

        /// Portrait Hi-Res — the ImageWriter's native Lisa mode
        /// (160×144 dpi, 1280×1584 dots; docs/hardware-notes.md §12.3).
        public static let imageWriterPortraitHiRes =
            Config(dpiH: 160, dpiV: 144, widthDots: 1280, pageLength144: 1584)

        /// Portrait Lo-Res (96×72 dpi, 768×792 dots; §12.3).
        public static let imageWriterPortraitLoRes =
            Config(dpiH: 96, dpiV: 72, widthDots: 768, pageLength144: 1584)
    }

    // MARK: Wire-contract constants (docs/hardware-notes.md §12.1, CiDev:103).
    private enum Ctl {
        static let lf: UInt8 = 10
        static let ff: UInt8 = 12   // never emitted by this driver; honored defensively (§12.6)
        static let so: UInt8 = 14
        static let si: UInt8 = 15
        static let can: UInt8 = 24
        static let esc: UInt8 = 27
    }

    public let config: Config
    /// Called with each finished page. Default no-op so the interpreter is
    /// trivially constructible; Task 4 / the spooler assigns a real sink.
    public var onPage: (PrinterPage) -> Void = { _ in }

    // MARK: Bounded diagnostic log (house pattern, cf. Bus.mmuPortLog).
    /// Unknown / unmodeled bytes that were no-op'd, most-recent-capped.
    /// `(byte, y144)` = the offending byte and the vertical position at the
    /// time, for post-mortem. Bounded to `logLimit`; overflow bumps
    /// `unknownLogDropped` instead of growing.
    public private(set) var unknownLog: [(byte: UInt8, y144: Int)] = []
    public private(set) var unknownLogDropped = 0
    private static let logLimit = 256

    // MARK: Parser state.
    private enum State {
        case ground
        case escape
        /// Collecting `remaining` ASCII digits into `accum` for `cmd`.
        case digits(cmd: UInt8, remaining: Int, accum: Int)
        /// Reading `remaining` raw graphics column bytes.
        case graphics(remaining: Int)
        /// Consuming `remaining` raw operand bytes (DIP-switch masks).
        case rawBytes(remaining: Int)
    }
    private var state: State = .ground

    // MARK: Printer state.
    private var bpi: Int                 // current horizontal density (§12.2)
    private var lineHeight144 = 16       // ESC T pitch; CiDevOpen default (CiDev:278)
    private var lfForward = true         // ESC f / ESC r
    private var wide = false             // SO / SI elongated
    private var emphasized = false       // ESC ! / ESC "
    private var underline = false        // ESC X / ESC Y
    private var biDir = false            // ESC < / ESC >
    private var peStop = false           // ESC o / ESC O
    private var y144 = 0                 // vertical position, 144ths of an inch
    private var cursorX = 0              // horizontal dot column (ESC F / graphics)

    // MARK: Page canvas (lazily inked).
    private var canvas: [UInt8]
    private let rowBytes: Int
    private var pageDirty = false

    public init(config: Config = .imageWriterPortraitHiRes) {
        self.config = config
        self.bpi = config.dpiH
        self.rowBytes = (config.widthDots + 7) / 8
        self.canvas = [UInt8](repeating: 0, count: rowBytes * config.heightDots)
    }

    // MARK: - Public API

    /// Feed one byte from the printer stream.
    public func feed(_ byte: UInt8) {
        switch state {
        case .ground:      feedGround(byte)
        case .escape:      feedEscape(byte)
        case .digits(let cmd, let remaining, let accum):
            feedDigits(byte, cmd: cmd, remaining: remaining, accum: accum)
        case .graphics(let remaining):
            feedGraphics(byte, remaining: remaining)
        case .rawBytes(let remaining):
            state = remaining <= 1 ? .ground : .rawBytes(remaining: remaining - 1)
        }
    }

    /// Feed a whole buffer.
    public func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { feed(b) }
    }

    /// Emit any partial (dirty) page — end-of-stream or spooler idle
    /// (docs/hardware-notes.md §12.6 decision 4b). No-op if nothing is inked.
    public func flush() {
        // Abandon any half-parsed command; a truncated stream should not
        // strand the parser.
        state = .ground
        emitPageIfDirty()
        y144 = 0
    }

    // MARK: - Ground state

    private func feedGround(_ byte: UInt8) {
        switch byte {
        case Ctl.esc: state = .escape
        case Ctl.lf:  lineFeed()
        case Ctl.so:  wide = true
        case Ctl.si:  wide = false
        case Ctl.can: break                     // abort partial graphics line (§12.1)
        case Ctl.ff:  formFeed()                // defensive (§12.6) — driver never emits
        case 0x20...0x7E, 0xA0...0xFF:           // printable → draft synthetic font (§12.6.5)
            drawGlyph(byte)
        default:      note(byte)                 // stray control byte
        }
    }

    // MARK: - Escape state

    private func feedEscape(_ byte: UInt8) {
        switch byte {
        // Operand-carrying commands → digit/data collection.
        case UInt8(ascii: "T"): state = .digits(cmd: byte, remaining: 2, accum: 0) // line height
        case UInt8(ascii: "G"): state = .digits(cmd: byte, remaining: 4, accum: 0) // std graphics
        case UInt8(ascii: "g"): state = .digits(cmd: byte, remaining: 3, accum: 0) // fast graphics
        case UInt8(ascii: "F"): state = .digits(cmd: byte, remaining: 4, accum: 0) // tab
        case UInt8(ascii: "Z"), UInt8(ascii: "D"):
            state = .rawBytes(remaining: 2)      // DIP-switch masks (country)
        // Flag toggles (no operands).
        case UInt8(ascii: "f"): lfForward = true;  state = .ground
        case UInt8(ascii: "r"): lfForward = false; state = .ground
        case UInt8(ascii: "<"): biDir = true;      state = .ground
        case UInt8(ascii: ">"): biDir = false;     state = .ground
        case UInt8(ascii: "o"): peStop = true;     state = .ground
        case UInt8(ascii: "O"): peStop = false;    state = .ground
        case UInt8(ascii: "!"): emphasized = true; state = .ground
        case UInt8(ascii: "\""): emphasized = false; state = .ground
        case UInt8(ascii: "X"): underline = true;  state = .ground
        case UInt8(ascii: "Y"): underline = false; state = .ground
        case UInt8(ascii: "c"): resetPrinter();    state = .ground
        // Density (bpi) codes — §12.2.
        case UInt8(ascii: "n"): setDensity(72,  code: byte)
        case UInt8(ascii: "N"): setDensity(80,  code: byte)
        case UInt8(ascii: "E"): setDensity(96,  code: byte)
        case UInt8(ascii: "q"): setDensity(120, code: byte)
        case UInt8(ascii: "Q"): setDensity(136, code: byte)
        case UInt8(ascii: "p"): setDensity(144, code: byte)
        case UInt8(ascii: "P"): setDensity(160, code: byte)
        default:
            // ESC 'V' (declared-but-unused, §12.1) and any other unknown
            // escape land here.
            note(byte)
            state = .ground
        }
    }

    /// Apply a commanded horizontal density (§12.2). The canvas geometry is
    /// fixed per page (§12.6 decision 1); a density that disagrees with the
    /// canvas `config.dpiH` means the raster will be mis-scaled, so it is
    /// bounded-logged (the `code` byte) as a diagnostic rather than silently
    /// mis-rendered. A matching density is applied without noise.
    private func setDensity(_ newBpi: Int, code: UInt8) {
        bpi = newBpi
        if newBpi != config.dpiH { note(code) }
        state = .ground
    }

    // MARK: - Digit collection

    private func feedDigits(_ byte: UInt8, cmd: UInt8, remaining: Int, accum: Int) {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
            // Malformed operand: ciprint always emits exactly the right
            // digits, so this is a corrupt stream. Bounded-log and drop the
            // command; do NOT abort the whole page (§12.6.6).
            note(byte)
            state = .ground
            return
        }
        let value = accum * 10 + Int(byte - UInt8(ascii: "0"))
        if remaining > 1 {
            state = .digits(cmd: cmd, remaining: remaining - 1, accum: value)
        } else {
            applyOperand(cmd: cmd, value: value)
        }
    }

    private func applyOperand(cmd: UInt8, value: Int) {
        switch cmd {
        case UInt8(ascii: "T"):
            lineHeight144 = min(value, 99)       // cLFMax (CiDev:121, :621)
            state = .ground
        case UInt8(ascii: "F"):
            cursorX = value                      // absolute column (§12.1)
            state = .ground
        case UInt8(ascii: "G"):
            beginGraphics(columns: value)        // std: value = column count
        case UInt8(ascii: "g"):
            beginGraphics(columns: value * 8)    // fast: value = columns/8 (§12.4)
        default:
            state = .ground
        }
    }

    // MARK: - Graphics

    private func beginGraphics(columns: Int) {
        if columns <= 0 { state = .ground; return }
        state = .graphics(remaining: columns)
    }

    private func feedGraphics(_ byte: UInt8, remaining: Int) {
        writeColumn(byte)
        state = remaining <= 1 ? .ground : .graphics(remaining: remaining - 1)
    }

    /// Paint one 8-dot column at the current cursor. Bit 7 = top dot
    /// (modeling decision, §12.4). Elongated (`wide`) doubles the column
    /// horizontally (§12.1, CiSetWide). Advances the cursor; clips to page.
    private func writeColumn(_ columnByte: UInt8) {
        let rowTop = y144 * config.dpiV / 144
        let reps = wide ? 2 : 1
        for _ in 0..<reps {
            let x = cursorX
            if x >= 0, x < config.widthDots, columnByte != 0 {
                for bit in 0..<8 {
                    // bit 7 (0x80) = top dot.
                    if columnByte & (0x80 >> UInt8(bit)) != 0 {
                        setInk(x: x, y: rowTop + bit)
                    }
                }
            }
            cursorX += 1
        }
    }

    private func setInk(x: Int, y: Int) {
        guard x >= 0, x < config.widthDots, y >= 0, y < config.heightDots else { return }
        canvas[y * rowBytes + (x >> 3)] |= (0x80 >> UInt8(x & 7))
        pageDirty = true
    }

    // MARK: - Vertical motion / page breaks

    private func lineFeed() {
        let delta = lfForward ? lineHeight144 : -lineHeight144
        let newY = y144 + delta
        if lfForward && newY >= config.pageLength144 {
            // Forward-crossing the page length is the form-feed mechanism
            // (§12.5): eject, then wrap the remainder (CiBindV MOD, CiDev:187).
            emitPage()
            y144 = newY % config.pageLength144
        } else {
            // Reverse motion clamps at the top; a stream never LFs above 0.
            y144 = max(0, newY)
        }
    }

    /// Explicit eject (defensive FF, §12.6). Emits whatever is inked and
    /// resets to the top of a fresh page.
    private func formFeed() {
        emitPage()
        y144 = 0
    }

    private func resetPrinter() {
        // ESC c is the last byte of CiDevClose (CiDev:253); flush any dirty
        // page, then restore power-on transient state (§12.6.4c).
        emitPageIfDirty()
        y144 = 0
        cursorX = 0
        bpi = config.dpiH
        lineHeight144 = 16
        lfForward = true
        wide = false
        emphasized = false
        underline = false
        biDir = false
        peStop = false
    }

    private func emitPageIfDirty() {
        if pageDirty { emitPage() }
    }

    /// Publish the current canvas (even if blank, for an explicit eject) and
    /// start a fresh page.
    private func emitPage() {
        onPage(PrinterPage(width: config.widthDots,
                           height: config.heightDots,
                           bits: canvas,
                           dpi: PrinterPage.DPI(h: bpi, v: config.dpiV)))
        canvas = [UInt8](repeating: 0, count: rowBytes * config.heightDots)
        pageDirty = false
        cursorX = 0
    }

    // MARK: - Text (draft-mode synthetic font, §12.6.5)

    /// Render one printable byte through the built-in 5×7 dot font, at the
    /// current cursor, then advance one glyph cell (6 columns). The font is
    /// entirely ours (SyntheticDotFont) — no Lisa font is ever extracted.
    private func drawGlyph(_ byte: UInt8) {
        let rowTop = y144 * config.dpiV / 144
        let glyph = SyntheticDotFont.rows(for: byte)
        for (dy, rowBits) in glyph.enumerated() {
            for dx in 0..<SyntheticDotFont.width {
                // bit (width-1-dx) = leftmost column.
                if rowBits & (1 << (SyntheticDotFont.width - 1 - dx)) != 0 {
                    setInk(x: cursorX + dx, y: rowTop + dy)
                }
            }
        }
        cursorX += SyntheticDotFont.cellWidth
    }

    // MARK: - Bounded logging

    private func note(_ byte: UInt8) {
        if unknownLog.count < Self.logLimit {
            unknownLog.append((byte: byte, y144: y144))
        } else {
            unknownLogDropped += 1
        }
    }
}
