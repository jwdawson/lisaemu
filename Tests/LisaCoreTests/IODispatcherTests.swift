import Foundation
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

/// A WORD write to the video latch leaves the ODD (low) byte latched -- the
/// lane a 68000 `MOVE.W` puts the page number on. MacWorks Plus II sets the
/// screen this way (`$003E`); the Rev H ROM and the Lisa OS both use a BYTE
/// write to the even address instead, so both lanes must latch. Regression
/// pin for the "MacWorks Plus II renders physical page 0" bug -- see
/// `IODispatcher.applyNonLatchWrite`'s citation block.
@Test func videoPageLatchTakesTheLowByteOfAWordWrite() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E800, 0x3F)          // start from a ROM-style byte write
    #expect(bus.videoPageLatch == 0x3F)

    bus.write16(0xFC_E800, 0x003E)       // MacWorks-style word write
    #expect(bus.videoPageLatch == 0x3E)
}

/// The even-address byte write the ROM and OS actually use must keep
/// working unchanged after the odd byte started latching -- a lone byte
/// write to `$FCE800` never touches `$FCE801`, so nothing overwrites it.
@Test func videoPageLatchByteWriteToEvenAddressIsUnchanged() {
    let bus = Bus(ramSize: 0x1000)
    bus.write8(0xFC_E800, 0xAF)          // the ROM's own first value
    #expect(bus.videoPageLatch == 0xAF)
    bus.write8(0xFC_E800, 0x2F)          // and its second
    #expect(bus.videoPageLatch == 0x2F)
}

// MARK: - Status register low byte ($F801)

@Test func statusByteIsSoftwareDrivenAlongsideTheActiveLowVsyncBit() {
    let bus = Bus(ramSize: 0x1000)
    // $F801 bit 2 is the vertical-retrace line, ACTIVE-LOW (0 == pending),
    // owned by `videoTiming.pending` -- see the OS-source derivation in
    // docs/rom-trace-notes.md "Checkpoint E" (M4 Task 3) and
    // VideoTimingTests. A bare bus has never fired a vsync, so `pending` is
    // false and bit 2 reads SET. The software-driven `statusByte` owns the
    // OTHER bits; exercise it via bit 1 so the two don't overlap.
    #expect(bus.read8(0xFC_F801) == 0x04, "no vsync pending -> bit 2 set (active-low)")
    bus.statusByte = 0x02   // a non-vsync status bit, software-driven
    #expect(bus.read8(0xFC_F801) == 0x06, "software bit 1 OR'd with the not-pending vsync bit 2")
    // CPU writes to the status register are hardware-driven, not
    // software-settable -- a bus write must not clobber it.
    bus.write8(0xFC_F801, 0xFF)
    #expect(bus.statusByte == 0x02)
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

@Test func boardIdReturnsPepsiClassDiskROMId() {
    // $FCC031 = DiskROMId (LIBHW-DRIVERS:135). M4 Task 4 round 4: the Task-3
    // era 0x00 stub made the OS's BOOT_IO_INIT decode our machine as a Twiggy
    // Lisa 1 (SOURCE-STARTUP:1876-1878: signed byte >= 0 -> iob_lisa), which
    // installed the vestigial TWIGIO stub driver on the boot floppy devrec
    // (SOURCE-CD:750; source-twiggy:1235+1237 -- body compiled out under
    // (*$IFC TWIGGYBUILD*)) and orphaned the FS-mount read (Checkpoint F
    // stall). The Lisa 2/10 machine we model must present a Pepsi-class ID:
    // bit7 set (LIBHW-DRIVERS:581), bit5 clear (not LisaLite, :583), and NOT
    // in [$A0,$DF] (SOURCE-STARTUP:1879-1885's iob_sony/iob_lite ranges) so
    // the decode falls through to the $FCC015 internal-disk check ->
    // iob_pepsi (STARTUP:1886-1890). The specific byte $88 is derived from
    // the decode (any bit7-set value outside [$A0,$DF] with bit5 clear
    // works; the 6504 disk ROM itself is not in the source tree) -- see
    // docs/hardware-notes.md "Board IDs".
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_C031) == 0x88)
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

// MARK: - ioTrace debugger controls (M8 tooling)

@Test func clearIOTraceEmptiesTheBufferAndTheDropCounter() {
    // The cap is a TOTAL, not a per-slice window: once a long boot has
    // filled it, every later access is dropped and `g`'s "I/O touches this
    // slice" list is silently empty. Clearing is what makes a late-boot
    // slice observable at all (docs/macworks-plus-notes.md P0).
    let bus = Bus(ramSize: 0x1000)
    for i in 0..<5000 {
        _ = bus.read8(0xFC_1000 &+ UInt32(i % 0x100))
    }
    #expect(bus.ioTraceDropped > 0)

    bus.clearIOTrace()

    #expect(bus.ioTrace.isEmpty)
    #expect(bus.ioTraceDropped == 0)

    _ = bus.read8(0xFC_1234)
    #expect(bus.ioTrace.count == 1, "recording resumes after a clear")
}

