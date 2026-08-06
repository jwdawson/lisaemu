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

@Test func bareReadOfSetupLatchTogglesIt() {
    // The earlier "clears" test above only issues a WRITE to $E012 and a
    // READ to $E010 while setup was already true (so the read was
    // observably a no-op). This test isolates a bare READ actually
    // toggling state: turn setup off via a write, then perform ONLY a read
    // of $E010 (SetUpSet) and confirm setup mode is back on -- proving the
    // latch really is address-decoded on ANY access, not just writes
    // (docs/hardware-notes.md "Setup Latch": "ANY access (read or write)").
    //
    // Segment 126 (the $FC0000 block) is pre-mapped as io in domain 0 so
    // that once the write below flips setupMode off, the read that
    // follows still reaches IODispatcher via the translated `.io` route
    // instead of faulting on an otherwise-unmapped segment 126 -- without
    // this, the write's own side effect (setupMode false) would silently
    // change how the very next access is routed.
    let bus = Bus(ramSize: 0x1000)
    bus.mmu.domains[0][126] = SegmentRegister(sorg: 0, slim: 0x800)  // access $8 = io
    bus.write8(0xFC_E012, 0x00)   // SetUpReset -- setup off (still flat here)
    #expect(bus.setupMode == false)
    _ = bus.read8(0xFC_E010)      // bare READ of SetUpSet -- now via translated .io
    #expect(bus.setupMode == true)
}

@Test func bareReadOfContextLatchSetsDomainBit() {
    // Same point for a context latch: a READ of $E00A (context bit1 on)
    // must set the domain bit, not just a write.
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.domain == 0)
    _ = bus.read8(0xFC_E00A)
    #expect(bus.domain == 1)
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

// MARK: - VIA1 (stride 8, 16 regs at $D901) / VIA2 (stride 2, 16 regs at $DD81)
//
// ROM-observed bases (docs/hardware-notes.md §3); the historical
// $D801/$DC01 OS-source equates are refuted for the Rev H boot path (see
// docs/rom-trace-notes.md "Beyond the M1a boundary"). As of Task 3 these
// route to a real `VIA6522`, not a dumb byte-store stub -- PORTA/PORTB
// reads are DDR-mixed against `portAInput`/`portBInput` (default all-ones),
// so DDR is driven all-output here first to make the plain write/read-back
// shape below observable; full VIA semantics (timers, IFR/IER, DDR mixing
// itself) are covered by the CPU-free `VIA6522Tests.swift`, not here --
// this file only checks that `IODispatcher` maps these IOSpace offsets onto
// the right VIA/register index.

@Test func via1RegisterFileReadBack() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_D901 + 0x10, 0xFF)   // DDRB1 (index 2, offset 2*8=0x10) = all outputs
    bus.write8(0xFC_D901 + 0x18, 0xFF)   // DDRA1 (index 3, offset 3*8=0x18) = all outputs
    bus.write8(0xFC_D901, 0xAB)          // ORB1/PORTB1 (index 0)
    bus.write8(0xFC_D901 + 0x78, 0xCD)   // IORA1 (index 15, offset 15*8=0x78)
    #expect(bus.read8(0xFC_D901) == 0xAB)
    #expect(bus.read8(0xFC_D901 + 0x78) == 0xCD)
    // Untouched register (SR1, index 10, offset 10*8=0x50) still reads its
    // power-on default (0).
    #expect(bus.read8(0xFC_D901 + 0x50) == 0)
}

@Test func via2RegisterFileReadBackWithStrideTwo() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_DD81 + 4, 0xFF)      // DDRB2 (index 2, offset 4) = all outputs
    bus.write8(0xFC_DD81 + 6, 0xFF)      // DDRA2 (index 3, offset 6) = all outputs
    bus.write8(0xFC_DD81, 0x11)          // PORTB2 (index 0)
    bus.write8(0xFC_DD81 + 30, 0x22)     // IORA2 (index 15, offset 15*2=30)
    #expect(bus.read8(0xFC_DD81) == 0x11)
    #expect(bus.read8(0xFC_DD81 + 30) == 0x22)
}

// MARK: - VIA2 register self-test, the exact stall pattern (rom-trace-notes.md)

@Test func via2T1LatchOffsetsSurviveTheROMSelfTestPattern() {
    // $FCDD8D/$FCDD8F = T1L-L2/T1L-H2 (base $DD81 + stride-2 offsets 12/14,
    // i.e. register indices 6/7) -- the exact cells the ROM's VIA2 register
    // self-test hammers (rom-trace-notes.md "The hard stall"): clear, write
    // $FF, read back expecting the written value, repeatedly.
    let bus = Bus(ramSize: 0x1000)
    for _ in 0..<8 {
        bus.write8(0xFC_DD8D, 0x00)
        #expect(bus.read8(0xFC_DD8D) == 0x00)
        bus.write8(0xFC_DD8D, 0xFF)
        #expect(bus.read8(0xFC_DD8D) == 0xFF)
        bus.write8(0xFC_DD8F, 0x00)
        #expect(bus.read8(0xFC_DD8F) == 0x00)
        bus.write8(0xFC_DD8F, 0xFF)
        #expect(bus.read8(0xFC_DD8F) == 0xFF)
    }
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

// MARK: - FloppyController window ($C000-$C7FF) + board IDs (M2 Task 4)
//
// Pure Bus/IODispatcher routing checks -- FloppyController's own protocol
// (go-byte state machine, zone mapping, etc.) is covered CPU-free and
// Bus-free in FloppyControllerTests.swift. A bare `Bus`'s `scheduleEvent`
// defaults to a no-op (see that property's doc comment), so a DISKCMD
// write's scheduled command-processing event never actually fires here --
// these tests only exercise that IODispatcher hands offsets in this range
// to `floppy.read`/`floppy.write` at all, and that the two explicit
// board-ID cells sharing this address range stay independently correct.

@Test func c015ReturnsSingleSidedSonyBoardID() {
    // $FCC015 (adr_intdisk, docs/hardware-notes.md §9 "Board IDs"): Task 4
    // moves this from unknown-I/O (0xFF) to 1 (single-sided Sony).
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_C015) == 1)
    bus.write8(0xFC_C015, 0x42)   // hardware-driven; CPU writes have no effect
    #expect(bus.read8(0xFC_C015) == 1)
}

@Test func c031BoardIDUnchangedByTheFloppyWindow() {
    // $FCC031 falls inside the $C000-$C7FF window but must keep its own
    // pre-existing (Task 3 era) behavior, not become a plain window byte.
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_C031) == 0x00)
}

@Test func floppyWindowRoutesPlainCellsAsRAMThroughTheBus() {
    // DISKSEC ($C009) has no address-decoded side effect of its own --
    // a plain read-back through the real Bus, same as any other window
    // cell besides DISKCMD.
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_C009, 0x07)
    #expect(bus.read8(0xFC_C009) == 0x07)
    #expect(bus.floppy.read(0x09) == 0x07, "the same byte, seen directly on the owning FloppyController")
}

@Test func floppyWindowDiskCmdWriteReachesTheController() {
    // DISKCMD ($C001) IS address-decoded (the go-byte hook) -- a bus write
    // must reach FloppyController.write, not just land in a dumb byte
    // store, even though a bare Bus's no-op scheduleEvent means the
    // command itself never actually completes here.
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_C001, FloppyController.GoByte.excmd.rawValue)
    #expect(bus.floppy.read(0x01) == FloppyController.GoByte.excmd.rawValue)
}
