import Testing
@testable import LisaCore

@Test func ramRoundTripAndEndianness() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0x10, 0xAB)
    #expect(bus.read8(0x10) == 0xAB)
    bus.write16(0x20, 0x1234)
    #expect(bus.read8(0x20) == 0x12)      // big-endian high byte first
    #expect(bus.read8(0x21) == 0x34)
    bus.write32(0x30, 0xDEAD_BEEF)
    #expect(bus.read16(0x30) == 0xDEAD)
    #expect(bus.read16(0x32) == 0xBEEF)
}

@Test func addressesMaskTo24Bits() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFF00_0040, 0x77)         // top byte ignored
    #expect(bus.read8(0x40) == 0x77)
}

@Test func unmappedAccessIsRecordedAndReadsFF() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0x80_0000) == 0xFF)
    #expect(bus.unmappedAccesses == [0x80_0000])
}

@Test func loadPlacesBytes() {
    let bus = Bus(ramSize: 0x1000)
    bus.load([0x70, 0x2A], at: 0x400)
    #expect(bus.read16(0x400) == 0x702A)
}

@Test func loadGracefullyHandlesOverflow() {
    let bus = Bus(ramSize: 0x1000)
    // Load 4 bytes at ramSize - 2, so first 2 land in RAM and last 2 are out-of-bounds
    bus.load([0xAA, 0xBB, 0xCC, 0xDD], at: 0xFFE)
    #expect(bus.read8(0xFFE) == 0xAA)       // in bounds
    #expect(bus.read8(0xFFF) == 0xBB)       // in bounds
    // Accessing out-of-bounds will also record unmapped accesses, so we verify without reading
    // Just verify that in-bounds bytes were written and out-of-bounds were silently ignored
    #expect(bus.unmappedAccesses.count >= 2)  // at least 2 out-of-bounds write attempts
    #expect(bus.unmappedAccesses.contains(0x1000))
    #expect(bus.unmappedAccesses.contains(0x1001))
}

@Test func unmappedAccessListIsBounded() {
    let bus = Bus(ramSize: 0x100)
    for i in 0..<1500 { _ = bus.read8(0x80_0000 + UInt32(i)) }
    #expect(bus.unmappedAccesses.count == 1024)
    #expect(bus.unmappedDropped == 1500 - 1024)
}

@Test func peekSuppressesDiagnostics() {
    let bus = Bus(ramSize: 0x100)
    let v = bus.withPeek { bus.read8(0x80_0000) }
    #expect(v == 0xFF)
    #expect(bus.unmappedAccesses.isEmpty)
}

@Test func domainSetterValidates() {
    let bus = Bus(ramSize: 0x100)
    // Valid domains 0-3 should work
    for domain in 0...3 {
        bus.domain = domain
        #expect(bus.domain == domain)
    }
    // Invalid domain should trap (not tested, as precondition is debug-only)
}

@Test func peekSuppressesLastFaultInTranslatedPath() {
    let bus1 = Bus(ramSize: 0x100)
    bus1._setSetupModeForTesting(false)  // Enable MMU translation
    // Read from unmapped location outside withPeek — should record fault
    _ = bus1.read8(0x1000)
    let faultRecorded = bus1.lastFault != nil

    let bus2 = Bus(ramSize: 0x100)
    bus2._setSetupModeForTesting(false)  // Enable MMU translation
    // Same address read inside withPeek — should NOT record fault
    _ = bus2.withPeek { bus2.read8(0x1000) }
    let faultSuppressed = bus2.lastFault == nil

    #expect(faultRecorded && faultSuppressed)
}

// MARK: - ROM window ($FE0000-$FE3FFF) + low mirror ($0000-$3FFF while setupMode)

@Test func romWindowReadsLoadedBytes() {
    let bus = Bus(ramSize: 0x1000)
    let rom = (0..<0x4000).map { UInt8($0 & 0xFF) }
    bus.loadROM(rom)
    #expect(bus.read8(0xFE_0000) == rom[0])
    #expect(bus.read8(0xFE_0001) == rom[1])
    #expect(bus.read8(0xFE_3FFF) == rom[0x3FFF])
}

@Test func romWindowWritesAreIgnoredAndLogged() {
    let bus = Bus(ramSize: 0x1000)
    bus.loadROM([UInt8](repeating: 0xAA, count: 0x4000))
    bus.write8(0xFE_0000, 0x00)
    #expect(bus.read8(0xFE_0000) == 0xAA)   // write had no effect
    #expect(bus.unmappedAccesses.contains(0xFE_0000))   // but was logged
}

