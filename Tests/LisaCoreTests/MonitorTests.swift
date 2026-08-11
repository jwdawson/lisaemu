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
            #expect(Monitor.parse("bootdisk") == .bootdisk(nil))
            #expect(Monitor.parse("bootdisk 5000000") == .bootdisk(5_000_000))
            #expect(Monitor.parse("sym 520824") == .sym(0x52_0824))
            #expect(Monitor.parse("sym") == nil, "sym requires an address argument")
            #expect(Monitor.parse("symbase 500000") == .symbase(0x50_0000))
            #expect(Monitor.parse("symbase") == nil, "symbase requires an address argument")
            #expect(Monitor.parse("widget create /tmp/hd.widget") == .widgetCreate("/tmp/hd.widget"))
            #expect(Monitor.parse("widget") == nil, "widget requires a sub-command")
            #expect(Monitor.parse("widget create") == nil, "widget create requires a path")
            // M5 Task 3: click/type scripting primitives.
            #expect(Monitor.parse("click 615 210") == .click(615, 210))
            #expect(Monitor.parse("click 615") == nil, "click requires both x and y")
            #expect(Monitor.parse("click") == nil, "click requires coordinates")
            #expect(Monitor.parse("type Hello World") == .type("Hello World"))
            #expect(Monitor.parse("type") == nil, "type requires text")
            // M6 Task 1: soft-power button.
            #expect(Monitor.parse("power") == .power)
            #expect(Monitor.parse("q") == .quit)
            #expect(Monitor.parse("bogus") == nil)
        }

        /// M4 Task 2: a non-positive `bootdisk` budget falls back to the
        /// default (resolved by `lisadbg`'s `defaultBootdiskBudget`),
        /// matching the `s`/`t`/`g` negative-count convention above.
        @Test func bootdiskWithoutOrWithAnInvalidBudgetFallsBackToNil() {
            #expect(Monitor.parse("bootdisk -5") == .bootdisk(nil))
            #expect(Monitor.parse("bootdisk 0") == .bootdisk(nil))
        }

        /// M4 Task 2: symbol annotation is opt-in via `Monitor.symbols` --
        /// unset (the default), `disassembly` is byte-identical to
        /// pre-Task-2 output; set, an address `lookup` resolves gets a
        /// `[UNIT.PROC+0xNN]` suffix.
        @Test func disassemblyAnnotatesWithLoadedSymbols() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000); m.bus.write32(0x4, 0x400)
            m.bus.load([0x70, 0x2A, 0x4E, 0x71], at: 0x400)   // MOVEQ; NOP
            m.reset()
            var monitor = Monitor(machine: m)
            monitor.symbols = LinkmapSymbols(symbols: [.init(unit: "fakeUnit", proc: "FAKEROUT", address: 0x400)])
            let text = monitor.disassembly(from: 0x400, count: 1)
            #expect(text.hasPrefix("000400 [fakeUnit.FAKEROUT]:"))
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

        /// M4 Task 2 review fix: `registerDump`'s `PC=` field must carry the
        /// same `[UNIT.PROC+0xNN]` annotation `disassembly` does when
        /// symbols are loaded -- it wasn't wired up initially, so `r`/`s`/
        /// `t`/`g`/`bootdisk`'s status output (all built on `registerDump`)
        /// silently showed raw hex even with a Linkmap loaded.
        @Test func registerDumpAnnotatesPCWithLoadedSymbols() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000); m.bus.write32(0x4, 0x400)
            m.bus.load([0x70, 0x2A, 0x60, 0xFE], at: 0x400)   // MOVEQ #42,D0; spin (BRA.S $402)
            m.reset()
            m.run(until: 20)
            #expect(m.cpu[.pc] == 0x402, "the spin loop parks at its own BRA.S target")

            var monitor = Monitor(machine: m)
            #expect(!monitor.registerDump().contains("["),
                    "no symbols loaded -- PC shows plain hex, no annotation (unchanged from pre-fix)")

            monitor.symbols = LinkmapSymbols(symbols: [.init(unit: "fakeUnit", proc: "SPIN", address: 0x402)])
            #expect(monitor.registerDump().contains("PC=000402 [fakeUnit.SPIN]"))
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
