import Testing
@testable import LisaCore

/// CPU-driving end-to-end interrupt delivery test: a tiny hand-assembled
/// 68000 program lowers the SR interrupt mask, programs VIA1's Timer 1 as a
/// one-shot (mirroring the driver-init shape in docs/hardware-notes.md §3
/// "VIA1 Function"/"Driver Initialization Sequence" -- ACR/T1CL/T1CH/IER),
/// installs a level-1 autovector handler ($64, docs/hardware-notes.md §5),
/// and spins. The handler increments D2 and acknowledges by writing IFR1.
/// Once `Machine` ticks VIA1 far enough for T1 to underflow and asserts IRQ
/// level 1, Musashi must autovector into the handler -- see `M68K.setIRQ`'s
/// doc comment for why autovectoring needs no extra wiring here.
///
/// Nested under `MusashiSuites` (builds a `Machine`, hence an `M68K` --
/// Musashi is a process-global singleton).
extension MusashiSuites {
    @Suite struct InterruptTests {
        /// Opcodes below were verified against Musashi's OWN disassembler
        /// (`M68K.disassemble(at:)`) before being committed here, not typed
        /// from memory -- see the task-3 report for the verification
        /// transcript.
        private func loadProgram(_ m: Machine) {
            m.bus.write32(0x0, 0x3000)     // initial SSP
            m.bus.write32(0x4, 0x400)      // initial PC
            // Level-1 autovector handler lives at vector 25 ($64 = 25*4).
            m.bus.write32(0x64, 0x500)

            m.bus.load([
                0x46, 0xFC, 0x20, 0x00,                              // MOVE.W #$2000,SR       (mask=0: accept level 1+)
                0x13, 0xFC, 0x00, 0x00, 0x00, 0xFC, 0xD9, 0x59,      // MOVE.B #$00,$FCD959.L  (ACR1: one-shot)
                0x13, 0xFC, 0x00, 0xC0, 0x00, 0xFC, 0xD9, 0x71,      // MOVE.B #$C0,$FCD971.L  (IER1: set bit6, enable T1)
                0x13, 0xFC, 0x00, 0x05, 0x00, 0xFC, 0xD9, 0x31,      // MOVE.B #$05,$FCD931.L  (T1L-L1 latch = 5)
                0x13, 0xFC, 0x00, 0x00, 0x00, 0xFC, 0xD9, 0x29,      // MOVE.B #$00,$FCD929.L  (T1C-H1: load+arm+start, period 6)
                0x60, 0xFE,                                          // spin: BRA.s spin
            ], at: 0x400)

            m.bus.load([
                0x52, 0x82,                                          // ADDQ.L #1,D2
                0x13, 0xFC, 0x00, 0x40, 0x00, 0xFC, 0xD9, 0x69,      // MOVE.B #$40,$FCD969.L  (IFR1: clear T1 flag -- acknowledge)
                0x4E, 0x73,                                          // RTE
            ], at: 0x500)

            m.reset()
            // Musashi's data/address registers are NOT cleared by a real
            // 68000 reset (only SSP/PC/SR come from the vectors) -- and
            // since Musashi is a process-global singleton core (see
            // `M68K`'s header comment), D2 can carry a stale value left by
            // a PREVIOUS test's `Machine`/`M68K` instance within the same
            // test process. Zero it explicitly rather than assuming `reset`
            // did.
            m.cpu[.d2] = 0
        }

        @Test
        func viaTimerInterruptRunsLevel1AutovectorHandler() {
            let m = Machine(ramSize: 0x10000)
            loadProgram(m)

            #expect(m.cpu[.d2] == 0)

            // `step()` ticks VIA1 and recomputes the CPU's IRQ level after
            // every single instruction (exact, unlike run(until:)'s bounded
            // quantum -- see Machine.irqPollQuantum's doc comment), so this
            // loop is deterministic: once T1 underflows and IER1 has T1
            // enabled, the very next instruction boundary takes the
            // interrupt.
            var steps = 0
            while m.cpu[.d2] == 0 && steps < 100 {
                m.step()
                steps += 1
            }

            #expect(m.cpu[.d2] == 1, "level-1 autovector handler should have run exactly once")
            #expect(m.halted == false)

            // The handler acknowledged by writing IFR1 (clearing T1's
            // flag), and T1 is one-shot (disarmed after firing), so no
            // second interrupt should occur even after many more steps.
            for _ in 0..<200 { m.step() }
            #expect(m.cpu[.d2] == 1, "one-shot T1 must not refire after acknowledge")
        }

        @Test
        func viaTimerInterruptIsBlockedWhileSRMaskIsHigh() {
            // Sanity check on the other side of the mask: if the program
            // never lowers SR's interrupt mask (reset leaves it at 7, per
            // m68kcpu.c's m68k_pulse_reset), VIA1's IRQ level 1 must never
            // be taken, no matter how long T1 free-runs. Confirms the test
            // above is actually exercising interrupt *delivery*, not some
            // other path to D2 incrementing.
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000)
            m.bus.write32(0x4, 0x400)
            m.bus.write32(0x64, 0x500)
            m.bus.load([
                // (no SR write -- mask stays at 7 from reset)
                0x13, 0xFC, 0x00, 0x40, 0x00, 0xFC, 0xD9, 0x59,      // MOVE.B #$40,$FCD959.L  (ACR1: free-run)
                0x13, 0xFC, 0x00, 0xC0, 0x00, 0xFC, 0xD9, 0x71,      // MOVE.B #$C0,$FCD971.L  (IER1: enable T1)
                0x13, 0xFC, 0x00, 0x05, 0x00, 0xFC, 0xD9, 0x31,      // MOVE.B #$05,$FCD931.L  (T1L-L1 = 5)
                0x13, 0xFC, 0x00, 0x00, 0x00, 0xFC, 0xD9, 0x29,      // MOVE.B #$00,$FCD929.L  (T1C-H1: load+arm)
                0x60, 0xFE,                                          // spin: BRA.s spin
            ], at: 0x400)
            m.bus.load([0x52, 0x82, 0x4E, 0x73], at: 0x500)   // ADDQ.L #1,D2 ; RTE (unreachable)
            m.reset()
            m.cpu[.d2] = 0   // see the doc comment on the same line in loadProgram above

            for _ in 0..<500 { m.step() }

            #expect(m.cpu[.d2] == 0, "mask=7 must block a level-1 interrupt regardless of VIA1 state")
            #expect(m.bus.via1.irqAsserted == true, "VIA1 itself should still be asserting -- the CPU is what's blocking it")
        }
    }
}
