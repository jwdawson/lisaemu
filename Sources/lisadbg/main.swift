import CoreGraphics
import Foundation
import ImageIO
import LisaCore
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
/// "Set bit = black" (task brief) is expressed with a `decode` array rather
/// than by unpacking bits manually: `CGImage`'s default 1bpp DeviceGray
/// decode maps component 0 -> black, 1 -> white -- the OPPOSITE of what the
/// brief specifies -- so `decode: [1, 0]` inverts it (component 0 -> output
/// 1.0/white, component 1 -> output 0.0/black). This is debugger tooling
/// only (`lisadbg`, not `LisaCore` -- see that module's "framework-free"
/// constraint), hence the direct ImageIO/CoreGraphics dependency here.
func writeScreenshotPNG(_ framebuffer: [UInt8], to path: String) throws {
    let width = Bus.framebufferWidth
    let height = Bus.framebufferHeight
    let bytesPerRow = width / 8
    guard let provider = CGDataProvider(data: Data(framebuffer) as CFData) else {
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
        decode: [1, 0],
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

/// Coarse ~90x45 block-averaged ASCII preview of a framebuffer snapshot,
/// printed straight to the terminal (`sca`) -- a quick "is anything drawn
/// yet" sanity check without leaving the shell. Each output cell averages
/// the black-pixel density of the source block it covers and picks a
/// character from a light-to-dark ramp; block boundaries are computed by
/// plain integer scaling (`width * col / outCols`), so boundaries aren't
/// perfectly uniform when the source dimensions don't divide evenly (364 /
/// 45 isn't exact) -- "block-averaged", not exact-area-averaged, per the
/// brief's "~90x45" wording.
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

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: lisadbg <binary> [hex-load-address]  |  lisadbg --rom <dir>")
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

let monitor = Monitor(machine: machine)
print(monitor.registerDump())
while let line = readLine(strippingNewline: true) {
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
        var status = "      setup=\(machine.bus.setupMode ? "ON" : "OFF") domain=\(machine.bus.domain) mmuPortWrites=\(machine.bus.mmuPortWrites)"
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
        print("--- MMU port writes this slice ---")
        for e in machine.bus.mmuPortLog[beforeMMU...] {
            print(formatMMUPortWrite(e))
        }
        print("--- I/O touches this slice ---")
        for access in machine.bus.ioTrace[beforeIO...] {
            print(formatIOAccess(access))
        }
        print("      setup=\(machine.bus.setupMode ? "ON" : "OFF") domain=\(machine.bus.domain) mmuPortWrites=\(machine.bus.mmuPortWrites) halted=\(machine.halted)")
        print(monitor.disassembly(from: machine.cpu[.pc], count: 1))
        print(monitor.registerDump())
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
    case .quit:
        exit(0)
    case .help:
        print("r | s [n] | d [hexaddr] [n] | m <hexaddr> [n] | t [n] | g [cycles] | sc <path.png> | sca | q")
    case nil:
        print("? — unknown command")
    }
}
