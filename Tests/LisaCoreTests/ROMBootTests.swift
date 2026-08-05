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

        /// Steps the ROM to the exact setup-drop instant (`clr.b $fce012` at
        /// `$FE0440`) rather than a fixed cycle budget. This is a
        /// deterministic ROM-defined milestone (~75,000 instructions --
        /// rom-trace-notes.md "Summary") that used to coincide with the M1a
        /// halt; now that M1b Task 1 dissolved that boundary, execution
        /// continues past it and does MORE MMU programming later in the boot
        /// (Task 2+ territory -- see `romRunsPastTheFormerHaltBoundary`
        /// below), so a blind `run(until: 2_000_000)` no longer lands on a
        /// stable mmuPortWrites count the way it did at M1a. Stepping to
        /// setup-drop itself keeps this assertion exact regardless of what
        /// later tasks unlock beyond it.
        @Test
        func romTouchesIOAndProgramsMMU() throws {
            let m = try bootedMachine()
            while m.bus.setupMode && !m.halted {
                _ = m.step()
            }

            // (b) The ROM touched I/O space by setup-drop. The only
            // IODispatcher-visible touches up to this point are the
            // domain-context latch toggles ($FCE008/A/C/E) and the final
            // setup-OFF ($FCE012) -- SLIM/SORG port writes go through
            // Bus.slimSorgPortAccess, not ioTrace. See rom-trace-notes.md
            // "First I/O touches".
            #expect(!m.bus.ioTrace.isEmpty, "ROM should touch I/O space")

            // (c) The ROM programmed the MMU. The cold-boot MMU register
            // self-test plus domain-0 real map programming performs exactly
            // 4132 SLIM/SORG port writes across all 128 segments and all 4
            // domains by the moment setup drops (rom-trace-notes.md "MMU
            // programming"). Deterministic under Musashi.
            #expect(m.bus.mmuPortWrites == 4132,
                    "cold-boot MMU self-test writes 4132 SLIM/SORG ports by setup-drop")

            // The very first SLIM/SORG port write is domain 0, segment 0,
            // SLIM = $55A (the first walking-pattern of the register test).
            let first = try #require(m.bus.mmuPortLog.first)
            #expect(first.domain == 0)
            #expect(first.segment == 0)
            #expect(first.isSorg == false)
            #expect(first.value == 0x55A)
        }

        /// The M1a halt boundary, DISSOLVED: after the MMU self-test the ROM
        /// programs the real domain-0 segment map -- seg 0-15 readWrite
        /// ($700), seg 126 (iospace) SLIM $900/$901 (access nibble $9), seg
        /// 127 (prom) SLIM $F00 (access nibble $F) -- then drops setup mode
        /// at $FE0440 (`clr.b $fce012`). Its next fetch ($FE0446) goes
        /// through the MMU as segment 127; under M1a, `MMU.translate` didn't
        /// decode access nibble $F, so this faulted, exception stacking
        /// faulted again, and `Bus.forceHaltHandler` fired (double bus
        /// fault). As of M1b Task 1, `MMU.translate` decodes nibble $F as
        /// `.special` (and $9 as `.io`) -- see docs/rom-trace-notes.md OQ2
        /// -- so that fetch now succeeds and the ROM keeps running.
        ///
        /// Trace checkpoint A (Task 2) mapped the post-boundary territory
        /// fully -- see docs/rom-trace-notes.md "Beyond the M1a boundary".
        /// The observed PC frontier (via `g` in lisadbg): $FE0F00 at 2M
        /// (RAM-fill loop), $FE35FE at 5M (delay loop), then by ~5.5M cycles
        /// the ROM enters the VIA2 register self-test retry loop at $FE08B0
        /// and STALLS there indefinitely -- 10M/20M/30M/60M all sample PC in
        /// the $FE07B8-$FE08D2 loop, still setup=OFF / domain=0 / NOT halted.
        ///
        /// The stall is a live busy-loop, not a fault/halt: $FE07B8 is a
        /// read/write presence test on VIA2 registers $FCDD8D/$FCDD8F (base
        /// $DD81, stride 2), which the current stub leaves as unknown IOSpace
        /// (0xFF reads, dropped writes), so the test never passes and the ROM
        /// retries forever (D7 sign bit keeps `bmi $fe08b0` taken). Making
        /// VIA2 a real read/write register file at base $DD81 is Task 3 (VIA
        /// core) -- confirmed empirically: pointing the stub at the ROM's
        /// bases lets the ROM advance to $FE099A.
        ///
        /// This assertion is deliberately LOOSE: it pins that the CPU is
        /// alive, past the old boundary, and parked in the documented VIA2
        /// self-test loop -- not exact cycle-for-cycle behavior. 10M cycles
        /// is safely inside the stall.
        @Test
        func romRunsPastBoundaryAndStallsOnVIA2SelfTest() throws {
            let m = try bootedMachine()
            m.run(until: 10_000_000)

            #expect(m.bus.setupMode == false, "ROM dropped setup mode (clr.b $fce012)")
            #expect(m.bus.domain == 0, "domain 0 still active")
            #expect(m.halted == false,
                    "post-boundary the ROM busy-loops on the VIA2 self-test, it does not halt/fault; PC=\(String(format: "%08X", m.cpu[.pc]))")
            // Parked in the VIA2 register self-test retry loop
            // ($FE07B8 test body + $FE08B0-$FE08D2 retry) -- rom-trace-notes.md
            // "The hard stall".
            let pc = m.cpu[.pc]
            #expect((0x00FE_07B8...0x00FE_08D2).contains(pc),
                    "PC should be in the documented VIA2 self-test loop; got \(String(format: "%08X", pc))")
        }
    }
}
