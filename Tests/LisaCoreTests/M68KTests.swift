import Testing
@testable import LisaCore

/// Reset vectors + a two-instruction program: MOVEQ #42,D0; BRA *-0 loop.
private func makeMachineRAM() -> Bus {
    let bus = Bus(ramSize: 0x10000)
    bus.write32(0x0, 0x3000)        // initial SSP
    bus.write32(0x4, 0x400)         // initial PC
    bus.load([0x70, 0x2A,           // MOVEQ #42, D0
              0x60, 0xFE],          // BRA.s -2 (spin)
             at: 0x400)
    return bus
}

// Musashi is a process-global singleton core (see M68K.currentBus), so these
// tests cannot run concurrently with each other without corrupting each
// other's CPU/bus state. `.serialized` keeps them from overlapping while
// still letting other suites (e.g. BusTests) run in parallel.
@Suite(.serialized)
struct M68KTests {
    @Test func executesMoveq() {
        let bus = makeMachineRAM()
        let cpu = M68K(bus: bus)
        cpu.reset()
        #expect(cpu[.pc] == 0x400)
        #expect(cpu[.a7] == 0x3000)
        cpu.run(cycles: 20)
        #expect(cpu[.d0] == 42)
    }

    @Test func disassemblesMoveq() {
        let bus = makeMachineRAM()
        let cpu = M68K(bus: bus)
        cpu.reset()
        let (text, length) = cpu.disassemble(at: 0x400)
        #expect(length == 2)
        #expect(text.lowercased().contains("moveq"))
    }
}
