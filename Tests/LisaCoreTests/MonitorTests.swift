import Testing
@testable import LisaCore

extension MusashiSuites {
    @Suite struct MonitorTests {
        @Test func parsesCommands() {
            #expect(Monitor.parse("r") == .regs)
            #expect(Monitor.parse("s") == .step(1))
            #expect(Monitor.parse("s 10") == .step(10))
            #expect(Monitor.parse("d 400 3") == .disasm(0x400, 3))
            #expect(Monitor.parse("d") == .disasm(nil, 8))
            #expect(Monitor.parse("m 400 32") == .mem(0x400, 32))
            #expect(Monitor.parse("q") == .quit)
            #expect(Monitor.parse("bogus") == nil)
        }

        @Test func registerDumpShowsKnownState() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000); m.bus.write32(0x4, 0x400)
            m.bus.load([0x70, 0x2A, 0x60, 0xFE], at: 0x400)   // MOVEQ #42,D0; spin
            m.reset()
            m.run(until: 20)
            let dump = Monitor(machine: m).registerDump()
            #expect(dump.contains("D0=0000002A"))
            #expect(dump.contains("PC="))
        }

        @Test func disassemblyWalksInstructionLengths() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000); m.bus.write32(0x4, 0x400)
            m.bus.load([0x70, 0x2A, 0x4E, 0x71], at: 0x400)   // MOVEQ; NOP
            m.reset()
            let text = Monitor(machine: m).disassembly(from: 0x400, count: 2)
            let lines = text.split(separator: "\n")
            #expect(lines.count == 2)
            #expect(lines[0].hasPrefix("000400:"))
            #expect(lines[1].hasPrefix("000402:"))
        }
    }
}
