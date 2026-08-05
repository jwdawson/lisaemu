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
            #expect(Monitor.parse("t") == .trace(1))
            #expect(Monitor.parse("t 5") == .trace(5))
            #expect(Monitor.parse("g") == .go(100000))
            #expect(Monitor.parse("g 50") == .go(50))
            #expect(Monitor.parse("sc /tmp/shot.png") == .screenshot("/tmp/shot.png"))
            #expect(Monitor.parse("sc") == nil, "sc requires a path argument")
            #expect(Monitor.parse("sca") == .asciiPreview)
            #expect(Monitor.parse("q") == .quit)
            #expect(Monitor.parse("bogus") == nil)
        }

        /// Deferred M1b Task 4-review minor, folded in by Task 5: a negative
        /// count for `s`/`t`/`g` (and, incidentally, `d`/`m`, which share the
        /// same `int(_:default:)` parsing helper) must fall back to the
        /// command's default rather than reaching a `0..<n` Range downstream
        /// and crashing the debugger.
        @Test func negativeCountsFallBackToDefaultsInsteadOfCrashing() {
            #expect(Monitor.parse("s -5") == .step(1))
            #expect(Monitor.parse("t -1") == .trace(1))
            #expect(Monitor.parse("g -100") == .go(100000))
            #expect(Monitor.parse("d 400 -3") == .disasm(0x400, 8))
            #expect(Monitor.parse("m 400 -3") == .mem(0x400, 64))
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
