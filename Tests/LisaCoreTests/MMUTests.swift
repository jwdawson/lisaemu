import Testing
@testable import LisaCore

private func mmuWith(_ seg: Int, _ reg: SegmentRegister, domain: Int = 0) -> MMU {
    var mmu = MMU()
    mmu.domains[domain][seg] = reg
    return mmu
}

@Test func translatesReadWriteSegment() {
    let mmu = mmuWith(1, .init(origin: 0x40000, limitBytes: 0x20000, access: .readWrite))
    // logical 0x2_0000 = segment 1, offset 0
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false) == .success(0x40000))
    #expect(mmu.translate(0x2_0004, domain: 0, isSupervisor: true, isWrite: true) == .success(0x40004))
}

@Test func limitViolationFaults() {
    let mmu = mmuWith(1, .init(origin: 0x40000, limitBytes: 0x100, access: .readWrite))
    #expect(mmu.translate(0x2_0100, domain: 0, isSupervisor: true, isWrite: false)
            == .failure(MMUFault(logical: 0x2_0100, reason: .limitViolation)))
}

@Test func readOnlyRejectsWrites() {
    let mmu = mmuWith(0, .init(origin: 0, limitBytes: 0x20000, access: .readOnly))
    #expect(mmu.translate(0x10, domain: 0, isSupervisor: true, isWrite: false) == .success(0x10))
    #expect(mmu.translate(0x10, domain: 0, isSupervisor: true, isWrite: true)
            == .failure(MMUFault(logical: 0x10, reason: .writeToReadOnly)))
}

@Test func stackSegmentGrowsDown() {
    let mmu = mmuWith(2, .init(origin: 0x80000, limitBytes: 0x1000, access: .stack))
    // Top 0x1000 bytes of the 128K window are valid: offsets >= 0x1F000
    #expect(mmu.translate(0x5_F000, domain: 0, isSupervisor: true, isWrite: true) == .success(0x9F000))
    #expect(mmu.translate(0x4_0000, domain: 0, isSupervisor: true, isWrite: true)
            == .failure(MMUFault(logical: 0x4_0000, reason: .limitViolation)))
}

@Test func domainsAreIsolated() {
    var mmu = MMU()
    mmu.domains[1][0] = .init(origin: 0x10000, limitBytes: 0x20000, access: .readWrite)
    #expect(mmu.translate(0x0, domain: 1, isSupervisor: true, isWrite: false) == .success(0x10000))
    #expect(mmu.translate(0x0, domain: 0, isSupervisor: true, isWrite: false)
            == .failure(MMUFault(logical: 0x0, reason: .invalidSegment)))
}

@Test func translateAcceptsSupervisorParameter() {
    let mmu = mmuWith(1, .init(origin: 0x40000, limitBytes: 0x20000, access: .readWrite))
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: false, isWrite: false)
            == mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false))
}

@Test func busTranslatesWhenSetupModeOff() {
    let bus = Bus(ramSize: 0x100000)
    bus.write8(0x40000, 0x5A)                 // physical, while in setup mode
    bus.mmu.domains[0][0] = .init(origin: 0x40000, limitBytes: 0x20000, access: .readWrite)
    bus.setupMode = false
    #expect(bus.read8(0x0) == 0x5A)           // logical 0 → physical 0x40000
    _ = bus.read8(0x2_0000)                   // segment 1 is invalid
    #expect(bus.lastFault == MMUFault(logical: 0x2_0000, reason: .invalidSegment))
}
