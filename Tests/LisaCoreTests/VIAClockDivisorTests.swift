import Testing
@testable import LisaCore

// Regression test for the keyboard-duplication bug (branch (b) of the
// discriminating experiment: hold-time-dependent duplicates from the OS's
// auto-repeat firing too early).
//
// ROOT CAUSE, cited: the 6522 VIAs are clocked at phi2 = CPU/4 on the Pepsi
// board this emulator models. The OS loads VIA1 T1 with $637B = 25467
// (LIBHW-DRIVERS:587-588) SPECIFICALLY so that count == 20 ms of real time,
// and its Timer1 handler adds 20 to the millisecond clock `TimerTicks` per T1
// IRQ (LIBHW-DRIVERS:974/987). Ticking the VIAs at CPU/1 (the pre-fix model)
// made T1 fire every ~5.09 ms instead of 20 ms, so `TimerTicks` advanced
// ~3.93x too fast and the keyboard auto-repeat's 400 ms `RepeatInitial` delay
// (LIBHW-DRIVERS:543) elapsed after only ~102 ms of real key-hold -- inside a
// normal human keypress -- duplicating the typed key.
//
// This measures VIA1 T1's IRQ period IN CPU CYCLES through a real `Machine`,
// with T1 programmed exactly as the OS does (ACR1=$48 free-run, latch $637B),
// and pins it to the ~20 ms the OS intends -- NOT the ~5 ms the pre-fix model
// produced. Lives in `MusashiSuites` because it drives the process-global
// Musashi CPU core (see MusashiSerialized.swift / InterruptTests.swift).

extension MusashiSuites {
    @Suite struct VIAClockDivisorTests {
        @Test
        func via1T1FreeRunFiresAtOSIntended20msNotCPU1to1() {
            let m = Machine(ramSize: 0x10000)

            // Reset vectors + a level-1 handler that counts IRQs into D2 and
            // acknowledges by clearing T1's IFR bit (so free-run T1 keeps
            // delivering). Vector 25 ($64) = level-1 autovector.
            m.bus.write32(0x0, 0x3000)     // initial SSP
            m.bus.write32(0x4, 0x400)      // initial PC
            m.bus.write32(0x64, 0x500)     // level-1 autovector handler

            m.bus.load([
                0x46, 0xFC, 0x20, 0x00,                              // MOVE.W #$2000,SR      (mask=0: accept level 1+)
                0x13, 0xFC, 0x00, 0x48, 0x00, 0xFC, 0xD9, 0x59,      // MOVE.B #$48,$FCD959.L (ACR1: T1 free-run)
                0x13, 0xFC, 0x00, 0xC0, 0x00, 0xFC, 0xD9, 0x71,      // MOVE.B #$C0,$FCD971.L (IER1: enable T1)
                0x13, 0xFC, 0x00, 0x7B, 0x00, 0xFC, 0xD9, 0x31,      // MOVE.B #$7B,$FCD931.L (T1L-L1 = $7B)
                0x13, 0xFC, 0x00, 0x63, 0x00, 0xFC, 0xD9, 0x29,      // MOVE.B #$63,$FCD929.L (T1C-H1 = $63 -> $637B, load+arm)
                0x60, 0xFE,                                          // spin: BRA.s spin
            ], at: 0x400)

            m.bus.load([
                0x52, 0x82,                                          // ADDQ.L #1,D2
                0x13, 0xFC, 0x00, 0x40, 0x00, 0xFC, 0xD9, 0x69,      // MOVE.B #$40,$FCD969.L (IFR1: clear T1 flag)
                0x4E, 0x73,                                          // RTE
            ], at: 0x500)

            m.reset()
            m.cpu[.d2] = 0   // Musashi is a global singleton; zero stale D2

            // Run a fixed CPU-cycle budget and count how many T1 IRQs fired.
            let budget: UInt64 = 1_000_000
            m.run(until: budget)

            let irqCount = m.cpu[.d2]
            #expect(irqCount > 0, "T1 free-run must deliver at least one IRQ in \(budget) cycles")
            let cyclesPerIRQ = Double(budget) / Double(irqCount)
            let msPerIRQ = cyclesPerIRQ / 5_000_000.0 * 1000.0

            // OS intends 20 ms per T1 IRQ (= $637B VIA-clocks at CPU/4 =
            // ~101,872 CPU cycles). The pre-fix CPU/1 model produced ~5.09 ms
            // (~25,468 cycles). Assert we are in the 20 ms regime, comfortably
            // separated from the 5 ms one. Tolerance covers run(until:)'s
            // coarse (quantum-bounded) IRQ latency and the 5.0-vs-5.093 MHz
            // approximation.
            let detail = "VIA1 T1 should fire ~20ms apart (OS intent); got \(msPerIRQ)ms (\(cyclesPerIRQ) cycles). ~5ms would mean the VIAs are still ticked at CPU/1 -> keyboard auto-repeat duplicates."
            #expect(msPerIRQ > 15.0 && msPerIRQ < 25.0, "\(detail)")
        }
    }
}
