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
            let before = machine.bus.ioTrace.count
            _ = machine.step()
            for access in machine.bus.ioTrace[before...] {
                print(formatIOAccess(access))
            }
        }
        print(monitor.registerDump())
    case .quit:
        exit(0)
    case .help:
        print("r | s [n] | d [hexaddr] [n] | m <hexaddr> [n] | t [n] | q")
    case nil:
        print("? — unknown command")
    }
}
