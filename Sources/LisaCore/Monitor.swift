import Foundation

public struct Monitor {
    public enum Command: Equatable {
        case regs, step(Int), disasm(UInt32?, Int), mem(UInt32, Int), trace(Int), go(Int)
        case screenshot(String), asciiPreview
        /// The scripted menu-boot harness (M4 Task 2): cycle/instruction
        /// budget defaults to `bootdisk`'s own generous constant when no
        /// argument is given (see `bootdisk`'s doc comment in `lisadbg`).
        case bootdisk(Int?)
        /// `sym <hexaddr>` -- one-shot `LinkmapSymbols.lookup` (M4 Task 2).
        case sym(UInt32)
        /// `symbase <hexaddr>` -- sets `LinkmapSymbols.baseOffset` (M4 Task
        /// 2's relocation model; see `LinkmapSymbols.swift`'s doc comment
        /// "base-offset story").
        case symbase(UInt32)
        /// `widget create <path>` (M5 Task 2) -- creates a fresh all-zero
        /// Widget-10 hard-disk image at `<path>` and attaches it, so the
        /// installer can format-and-populate a blank disk (§10.10).
        case widgetCreate(String)
        /// `click <x> <y>` (M5 Task 3) -- feedback-steer the cursor to screen
        /// pixel `(x,y)` and press/release the mouse button. Unlike `bootdisk`'s
        /// ROM-menu clicks (which steer the ROM cursor cells `$496`/`$498`),
        /// this drives the OS's own cursor once the OS is running -- see
        /// lisadbg's `osCursor`/`clickAt`.
        case click(Int, Int)
        /// `type <text>` (M5 Task 3) -- injects `text` as COPS keyboard
        /// make/break events (with Shift for uppercase / shifted symbols).
        case type(String)
        /// `power` (M6 Task 1) -- presses the Lisa's soft-power button
        /// (`COPS.pressPowerButton()`): COPS delivers `$80,$FB` on its input
        /// stream, the OS runs its own shutdown and issues a COPS power-off
        /// command, and the machine stops (`Machine.powerState == .off`).
        case power
        case quit, help
    }

    let machine: Machine
    /// Address->symbol overlay for `d`/`t`/status annotation and the `sym`
    /// command (M4 Task 2). `nil` (the default) leaves every output
    /// byte-identical to pre-Task-2 `Monitor` -- existing pins
    /// (`MonitorTests`) rely on this.
    public var symbols: LinkmapSymbols?
    public init(machine: Machine) { self.machine = machine }

