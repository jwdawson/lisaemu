import Testing
@testable import LisaCore

// Bus-level tests for the I/O dispatcher, hardware latches, MMU ports, and
// the ROM window. No CPU is driven here (pure Bus/IODispatcher plumbing),
// so unlike the CPU-driving suites these do NOT need MusashiSuites
// serialization -- see docs/hardware-notes.md for every address cited.

// MARK: - Setup latch ($E010/$E012) -- address-decoded, ANY access, data ignored

@Test func setupLatchClearsViaFlatIOAddressWhileInSetupMode() {
    // Power-on: setupMode starts TRUE, translation is off, so I/O access
    // happens via the flat $FCxxxx physical address (IOSpace + $E010).
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.setupMode == true)
    _ = bus.read8(0xFC_E010)   // SetUpSet -- a READ still triggers it (data irrelevant)
    #expect(bus.setupMode == true)  // already on; the important thing is no crash/side effect elsewhere
    bus.write8(0xFC_E012, 0x00)  // SetUpReset -- turns setup OFF
    #expect(bus.setupMode == false)
}

@Test func setupLatchTogglesViaTranslatedIOSegment() {
    // Same latch, but reached through a translated `.io` segment instead of
    // the flat setup-mode address -- exercises the other path into
    // IODispatcher (MMU.translate's `.io(offset)` case). Only one toggle is
    // exercised here: the write itself flips `setupMode` to true, which
    // would immediately change how a *second* access to the same address
    // is routed (flat, not translated) -- a real hardware interaction, but
    // not what this test is isolating.
    let bus = Bus(ramSize: 0x1000)
    bus.mmu.domains[0][10] = SegmentRegister(sorg: 0, slim: 0x800)  // access $8 = io
    bus._setSetupModeForTesting(false)
    let base: UInt32 = 10 << 17
    bus.write8(base | 0xE010, 0xFF)   // SetUpSet -- data ignored
    #expect(bus.setupMode == true)
}

// MARK: - Context/domain latches ($E008/$E00A bit1, $E00C/$E00E bit2)

@Test func contextLatchesComposeDomain() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.domain == 0)
    bus.write8(0xFC_E00A, 0)   // bit1 on
    #expect(bus.domain == 1)
    bus.write8(0xFC_E00E, 0)   // bit2 on
    #expect(bus.domain == 3)
    bus.write8(0xFC_E008, 0)   // bit1 off
    #expect(bus.domain == 2)
    bus.write8(0xFC_E00C, 0)   // bit2 off
    #expect(bus.domain == 0)
}

// MARK: - Video page latch ($E800)

@Test func videoPageLatchStoresByte() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E800, 0x42)
    #expect(bus.videoPageLatch == 0x42)
    #expect(bus.read8(0xFC_E800) == 0x42)
}

// MARK: - Status register low byte ($F801)

@Test func statusByteDefaultsToZeroAndIsSoftwareDriven() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_F801) == 0)
    bus.statusByte = 0x04   // M1b will drive this (vsync bit 2); simulate directly
    #expect(bus.read8(0xFC_F801) == 0x04)
    // CPU writes to the status register are hardware-driven, not
    // software-settable -- a bus write must not clobber it.
    bus.write8(0xFC_F801, 0xFF)
    #expect(bus.statusByte == 0x04)
}

// MARK: - Vsync reset/enable ($E018/$E01A) -- stored + logged

@Test func vsyncResetAndEnableAreStoredAndLogged() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E018, 0)
    bus.write8(0xFC_E018, 0)
    bus.write8(0xFC_E01A, 0)
    #expect(bus.ioTrace.contains { $0.offset == 0xE018 })
    #expect(bus.ioTrace.contains { $0.offset == 0xE01A })
    #expect(bus.ioTrace.filter { $0.offset == 0xE018 }.count == 2)
}

// MARK: - Board ID ($C031)

@Test func boardIdReturnsZero() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_C031) == 0x00)
}

// MARK: - VIA1 (stride 8, 16 regs at $D801) / VIA2 (stride 2, 16 regs at $DC01)

@Test func via1RegisterFileReadBack() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_D801, 0xAB)          // PORTB1 (index 0)
    bus.write8(0xFC_D801 + 0x78, 0xCD)   // IORA1 (index 15, offset 15*8=0x78)
    #expect(bus.read8(0xFC_D801) == 0xAB)
    #expect(bus.read8(0xFC_D801 + 0x78) == 0xCD)
    // Untouched register still reads its stub default (0).
    #expect(bus.read8(0xFC_D801 + 0x08) == 0)
}

