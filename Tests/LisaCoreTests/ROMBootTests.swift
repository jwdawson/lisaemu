import Foundation
import Testing
@testable import LisaCore

/// M1a exit-criterion: the real Rev H boot ROM executes under the emulator.
///
/// Env-gated on `LISAEMU_ROM_DIR` (point it at a directory holding
/// `341-0175-H.BIN` / `341-0176-H.BIN`). Every assertion here is anchored to
/// an observation documented in `docs/rom-trace-notes.md`; that file is the
/// authoritative M1b requirements record and should be updated in lockstep
/// with any change to these expectations.
///
/// Nested under `MusashiSuites` because it builds a `Machine` (hence an
/// `M68K`), and Musashi is a process-global singleton.
private let romDir = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]

extension MusashiSuites {
    @Suite(.enabled(if: romDir != nil, "Set LISAEMU_ROM_DIR to run real-ROM boot tests"))
    struct ROMBootTests {
        /// Builds a 2 MB Machine (the Lisa hardware maximum -- the ROM sizes
        /// memory), loads the interleaved ROM, and resets.
        private func bootedMachine() throws -> Machine {
            let rom = try ROMImage.load(directory: URL(fileURLWithPath: romDir!))
            let m = Machine(ramSize: 0x20_0000)   // 2 MB, hardware max
            m.bus.loadROM(rom)
            m.reset()
            return m
        }

        /// Reset vectors decode to the documented SSP/PC (rom-trace-notes.md
        /// "Reset vectors"; also verified in Task 6 / ROMImage docs).
        @Test
        func resetVectorsMatchDocumentedValues() throws {
            let m = try bootedMachine()
            #expect(m.cpu[.a7] == 0x0000_0480, "initial SSP (vector 0)")
            #expect(m.cpu[.pc] == 0x00FE_00F6, "initial PC (vector 4), inside the ROM window")
        }

        /// Running 2 M cycles (~0.4 emulated seconds) drives the ROM through
        /// its full power-on sequence. Under the current (M1a) model this ends
        /// in a deterministic HALT at the setup-drop boundary -- see the
        /// dedicated test below; here we assert the *productive* facts that
        /// hold regardless: the ROM touched I/O and programmed the MMU.
        @Test
        func romTouchesIOAndProgramsMMU() throws {
            let m = try bootedMachine()
            m.run(until: 2_000_000)

            // (b) The ROM touched I/O space. The only IODispatcher-visible
            // touches before the halt are the domain-context latch toggles
            // ($FCE008/A/C/E) and the final setup-OFF ($FCE012) -- SLIM/SORG
            // port writes go through Bus.slimSorgPortAccess, not ioTrace.
            // See rom-trace-notes.md "First I/O touches".
            #expect(!m.bus.ioTrace.isEmpty, "ROM should touch I/O space")

            // (c) The ROM programmed the MMU. The cold-boot MMU register
            // self-test performs exactly 4132 SLIM/SORG port writes across
            // all 128 segments and all 4 domains (rom-trace-notes.md
            // "MMU programming"). Deterministic under Musashi.
            #expect(m.bus.mmuPortWrites == 4132,
                    "cold-boot MMU self-test writes 4132 SLIM/SORG ports")

            // The very first SLIM/SORG port write is domain 0, segment 0,
            // SLIM = $55A (the first walking-pattern of the register test).
            let first = try #require(m.bus.mmuPortLog.first)
            #expect(first.domain == 0)
            #expect(first.segment == 0)
            #expect(first.isSorg == false)
            #expect(first.value == 0x55A)
        }

        /// Documented M1a boundary: after the MMU self-test the ROM programs
        /// the real domain-0 segment map -- seg 0-15 readWrite ($700), seg 126
        /// (iospace) SLIM $900/$901 (access nibble $9), seg 127 (prom) SLIM
        /// $F00 (access nibble $F) -- then drops setup mode at $FE0440
        /// (`clr.b $fce012`). Its next fetch ($FE0446) goes through the MMU as
        /// segment 127, whose access nibble $F the M1a `MMU.translate` does not
        /// decode (it recognizes only $5/$6/$7/$8/$C), so it faults; exception
        /// stacking faults again -> double bus fault -> HALT. Serving prom/io
        /// special space in translated mode (nibbles $F/$9) is the M1b work
        /// this test marks the boundary of. See rom-trace-notes.md
        /// "Where execution stalls".
        @Test
        func romReachesSetupDropBoundaryThenHalts() throws {
            let m = try bootedMachine()
            m.run(until: 2_000_000)

            #expect(m.bus.setupMode == false, "ROM dropped setup mode (clr.b $fce012)")
            #expect(m.bus.domain == 0, "domain 0 active at setup-drop")
            #expect(m.halted == true,
                    "double bus fault at translated-mode ROM fetch; PC=\(String(format: "%08X", m.cpu[.pc])) -- M1b (prom access nibble $F) not yet modeled")
        }
    }
}
