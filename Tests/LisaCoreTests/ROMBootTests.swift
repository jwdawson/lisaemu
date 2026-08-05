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
        /// Running the SAME 2,000,000-cycle budget the old halt-boundary
        /// test used, the real Rev H ROM is observed (via `t`/`g` trace,
        /// `swift run lisadbg --rom $LISAEMU_ROM_DIR`, then `g 2000000`) to
        /// reach PC=$FE0F00 (`move.l D1,(A0)+`) with mmuPortWrites=4384 (up
        /// from 4132 at setup-drop -- 252 MORE SLIM/SORG writes happen past
        /// the old boundary, unexplored territory), still setup=OFF /
        /// domain=0, NOT halted -- having also touched VIA-shaped I/O
        /// offsets ($D241, $D931/$D939) and the video page latch ($E800)
        /// that the M1a trace never reached. Continuing further (checked to
        /// 2.5M cycles during investigation) keeps making forward progress
        /// (PC reaches $FE3154), i.e. this is not a new stall either.
        ///
        /// This assertion is deliberately LOOSE: Task 2 ("Trace checkpoint
        /// A") is the one that documents this new post-boundary territory
        /// fully in rom-trace-notes.md. This test only pins down that the
        /// CPU is alive and past the old boundary, not what it's doing
        /// there.
        @Test
        func romRunsPastTheFormerHaltBoundary() throws {
            let m = try bootedMachine()
            m.run(until: 2_000_000)

            #expect(m.bus.setupMode == false, "ROM dropped setup mode (clr.b $fce012)")
            #expect(m.bus.domain == 0, "domain 0 still active at 2M cycles")
            #expect(m.halted == false,
                    "M1b Task 1: translated-mode prom fetch ($FE0446, nibble $F) now decodes via .special instead of double-bus-faulting; PC=\(String(format: "%08X", m.cpu[.pc])) at 2M cycles (was garbage post-halt PC under M1a)")
        }
    }
}
