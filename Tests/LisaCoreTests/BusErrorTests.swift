import Testing
@testable import LisaCore

extension MusashiSuites {
    @Suite struct BusErrorTests {
        @Test func mmuFaultRaisesRealBusErrorException() {
            let machine = Machine(ramSize: 0x10000)
            machine.bus._setSetupModeForTesting(false)
            // Domain 0, segment 0 (logical 0x0...0x1FFFF): vectors + code,
            // mapped identity read/write. Segment 1 (logical 0x2_0000...) is
            // left absent (the default slim 0 -> absent nibble), so the
            // absolute-long read at $20000 below takes a real MMU fault.
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)

            machine.bus.write32(0x0, 0x3000)   // initial SSP
            machine.bus.write32(0x4, 0x400)    // initial PC
            machine.bus.write32(0x8, 0x500)    // bus-error vector ($8) -> handler

            // Handler: MOVEQ #99,D1 ; BRA * (spin)
            machine.bus.load([0x72, 0x63, 0x60, 0xFE], at: 0x500)

            // Program: MOVE.B $20000,D0 (absolute-long read of absent segment 1)
            // then NOP.
            machine.bus.load([0x10, 0x39, 0x00, 0x02, 0x00, 0x00, 0x4E, 0x71], at: 0x400)

            machine.reset()
            machine.run(until: 500)

            #expect(machine.cpu[.d1] == 99)
            #expect(machine.bus.lastFault?.reason == .invalidSegment)
        }

        @Test func doubleBusFaultDuringExceptionStackingHalts() {
            // Same fault as above (absolute-long read of an absent segment
            // 1), but the supervisor stack pointer itself points into a
            // second absent segment. When the MOVE.B fault pulses a bus
            // error, Musashi tries to push the exception stack frame
            // through that unmapped SSP -- a fault while stacking a fault
            // is a genuine 68000 *double* bus fault. Real hardware halts
            // rather than taking yet another exception; Bus's
            // consecutive-fault tracking must reproduce that (via
            // forceHaltHandler) instead of pulsing Musashi a second time,
            // which would recurse into `m68ki_exception_bus_error`'s
            // "already stacking" branch -- itself a live bus access
            // (`m68k_read_memory_8(0x00ffff01)`) performed *before*
            // `CPU_STOPPED` is set, so an unguarded second pulse recurses
            // without a base case and crashes the process (SIGBUS/stack
            // overflow), not merely fails an assertion.
            let machine = Machine(ramSize: 0x10000)
            machine.bus._setSetupModeForTesting(false)
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)
            // Segment 1 (0x2_0000...) and segment 2 (0x4_0000...) are both
            // left absent (the default): segment 1 is the program's
            // faulting read target, segment 2 is where the (unmapped)
            // supervisor stack lives.

            machine.bus.write32(0x0, 0x40000)  // initial SSP -- unmapped (segment 2)
            machine.bus.write32(0x4, 0x400)    // initial PC

            // Program: MOVE.B $20000,D0 (absolute-long read of absent segment 1)
            // then NOP.
            machine.bus.load([0x10, 0x39, 0x00, 0x02, 0x00, 0x00, 0x4E, 0x71], at: 0x400)

            machine.reset()
            machine.run(until: 500)   // must return promptly -- no crash, no hang

            #expect(machine.halted == true)
            #expect(machine.cpu.isHalted == true)
        }
    }
}
