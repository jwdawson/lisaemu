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
    bus1.setupMode = false  // Enable MMU translation
    // Read from unmapped location outside withPeek — should record fault
    _ = bus1.read8(0x1000)
    let faultRecorded = bus1.lastFault != nil

    let bus2 = Bus(ramSize: 0x100)
    bus2.setupMode = false  // Enable MMU translation
    // Same address read inside withPeek — should NOT record fault
    _ = bus2.withPeek { bus2.read8(0x1000) }
    let faultSuppressed = bus2.lastFault == nil

    #expect(faultRecorded && faultSuppressed)
}
