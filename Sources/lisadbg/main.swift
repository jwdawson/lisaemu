import CoreGraphics
import Foundation
import ImageIO
import LisaCore
import LisaShell
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("lisadbg: \(message)\n".data(using: .utf8) ?? Data())
    exit(1)
}

/// Human-readable annotation for a known I/O offset, for the `t` trace
/// command. Deliberately kept here (not in LisaCore) -- it is debugger
/// presentation, not emulation behavior. Table per docs/hardware-notes.md:
/// setup/context latches, video/status/vsync/board-ID, VIA1/VIA2 register
/// blocks, and the SLIM/SORG MMU ports. Offset is `IOAccess.offset`, the
/// low 17 bits of the access (see `IOAccess`'s doc comment); SLIM/SORG
/// ports are checked against the same low-17-bit pattern here for
/// completeness, even though `Bus.slimSorgPortAccess` currently intercepts
/// those addresses before they ever reach `IODispatcher`/`ioTrace` -- see
/// `Bus.access`.
func ioAnnotation(_ offset: UInt32) -> String? {
    switch offset {
    case 0xE010: return "setup ON"
    case 0xE012: return "setup OFF"
    case 0xE008: return "context bit1 OFF"
    case 0xE00A: return "context bit1 ON"
    case 0xE00C: return "context bit2 OFF"
    case 0xE00E: return "context bit2 ON"
    case 0xE018: return "vsync reset"
    case 0xE01A: return "vsync enable"
    case 0xE800: return "video page latch"
    case 0xF801: return "status register"
    case 0xC031: return "board ID"
    case 0x8000, 0x8001: return "SLIM port"
    case 0x8008, 0x8009: return "SORG port"
    default:
        // ROM-observed bases (docs/hardware-notes.md §3, task-3 VIA core):
        // VIA1 = $D901 stride 8, VIA2 = $DD81 stride 2. The historical
        // $D801/$DC01 OS-source equates are refuted for the Rev H boot path.
        if offset >= 0xD901, offset <= 0xD901 + 15 * 8, (offset - 0xD901) % 8 == 0 {
            return "VIA1 reg \((offset - 0xD901) / 8)"
        }
        if offset >= 0xDD81, offset <= 0xDD81 + 15 * 2, (offset - 0xDD81) % 2 == 0 {
            return "VIA2 reg \((offset - 0xDD81) / 2)"
        }
        return nil
    }
}

/// Decodes a SLIM (limit/access) or SORG (origin) MMU register value the way
/// `MMU.translate`/`do_an_mmu` do (docs/hardware-notes.md §1), for the trace.
func decodeMMUValue(isSorg: Bool, value: UInt16) -> String {
    if isSorg {
        let originPage = value & 0xFFF
        let physBase = UInt32(originPage) << 9
        return "origin page $\(String(format: "%03X", originPage)) -> phys $\(String(format: "%06X", physBase))"
    }
    let nibble = (value >> 8) & 0xF
    let limitByte = Int(value & 0xFF)
    let access: String
    switch nibble {
    case 0x5: access = "readOnly"
    case 0x6: access = "stack"
    case 0x7: access = "readWrite"
    case 0x8: access = "io"
    case 0xC: access = "absent"
    default:  access = "nibble$\(String(nibble, radix: 16))"
    }
    let pages: String
    if nibble == 0x6 {
        pages = "\(limitByte + 1) pages (stack)"
    } else {
        let raw = (0x100 - limitByte) & 0xFF
        pages = "\(raw == 0 ? 256 : raw) pages"
    }
    return "access $\(String(nibble, radix: 16)) (\(access)), limit \(pages)"
}

func formatMMUPortWrite(_ e: (domain: Int, segment: Int, isSorg: Bool, value: UInt16, cycles: UInt64)) -> String {
    let reg = e.isSorg ? "SORG" : "SLIM"
    return "      mmu dom\(e.domain) seg\(e.segment) \(reg)=$\(String(format: "%03X", e.value))  [\(decodeMMUValue(isSorg: e.isSorg, value: e.value))]"
}

/// Compact disk-state suffix for the `t`/`g` status lines (M2 Task 4 brief:
/// "status line shows disk state").
func diskStatus(_ machine: Machine) -> String {
    // Widget hard-disk stats appended only when one is attached (M5 Task 4:
    // `widgetCmds` = completed ProFile commands, the unambiguous boot-from-
    // Widget progress signal -- it counts both the OS driver's $FCD801 path
    // and the boot ROM's $FCD901 path, unlike `widgetRegionAccesses` which is
    // the $FCD801 OS-driver seam metric only).
    let widget = machine.bus.widget.isAttached
        ? " widgetCmds=\(machine.bus.widget.completedCommands)" : ""
    guard machine.bus.floppy.isInserted else { return "disk=OUT" + widget }
    return "disk=IN blocksRead=\(machine.bus.floppy.blocksRead)" + widget
}