    public static func parse(_ line: String) -> Command? {
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return nil }
        func hex(_ i: Int) -> UInt32? {
            parts.count > i ? UInt32(parts[i], radix: 16) : nil
        }
        // Rejects a negative count rather than letting it reach a `0..<n`
        // Range construction downstream (`s`/`t`/`g`'s call sites in
        // lisadbg all loop/run using a count built this way) -- `Range`
        // traps on a negative upper bound, so a stray `s -5` typed at the
        // prompt would crash the whole debugger instead of just being
        // rejected. Falls back to `d`, matching every other malformed-arg
        // case here.
        func int(_ i: Int, default d: Int) -> Int {
            guard parts.count > i, let v = Int(parts[i]), v >= 0 else { return d }
            return v
        }
        switch cmd {
        case "r": return .regs
        case "s": return .step(int(1, default: 1))
        case "d": return .disasm(hex(1), int(2, default: 8))
        case "m": guard let a = hex(1) else { return nil }
                  return .mem(a, int(2, default: 64))
        case "t": return .trace(int(1, default: 1))
        case "g": return .go(int(1, default: 100000))
        case "sc": guard parts.count > 1 else { return nil }
                   return .screenshot(parts[1])
        case "sca": return .asciiPreview
        case "bootdisk":
            if parts.count > 1, let n = Int(parts[1]), n > 0 { return .bootdisk(n) }
            return .bootdisk(nil)
        case "sym": guard let a = hex(1) else { return nil }
                    return .sym(a)
        case "symbase": guard let a = hex(1) else { return nil }
                        return .symbase(a)
        case "widget":
            // `widget create <path>` -- only sub-command today.
            guard parts.count >= 3, parts[1] == "create" else { return nil }
            // Rejoin the tail so paths containing spaces survive the split.
            let path = parts[2...].joined(separator: " ")
            return .widgetCreate(path)
        case "click":
            // Decimal screen pixel coordinates (unlike the hex address args).
            guard parts.count >= 3, let x = Int(parts[1]), let y = Int(parts[2]),
                  x >= 0, y >= 0 else { return nil }
            return .click(x, y)
        case "type":
            guard parts.count >= 2 else { return nil }
            return .type(parts[1...].joined(separator: " "))
        case "power": return .power
        case "q": return .quit
        case "?": return .help
        default:  return nil
        }
    }

    /// The `r`/`s`/`t`/`g`/`bootdisk` status dump. `PC=` is routed through
    /// `annotatedAddress` (M4 Task 2) -- unlike the other registers, PC is
    /// an executable address a Linkmap symbol can actually resolve, so it
    /// gets the same `[UNIT.PROC+0xNN]` annotation `d`/`t` show, when
    /// `symbols` is loaded and it resolves. Note the differing digit
    /// counts: `annotatedAddress` formats 6 hex digits (`%06X`, matching
    /// `d`'s address column and the CPU's 24-bit address bus), while this
    /// dump's other registers stay 8-digit `%08X` (full 32-bit D/A
    /// register values) -- PC's field width changes here from its
    /// pre-Task-2 8 digits to 6, which is correct (a PC value never
    /// occupies the top byte) but is a visible format change downstream
    /// consumers should note.
    public func registerDump() -> String {
        let c = machine.cpu
        func h(_ v: UInt32) -> String {
            String(format: "%08X", v)
        }
        let sr = UInt16(truncatingIfNeeded: c[.sr])
        return """
        D0=\(h(c[.d0])) D1=\(h(c[.d1])) D2=\(h(c[.d2])) D3=\(h(c[.d3]))
        D4=\(h(c[.d4])) D5=\(h(c[.d5])) D6=\(h(c[.d6])) D7=\(h(c[.d7]))
        A0=\(h(c[.a0])) A1=\(h(c[.a1])) A2=\(h(c[.a2])) A3=\(h(c[.a3]))
        A4=\(h(c[.a4])) A5=\(h(c[.a5])) A6=\(h(c[.a6])) A7=\(h(c[.a7]))
        PC=\(annotatedAddress(c[.pc])) SR=\(String(format: "%04X", Int(sr))) cycles=\(machine.cycles)
        """
    }

    /// Formats `addr`'s hex + (when `symbols` is loaded and resolves it) a
    /// `[UNIT.PROC+0xNN]`-style annotation -- the shared "d"/"t"/status
    /// address presentation (`registerDump`'s `PC=` field, `disassembly`'s
    /// address column) (M4 Task 2).
    public func annotatedAddress(_ addr: UInt32) -> String {
        let addrStr = String(format: "%06X", Int(addr))
        guard let sym = symbols?.lookup(addr) else { return addrStr }
        return "\(addrStr) [\(sym)]"
    }

    public func disassembly(from address: UInt32, count: Int) -> String {
        machine.bus.withPeek {
            var lines: [String] = []
            var pc = address
            for _ in 0..<count {
                let (text, length) = machine.cpu.disassemble(at: pc)
                let line = "\(annotatedAddress(pc)): \(text)"
                lines.append(line)
                pc &+= UInt32(length)
            }
            return lines.joined(separator: "\n")
        }
    }

    public func hexDump(at address: UInt32, count: Int) -> String {
        machine.bus.withPeek {
            var lines: [String] = []
            for row in stride(from: 0, to: count, by: 16) {
                var bytes: [String] = []
                for i in 0..<min(16, count - row) {
                    let byte = machine.bus.read8(address &+ UInt32(row + i))
                    bytes.append(String(format: "%02X", Int(byte)))
                }
                let byteString = bytes.joined(separator: " ")
                let addrStr = String(format: "%06X", Int(address &+ UInt32(row)))
                let line = "\(addrStr): \(byteString)"
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
    }
}
