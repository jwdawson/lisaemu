import Testing
@testable import LisaCore

extension MusashiSuites {
    @Suite struct BusErrorTests {
        @Test func mmuFaultRaisesRealBusErrorException() {
            let machine = Machine(ramSize: 0x10000)
            machine.bus.setupMode = false
            // Domain 0, segment 0 (logical 0x0...0x1FFFF): vectors + code,
            // mapped identity read/write. Segment 1 (logical 0x2_0000...) is
            // left .invalid (the default), so the absolute-long read at
            // $20000 below takes a real MMU fault.
            machine.bus.mmu.domains[0][0] = SegmentRegister(origin: 0, limitBytes: 0x10000, access: .readWrite)

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
    }
}
