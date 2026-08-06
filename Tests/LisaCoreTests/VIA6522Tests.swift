import Testing
@testable import LisaCore

// Datasheet-driven, CPU-free tests for the standalone 6522 VIA register
// file (`VIA6522`). No `Bus`/`Machine`/`M68K` involved -- these construct
// `VIA6522` directly and drive it purely through `read`/`write`/`peek`/
// `tick`, matching how `IODispatcher` (a different, address-mapping layer)
// will use it. Because no CPU is driven, this suite does NOT need
// `MusashiSuites` serialization -- see `IODispatcherTests.swift`'s header
// comment for the same reasoning.
//
// Register index map: 0=ORB/IRB 1=ORA/IRA 2=DDRB 3=DDRA 4=T1C-L 5=T1C-H
// 6=T1L-L 7=T1L-H 8=T2C-L 9=T2C-H 10=SR 11=ACR 12=PCR 13=IFR 14=IER
// 15=ORA (no handshake). See `VIA6522`'s type doc comment for the full
// semantics table this file tests against.

// MARK: - Timer 1: one-shot

@Test func t1OneShotFiresOnceThenIsSilentUntilRearmed() {
    let via = VIA6522()
    via.write(11, 0x00)   // ACR: bit6=0 -> one-shot
    via.write(6, 5)       // T1L-L latch = 5
    via.write(5, 0)       // T1C-H write: loads counter=(0<<8)|5=5, arms, clears IFR6

    via.tick(cycles: 6)   // period+1 cycles to reach the underflow instant
    #expect(via.read(13) == 0x40, "IFR6 (T1) should be set on underflow")

    // T1C-L read returns the wrapped counter's low byte AND clears IFR6.
    #expect(via.read(4) == 0xFF, "counter free-wraps to $FFFF on a one-shot underflow")
    #expect(via.read(13) == 0x00, "T1C-L read clears IFR6")

    // A full further 16-bit wrap with NO reload (one-shot, not re-armed):
    // must NOT refire.
    via.tick(cycles: 0x1_0000)
    #expect(via.read(13) == 0x00, "one-shot must not refire without an explicit T1C-H reload")

    // Re-arming (another T1C-H write) lets it fire again.
    via.write(6, 5)
    via.write(5, 0)
    via.tick(cycles: 6)
    #expect(via.read(13) == 0x40, "re-armed one-shot fires again")
}

// MARK: - Timer 1: free-run

@Test func t1FreeRunReloadsAndRefiresEveryPeriod() {
    let via = VIA6522()
    via.write(11, 0x40)   // ACR bit6=1 -> free-run
    via.write(6, 5)       // T1L-L latch = 5
    via.write(5, 0)       // T1C-H write: loads counter=5, clears IFR6

    via.tick(cycles: 6)
    #expect(via.read(13) == 0x40, "first underflow sets IFR6")
    #expect(via.read(4) == 5, "free-run reloads the counter from the latches on underflow")
    #expect(via.read(13) == 0x00, "T1C-L read clears IFR6")

    // Unlike one-shot, free-run refires every period with no further reload.
    via.tick(cycles: 6)
    #expect(via.read(13) == 0x40, "free-run refires on the next underflow")
}

// MARK: - Timer 1 latches: read-back, no IFR side effects except T1L-H write

@Test func t1LatchesReadBackWrittenValuesWithoutTouchingCounterOrIFR() {
    // Mirrors the ROM's VIA2 self-test pattern exactly (rom-trace-notes.md
    // "The hard stall": clear each latch, write $FF, read back expecting
    // the written value -- the ROM does this 256 times against T1L-L/T1L-H
    // (offsets $DD8D/$DD8F); this exercises the same read/write path this
    // emulator serves those offsets through (`IODispatcher` -> register
    // indices 6/7).
    let via = VIA6522()
    for _ in 0..<8 {
        via.write(6, 0x00)
        #expect(via.read(6) == 0x00)
        via.write(6, 0xFF)
        #expect(via.read(6) == 0xFF)
        via.write(7, 0x00)
        #expect(via.read(7) == 0x00)
        via.write(7, 0xFF)
        #expect(via.read(7) == 0xFF)
    }
    // T1L-L writes never touch IFR.
    #expect(via.read(13) == 0x00)
}

