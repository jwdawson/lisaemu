import Testing
@testable import LisaCore

extension MusashiSuites {
    @Suite struct MachineTests {
        private func loadSpin(_ machine: Machine) {
            machine.bus.write32(0x0, 0x3000)
            machine.bus.write32(0x4, 0x400)
            machine.bus.load([0x60, 0xFE], at: 0x400)   // BRA.s spin
            machine.reset()
        }

        @Test
        func runAdvancesCycles() {
            let m = Machine(ramSize: 0x10000)
            loadSpin(m)
            m.run(until: 100)
            #expect(m.cycles >= 100)          // CPU slices may slightly overshoot
        }

        @Test
        func eventsFireInOrderAtTheirCycle() {
            let m = Machine(ramSize: 0x10000)
            loadSpin(m)
            var fired: [Int] = []
            m.schedule(at: 60) { _ in fired.append(2) }
            m.schedule(at: 30) { _ in fired.append(1) }
            m.run(until: 200)
            #expect(fired == [1, 2])
        }

        @Test
        func eventScheduledByEventFires() {
            let m = Machine(ramSize: 0x10000)
            loadSpin(m)
            var count = 0
            m.schedule(at: 10) { machine in
                count += 1
                machine.schedule(at: machine.cycles + 50) { _ in count += 1 }
            }
            m.run(until: 500)
            #expect(count == 2)
        }

        @Test
        func stopInstructionIsNotFatalHalt() {
            // MOVEQ #42,D0 ; STOP #$2700 -- STOP is a low-power wait that
            // resumes on interrupt, not a fatal condition. It must not set
            // Machine.halted, and run(until:) must return promptly because
            // Musashi bills the full requested slice against a STOPPED core
            // (see the "defensive only" comment on Machine.run(until:)).
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000)
            m.bus.write32(0x4, 0x400)
            m.bus.load([0x70, 0x2A, 0x4E, 0x72, 0x27, 0x00], at: 0x400)
            m.reset()

            m.run(until: 1000)

            #expect(m.cpu[.d0] == 42)
            #expect(m.cpu.isStopped == true)
            #expect(m.halted == false)
            #expect(m.cycles >= 1000)
        }

        @Test
        func doubleFaultProducesFatalHalt() {
            // Odd SSP (0x3001) and odd PC (0x401): the initial instruction
            // fetch takes an address error, and writing that exception's
            // stack frame via the odd SSP takes a second address error
            // while already processing the first -- a double bus fault,
            // which Musashi reports as STOP_LEVEL_HALT. This retries the
            // Task 6 experiment now that M68K_EMULATE_ADDRESS_ERROR is ON
            // (Task 7), so the first fetch actually faults instead of
            // silently executing whatever was at the odd address.
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3001)
            m.bus.write32(0x4, 0x401)
            m.bus.load([0x60, 0xFE], at: 0x400)   // BRA.s spin (never reached)
            m.reset()

            m.run(until: 1000)

            #expect(m.halted == true)
            #expect(m.cpu.isHalted == true)
        }

        @Test
        func haltedFlagClearedOnReset() {
            let m = Machine(ramSize: 0x10000)
            loadSpin(m)
            m.run(until: 100)
            // Even if halted was set somehow, reset should clear it
            m.reset()
            #expect(m.halted == false)
        }

        @Test
        func boundedSliceClampsToInt32MaxForFarTargets() {
            // stop - cycles vastly exceeds Int32.max; the slice must clamp
            // rather than let `Int32(cycles)` inside M68K.run(cycles:) trap.
            let cycles: UInt64 = 10
            let stop = cycles + UInt64(Int32.max) + 1_000
            #expect(Machine.boundedSlice(from: cycles, to: stop) == Int(Int32.max))
        }

        @Test
        func boundedSliceUnchangedForSmallTargets() {
            #expect(Machine.boundedSlice(from: 0, to: 100) == 100)
            #expect(Machine.boundedSlice(from: 50, to: 50) == 1)
            #expect(Machine.boundedSlice(from: 0, to: 1) == 1)
        }

        @Test
        func stepAdvancesCyclesAndDrainsDueEvents() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000)
            m.bus.write32(0x4, 0x400)
            // MOVEQ #42,D0 ; BRA.s spin (self-loop at 0x402)
            m.bus.load([0x70, 0x2A, 0x60, 0xFE], at: 0x400)
            m.reset()

            var fired = false
            m.schedule(at: 1) { _ in fired = true }

            m.step()
            m.step()

            #expect(m.cpu[.d0] == 42)
            #expect(m.cycles > 0)
            #expect(fired == true)
        }
    }
}