/// The shared `g`/`gu` slice report: the SLIM/SORG port writes and I/O
/// touches recorded during the slice, the status line, the instruction the
/// PC now sits on, and the register dump. `prefix` (used by `gu` for its
/// stop reason) is printed ahead of all of it.
///
/// Callers pass the `ioTrace`/`mmuPortLog` counts they sampled *before* the
/// run. Both logs are bounded (`Bus.ioTraceLimit`, house capped-array
/// pattern), so a slice late in a boot can legitimately show nothing:
/// `iot clear` first when the I/O list matters.
func reportSlice(_ machine: Machine, monitor: Monitor,
                 beforeIO: Int, beforeMMU: Int, prefix: String? = nil) {
    if let prefix { print(prefix) }
    print("--- MMU port writes this slice ---")
    // Clamped because `iot clear` can leave a stale, larger `beforeIO` from
    // an earlier sample; slicing past the end would trap.
    for e in machine.bus.mmuPortLog[min(beforeMMU, machine.bus.mmuPortLog.count)...] {
        print(formatMMUPortWrite(e))
    }
    print("--- I/O touches this slice ---")
    for access in machine.bus.ioTrace[min(beforeIO, machine.bus.ioTrace.count)...] {
        print(formatIOAccess(access))
    }
    if machine.bus.ioTraceDropped > 0 {
        print("      (ioTrace full: \(machine.bus.ioTraceDropped) accesses dropped -- `iot clear` / `iot limit <n>`)")
    }
    let pcl = machine.bus.cops.powerCommandLog
    let powerSuffix = machine.powerState == .off
        ? " power=OFF powerCmds=[\(pcl.map { String(format: "$%02X", $0) }.joined(separator: ","))]"
        : (pcl.isEmpty ? "" : " powerCmds=[\(pcl.map { String(format: "$%02X", $0) }.joined(separator: ","))]")
    print("      setup=\(machine.bus.setupMode ? "ON" : "OFF") domain=\(machine.bus.domain) mmuPortWrites=\(machine.bus.mmuPortWrites) busErrorPulses=\(machine.bus.busErrorPulseCount) halted=\(machine.halted)\(powerSuffix) \(diskStatus(machine))")
    print(monitor.disassembly(from: machine.cpu[.pc], count: 1))
    print(monitor.registerDump())
}

func formatIOAccess(_ access: IOAccess) -> String {
    let offsetStr = String(format: "%06X", access.offset)
    let rw = access.isWrite ? "W" : "R"
    let valueStr = String(format: "%02X", access.value)
    var line = "      io \(offsetStr) \(rw) \(valueStr)"
    if let note = ioAnnotation(access.offset) {
        line += "  [\(note)]"
    }
    return line
}

enum ScreenshotError: Error, CustomStringConvertible {
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed

    var description: String {
        switch self {
        case .imageCreationFailed: return "failed to build a CGImage from the framebuffer"
        case .destinationCreationFailed: return "failed to open the destination file"
        case .finalizeFailed: return "failed to write PNG data"
        }
    }
}

/// Renders a `Bus.framebufferSnapshot()` (720x364, 1 bit/pixel, row-major
/// MSB-first, `Bus.framebufferByteCount` bytes) to a PNG file at `path`.
///
/// "Set bit = black" (task brief) is the established M1b/M1c convention --
/// see `LisaShell/FrameExpansion.swift`'s `expand1bppRow`, which bakes the
/// same polarity into its 8bpp output (`isSet ? 0 : 255`) and cites this
/// function as its counterpart. An earlier version of this function tried
/// to express the polarity via a `decode: [1, 0]` array instead of
/// inverting the bits, reasoning that `CGImage`'s default 1bpp DeviceGray
/// decode (component 0 -> black, 1 -> white) is the opposite of what's
/// wanted, so a `[1, 0]` decode array should flip it back. That reasoning
/// is correct for on-screen rendering, but **`CGImageDestinationFinalize`
/// does not honor a custom `decode` array when encoding to PNG** (PNG has
/// no decode-array concept, so ImageIO silently falls back to writing the
/// raw sample bits under the *default* decode) -- confirmed by an actual
/// negative-image regression (`m1b-boot-screen.png`/`live-boot-demo.png`
/// were negatives of the app's proven-correct render; see task-3's review
/// and M1c Task 5's ledger fold). The fix inverts the bits up front and
/// relies on the *default* decode ([0, 1]: component 0 -> black), matching
/// `expand1bppRow`'s "bake polarity into the data, not a decode array"
/// approach. This is debugger tooling only (`lisadbg`, not `LisaCore` --
/// see that module's "framework-free" constraint), hence the direct
/// ImageIO/CoreGraphics dependency here.
func writeScreenshotPNG(_ framebuffer: [UInt8], to path: String) throws {
    let width = Bus.framebufferWidth
    let height = Bus.framebufferHeight
    let bytesPerRow = width / 8
    let inverted = framebuffer.map { ~$0 }
    guard let provider = CGDataProvider(data: Data(inverted) as CFData) else {
        throw ScreenshotError.imageCreationFailed
    }
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 1,
        bitsPerPixel: 1,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw ScreenshotError.imageCreationFailed
    }
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw ScreenshotError.destinationCreationFailed
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw ScreenshotError.finalizeFailed
    }
}

/// Renders one `PrinterPage` (1 bit/pixel, MSB-first, `rowBytes` per row,
/// **set bit = ink = black**, docs/hardware-notes.md §12.4) to a grayscale PNG
/// at `path`. Same polarity handling as `writeScreenshotPNG`: invert the bits
/// up front and rely on CGImage's *default* 1bpp DeviceGray decode (component
/// 0 → black), because `CGImageDestinationFinalize` does not honor a custom
/// `decode` array when encoding PNG (see `writeScreenshotPNG`'s doc comment for
/// the negative-image regression that established this). Unlike the fixed
/// 720×364 screen, a page's dimensions come from the `PrinterPage` (e.g.
/// 1280×1584 for Portrait Hi-Res).
func writePrinterPagePNG(_ page: PrinterPage, to path: String) throws {
    let inverted = page.bits.map { ~$0 }
    guard let provider = CGDataProvider(data: Data(inverted) as CFData) else {
        throw ScreenshotError.imageCreationFailed
    }
    guard let cgImage = CGImage(
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
    ) else {
        throw ScreenshotError.imageCreationFailed
    }
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw ScreenshotError.destinationCreationFailed
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw ScreenshotError.finalizeFailed
    }
}