@Test func via2RegisterFileReadBackWithStrideTwo() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_DC01, 0x11)          // PORTB2 (index 0)
    bus.write8(0xFC_DC01 + 30, 0x22)     // IORA2 (index 15, offset 15*2=30)
    #expect(bus.read8(0xFC_DC01) == 0x11)
    #expect(bus.read8(0xFC_DC01 + 30) == 0x22)
}

// MARK: - Unknown I/O offsets

@Test func unknownIOOffsetReadsFFAndIsLogged() {
    let bus = Bus(ramSize: 0x1000)
    let before = bus.ioTrace.count
    #expect(bus.read8(0xFC_1234) == 0xFF)
    #expect(bus.ioTrace.count == before + 1)
    #expect(bus.ioTrace.last?.offset == 0x1234)
    #expect(bus.ioTrace.last?.isWrite == false)
}

// MARK: - ioTrace bounded growth

@Test func ioTraceIsBoundedWithDropCounter() {
    let bus = Bus(ramSize: 0x1000)
    for i in 0..<5000 {
        _ = bus.read8(0xFC_1000 &+ UInt32(i % 0x100))
    }
    #expect(bus.ioTrace.count == 4096)
    #expect(bus.ioTraceDropped == 5000 - 4096)
}

// MARK: - Peek suppresses IO side effects and logging

@Test func peekDoesNotToggleLatchesOrLog() {
    let bus = Bus(ramSize: 0x1000)
    let before = bus.ioTrace.count
    let v = bus.withPeek { bus.read8(0xFC_E012) }   // would reset setup if not peeking
    #expect(bus.setupMode == true)          // unchanged -- peek must not toggle the latch
    #expect(bus.ioTrace.count == before)    // no trace entry recorded
    _ = v
}

@Test func peekReadsCurrentStoredIOValueWithoutLogging() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E800, 0x77)
    let before = bus.ioTrace.count
    let v = bus.withPeek { bus.read8(0xFC_E800) }
    #expect(v == 0x77)
    #expect(bus.ioTrace.count == before)
}

// MARK: - SLIM/SORG MMU ports ($8000/$8008 per 128KB block, while setupMode)

@Test func slimSorgPortsProgramSegmentRegistersAndReadBack() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.setupMode == true)
    // Program segment 3 (base 3 * 0x20000 = 0x60000): SLIM port at
    // 0x60000+0x8000 = 0x68000, SORG port 8 higher at 0x68008.
    bus.write16(0x6_8000, 0x7F0)   // readWrite, limit-byte 0xF0 (16 pages)
    bus.write16(0x6_8008, 0x200)   // origin page 0x200 (phys 0x40000)
    #expect(bus.mmuPortWrites == 2)
    #expect(bus.mmu.domains[0][3].slim == 0x7F0)
    #expect(bus.mmu.domains[0][3].sorg == 0x200)
    // Read-back through the same ports (needed by the ROM's MMU test).
    #expect(bus.read16(0x6_8000) == 0x7F0)
    #expect(bus.read16(0x6_8008) == 0x200)
}

@Test func slimSorgPortsTargetCurrentDomain() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E00A, 0)   // domain = 1 (bit1 on)
    #expect(bus.domain == 1)
    bus.write16(0x0_8000, 0x612)
    #expect(bus.mmu.domains[1][0].slim == 0x612)
    #expect(bus.mmu.domains[0][0].slim == 0)   // domain 0 untouched
}

@Test func slimSorgProgrammingEndToEndMatchesTranslation() {
    // Program via ports in setup mode, exit setup, verify translation
    // matches Task 4 (MMU.translate) expectations end-to-end.
    let bus = Bus(ramSize: 0x100000)
    bus.write16(0x0_8008, 0x200)   // segment 0 SORG: origin page 0x200 (phys 0x40000)
    bus.write16(0x0_8000, 0x7FF)   // segment 0 SLIM: readWrite, limit byte 0xFF (1 page)
    bus.write8(0x40000, 0x5A)      // physical, still flat (setup mode on)
    bus._setSetupModeForTesting(false)
    #expect(bus.read8(0x0) == 0x5A)   // logical 0 -> segment 0 -> physical 0x40000
}

// MARK: - Machine wires cycleProvider into IOAccess.cycles

@Test func cycleProviderDefaultsToZero() {
    let bus = Bus(ramSize: 0x1000)
    _ = bus.read8(0xFC_1234)
    #expect(bus.ioTrace.last?.cycles == 0)
}

@Test func cycleProviderStampsIOAccess() {
    let bus = Bus(ramSize: 0x1000)
    bus.cycleProvider = { 42 }
    _ = bus.read8(0xFC_1234)
    #expect(bus.ioTrace.last?.cycles == 42)
}