@Test func t1LHWriteClearsIFR6() {
    let via = VIA6522()
    via.write(11, 0x00)
    via.write(6, 5)
    via.write(5, 0)
    via.tick(cycles: 6)
    #expect(via.read(13) == 0x40, "precondition: IFR6 set")

    via.write(7, 0x00)   // T1L-H write -- brief: "cleared by T1CL read / T1LH write"
    #expect(via.read(13) == 0x00, "T1L-H write clears IFR6")
}

// MARK: - Timer 2: one-shot

@Test func t2OneShotUnderflowSetsIFR5ClearedByT2CLRead() {
    let via = VIA6522()
    via.write(8, 5)   // T2C-L write: low-order latch = 5
    via.write(9, 0)   // T2C-H write: loads counter=5, arms, clears IFR5

    via.tick(cycles: 6)
    #expect(via.read(13) == 0x20, "IFR5 (T2) set on underflow")

    #expect(via.read(8) == 0xFF, "T2C-L read returns the wrapped counter low byte")
    #expect(via.read(13) == 0x00, "T2C-L read clears IFR5")

    // T2 (as scoped here) is one-shot only: no refire without reload.
    via.tick(cycles: 0x1_0000)
    #expect(via.read(13) == 0x00)
}

// MARK: - IER set/clear protocol

@Test func ierSetClearProtocolAndAlwaysReadsBit7Set() {
    let via = VIA6522()
    via.write(14, 0x80 | 0x40)   // bit7=1 (set mode): enable bit6
    #expect(via.read(14) == 0xC0, "IER read always has bit7 set")

    via.write(14, 0x40)          // bit7=0 (clear mode): disable bit6
    #expect(via.read(14) == 0x80, "bit6 cleared, nothing else was ever enabled")

    via.write(14, 0x80 | 0x60)   // enable bit6+bit5
    via.write(14, 0x20)          // clear mode: clear only bit5
    #expect(via.read(14) == 0xC0, "bit6 untouched by clearing bit5")
}

// MARK: - IFR master bit (bit 7) and write-1-to-clear

@Test func ifrMasterBitOnlyReflectsEnabledFlags() {
    let via = VIA6522()
    via.write(14, 0x80 | 0x40)   // enable T1 (IER bit6)
    via.write(11, 0x00)
    via.write(6, 5)
    via.write(5, 0)
    via.tick(cycles: 6)          // T1 underflows -> IFR6 set

    #expect(via.read(13) == 0xC0, "IFR6 flag + bit7 master (enabled & flagged)")
    #expect(via.irqAsserted == true)

    via.write(14, 0x40)          // disable T1 in IER (clear mode)
    #expect(via.peek(13) & 0x80 == 0, "master bit clears once the flag is no longer enabled")
    #expect(via.peek(13) & 0x40 != 0, "the raw flag bit itself is untouched by IER changes")
    #expect(via.irqAsserted == false)
}

@Test func writingIFRClearsOnlyTheWrittenBits() {
    let via = VIA6522()
    // Fire both T1 and T2 once so IFR6 and IFR5 are both set.
    via.write(11, 0x00)
    via.write(6, 5); via.write(5, 0); via.tick(cycles: 6)
    via.write(8, 5); via.write(9, 0); via.tick(cycles: 6)
    #expect(via.peek(13) & 0x60 == 0x60, "precondition: both IFR5 and IFR6 set")

    via.write(13, 0x40)   // write 1 to bit6 only -> clears just that bit
    #expect(via.peek(13) & 0x40 == 0, "bit6 cleared")
    #expect(via.peek(13) & 0x20 != 0, "bit5 untouched")
}

// MARK: - Port A/B: DDR-mixed reads, output latches

@Test func portBReadMixesOutputLatchWithInputPinsPerDDR() {
    let via = VIA6522()
    via.write(2, 0x0F)     // DDRB: low nibble output, high nibble input
    via.write(0, 0xAA)     // ORB = 1010_1010
    via.portBInput = { 0x55 }   // 0101_0101

    // (orb & ddrb) | (input & ~ddrb) = (0xAA & 0x0F) | (0x55 & 0xF0) = 0x0A | 0x50
    #expect(via.read(0) == 0x5A)
}