/// The `--printer-dir` PNG sink: receives each closed print job (from the
/// `PrinterPipeline`'s spooler) and writes its pages as
/// `job-<n>-page-<m>.png` under `dir`, tracking cumulative counters for the
/// `printer` status command. `@unchecked Sendable` because
/// `PrintJobSpooler.onJob` is `@Sendable`; in lisadbg the whole pipeline is
/// driven from the single interactive thread, so the counters are never
/// touched concurrently (the box exists only to satisfy the closure-capture
/// contract, matching `FrameCoalescer`'s rationale in AppModel).
final class PrinterSink: @unchecked Sendable {
    let dir: String
    private(set) var jobsWritten = 0
    private(set) var pagesWritten = 0
    private(set) var lastPaths: [String] = []

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func write(_ job: [PrinterPage]) {
        let jobIndex = jobsWritten + 1
        var paths: [String] = []
        for (i, page) in job.enumerated() {
            let path = "\(dir)/job-\(jobIndex)-page-\(i + 1).png"
            do {
                try writePrinterPagePNG(page, to: path)
                pagesWritten += 1
                paths.append(path)
            } catch {
                FileHandle.standardError.write("lisadbg: printer PNG write failed for \(path): \(error)\n".data(using: .utf8) ?? Data())
            }
        }
        jobsWritten += 1
        lastPaths = paths
        print("      printer: wrote job \(jobIndex) — \(job.count) page(s) -> \(paths.joined(separator: ", "))")
    }
}

/// Accumulates the raw Serial-B wire bytes for `--printer-raw` (debug escape-
/// stream capture). Single-threaded in lisadbg; the box just defers the file
/// write to an explicit flush.
final class RawByteBox {
    private(set) var bytes: [UInt8] = []
    func append(_ b: UInt8) { bytes.append(b) }
    func write(to path: String) {
        do { try Data(bytes).write(to: URL(fileURLWithPath: path))
             print("      printer: wrote \(bytes.count) raw Serial-B bytes to \(path)") }
        catch { print("      printer: raw write failed: \(error)") }
    }
}

