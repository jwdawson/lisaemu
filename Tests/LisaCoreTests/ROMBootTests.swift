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
        /// The observed PC frontier (via `g` in lisadbg) up to M1b Task 3:
        /// $FE0F00 at 2M (RAM-fill loop), $FE35FE at 5M (delay loop), then
        /// by ~5.5M cycles the ROM entered the VIA2 register self-test
        /// retry loop at $FE08B0 and stalled there indefinitely (this was
        /// the M1b Task 2 frontier, with a dumb VIA read-back stub at the
        /// WRONG bases $D801/$DC01).
        ///
        /// **M1b Task 3** replaced that stub with a real `VIA6522` at the
        /// ROM-observed bases ($D901/$DD81, docs/hardware-notes.md §3) --
        /// T1 latch read-back now genuinely works, so the self-test passes
        /// and the ROM advances. The NEW frontier (task-3-report.md has the
        /// full trace): by 10M cycles the ROM is well past $FE08B0, has run
        /// the VIA1/VIA2 driver-init sequences ($FE0920-$FE093E: ACR2=$01,
        /// PCR2|=$09, IER2=$7F clear-all, IFR2=$7F clear-all -- matching
        /// hardware-notes.md §3's "Driver Initialization Sequence"), and is
        /// parked in the COPS presence/handshake poll (hardware-notes.md
        /// §4 "Command Protocol" step 2, "Poll CRDY"): `btst
        /// D4,(A1)`/`bne` at $FE0980/$FE0982, testing VIA2 PORTB2
        /// ($FCDD81) bit 6 with a ~0x61A-iteration bounded timeout per
        /// attempt ($FE097C-$FE097E), retried indefinitely from an outer
        /// caller since no COPS chip is modeled yet (VIA2's `portBInput`
        /// defaults to a constant all-ones, so CRDY never toggles). This is
        /// deterministic and stable at 10M cycles (confirmed by direct
        /// `lisadbg g 10000000` and by re-sampling every 30M cycles out to
        /// 300M -- PC never leaves this 4-instruction poll body). Exactly
        /// the COPS/VIA2-Port-A dependency the M1b Task 2 wait-target table
        /// predicted for Task 4 ("Task 4's requirements must come from a
        /// post-Task-3 re-trace").
        ///
        /// This assertion is deliberately LOOSE: it pins that the CPU is
        /// alive, past the VIA2 self-test, and parked at the COPS poll --
        /// not exact cycle-for-cycle behavior. 10M cycles is safely inside
        /// that stall (task-3-report.md's frontier, superseded below).
        @Test
        func romClearsVIA2SelfTestAndReachesCOPSPresencePoll() throws {
            let m = try bootedMachine()
            m.run(until: 10_000_000)

            #expect(m.bus.setupMode == false, "ROM dropped setup mode (clr.b $fce012)")
            #expect(m.bus.domain == 0, "domain 0 still active")
            #expect(m.halted == false,
                    "post-boundary the ROM busy-loops on the COPS presence poll, it does not halt/fault; PC=\(String(format: "%08X", m.cpu[.pc]))")
            // Parked in the pre-Task-4-COPS-device era of the COPS CRDY poll
            // loop ($FE097C-$FE0982), or already just past it (the two live
            // side-by-side in ROM: `$FE0AE2` is the very next block, a
            // long-running contrast-DAC calibration delay some boot paths
            // hit around here too) -- task-3-report.md "New ROM frontier".
            let pc = m.cpu[.pc]
            #expect((0x00FE_0920...0x00FE_0AE6).contains(pc),
                    "PC should be in the documented COPS presence-poll/post-poll region; got \(String(format: "%08X", pc))")
        }

        /// **M1b Task 4** (task-4-report.md has the full trace) added a real
        /// `COPS` HLE endpoint behind VIA2 -- CRDY (corrected to PORTB2 bit
        /// 6, refuting hardware-notes.md §4's Port-A claim -- see that
        /// file's "COPS" section), the command handshake, and an input FIFO
        /// delivering the power-on reset packet. That clears the
        /// `$FE0920-$FE09B2` presence-poll stall entirely: the ROM now runs
        /// the VIA2 driver-init, the pre-Pepsi contrast-DAC calibration
        /// delay (`$FE0AE2`, ~5-9M cycles), the COPS presence probe (4
        /// commands: `$00,$70,$50,$60`), consumes the full power-on packet
        /// (`$80` + keyboard-ID + 5 trailing bytes) via the driver's bounded
        /// and unbounded receive routines, and reaches a NEW stable stall by
        /// ~18M cycles at `$FE2DCE` (`beq $fe2dc6`, inside
        /// `$FE2DBE-$FE2DD6`): an UNCONDITIONAL (no-timeout) poll of VIA2
        /// IFR2 bit 1 waiting for the CPU's *next* COPS input byte -- one
        /// this task's COPS model has nothing further queued to deliver
        /// (task-4-report.md "New ROM frontier" has the full call chain:
        /// `$FE2624` (sets flag `$2A2` bit 5) -> `$FE2C46` -> `$FE2D38` ->
        /// `$FE2DBE`). Confirmed stable by direct `lisadbg g` sampling from
        /// 18M through 150M cycles -- PC never leaves this 4-instruction
        /// poll body. 20M cycles is safely inside the new stall.
        ///
        /// **M1b Task 5** (docs/rom-trace-notes.md "Trace checkpoint B")
        /// re-traced this frontier with `VideoTiming` (vsync/`$F801` bit 2/
        /// `$E018`/`$E01A`) live and confirmed it is UNCHANGED: resampled
        /// stable from 20M through 220M cycles.
        ///
        /// **M1b Task 7** (docs/rom-trace-notes.md "POST completion (Task 7)")
        /// finally identified what this `$FE2DBE` poll IS: not a POST blocker
        /// at all, but the boot MENU's "await the next COPS input event"
        /// (mouse-move / keypress) idle loop. By the time the ROM reaches it,
        /// POST has completed and the standard startup menu (RESTART /
        /// CONTINUE / STARTUP FROM..., plus a no-boot-device error icon) is
        /// fully drawn -- see `romCompletesPOSTAndReachesBootMenu` below,
        /// which asserts the framebuffer. `$FE2DBE-$FE2DD6` is the mouse
        /// cursor-tracking loop `$FE2C46`'s per-packet receive
        /// (`bsr $fe2dbe` -> read VIA2 IFR2 bit 1 -> read PORTA2), reached
        /// from `$FE2624`; with no user at the keyboard/mouse it legitimately
        /// waits forever, which is the correct terminal state for a menu.
        /// This test keeps the loose "parked in the poll body, not halted"
        /// characterization; the menu assertions are in the dedicated test.
        @Test
        func romClearsCOPSPresencePollAndReachesBootMenuInputLoop() throws {
            let m = try bootedMachine()
            m.run(until: 20_000_000)

            #expect(m.bus.setupMode == false, "ROM dropped setup mode (clr.b $fce012)")
            #expect(m.bus.domain == 0, "domain 0 still active")
            #expect(m.halted == false,
                    "at the boot menu the ROM busy-loops awaiting the next COPS input event, it does not halt/fault; PC=\(String(format: "%08X", m.cpu[.pc]))")
            // Parked in the boot-menu input-idle poll ($FE2DBE-$FE2DD6) --
            // docs/rom-trace-notes.md "POST completion (Task 7)".
            let pc = m.cpu[.pc]
            #expect((0x00FE_2DBE...0x00FE_2DD6).contains(pc),
                    "PC should be in the documented boot-menu input-wait region; got \(String(format: "%08X", pc))")
        }

        /// **M1b Task 6** (task-6-report.md / docs/rom-trace-notes.md "Bus-error
        /// frame spike") instrumented `Bus.busErrorPulseCount` and ran the
        /// boot 10M cycles past the `$FE2DBE` frontier (30M total). The count
        /// stays 0 the entire way: every device-presence probe actually
        /// exercised on this path (VIA2, COPS/VIA2, the `$D241` candidate
        /// SCC) targets IOSpace addresses `IODispatcher` serves with a
        /// benign stub rather than an MMU segment fault, and the ROM's
        /// statically-present RAM-sizing routine (`$FE0D68-$FE0FCC`) scores
        /// zero PC hits in a separate unbounded reachability check (fix
        /// round 1 correction -- its live status is unconfirmed, not a
        /// confirmed non-faulting ID-register read as an earlier draft of
        /// this comment claimed; either way it's not a source of bus
        /// errors). This is the empirical half of the spike's evidence for
        /// deferring the Musashi 68010-format bus-error-frame fix
        /// (`m68ki_exception_bus_error` hardcoding a 29-word format-8 frame
        /// with fault address 0 instead of the real 68000 7-word group-0
        /// frame) to M2 -- see task-6-report.md for the static disassembly
        /// evidence (the ROM's 20 vector-`$8` handler installs/restores
        /// never RTE; they either fall into a shared mark-failure-and-continue
        /// dispatcher or get wholesale-discarded via a saved/restored A7, so
        /// the frame's exact shape/fault-address content is unread either
        /// way).
        @Test
        func romTakesNoBusErrorThroughTheFrontier() throws {
            let m = try bootedMachine()
            m.run(until: 30_000_000)

            #expect(m.halted == false, "still no halt/fault at 30M cycles")
            #expect(m.bus.busErrorPulseCount == 0,
                    "no recoverable-or-otherwise bus error should occur on the boot path through the $FE2DBE frontier")
        }

        /// 64-bit FNV-1a over the framebuffer bytes -- a compact,
        /// dependency-free content fingerprint (no CryptoKit in this target).
        private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
            return h
        }

        /// **M1b exit criterion (Task 7): POST completes and the ROM draws
        /// the startup/boot-device MENU.** After the checksum/MMU/RAM/VIA/COPS
        /// power-on sequence the ROM renders the classic Lisa boot menu --
        /// RESTART / CONTINUE / STARTUP FROM... buttons, a mouse cursor, the
        /// "H" ROM-revision marker, and (because no floppy/hard-disk hardware
        /// is modeled) a crossed-out ProFile icon with error code 42 -- then
        /// enters its "await next COPS input event" idle loop at
        /// `$FE2DBE-$FE2DD6` (see `romClearsCOPSPresencePollAndReachesBoot
        /// MenuInputLoop`). This is exactly the brief's accepted success
        /// state ("startup/boot-device UI or an error screen -- EITHER is M1b
        /// success"); here we get BOTH the menu and the no-boot-device error
        /// indicator. Full path documented in docs/rom-trace-notes.md "POST
        /// completion (Task 7)"; screenshot reproduce steps in docs/m1b-demo.md.
        ///
        /// Cycle budget: the menu is fully drawn and the input-idle loop is
        /// entered by ~18M cycles; the framebuffer content is then bit-stable
        /// (identical FNV hash) through at least 60M cycles (verified during
        /// Task 7). 25M is a comfortable, deterministic sampling point inside
        /// that stable window. The content is independent of the host wall
        /// clock (the boot menu shows no time-of-day; verified reproducible
        /// across processes at different times) -- so the exact hash below is
        /// a legitimate deterministic anchor, NOT a wall-clock artifact.
        @Test
        func romCompletesPOSTAndReachesBootMenu() throws {
            let m = try bootedMachine()
            m.run(until: 25_000_000)

            // POST-complete markers (rom-trace-notes.md "POST completion"):
            // setup dropped, domain 0, alive, and parked in the boot-menu
            // input-idle loop -- NOT halted, NOT faulted.
            #expect(m.bus.setupMode == false, "ROM dropped setup mode")
            #expect(m.bus.domain == 0, "domain 0 active")
            #expect(m.halted == false, "menu input-idle loop is live, not halted")
            #expect(m.bus.busErrorPulseCount == 0, "no bus error on the path to the menu")
            let pc = m.cpu[.pc]
            #expect((0x00FE_2DBE...0x00FE_2DD6).contains(pc),
                    "parked in the boot-menu input-wait poll; got \(String(format: "%08X", pc))")

            // Framebuffer: non-blank, with a stable exact content hash AND a
            // robust weaker invariant (>1% black). The menu occupies ~29.8%
            // of the 720x364 1bpp framebuffer (78,100 of 262,080 pixels set).
            let fb = m.bus.framebufferSnapshot()
            #expect(fb.count == Bus.framebufferByteCount)
            var blackPixels = 0
            for b in fb { blackPixels += b.nonzeroBitCount }
            let totalPixels = fb.count * 8

            // Robust weaker invariant (survives future timing/rendering
            // tweaks): the menu is unmistakably drawn, far above blank.
            #expect(Double(blackPixels) / Double(totalPixels) > 0.01,
                    ">1% of pixels are set; got \(blackPixels)/\(totalPixels)")

            // Exact anchors (BRITTLE across future timing/rendering changes,
            // per the brief -- update alongside rom-trace-notes.md if the
            // documented boot path legitimately changes):
            #expect(blackPixels == 78_100,
                    "exact set-pixel count for the drawn boot menu; got \(blackPixels)")
            #expect(fnv1a(fb) == 0xd092_34d2_5516_d0b8,
                    "stable boot-menu framebuffer fingerprint; got \(String(format: "%016llx", fnv1a(fb)))")
        }
    }
}
