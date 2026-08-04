import Foundation
import LisaCore

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
        if offset >= 0xD801, offset <= 0xD801 + 15 * 8, (offset - 0xD801) % 8 == 0 {
            return "VIA1 reg \((offset - 0xD801) / 8)"
        }
        if offset >= 0xDC01, offset <= 0xDC01 + 15 * 2, (offset - 0xDC01) % 2 == 0 {
            return "VIA2 reg \((offset - 0xDC01) / 2)"
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
        print("      setup=\(machine.bus.setupMode ? "ON" : "OFF") domain=\(machine.bus.domain) mmuPortWrites=\(machine.bus.mmuPortWrites)")
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
    case .quit:
        exit(0)
    case .help:
        print("r | s [n] | d [hexaddr] [n] | m <hexaddr> [n] | t [n] | g [cycles] | q")
    case nil:
        print("? — unknown command")
    }
}