/// Coarse ~90x45 block-averaged ASCII preview of a framebuffer snapshot,
/// printed straight to the terminal (`sca`) -- a quick "is anything drawn
/// yet" sanity check without leaving the shell. Each output cell averages
/// the black-pixel density of the source block it covers and picks a
/// character from a light-to-dark ramp; block boundaries are computed by
/// plain integer scaling (`width * col / outCols`), so boundaries aren't
/// perfectly uniform when the source dimensions don't divide evenly (364 /
/// 45 isn't exact) -- "block-averaged", not exact-area-averaged, per the
/// brief's "~90x45" wording.
///
/// Unlike `writeScreenshotPNG` (see that function's doc comment for the
/// PNG-specific polarity bug this module had), this function never touches
/// `CGImage`/ImageIO -- it counts raw set bits directly, the same way
/// `expand1bppRow` and `ROMBootTests`' `blackPixels` do, so the "set bit =
/// black = higher density = darker ramp glyph" mapping below was already
/// correct under the established convention (confirmed by a side-by-side
/// comparison against the app's proven-correct render during M1c Task 5's
/// polarity investigation: the sc bug did not extend here).
func asciiPreview(_ framebuffer: [UInt8], outCols: Int = 90, outRows: Int = 45) -> String {
    let width = Bus.framebufferWidth
    let height = Bus.framebufferHeight
    let bytesPerRow = width / 8
    let ramp = Array(" .:-=+*#%@")
    var lines: [String] = []
    lines.reserveCapacity(outRows)
    for oy in 0..<outRows {
        let y0 = oy * height / outRows
        let y1 = max(y0 + 1, (oy + 1) * height / outRows)
        var line = ""
        line.reserveCapacity(outCols)
        for ox in 0..<outCols {
            let x0 = ox * width / outCols
            let x1 = max(x0 + 1, (ox + 1) * width / outCols)
            var black = 0
            var total = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let byteIndex = y * bytesPerRow + x / 8
                    let bit = 7 - (x % 8)
                    if (framebuffer[byteIndex] >> bit) & 1 != 0 {
                        black += 1
                    }
                    total += 1
                }
            }
            let density = total > 0 ? Double(black) / Double(total) : 0
            let idx = min(ramp.count - 1, Int(density * Double(ramp.count)))
            line.append(ramp[idx])
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

// MARK: - `bootdisk` (M4 Task 2)
//
// Ports `ROMFloppyBootTests`' proven cursor-walk + click mechanism
// (Tests/LisaCoreTests/ROMFloppyBootTests.swift `moveCursor`/`click`) into
// `lisadbg` itself, retiring the "integration test is the sole
// reproduction vehicle for the $520000 state" limitation documented in
// docs/rom-trace-notes.md "Kernel push (M3 Task 4)" and docs/m3-demo.md
// "In lisadbg" (struck, not erased, alongside this change).

/// Walks the ROM's on-screen cursor (`$496`/`$498`) to `(tx,ty)` by
/// feeding relative mouse-delta packets through `COPS.postMouse` -- see
/// `ROMFloppyBootTests.moveCursor` for the original derivation.
func moveCursor(_ m: Machine, to tx: Int, _ ty: Int) {
    for _ in 0..<24 {
        let cx = Int(m.bus.read16(0x496)), cy = Int(m.bus.read16(0x498))
        if abs(cx - tx) <= 1 && abs(cy - ty) <= 1 { return }
        m.bus.cops.postMouse(dx: Int8(max(-120, min(120, tx - cx))),
                             dy: Int8(max(-120, min(120, ty - cy))))
        m.run(until: m.cycles + 250_000)
    }
}

/// A mouse click = button-down keycap `$06` then button-up -- see
/// `ROMFloppyBootTests.click`.
func click(_ m: Machine) {
    m.bus.cops.postKey(code: 0x06, down: true)
    m.run(until: m.cycles + 300_000)
    m.bus.cops.postKey(code: 0x06, down: false)
    m.run(until: m.cycles + 300_000)
}

/// A tight double-click: steer to `(tx,ty)` then post the double-click
/// gesture (opens icons/folders). The gesture timing lives in ONE place —
/// `Machine.postDoubleClick()` (both button-downs within ~400k cycles; two
/// separate `clickAt` calls put the downs ~600k+ apart, marginal vs the OS
/// double-click threshold and flaky) — shared with `ROMPrinterTests`.
func doubleClickAt(_ m: Machine, _ tx: Int, _ ty: Int) {
    steerCursor(m, to: tx, ty)
    m.postDoubleClick()
}

// MARK: - `click <x> <y>` / `type <text>` (M5 Task 3)
//
// bootdisk's ROM-cursor steering ($496/$498) goes dead once the OS is running
// -- the OS keeps its own cursor at physical RAM $3CF0 (MousX/MousY, found by
// M5 Task 3's install trace). `click` feedback-steers whichever cursor is live,
// so it drives both the ROM boot menu and the OS/installer UI.

/// The live cursor (x,y): the OS cursor (`MousX`/`MousY`, physical $3CF0) when
/// it reads plausibly on-screen, else the ROM boot-menu cursor ($496/$498).
func osCursor(_ m: Machine) -> (Int, Int) {
    let ox = Int(m.bus.physicalRead16(0x3CF0)), oy = Int(m.bus.physicalRead16(0x3CF2))
    if ox <= 720 && oy <= 364 && (ox > 0 || oy > 0) { return (ox, oy) }
    return (Int(m.bus.read16(0x496)), Int(m.bus.read16(0x498)))
}

/// Feedback-steer the cursor to `(tx,ty)` then press+release the button. The
/// half-step on X damps the OS mouse driver's 3/2 coarse scaling (LIBHW-MOUSE).
func clickAt(_ m: Machine, _ tx: Int, _ ty: Int) {
    for _ in 0..<80 {
        let (cx, cy) = osCursor(m)
        let dx = tx - cx, dy = ty - cy
        if abs(dx) <= 1 && abs(dy) <= 1 { break }
        m.bus.cops.postMouse(dx: Int8(max(-100, min(100, dx / 2))),
                             dy: Int8(max(-100, min(100, dy))))
        m.run(until: m.cycles + 200_000)
    }
    click(m)
}

/// Feedback-steer the cursor to `(tx,ty)` using the same convergence loop as
/// `clickAt`, but WITHOUT clicking -- shared by `press`/`drag` so the button
/// transitions land at the intended pixel.
func steerCursor(_ m: Machine, to tx: Int, _ ty: Int) {
    for _ in 0..<80 {
        let (cx, cy) = osCursor(m)
        let dx = tx - cx, dy = ty - cy
        if abs(dx) <= 1 && abs(dy) <= 1 { break }
        m.bus.cops.postMouse(dx: Int8(max(-100, min(100, dx / 2))),
                             dy: Int8(max(-100, min(100, dy))))
        m.run(until: m.cycles + 200_000)
    }
}

/// Steer to `(tx,ty)` then press the mouse button DOWN and leave it held
/// (keycap `$06` down, no up). See `Monitor.Command.press`.
func pressAt(_ m: Machine, _ tx: Int, _ ty: Int) {
    steerCursor(m, to: tx, ty)
    m.bus.cops.postKey(code: 0x06, down: true)
    m.run(until: m.cycles + 300_000)
}

/// Release the mouse button in place (keycap `$06` up). See
/// `Monitor.Command.release`.
func releaseButton(_ m: Machine) {
    m.bus.cops.postKey(code: 0x06, down: false)
    m.run(until: m.cycles + 300_000)
}

/// A full drag: steer to the start, press, steer to the end with the button
/// held, release. See `Monitor.Command.drag`.
func dragFromTo(_ m: Machine, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
    pressAt(m, x1, y1)
    steerCursor(m, to: x2, y2)
    releaseButton(m)
}

/// Maps a printable ASCII character to its Lisa keycap + whether Shift is held
/// (Final-US layout, docs/hardware-notes.md §8 -- the same keycaps as
/// `LisaShell/KeyMap`, keyed on ASCII here rather than macOS virtual codes).
func lisaKeycap(for ch: Character) -> (code: UInt8, shift: Bool)? {
    let lower: [Character: UInt8] = [
        "a": 0x70, "b": 0x6E, "c": 0x6D, "d": 0x7B, "e": 0x60, "f": 0x69, "g": 0x6A,
        "h": 0x6B, "i": 0x53, "j": 0x54, "k": 0x55, "l": 0x59, "m": 0x58, "n": 0x6F,
        "o": 0x5F, "p": 0x44, "q": 0x75, "r": 0x65, "s": 0x76, "t": 0x66, "u": 0x52,
        "v": 0x6C, "w": 0x77, "x": 0x7A, "y": 0x67, "z": 0x79,
        "1": 0x74, "2": 0x71, "3": 0x72, "4": 0x73, "5": 0x64, "6": 0x61, "7": 0x62,
        "8": 0x63, "9": 0x50, "0": 0x51,
        "-": 0x40, "=": 0x41, "\\": 0x42, "[": 0x56, "]": 0x57, ";": 0x5A, "'": 0x5B,
        ",": 0x5D, ".": 0x5E, "/": 0x4C, "`": 0x68,
        " ": 0x5C, "\n": 0x48, "\t": 0x78,
    ]
    // Shifted symbols -> the unshifted key's keycap + Shift (US layout).
    let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "|": "\\", "{": "[",
        "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
    if let c = lower[ch] { return (c, false) }
    if ch.isLetter, let c = lower[Character(ch.lowercased())] { return (c, true) }
    if let base = shifted[ch], let c = lower[base] { return (c, true) }
    return nil
}

/// Injects `text` as COPS make/break keyboard events (Shift keycap $7E held for
/// uppercase / shifted symbols). Unmappable characters are skipped.
func typeText(_ m: Machine, _ text: String) {
    let shiftKeycap: UInt8 = 0x7E
    for ch in text {
        guard let (code, shift) = lisaKeycap(for: ch) else { continue }
        if shift { m.bus.cops.postKey(code: shiftKeycap, down: true); m.run(until: m.cycles + 100_000) }
        m.bus.cops.postKey(code: code, down: true);  m.run(until: m.cycles + 150_000)
        m.bus.cops.postKey(code: code, down: false); m.run(until: m.cycles + 150_000)
        if shift { m.bus.cops.postKey(code: shiftKeycap, down: false); m.run(until: m.cycles + 100_000) }
    }
}

/// Generous default post-click cycle budget: `ROMFloppyBootTests.
/// bootIntoLoader` needs ~66M cycles (18M POST + 3M menu redraw + 40M to
/// reach the loaded boot block + 5M to reach the trap-#6 gate) and the
/// domain-1 crossover + OS entry a few million more
/// (`domain1CrossoverSurvivesLoaderLoadsOSImageAndReachesTheCOPSDriver`,
/// 400,000 further *instructions* -- comfortably under a few more million
/// cycles). 90M clears the whole documented path with slack for Task 3's
/// frontier to move further still.
let defaultBootdiskBudget = 90_000_000

/// Drives the scripted menu-boot harness: waits out POST, clicks "STARTUP
/// FROM..." (`420,182`, the `$53a` hit-test rect `[416,165,496,192]`),
/// clicks the top device-list item (`88,33`), then runs in bursts up to
/// `budget` further cycles -- printing a status line after each phase so
/// progress is visible interactively, and after every burst once the free
/// run starts. Requires a disk already inserted (`--disk`) and the machine
/// parked at power-on (run this as the first command). End condition (the
/// task brief's wording): a cycle budget, or PC having moved past
/// `$020000` -- i.e. out of ROM into loaded code, the same RAM/ROM
/// threshold `ROMFloppyBootTests` anchors its first-jump check on -- either
/// way, always finishes with a status line.
func bootdisk(_ m: Machine, monitor: Monitor, budget: Int) {
    guard m.bus.floppy.isInserted else {
        print("bootdisk: no disk inserted -- start lisadbg with --disk <path.dc42>")
        return
    }
    func status(_ label: String) {
        let pc = m.cpu[.pc]
        let location = (0x02_0000..<0xFE_0000).contains(pc) ? "RAM/loaded code" : "ROM"
        print("      [\(label)] PC=\(monitor.annotatedAddress(pc)) (\(location)) cycles=\(m.cycles) halted=\(m.halted) \(diskStatus(m))")
    }

    if m.cycles < 18_000_000 { m.run(until: 18_000_000) }         // POST done, menu idle
    status("POST complete, menu idle")

    moveCursor(m, to: 420, 182); click(m)                          // "STARTUP FROM..."
    m.run(until: m.cycles + 3_000_000)                             // device-list window drawn
    status("STARTUP FROM... clicked")

    moveCursor(m, to: 88, 33); click(m)                            // top device item
    status("device item clicked")

    let burstSize: UInt64 = 10_000_000
    let target = m.cycles + UInt64(max(0, budget))
    while m.cycles < target && !m.halted {
        m.run(until: min(target, m.cycles + burstSize))
        status("running")
    }
    status("bootdisk complete")
}

// `--disk <path.dc42>` (M2 Task 4) can appear anywhere alongside either the
// `--rom <dir>` or `<binary> [hex-load-address]` forms below -- pulled out
// first so the rest of the parsing is unaffected by its position.
var args = CommandLine.arguments
var diskPath: String?
if let diskFlagIndex = args.firstIndex(of: "--disk") {
    guard diskFlagIndex + 1 < args.count else {
        fail("--disk requires a path argument")
    }
    diskPath = args[diskFlagIndex + 1]
    args.removeSubrange(diskFlagIndex...(diskFlagIndex + 1))
}

// `--widget <path.widget>` (M5 Task 2): attach a persistent Widget hard disk.
// A missing path is created as an all-zero blank Widget-10 image on demand
// (§10.10). Position-independent, same as `--disk`.
var widgetPath: String?
if let widgetFlagIndex = args.firstIndex(of: "--widget") {
    guard widgetFlagIndex + 1 < args.count else {
        fail("--widget requires a path argument")
    }
    widgetPath = args[widgetFlagIndex + 1]
    args.removeSubrange(widgetFlagIndex...(widgetFlagIndex + 1))
}

// `--printer-dir <path>` (M7 Task 4): attach the ImageWriter print pipeline to
// Serial B and write each closed print job's pages as PNGs into <path>.
// Position-independent, same as `--disk`/`--widget`.
var printerDir: String?
if let printerFlagIndex = args.firstIndex(of: "--printer-dir") {
    guard printerFlagIndex + 1 < args.count else {
        fail("--printer-dir requires a path argument")
    }
    printerDir = args[printerFlagIndex + 1]
    args.removeSubrange(printerFlagIndex...(printerFlagIndex + 1))
}

guard args.count >= 2 else {
    fail("usage: lisadbg <binary> [hex-load-address]  |  lisadbg --rom <dir>  [--disk <path.dc42>] [--widget <path.widget>] [--printer-dir <path>]")
}

let machine = Machine()

if args[1] == "--rom" {
    guard args.count >= 3 else {
        fail("--rom requires a directory argument")
    }
    let dir = URL(fileURLWithPath: args[2])
    let rom: [UInt8]
    do {
        rom = try ROMImage.load(directory: dir)
    } catch {
        fail("cannot load ROM from \(dir.path): \(error)")
    }
    machine.bus.loadROM(rom)
    machine.reset()
    print("lisadbg — loaded \(rom.count)-byte ROM from \(dir.path). ? for help.")
} else {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    } catch {
        fail("cannot read \(args[1]): \(error.localizedDescription)")
    }
    let loadAddr = args.count > 2 ? UInt32(args[2], radix: 16) ?? 0 : 0
    machine.bus.load([UInt8](data), at: loadAddr)
    machine.reset()
    print("lisadbg — \(data.count) bytes @ \(String(format: "%06X", loadAddr)). ? for help.")
}

