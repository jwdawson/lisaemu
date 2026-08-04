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