@Test func portAIndex1And15ShareStorageWithNoHandshakeDifferenceModeled() {
    let via = VIA6522()
    via.write(3, 0xF0)     // DDRA: high nibble output, low nibble input
    via.write(1, 0xCC)     // ORA via the normal (handshake) register
    via.portAInput = { 0x33 }

    // (ora & ddra) | (input & ~ddra) = (0xCC & 0xF0) | (0x33 & 0x0F) = 0xC0 | 0x03
    #expect(via.read(1) == 0xC3)
    #expect(via.read(15) == 0xC3, "index 15 (no-handshake ORA) reads the same underlying register")

    via.write(15, 0x99)    // write through the no-handshake alias
    // (0x99 & 0xF0) | (0x33 & 0x0F) = 0x90 | 0x03
    #expect(via.read(1) == 0x93, "index 1 sees the write index 15 made -- shared storage")
}

// MARK: - Peek discipline: side-effect-free, unlike read

@Test func peekDoesNotClearIFRUnlikeRead() {
    let via = VIA6522()
    via.write(11, 0x00)
    via.write(6, 5)
    via.write(5, 0)
    via.tick(cycles: 6)
    #expect(via.peek(13) & 0x40 != 0, "precondition: IFR6 set")

    #expect(via.peek(4) == 0xFF, "peek returns the same value read(4) would")
    #expect(via.peek(13) & 0x40 != 0, "peek(4) must NOT clear IFR6 -- unlike a real read(4)")

    #expect(via.read(4) == 0xFF, "a real read of the same register...")
    #expect(via.peek(13) & 0x40 == 0, "...DOES clear IFR6")
}

@Test func peekOfDDRMixedPortMatchesReadWithNoSideEffect() {
    let via = VIA6522()
    via.write(2, 0xFF)
    via.write(0, 0x42)
    #expect(via.peek(0) == via.read(0))
}

// MARK: - Hardware reset (M2 Task 2)

@Test func resetClearsDDRsORsACRPCRIERIFRAndDisarmsTimers() {
    let via = VIA6522()
    via.write(2, 0xFF)     // DDRB
    via.write(3, 0xFF)     // DDRA
    via.write(0, 0x11)     // ORB
    via.write(1, 0x22)     // ORA
    via.write(11, 0x40)    // ACR: T1 free-run
    via.write(12, 0xC9)    // PCR
    via.write(14, 0x82)    // IER: enable bit1
    via.write(6, 5)        // T1LL
    via.write(5, 0)        // T1CH: loads + arms T1 (free-run)
    via.tick(cycles: 6)    // let it fire once, confirming it was really armed
    #expect(via.read(13) == 0x40, "precondition: T1 fired and set IFR6")

    via.reset()

    #expect(via.peek(2) == 0, "DDRB cleared")
    #expect(via.peek(3) == 0, "DDRA cleared")
    #expect(via.peek(11) == 0, "ACR cleared")
    #expect(via.peek(12) == 0, "PCR cleared")
    #expect(via.peek(14) == 0x80, "IER cleared (bit7 is always-synthesized, not stored)")
    #expect(via.peek(13) == 0x00, "IFR cleared, no bits, no synthesized master bit")
    #expect(via.irqAsserted == false)

    // Timers stopped: a full 16-bit wrap with no reload must NOT set any
    // further IFR flag, even though ACR/T1 were free-run and armed right
    // before reset (see `VIA6522.reset()`'s doc comment on this exact
    // simplification vs. some datasheets' "T1/T2 unaffected by RES").
    via.tick(cycles: 0x1_0000)
    #expect(via.peek(13) == 0x00, "T1 must not refire after reset without an explicit reload")
}

@Test func resetLeavesUnaffectedRegistersReadableForATestFollowingReload() {
    // After reset, a fresh reload (matching real post-reset software
    // init) must still successfully re-arm and fire -- reset must not
    // leave the VIA in some permanently-disarmed state.
    let via = VIA6522()
    via.write(11, 0x00)
    via.write(6, 5)
    via.write(5, 0)
    via.tick(cycles: 6)
    via.reset()

    via.write(6, 5)
    via.write(5, 0)   // re-arm one-shot T1
    via.tick(cycles: 6)
    #expect(via.read(13) == 0x40, "T1 fires again once explicitly re-armed after reset")
}
