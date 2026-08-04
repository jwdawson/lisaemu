import Testing
@testable import LisaCore

@Suite(.serialized)
struct MachineTests {
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
}
