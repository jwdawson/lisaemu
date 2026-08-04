import Foundation

public struct Monitor {
    public enum Command: Equatable {
        case regs, step(Int), disasm(UInt32?, Int), mem(UInt32, Int), trace(Int), go(Int), quit, help
    }

    let machine: Machine
    public init(machine: Machine) { self.machine = machine }

    public static func parse(_ line: String) -> Command? {
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return nil }
        func hex(_ i: Int) -> UInt32? {
            parts.count > i ? UInt32(parts[i], radix: 16) : nil
        }
        func int(_ i: Int, default d: Int) -> Int {
            parts.count > i ? Int(parts[i]) ?? d : d
        }
        switch cmd {
        case "r": return .regs
        case "s": return .step(int(1, default: 1))
        case "d": return .disasm(hex(1), int(2, default: 8))
        case "m": guard let a = hex(1) else { return nil }
                  return .mem(a, int(2, default: 64))
        case "t": return .trace(int(1, default: 1))
        case "g": return .go(int(1, default: 100000))
        case "q": return .quit
        case "?": return .help
        default:  return nil
        }
    }

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
        PC=\(h(c[.pc])) SR=\(String(format: "%04X", Int(sr))) cycles=\(machine.cycles)
        """
    }

    public func disassembly(from address: UInt32, count: Int) -> String {
        machine.bus.withPeek {
            var lines: [String] = []
            var pc = address
            for _ in 0..<count {
                let (text, length) = machine.cpu.disassemble(at: pc)
                let addrStr = String(format: "%06X", Int(pc))
                let line = "\(addrStr): \(text)"
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