@Test func lowMirrorReadsROMWhileInSetupMode() {
    let bus = Bus(ramSize: 0x1000)
    var rom = [UInt8](repeating: 0, count: 0x4000)
    rom[0] = 0x60
    rom[1] = 0xFE
    bus.loadROM(rom)
    #expect(bus.setupMode == true)
    #expect(bus.read8(0x0) == rom[0])
    #expect(bus.read8(0x1) == rom[1])
}

@Test func lowMirrorWritesFallThroughToRAM() {
    // Modeled assumption (per task-5 brief): while the mirror is read-only
    // for ROM, writes to $0000-$3FFF are NOT dropped -- they fall straight
    // through to RAM underneath, since the boot ROM writes low RAM during
    // POST after mapping is established. Task 7's real-ROM trace will
    // confirm or correct this.
    let bus = Bus(ramSize: 0x1000)
    bus.loadROM([UInt8](repeating: 0xAA, count: 0x4000))
    bus.write8(0x10, 0x5A)
    // The mirror still shadows reads at $10 (ROM wins for reads)...
    #expect(bus.read8(0x10) == 0xAA)
    // ...but the byte really did land in RAM underneath: once setup mode
    // clears (and nothing maps segment 0), the mirror is gone entirely and
    // the flat/translated path is no longer meaningful here, so instead we
    // verify the underlying RAM directly via a segment 0 mapping.
    bus.mmu.domains[0][0] = .make(originPage: 0, limitPages: 256, access: .readWrite)
    bus._setSetupModeForTesting(false)
    #expect(bus.read8(0x10) == 0x5A)
}

// MARK: - Translated-mode `.special` routing (MMU nibble $F, rom-trace-notes.md OQ2)

@Test func specialSpaceServesROMBytesInLowRange() {
    let bus = Bus(ramSize: 0x1000)
    var rom = [UInt8](repeating: 0xAA, count: 0x4000)
    rom[0] = 0x11
    rom[0x3FFF] = 0x22
    bus.loadROM(rom)
    bus.mmu.domains[0][127] = SegmentRegister(sorg: 0, slim: 0xF00)   // nibble $F, full segment
    bus._setSetupModeForTesting(false)
    let base: UInt32 = 127 << 17
    #expect(bus.read8(base) == 0x11)
    #expect(bus.read8(base + 0x3FFF) == 0x22)
}

@Test func specialSpaceWritesToROMRangeAreIgnoredAndLogged() {
    let bus = Bus(ramSize: 0x1000)
    bus.loadROM([UInt8](repeating: 0xAA, count: 0x4000))
    bus.mmu.domains[0][127] = SegmentRegister(sorg: 0, slim: 0xF00)
    bus._setSetupModeForTesting(false)
    let base: UInt32 = 127 << 17
    bus.write8(base, 0x00)
    #expect(bus.read8(base) == 0xAA)              // write had no effect
    #expect(bus.unmappedAccesses.contains(base))  // but was logged
}

@Test func specialSpaceAboveROMReadsUnknownStub() {
    let bus = Bus(ramSize: 0x1000)
    bus.loadROM([UInt8](repeating: 0xAA, count: 0x4000))
    bus.mmu.domains[0][127] = SegmentRegister(sorg: 0, slim: 0xF00)
    bus._setSetupModeForTesting(false)
    let base: UInt32 = 127 << 17
    #expect(bus.read8(base + 0x4000) == 0xFF)
    #expect(bus.read8(base + 0x1_FFFF) == 0xFF)
    #expect(bus.ioTrace.contains { $0.offset == 0x4000 && !$0.isWrite })
}

@Test func mirrorIsGoneOnceSetupModeClearsWithAnMMUMapping() {
    let bus = Bus(ramSize: 0x100000)
    var rom = [UInt8](repeating: 0xAA, count: 0x4000)
    rom[0] = 0x11
    bus.loadROM(rom)
    #expect(bus.read8(0x0) == 0x11)   // setup mode: mirror shows ROM

    bus.write8(0x40000, 0x99)                 // physical, while still in setup mode
    bus.mmu.domains[0][0] = .make(originPage: 0x200, limitPages: 256, access: .readWrite)
    bus._setSetupModeForTesting(false)
    #expect(bus.read8(0x0) == 0x99)   // translated: RAM via the mapping, not ROM
}
