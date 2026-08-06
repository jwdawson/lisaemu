import Testing
@testable import LisaCore

extension MusashiSuites {
    /// Round-trip test for the real 68000 group-0 bus-error frame (M2 Task
    /// 1). `BusErrorTests.mmuFaultRaisesRealBusErrorException` never unwinds
    /// the pushed frame (its handler just spins); this suite is the first
    /// to actually read it and RTE back out, which is the exact shape the
    /// eventual OS loader's own bus-error handling will use.
    ///
    /// Frame layout consulted (Sources/CMusashi/m68kcpu.h's
    /// `m68ki_stack_frame_buserr`, ~line 1681 -- push order top-to-bottom,
    /// which becomes low-to-high stack offsets since each push predecrements
    /// SP):
    ///   push32(REG_PC)                                  -> ends at SP+10..13
    ///   push16(sr)                                       -> ends at SP+8..9
    ///   push16(REG_IR)                                   -> ends at SP+6..7
    ///   push32(m68ki_aerr_address)   /* fault address */ -> ends at SP+2..5
    ///   push16(write_mode|instr_mode|fc) /* status word*/-> ends at SP+0..1
    /// i.e. after the exception, SP+0/1 = function-code/status word,
    /// SP+2..5 = fault address, SP+6/7 = IR, SP+8/9 = SR, SP+10..13 = PC.
    /// This is the "SP+2..5" the task brief specifies.
    ///
    /// Critically, `m68k_op_rte_32`'s 68000 branch (m68kops.c, guarded by
    /// `CPU_TYPE_IS_000`) pops ONLY a plain 6-byte SR+PC frame -- the 68000
    /// has no format word and RTE does not know the frame it's unwinding was
    /// 7 words, not the usual 2. So real 68000 bus-error handlers (and this
    /// hand-assembled one) must manually strip the extra 8 bytes (status
    /// word + fault address + IR) with `ADDQ.L #8,A7` before executing RTE,
    /// leaving a plain SR/PC frame for RTE to consume.
    @Suite struct BusErrorFrameTests {
        @Test func rteRoundTripReadsFaultAddressAndResumesAtSuccessor() {
            let machine = Machine(ramSize: 0x10000)
            // Domain 0, segment 0 (logical 0x0...0x1FFFF) mapped identity
            // read/write -- vectors, code, handler, and the captured-address
            // cell all live here. Segment 1 (logical 0x2_0000...) is left
            // absent, so the absolute-long read below takes a real MMU
            // fault, exactly like BusErrorTests' existing fault setup.
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)

            let initialSSP: UInt32 = 0x3000
            machine.bus.write32(0x0, initialSSP)  // initial SSP
            machine.bus.write32(0x4, 0x400)       // initial PC
            machine.bus.write32(0x8, 0x600)       // bus-error vector ($8) -> handler

            // Program at $400: MOVE.B $20000,D0 (absolute-long read of the
            // absent segment 1 -- faults), then MOVEQ #1,D3 (successor --
            // proves RTE resumed at the right PC), then BRA * (spin).
            // Same MOVE.B encoding BusErrorTests already uses/verifies.
            machine.bus.load(
                [
                    0x10, 0x39, 0x00, 0x02, 0x00, 0x00,  // MOVE.B $20000,D0
                    0x76, 0x01,                          // MOVEQ #1,D3
                    0x60, 0xFE,                          // BRA * (spin)
                ],
                at: 0x400
            )

            // Handler at $600:
            //   MOVE.L 2(A7),D0     -- D0 = fault address (frame SP+2..5)
            //   MOVE.L D0,$900.L    -- stash it in a known RAM cell
            //   ADDQ.L #8,A7        -- strip status word + address + IR
            //   RTE
            machine.bus.load(
                [
                    0x20, 0x2F, 0x00, 0x02,              // MOVE.L 2(A7),D0
                    0x23, 0xC0, 0x00, 0x00, 0x09, 0x00,  // MOVE.L D0,$900.L
                    0x50, 0x8F,                          // ADDQ.L #8,A7
                    0x4E, 0x73,                           // RTE
                ],
                at: 0x600
            )

            // machine.reset() (M2 Task 2: a true hardware warm reset) itself
            // re-asserts the SETUP flip-flop -- exactly like real hardware
            // always starts a reset in flat/setup mode. Dropping setup mode
            // (to reach the MMU-translated fault path this test exercises)
            // must happen AFTER reset, not before, mirroring how the real
            // ROM only drops setup once its own boot code chooses to.
            machine.reset()
            machine.bus._setSetupModeForTesting(false)
            machine.run(until: 500)

            #expect(machine.bus.lastFault?.reason == .invalidSegment)
            #expect(machine.halted == false)
            // Handler ran and correctly extracted the fault address.
            #expect(machine.bus.read32(0x900) == 0x0002_0000)
            // RTE resumed execution cleanly at the successor instruction.
            #expect(machine.cpu[.d3] == 1)
            // SP unwound back to the pre-fault supervisor stack pointer:
            // -14 (7-word frame pushed) + 8 (ADDQ.L) + 6 (RTE's SR+PC pop) = 0.
            #expect(machine.cpu[.a7] == initialSSP)
        }
    }
}