@Test func ioTraceLimitIsAdjustable() {
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.ioTraceLimit == 4096, "default cap unchanged")

    bus.ioTraceLimit = 10
    for i in 0..<25 {
        _ = bus.read8(0xFC_1000 &+ UInt32(i))
    }
    #expect(bus.ioTrace.count == 10)
    #expect(bus.ioTraceDropped == 15)

    // Raising the cap lets recording resume without discarding what is
    // already held (a lowered cap likewise never truncates retroactively).
    bus.ioTraceLimit = 12
    _ = bus.read8(0xFC_1234)
    #expect(bus.ioTrace.count == 11)
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
    // hardware-register behavior (DiskROMId, $88 -- see
    // boardIdReturnsPepsiClassDiskROMId), not become a plain window byte.
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.read8(0xFC_C031) == 0x88)
    bus.write8(0xFC_C031, 0x42)   // hardware-driven; CPU writes have no effect
    #expect(bus.read8(0xFC_C031) == 0x88)
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

// MARK: - Widget/ProFile VIA1 routing (M5 Task 2, docs/hardware-notes.md §10)

@Test func widgetRegionIsIdleAndDisconnectedByDefault() {
    // No widget attached (the default): HWSTATUS ($FCDC01) reads DISCONNECT
    // asserted (bit 0 = 1) and the HWBASE register file at $FCD801 does not
    // crash / reads as an idle bus. The no-widget boot path is unmoved.
    let bus = Bus(ramSize: 0x1000)
    #expect(!bus.widget.isAttached)
    #expect(bus.read8(0xFC_DC01) & 0x01 == 0x01, "detached: DISCONNECT (Port B bit 0) asserted")
}

@Test func widgetHwbaseAndHwstatusRouteThroughTheBusToTheDrive() throws {
    // Attaching a Widget and driving the HWBASE=$FCD801 register file through
    // the REAL Bus must reach WidgetDrive: HWSTATUS ($FCDC01) reflects the
    // connected state, and a CMD strobe on Port B ($FCD801 reg 0) + an ORA
    // read ($FCD809 reg 1, DDRA=0 input) returns the $01 idle->ready response
    // (§10.1-10.3). Proves the $D801 decode widening + Port-B forward + Port-A
    // input wiring end-to-end.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iodisp-widget-\(UUID().uuidString).widget")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try WidgetImage(createBlankAt: url, blockCount: 8)

    let bus = Bus(ramSize: 0x1000)
    bus.widget.attach(image)

    // Connected: HWSTATUS DISCONNECT bit clear. (DDRB=0 at reset, so reg-0
    // read passes WidgetDrive.portBInput straight through.)
    #expect(bus.read8(0xFC_DC01) & 0x01 == 0x00)

    // Ready handshake (M5 Task 3 transport): CMD false->true (DIR=in) on Port B,
    // then read the response off PORTA (reg 15, $FCD879 -- the no-handshake ORA
    // the driver's DOSHAKE actually reads, PROFASM:1663).
    bus.write8(0xFC_D801, 0x18)   // reg 0: CMD false, DIR in
    bus.write8(0xFC_D801, 0x08)   // reg 0: CMD asserted -> present ready code, BSY->0
    #expect(bus.read8(0xFC_D879) == 0x01, "PORTA (reg 15) should read the $01 idle->ready response")
    // BSY (Port B bit 1) is a LEVEL: 0 while CMD held (controller busy/present),
    // 1 once CMD is released (idle/ready) -- PROFASM WAIT_BUSY/WAIT_NOTBUSY.
    #expect(bus.read8(0xFC_DC01) & 0x02 == 0x00, "BSY = 0 while CMD asserted")
    bus.write8(0xFC_D801, 0x18)   // reg 0: CMD deasserted
    #expect(bus.read8(0xFC_DC01) & 0x02 == 0x02, "BSY = 1 once CMD deasserts")
}

