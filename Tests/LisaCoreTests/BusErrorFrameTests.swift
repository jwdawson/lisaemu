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

            // Handler at $600 (M4 Task 4 round 4 update -- the frame PC for a
            // MID-INSTRUCTION data fault is now `instruction start + 2`, the
            // real-68000 convention the Lisa OS's own bus-error handler
            // decodes (SOURCE-EXCEPASM:434-505 backs the frame PC up by an
            // instruction-specific constant to RE-RUN the faulting
            // instruction -- e.g. its TST stack-probe case does PC-2 to
            // re-point at the TST). A handler that wants to SKIP the
            // faulting instruction must therefore rewrite the stacked PC
            // itself, exactly as this one now does:
            //   MOVE.L 2(A7),D0      -- D0 = fault address (frame SP+2..5)
            //   MOVE.L D0,$900.L     -- stash it in a known RAM cell
            //   MOVE.L 10(A7),D0     -- D0 = frame PC (faulting instr + 2)
            //   MOVE.L D0,$904.L     -- stash it
            //   MOVE.L #$406,10(A7)  -- retarget RTE past the 6-byte MOVE.B
            //   ADDQ.L #8,A7         -- strip status word + address + IR
            //   RTE
            machine.bus.load(
                [
                    0x20, 0x2F, 0x00, 0x02,              // MOVE.L 2(A7),D0
                    0x23, 0xC0, 0x00, 0x00, 0x09, 0x00,  // MOVE.L D0,$900.L
                    0x20, 0x2F, 0x00, 0x0A,              // MOVE.L 10(A7),D0
                    0x23, 0xC0, 0x00, 0x00, 0x09, 0x04,  // MOVE.L D0,$904.L
                    0x2F, 0x7C, 0x00, 0x00, 0x04, 0x06, 0x00, 0x0A,  // MOVE.L #$406,10(A7)
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
            // Frame PC = faulting instruction start + 2 (real-68000
            // mid-instruction convention, SOURCE-EXCEPASM:497-500's PC-2
            // re-run adjustment) -- NOT the successor address.
            #expect(machine.bus.read32(0x904) == 0x0000_0402)
            // RTE resumed at the successor only because the handler
            // explicitly retargeted the stacked PC.
            #expect(machine.cpu[.d3] == 1)
            // SP unwound back to the pre-fault supervisor stack pointer:
            // -14 (7-word frame pushed) + 8 (ADDQ.L) + 6 (RTE's SR+PC pop) = 0.
            #expect(machine.cpu[.a7] == initialSSP)
        }

        // MARK: - Jump-gate frame semantics (M4 Task 4 round 4)
        //
        // The Lisa OS's recoverable-bus-error engine (SOURCE-EXCEPASM
        // :434-505, `BUS_ERR`) decodes the group-0 frame's INSTRUCTION
        // REGISTER (frame+6, its B1/B2) and applies instruction-specific
        // frame-PC adjustments to RE-RUN the faulting jump after the memory
        // manager swaps the target code segment in:
        //   JSR.L    -> PC-6   JSR d16(An) -> PC-4   JSR (An)/JMP/RTS -> PC-2
        //   RTS      -> additionally UN-pops the return (USP -= 4)
        // For those constants to re-point at the jump instruction, the real
        // 68000 must (a) push frame PC = jump-instruction address + those
        // constants, (b) leave a faulting JSR's return address UN-pushed (a
        // re-run pushes it exactly once -- the target prefetch happens
        // BEFORE the return-address write in real 68000 microcode), and
        // (c) leave a faulting RTS's pop COMMITTED (the OS un-pops it).
        // The whole OS syscall/segment-swap gate mechanism ($A0xxxxxx
        // tagged jump-table entries) rides on these semantics; Musashi's
        // stock behavior (complete the jump, fault at the next loop-top
        // fetch with PC = target+2) breaks them -- observed live as a
        // second, spurious return address corrupting a syscall parameter
        // frame (docs/rom-trace-notes.md "Checkpoint G (round 4)").
        private func gateMachine(program: [UInt8], ssp: UInt32 = 0x3000) -> Machine {
            let machine = Machine(ramSize: 0x10000)
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)
            machine.bus.write32(0x0, ssp)
            machine.bus.write32(0x4, 0x400)       // initial PC
            machine.bus.write32(0x8, 0x600)       // bus-error vector -> handler
            machine.bus.load(program, at: 0x400)
            machine.bus.load([0x60, 0xFE], at: 0x600)   // handler: BRA * (spin)
            machine.reset()
            machine.bus._setSetupModeForTesting(false)
            var steps = 0
            while machine.cpu[.pc] != 0x600 && steps < 2000 && !machine.halted {
                _ = machine.step(); steps += 1
            }
            return machine
        }

        @Test func jsrAbsLongGateFaultPushesJumpSiteFrameAndNoReturnAddress() {
            // JSR $A0020000.L at $400 -- the OS's tagged-gate shape: masked
            // seg 1 is absent -> invalidSegment on the target prefetch.
            let m = gateMachine(program: [0x4E, 0xB9, 0xA0, 0x02, 0x00, 0x00])
            let sp = m.cpu[.a7]
            // No return address on the stack: the frame sits directly below
            // the pre-JSR SP ($3000 - 14).
            #expect(sp == 0x3000 - 14, "faulting JSR must NOT leave its return address pushed; sp=\(String(format:"$%04X", sp))")
            #expect(m.bus.read16(sp &+ 6) == 0x4EB9, "frame IR = the JSR.L opcode")
            #expect(m.bus.read32(sp &+ 2) == 0xA002_0000, "frame fault address = the full 32-bit tagged target")
            #expect(m.bus.read32(sp &+ 10) == 0x406, "frame PC = JSR.L address + 6 (OS re-runs at PC-6)")
        }

        @Test func jsrIndirectGateFaultPushesJumpSitePlus2() {
            // MOVEA.L #$A0020000,A0; JSR (A0) at $406.
            let m = gateMachine(program: [0x20, 0x7C, 0xA0, 0x02, 0x00, 0x00,   // MOVEA.L #$A0020000,A0
                                          0x4E, 0x90])                          // JSR (A0)
            let sp = m.cpu[.a7]
            #expect(sp == 0x3000 - 14, "no return address pushed")
            #expect(m.bus.read16(sp &+ 6) == 0x4E90, "frame IR = JSR (An)")
            #expect(m.bus.read32(sp &+ 10) == 0x408, "frame PC = JSR (An) address + 2")
        }

        @Test func jsrDisplacementGateFaultPushesJumpSitePlus4() {
            // MOVEA.L #$A001FFEE,A0; JSR $12(A0) at $406 -> EA $A0020000.
            let m = gateMachine(program: [0x20, 0x7C, 0xA0, 0x01, 0xFF, 0xEE,   // MOVEA.L #$A001FFEE,A0
                                          0x4E, 0xA8, 0x00, 0x12])              // JSR $12(A0)
            let sp = m.cpu[.a7]
            #expect(sp == 0x3000 - 14, "no return address pushed")
            #expect(m.bus.read16(sp &+ 6) == 0x4EA8, "frame IR = JSR d16(An)")
            #expect(m.bus.read32(sp &+ 10) == 0x40A, "frame PC = JSR d16(An) address + 4")
        }

        @Test func jmpAbsLongGateFaultPushesJumpSitePlus2() {
            let m = gateMachine(program: [0x4E, 0xF9, 0xA0, 0x02, 0x00, 0x00])  // JMP $A0020000.L
            let sp = m.cpu[.a7]
            #expect(sp == 0x3000 - 14)
            #expect(m.bus.read16(sp &+ 6) == 0x4EF9, "frame IR = JMP.L")
            #expect(m.bus.read32(sp &+ 10) == 0x402, "frame PC = JMP.L address + 2 (OS re-runs at PC-2)")
        }

        @Test func rtsGateFaultCommitsThePopAndPushesRtsSitePlus2() {
            // Seed the stack with the tagged return target, then RTS at $400.
            let machine = Machine(ramSize: 0x10000)
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)
            machine.bus.write32(0x0, 0x2FFC)      // initial SSP -> the seeded return
            machine.bus.write32(0x4, 0x400)
            machine.bus.write32(0x8, 0x600)
            machine.bus.write32(0x2FFC, 0xA002_0000)   // seeded return target
            machine.bus.load([0x4E, 0x75], at: 0x400)  // RTS
            machine.bus.load([0x60, 0xFE], at: 0x600)
            machine.reset()
            machine.bus._setSetupModeForTesting(false)
            var steps = 0
            while machine.cpu[.pc] != 0x600 && steps < 2000 && !machine.halted {
                _ = machine.step(); steps += 1
            }
            let sp = machine.cpu[.a7]
            // Pop COMMITTED (SP rose to $3000) before the target prefetch
            // faulted; the OS's RTS case un-pops it (SOURCE-EXCEPASM:452-456).
            #expect(sp == 0x3000 - 14, "RTS pop must be committed; the frame sits below the popped SP")
            #expect(machine.bus.read16(sp &+ 6) == 0x4E75, "frame IR = RTS")
            #expect(machine.bus.read32(sp &+ 10) == 0x402, "frame PC = RTS address + 2")
            #expect(machine.bus.read32(sp &+ 2) == 0xA002_0000, "frame fault address = the popped tagged target")
        }

        @Test func jmpIndirectGateFaultPushesJumpSitePlus2() {
            // MOVEA.L #$A0020000,A0; JMP (A0) at $406 -- the OS decodes
            // JMP (An) via its masked $D0 subcode (SOURCE-EXCEPASM:467-469)
            // with the same PC-2 re-run adjustment as JMP.L.
            let m = gateMachine(program: [0x20, 0x7C, 0xA0, 0x02, 0x00, 0x00,   // MOVEA.L #$A0020000,A0
                                          0x4E, 0xD0])                          // JMP (A0)
            let sp = m.cpu[.a7]
            #expect(sp == 0x3000 - 14, "JMP has no stack side effect")
            #expect(m.bus.read16(sp &+ 6) == 0x4ED0, "frame IR = JMP (An)")
            #expect(m.bus.read32(sp &+ 10) == 0x408, "frame PC = JMP (An) address + 2")
            #expect(m.bus.read32(sp &+ 2) == 0xA002_0000, "frame fault address = the full tagged target")
        }

        @Test func rteGateFaultPopsCommittedAndPushesRteSitePlus2() {
            // RTE popping a seeded [user SR $0700][tagged PC $A0020000]
            // frame -- the OS's "return into a swapped-out segment" path:
            // its RTE case sets PCX := BADADDR (SOURCE-EXCEPASM:457-460),
            // relying on the frame's fault address carrying the full popped
            // target. The pop must be COMMITTED (mode switched to user, SSP
            // risen past the popped frame) before the target fetch faults.
            let machine = Machine(ramSize: 0x10000)
            machine.bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 128, access: .readWrite)
            machine.bus.write32(0x0, 0x2FFA)      // initial SSP -> the seeded RTE frame
            machine.bus.write32(0x4, 0x400)
            machine.bus.write32(0x8, 0x600)
            machine.bus.write16(0x2FFA, 0x0700)        // popped SR: user mode, IRQs masked
            machine.bus.write32(0x2FFC, 0xA002_0000)   // popped PC: the tagged gate target
            machine.bus.load([
                0x20, 0x7C, 0x00, 0x00, 0x28, 0x00,   // MOVEA.L #$2800,A0
                0x4E, 0x60,                           // MOVE A0,USP
                0x4E, 0x73,                           // RTE            (at $408)
            ], at: 0x400)
            machine.bus.load([0x60, 0xFE], at: 0x600)
            machine.reset()
            machine.bus._setSetupModeForTesting(false)
            var steps = 0
            while machine.cpu[.pc] != 0x600 && steps < 2000 && !machine.halted {
                _ = machine.step(); steps += 1
            }
            let sp = machine.cpu[.a7]
            // Pop committed: SSP rose to $3000 before the fault re-entered
            // supervisor; the group-0 frame sits directly below it.
            #expect(sp == 0x3000 - 14, "RTE pop committed -- frame below the popped SSP; sp=\(String(format:"$%04X", sp))")
            #expect(machine.bus.read16(sp &+ 6) == 0x4E73, "frame IR = RTE")
            #expect(machine.bus.read32(sp &+ 10) == 0x40A, "frame PC = RTE address + 2")
            #expect(machine.bus.read32(sp &+ 2) == 0xA002_0000, "frame fault address = the popped tagged target (what the OS's PCX := BADADDR consumes)")
            #expect(machine.bus.read16(sp &+ 8) & 0x2000 == 0, "frame SR = the POPPED (user) SR -- the fault happened after the mode switch")
            #expect(machine.cpu[.usp] == 0x2800, "user SP untouched by the RTE gate fault")
        }

        @Test func userModeJsrGateFaultLeavesUspUnpushed() {
            // Supervisor prologue drops to user mode (masked), then the
            // user-mode JSR gate faults -- the OS's actual syscall-gate shape.
            let m = gateMachine(program: [
                0x20, 0x7C, 0x00, 0x00, 0x28, 0x00,   // MOVEA.L #$2800,A0
                0x4E, 0x60,                           // MOVE A0,USP
                0x46, 0xFC, 0x07, 0x00,               // MOVE #$0700,SR (user, IRQs masked)
                0x4E, 0xB9, 0xA0, 0x02, 0x00, 0x00,   // JSR $A0020000.L  (at $40C)
            ])
            #expect(m.cpu[.usp] == 0x2800, "the faulting user-mode JSR must NOT leave its return on the user stack")
            let sp = m.cpu[.a7]
            #expect(m.bus.read16(sp &+ 6) == 0x4EB9)
            #expect(m.bus.read32(sp &+ 10) == 0x412, "frame PC = user JSR.L address + 6")
            #expect(m.bus.read16(sp &+ 8) & 0x2000 == 0, "frame SR shows the fault happened in user mode")
        }
    }
}