if let diskPath {
    do {
        let image = try DC42Image.load(url: URL(fileURLWithPath: diskPath))
        machine.bus.floppy.insert(image)
        print("lisadbg — inserted disk image \(diskPath) (\(image.blockCount) blocks)")
    } catch {
        fail("cannot load disk image \(diskPath): \(error)")
    }
}

if let widgetPath {
    let url = URL(fileURLWithPath: widgetPath)
    do {
        let image: WidgetImage
        if FileManager.default.fileExists(atPath: url.path) {
            image = try WidgetImage(contentsOf: url)
            print("lisadbg — attached Widget image \(widgetPath) (\(image.blockCount) blocks)")
        } else {
            image = try WidgetImage(createBlankAt: url)
            print("lisadbg — created blank Widget image \(widgetPath) (\(image.blockCount) blocks)")
        }
        machine.bus.widget.attach(image)
    } catch {
        fail("cannot attach Widget image \(widgetPath): \(error)")
    }
}

// M7 Task 4: the printer pipeline. When `--printer-dir` is given, attach the
// ImageWriter interpreter + spooler to Serial B (bus.scc.channelB.printerPort)
// and route closed jobs to a PNG sink. The pipeline is ticked once per command
// (host wall-clock time) so an idle job auto-closes; the `printer` command
// force-flushes for a deterministic capture at end of a scripted print.
var printerPipeline: PrinterPipeline?
var printerSink: PrinterSink?
// `--printer-raw <path>` (debug): tee the raw Serial-B wire bytes to a file for
// escape-stream analysis. Accumulated in memory, flushed by the `printer`/`q`.
let printerRawPath = ProcessInfo.processInfo.environment["LISAEMU_PRINTER_RAW"]
let printerRawBox = RawByteBox()
if let printerDir {
    let pipeline = PrinterPipeline()
    let sink = PrinterSink(dir: printerDir)
    pipeline.onJob = { [sink] job in sink.write(job) }
    if printerRawPath != nil {
        pipeline.rawByteSink = { [printerRawBox] b in printerRawBox.append(b) }
    }
    machine.bus.scc.channelB.printerPort = pipeline.printerPort
    printerPipeline = pipeline
    printerSink = sink
    print("lisadbg — printer pipeline attached to Serial B; jobs -> PNGs in \(printerDir)")
}