@Test func widgetPortBStrobeRoutesThroughTheROMParallelBaseD901() throws {
    // **M5 Task 4 -- boot-from-Widget.** The boot ROM's own parallel-port boot
    // routine (`prof_entry` = $FE1F70) bit-bangs the ProFile CMD/DIR strobe on
    // VIA1 PORT B at base **$FCD901** (`A0 = $FCD901`, docs/rom-trace-notes.md
    // "Checkpoint K"), NOT the OS driver's $FCD801. $FCD801/$FCD901 alias the
    // SAME physical VIA1 PORTB register (viaRegisterIndex maps both to
    // (via:1,index:0)), so a CMD strobe through the $D901 alias must reach the
    // Widget exactly like the $D801 path above -- this is what lets the ROM
    // probe + boot the disk (before the fix the $D901 alias was excluded and
    // STARTUP FROM never listed the Widget). Data/BSY reads already reached the
    // drive at $D901 (same VIA instance); the gap was the Port-B WRITE forward.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iodisp-widget-d901-\(UUID().uuidString).widget")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try WidgetImage(createBlankAt: url, blockCount: 8)

    let bus = Bus(ramSize: 0x1000)
    bus.widget.attach(image)

    // The ROM's handshake, driven entirely through the $FCD901 alias:
    bus.write8(0xFC_D901, 0x18)   // reg 0 ($D901): CMD false, DIR in
    bus.write8(0xFC_D901, 0x08)   // reg 0: CMD asserted -> present ready code, BSY->0
    // Response byte on PORTA reg 15 ($FCD979 = $D901 + 15*8), and BSY on
    // PORTB bit 1 read back at $FCD901 (reg 0, DDRB=0 input at reset) -- the
    // ROM reads both off this base, not the $DC01 mirror.
    #expect(bus.read8(0xFC_D979) == 0x01, "PORTA (reg 15) via $D901 reads the $01 idle->ready response")
    #expect(bus.read8(0xFC_D901) & 0x02 == 0x00, "BSY = 0 while CMD asserted (read via $D901 PORTB)")
    bus.write8(0xFC_D901, 0x18)   // CMD deasserted
    #expect(bus.read8(0xFC_D901) & 0x02 == 0x02, "BSY = 1 once CMD deasserts")
}

@Test func widgetPortBForwardIgnoresNonPortBVia1Offsets() throws {
    // The forward is gated to VIA1 register 0 (PORTB/ORB) only. A write to a
    // DIFFERENT VIA1 register at the $D901 base -- e.g. DDRB (index 2, offset
    // $10) or a timer -- must NOT be mistaken for a CMD strobe. The floppy
    // read routine ($FE1E04) writes VIA1 DDRB (to make PB6 an input) on the
    // shared base every boot; that traffic must leave the Widget idle. Here:
    // DDRB writes with the CMD bit both clear and set leave BSY = 1 (idle),
    // proving no phantom CMD assertion.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iodisp-widget-guard-\(UUID().uuidString).widget")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try WidgetImage(createBlankAt: url, blockCount: 8)

    let bus = Bus(ramSize: 0x1000)
    bus.widget.attach(image)

    bus.write8(0xFC_D901 + 0x10, 0xFF)   // DDRB1 (index 2) with the CMD-bit position set
    bus.write8(0xFC_D901 + 0x50, 0x00)   // SR1 (index 10) -- not PORTB
    bus.write8(0xFC_D901 + 0x30, 0x00)   // T1LL1 (index 6, a timer latch) -- not PORTB
    // Assert on the drive's own view (bypasses VIA read-back DDR semantics):
    // the CMD line was never asserted, so BSY stays high (idle) and no
    // transaction opened.
    #expect(bus.widget.portBInput & 0x02 == 0x02,
            "BSY stays 1 (idle) -- non-PORTB VIA1 writes never assert the Widget CMD")
    #expect(bus.widget.completedCommands == 0, "no command was opened by non-PORTB traffic")
}

// MARK: - $C015 adr_intdisk drive capability (M8)

/// `$FCC015` distinguishes drive types for the OS: 0 = Twiggy, 1 =
/// single-sided Sony, 2 = double-sided Sony (STARTUP:1747-1748). It was a
/// static `1` stub, which M3 Task 3 flagged as inconsistent with
/// `FloppyController.insert(_:)` happily accepting an 800K double-sided
/// image and setting DISKFLG for it. M8 derives the byte from the media so
/// the two signals can no longer disagree -- needed by MacWorks Plus, whose
/// hard-disk install ships on an 800K diskette.
@Test func intDiskIdReflectsInsertedMediaSidedness() throws {
    let bus = Bus(ramSize: 0x1000)

    #expect(bus.read8(0xFC_C015) == 1, "empty drive keeps the single-sided Sony default")

    bus.floppy.insert(try makeSidedImage(blockCount: 800))
    #expect(bus.read8(0xFC_C015) == 1, "400K single-sided reads 1, exactly as before")

    bus.floppy.insert(try makeSidedImage(blockCount: 1600))
    #expect(bus.read8(0xFC_C015) == 2, "800K double-sided reads 2")
    #expect(bus.floppy.read(FloppyController.Cell.diskFlg) == 1,
            "DISKFLG agrees -- the two signals can no longer contradict")

    bus.floppy.eject()
    #expect(bus.read8(0xFC_C015) == 1)
}

/// Minimal DC42 container with a chosen block count (data plane only, zero
/// tags -- `DC42Image` synthesizes the tag plane).
private func makeSidedImage(blockCount: Int) throws -> DC42Image {
    var container = Data([UInt8("T".utf8.first!)])
    container = Data([1]) + container
    container.append(Data(repeating: 0, count: 64 - container.count))
    var dataLen = UInt32(blockCount * 512).bigEndian
    container.append(Data(bytes: &dataLen, count: 4))
    var tagLen: UInt32 = 0
    container.append(Data(bytes: &tagLen, count: 4))
    container.append(Data(repeating: 0, count: 12))
    container.append(Data(repeating: 0, count: blockCount * 512))
    return try DC42Image(data: container)
}