// Linkmap symbol overlay (M4 Task 2) -- `LISAEMU_LINKMAP_DIR` or the
// default `~/Development/Lisa_Source/LISA_OS/Linkmaps 3.0/`
// (`LinkmapSymbols.defaultDirectory`). Never bundled/committed: this is a
// user-supplied local path read at runtime only, per the global
// constraints. Missing directory = symbols simply stay unloaded (`d`/`t`/
// `sym` degrade gracefully to unannotated output, exactly the pre-Task-2
// behavior) -- this is routine, not an error, so it's not `fail()`.
var monitor = Monitor(machine: machine)
let linkmapDir = ProcessInfo.processInfo.environment["LISAEMU_LINKMAP_DIR"]
    .map { URL(fileURLWithPath: $0) } ?? LinkmapSymbols.defaultDirectory
do {
    let loaded = try LinkmapSymbols.load(directory: linkmapDir)
    monitor.symbols = loaded
    print("lisadbg — loaded \(loaded.symbols.count) linkmap symbols from \(linkmapDir.path)")
} catch {
    print("lisadbg — no linkmap symbols (\(linkmapDir.path): \(error)); d/t/sym will show raw addresses")
}

print(monitor.registerDump())
while let line = readLine(strippingNewline: true) {
    // M7 Task 4: advance the printer's idle clock before each command with
    // host wall-clock time, so a job that went quiet during a preceding
    // run/click closes on its own; `printer` also force-flushes below.
    printerPipeline?.tick(now: ProcessInfo.processInfo.systemUptime)
    switch Monitor.parse(line) {
    case .regs:
        print(monitor.registerDump())
    case .step(let n):
        for _ in 0..<n { _ = machine.step() }
        print(monitor.disassembly(from: machine.cpu[.pc], count: 1))
        print(monitor.registerDump())
    case .disasm(let addr, let n):
        print(monitor.disassembly(from: addr ?? machine.cpu[.pc], count: n))
    case .mem(let addr, let n):
        print(monitor.hexDump(at: addr, count: n))
    case .trace(let n):
        for _ in 0..<n {
            guard !machine.halted else { break }
            print(monitor.disassembly(from: machine.cpu[.pc], count: 1))
            let beforeIO = machine.bus.ioTrace.count
            let beforeMMU = machine.bus.mmuPortLog.count
            _ = machine.step()
            for e in machine.bus.mmuPortLog[beforeMMU...] {
                print(formatMMUPortWrite(e))
            }
            for access in machine.bus.ioTrace[beforeIO...] {
                print(formatIOAccess(access))
            }
        }
        var status = "      setup=\(machine.bus.setupMode ? "ON" : "OFF") domain=\(machine.bus.domain) mmuPortWrites=\(machine.bus.mmuPortWrites) busErrorPulses=\(machine.bus.busErrorPulseCount) \(diskStatus(machine))"
        if machine.bus.ioTraceDropped > 0 {
            status += " ioTraceDropped=\(machine.bus.ioTraceDropped)"
        }
        print(status)
        print(monitor.registerDump())
    case .go(let n):
        // Run n cycles quietly, then dump SLIM/SORG writes + I/O touches that
        // happened during the slice (deduped/summarized), plus final state.
        let beforeIO = machine.bus.ioTrace.count
        let beforeMMU = machine.bus.mmuPortLog.count
        let target = machine.cycles + UInt64(n)
        machine.run(until: target)
        reportSlice(machine, monitor: monitor, beforeIO: beforeIO, beforeMMU: beforeMMU)
    case .goUntil(let addr, let n):
        // Same slice report as `g`, plus WHY it stopped -- the whole point of
        // `gu` is distinguishing "arrived at the breakpoint" from "ran out of
        // budget", which a `g` of the same span cannot tell you.
        let beforeIO = machine.bus.ioTrace.count
        let beforeMMU = machine.bus.mmuPortLog.count
        let reason = machine.run(untilPC: addr, maxCycles: UInt64(n))
        reportSlice(machine, monitor: monitor, beforeIO: beforeIO, beforeMMU: beforeMMU,
                    prefix: "      gu $\(String(format: "%06X", Int(addr))) stop=\(reason) after \(n) cycle budget")
    case .goWatch(let addr, let n):
        let beforeIO = machine.bus.ioTrace.count
        let beforeMMU = machine.bus.mmuPortLog.count
        let (reason, before, after) = machine.run(untilChangeAt: addr, maxCycles: UInt64(n))
        let change = reason == .watchTriggered
            ? String(format: "$%02X -> $%02X", Int(before), Int(after))
            : String(format: "still $%02X", Int(before))
        reportSlice(machine, monitor: monitor, beforeIO: beforeIO, beforeMMU: beforeMMU,
                    prefix: "      gw $\(String(format: "%06X", Int(addr))) stop=\(reason) (\(change)) after \(n) cycle budget")
    case .ioTraceClear:
        machine.bus.clearIOTrace()
        print("      ioTrace cleared (limit=\(machine.bus.ioTraceLimit)) -- the next g/gu slice starts from empty")
    case .ioTraceLimit(let n):
        machine.bus.ioTraceLimit = n
        print("      ioTrace limit=\(n) (holding \(machine.bus.ioTrace.count), dropped=\(machine.bus.ioTraceDropped)); `iot clear` to start fresh")
    case .screenshot(let path):
        let snapshot = machine.bus.framebufferSnapshot()
        do {
            try writeScreenshotPNG(snapshot, to: path)
            print("wrote \(Bus.framebufferWidth)x\(Bus.framebufferHeight) screenshot to \(path)")
        } catch {
            print("sc: \(error)")
        }
    case .asciiPreview:
        print(asciiPreview(machine.bus.framebufferSnapshot()))
    case .bootdisk(let n):
        bootdisk(machine, monitor: monitor, budget: n ?? defaultBootdiskBudget)
        print(monitor.registerDump())
    case .sym(let addr):
        if monitor.symbols == nil {
            print("      no linkmap symbols loaded (set LISAEMU_LINKMAP_DIR, or check out Lisa_Source at \(LinkmapSymbols.defaultDirectory.path))")
        } else {
            print("      \(monitor.annotatedAddress(addr))")
        }
    case .symbase(let addr):
        guard monitor.symbols != nil else {
            print("      no linkmap symbols loaded -- symbase has nothing to offset")
            break
        }
        monitor.symbols?.baseOffset = addr
        print("      symbol base offset set to $\(String(format: "%06X", addr))")
    case .widgetCreate(let path):
        let url = URL(fileURLWithPath: path)
        do {
            // Refuse to clobber an existing file (e.g. a genuine installed
            // Widget image) -- `WidgetImage(createBlankAt:)` itself always
            // overwrites, so this bare-path command surface guards first.
            try WidgetImage.guardCreatable(at: url)
            let image = try WidgetImage(createBlankAt: url)
            machine.bus.widget.attach(image)
            print("      created + attached blank Widget image \(path) (\(image.blockCount) blocks, \(image.blockCount * WidgetImage.bytesPerBlock) bytes)")
        } catch WidgetImage.Error.alreadyExists(let existingPath) {
            print("      widget create: a file already exists at \(existingPath) -- remove it first or pick a new path (widget create never overwrites)")
        } catch {
            print("      widget create: \(error)")
        }
    case .click(let x, let y):
        clickAt(machine, x, y)
        let (cx, cy) = osCursor(machine)
        print("      clicked at cursor (\(cx),\(cy)) [target (\(x),\(y))]")
    case .dclick(let x, let y):
        doubleClickAt(machine, x, y)
        let (cx, cy) = osCursor(machine)
        print("      double-clicked at cursor (\(cx),\(cy)) [target (\(x),\(y))]")
    case .type(let text):
        typeText(machine, text)
        print("      typed \(text.count) character(s)")
    case .power:
        machine.bus.cops.pressPowerButton()
        print("      pressed soft-power button (COPS $80,$FB) -- run forward (g) to let the OS shut down; powerState=\(machine.powerState)")
    case .press(let x, let y):
        pressAt(machine, x, y)
        let (cx, cy) = osCursor(machine)
        print("      pressed (button held) at cursor (\(cx),\(cy)) [target (\(x),\(y))]")
    case .release:
        releaseButton(machine)
        let (cx, cy) = osCursor(machine)
        print("      released button at cursor (\(cx),\(cy))")
    case .moveTo(let x, let y):
        steerCursor(machine, to: x, y)
        let (cx, cy) = osCursor(machine)
        print("      moved to cursor (\(cx),\(cy)) [target (\(x),\(y))] (button state unchanged)")
    case .drag(let x1, let y1, let x2, let y2):
        dragFromTo(machine, x1, y1, x2, y2)
        let (cx, cy) = osCursor(machine)
        print("      dragged (\(x1),\(y1)) -> (\(x2),\(y2)); cursor now (\(cx),\(cy))")
    case .insertFloppy(let path):
        do {
            let image = try DC42Image.load(url: URL(fileURLWithPath: path))
            machine.bus.floppy.insertWhileRunning(image)
            print("      inserted floppy \(path) (\(image.blockCount) blocks) via media-change path -- bot_in attention raised, run forward (g) to let the OS mount it")
        } catch {
            print("      insert: cannot load \(path): \(error)")
        }
    case .ejectFloppy:
        // Bare eject, no OS-visible media-change attention -- deliberate and
        // correct, NOT asymmetric-by-oversight with `insert` above. See
        // `EmulationController.ejectFloppy()`'s doc comment and hardware-notes
        // §9 (M6 Task 4): a real Sony drive has no "diskette removed" interrupt;
        // the OS discovers the stale presence on its next disk access.
        machine.bus.floppy.eject()
        print("      ejected floppy")
    case .printer:
        guard let pipeline = printerPipeline, let sink = printerSink else {
            print("      printer: no pipeline attached — start lisadbg with --printer-dir <path>")
            break
        }
        // Force-close any inked page + open job to the PNG sink (deterministic
        // end-of-print capture), then report the pipeline counters.
        pipeline.flush()
        let bytes = machine.bus.scc.channelB.transmittedCount
        print("      printer: Serial-B bytes=\(bytes) jobsWritten=\(sink.jobsWritten) pagesWritten=\(sink.pagesWritten) dir=\(sink.dir)")
        if !sink.lastPaths.isEmpty {
            print("      printer: last job PNGs -> \(sink.lastPaths.joined(separator: ", "))")
        }
        if let printerRawPath { printerRawBox.write(to: printerRawPath) }
    case .reset:
        machine.reset()
        print("      warm reset -- CPU at ROM entry, cycles=\(machine.cycles), media/printer survive")
    case .quit:
        exit(0)
    case .help:
        print("r | s [n] | d [hexaddr] [n] | m <hexaddr> [n] | t [n] | g [cycles] | gu <hexaddr> [cycles] | gw <hexaddr> [cycles] | iot clear | iot limit <n> | sc <path.png> | sca | bootdisk [cycles] | click <x> <y> | dclick <x> <y> | press <x> <y> | release | moveto <x> <y> | drag <x1> <y1> <x2> <y2> | type <text> | insert <path.dc42> | eject | power | printer | sym <hexaddr> | symbase <hexaddr> | widget create <path> | q")
    case nil:
        print("? — unknown command")
    }
}
