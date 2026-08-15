import Foundation
import Testing
@testable import LisaCore

// MARK: - SCC8530: the register-level Z8530 (built-in RS-232 A/B), M7 Task 2
//
// The executable spec of docs/hardware-notes.md §11 -- the driver contract the
// real device replaces the `0xFF` stub against. No CPU is driven (pure device /
// Bus plumbing), so these need no MusashiSuites serialization. Every constant
// cites §11.
//
// Contract highlights the tests below pin:
//   - §11.1 address decode: B-ctrl $FCD201 / A-ctrl $FCD203 / B-data $FCD205 /
//     A-data $FCD207; higher bits undecoded ($FCD241 = channel-B-ctrl mirror).
//   - §11.2 two-step pointer protocol: write reg# (WR0, point-high for 8-15),
//     write value; pointer resets to 0 after each control access; bare read = RR0.
//   - §11.3 channel-B `dinit` sequence programs cleanly.
//   - §11.4 transmit: poll RR0 bit2 (Tx empty, pinned 1) + bit5 (CTS, pinned 0)
//     -> write data byte -> byte reaches the PrinterPort in order.
//   - §11.5 ROM POST probe at $FCD241 returns POST-passing behavior (ACK, any value).

/// Capture double for the channel-B transmit sink (the test stand-in for the
/// M7 ImageWriter interpreter). Records the byte stream in order; `ready` is
/// settable so tests can model a back-pressuring receiver.
private final class CapturePrinterPort: PrinterPort {
    private(set) var bytes: [UInt8] = []
    var ready = true
    func transmit(_ byte: UInt8) { bytes.append(byte) }
    var isReady: Bool { ready }
}

/// Drives one channel the way the OS `WR_SCC` does (§11.2): write the register
/// number to the control port, then the value. Reaches WR8-WR15 by writing the
/// raw register number (the Z8530 "point high" command in bits 3-5).
private func writeReg(_ ch: SCCChannel, _ reg: Int, _ value: UInt8) {
    ch.writeControl(UInt8(reg))
    ch.writeControl(value)
}

// MARK: - §11.2 two-step pointer protocol

@Test func pointerProtocolReachesLowAndHighRegistersThenResets() {
    let ch = SCCChannel(id: .b)

    // Low register (0-7), no point-high: $04 selects WR4 directly.
    writeReg(ch, 4, 0x44)
    #expect(ch.wr[4] == 0x44, "WR4 should hold the value written via the two-step protocol")
    #expect(ch.pointer == 0, "pointer resets to 0 after the value write (§11.2)")

    // High register (8-15) via point-high: writing raw $0B selects WR11.
    writeReg(ch, 11, 0xD0)
    #expect(ch.wr[11] == 0xD0, "WR11 reached via point-high (bits 3-5 = 001, +8)")
    #expect(ch.pointer == 0)

    writeReg(ch, 15, 0xA0)
    #expect(ch.wr[15] == 0xA0, "WR15 reached via point-high")
}

@Test func bareControlReadReturnsRR0AndResetsPointer() {
    let ch = SCCChannel(id: .b)
    // A bare read (no preceding select) returns RR0 (§11.2). RR0 = Tx buffer
    // empty set, CTS clear -> 0x04 (§11.4).
    #expect(ch.readControl() == 0x04, "bare control read returns RR0 = 0x04 (Tx empty, CTS asserted)")

    // Select RR1 (error status), read it, and confirm the pointer then resets
    // so the next bare read is RR0 again.
    ch.writeControl(0x01)                       // WR0: select register 1
    #expect(ch.readControl() == 0x00, "RR1 reads clean (no framing/overrun/parity, §11.4)")
    #expect(ch.readControl() == 0x04, "pointer reset after the RR1 read -> next bare read is RR0")
}

// MARK: - §11.3 channel-B dinit sequence programs cleanly

@Test func channelBDinitSequenceProgramsCleanly() {
    let ch = SCCChannel(id: .b)

    // §11.3 order (WR_SCC = reg#, value). Baud default 1200 -> TC = 94 = $005E.
    _ = ch.readControl()          // step 1: dummy read resets the pointer
    writeReg(ch, 9, 0x4A)          // step 2: reset channel B (clears the file)
    writeReg(ch, 4, 0x44)          // step 3: async, x16, 1 stop, no parity
    writeReg(ch, 11, 0xD0)         // step 4: clock source = oscillator
    writeReg(ch, 14, 0x00)         // step 5: BRG off
    writeReg(ch, 12, 0x5E)         //         TC low
    writeReg(ch, 13, 0x00)         //         TC high
    writeReg(ch, 14, 0x01)         //         BRG on from oscillator
    writeReg(ch, 10, 0x00)         // step 6: NRZ
    writeReg(ch, 3, 0xC1)          // step 7: Rx 8 bits/char, Rx enable
    writeReg(ch, 5, 0xEA)          // step 8: Tx enable + DTR
    writeReg(ch, 15, 0xA0)         // step 9: ext/status ints on Break + CTS
    ch.writeControl(0x10)          // step 10: reset ext/status latch (WR0 cmd)
    writeReg(ch, 1, 0x17)          // step 11: RESTORE -> Rx/Tx/status ints enabled

    #expect(ch.wr[4] == 0x44)
    #expect(ch.wr[11] == 0xD0)
    #expect(ch.wr[12] == 0x5E)
    #expect(ch.wr[13] == 0x00)
    #expect(ch.wr[14] == 0x01)
    #expect(ch.wr[10] == 0x00)
    #expect(ch.wr[3] == 0xC1)
    #expect(ch.wr[5] == 0xEA)
    #expect(ch.wr[15] == 0xA0)
    #expect(ch.wr[1] == 0x17)
    #expect(ch.pointer == 0, "pointer clean after the full sequence")
    #expect(ch.unknownAccesses.isEmpty, "every dinit register is in the modeled subset")
}

// MARK: - §11.4 transmit + ready/handshake

@Test func driverStyleTransmitLoopMovesBytesInOrder() {
    let ch = SCCChannel(id: .b)
    let port = CapturePrinterPort()
    ch.printerPort = port
    writeReg(ch, 1, 0x17)   // Tx interrupts enabled (WR1 bit1) -- dinit end state

    // The RSOUT loop (§11.4 steps 1-4), per byte: read RR0, require Tx buffer
    // empty (bit2) and -- under hardware handshake -- CTS (bit5 == 0), then
    // write the byte to the data register.
    let message: [UInt8] = Array("Hello, Lisa!".utf8)
    for byte in message {
        let rr0 = ch.readControl()                          // step 1: sample status
        #expect(rr0 & 0x04 == 0x04, "RR0 bit2 (Tx buffer empty) must be set to send")
        #expect(~rr0 & 0x20 == 0x20, "channel-B HW handshake: RR0 bit5 (CTS) must read 0 (§11.4 step 3)")
        ch.writeData(byte)                                  // step 4: byte out
    }

    #expect(port.bytes == message, "every byte reaches the PrinterPort in order")
    #expect(ch.transmittedCount == message.count)
}

@Test func readyReadsReportConnectedAndReady() {
    let ch = SCCChannel(id: .b)
    // "Connected and ready to accept a byte" (§11.4): RR0 bit2 set AND, under
    // hardware handshake, RR0 bit5 read 0.
    let rr0 = ch.readControl()
    #expect(rr0 & 0x04 == 0x04, "Tx buffer empty")
    #expect(rr0 & 0x20 == 0x00, "CTS asserted (bit5 = 0)")
    #expect(rr0 & 0x01 == 0x00, "no Rx char pending")
}

@Test func detachedChannelAbsorbsBytesWithoutCrashing() {
    let ch = SCCChannel(id: .b)   // no printerPort attached
    ch.writeData(0x41)
    ch.writeData(0x42)
    #expect(ch.transmittedCount == 2, "bytes are absorbed and counted even with no sink attached")
}

// MARK: - §11.4 step 5 Tx-empty interrupt ack/reset semantics

@Test func txInterruptPendingSetOnSendAndClearedByAckSequence() {
    let ch = SCCChannel(id: .b)
    let port = CapturePrinterPort()
    ch.printerPort = port
    writeReg(ch, 1, 0x17)          // Tx interrupts enabled (bit1)

    ch.writeData(0x5A)
    #expect(ch.txInterruptPending, "sending a byte with Tx ints enabled latches Tx-int-pending")

    // The driver's XMIT ack (§11.4 step 5): WR0=$29 (reset Tx int pending +
    // point WR1), WR1=0, WR0=$38 (reset IUS).
    ch.writeControl(0x29)
    #expect(!ch.txInterruptPending, "WR0=$29 resets Tx-int-pending")
    #expect(ch.pointer == 1, "WR0=$29 also points at WR1 (regSelect bits = 001)")
    ch.writeControl(0x00)          // WR1 = 0
    #expect(ch.wr[1] == 0x00)
    ch.writeControl(0x38)          // WR0=$38 reset highest IUS
    #expect(ch.pointer == 0, "pointer clean after the ack sequence")
}

@Test func txEmptyLatchSetsOnEveryWriteButOnlyAssertsWhenEnabled() {
    // M7 Task 4 transport rework: `txInterruptPending` is the Z8530
    // Tx-buffer-empty LATCH (set on every data write — the buffer goes
    // full→empty instantly for our host sink), distinct from the CPU /INT
    // assertion (`irqAsserted`), which additionally requires Tx interrupts
    // enabled (WR1 bit1) AND the master interrupt enable (WR9 bit3, MIE).
    let ch = SCCChannel(id: .b)
    ch.printerPort = CapturePrinterPort()
    // WR1 = 0 (Tx int disabled), WR9 not programmed (MIE off).
    ch.writeData(0x01)
    #expect(ch.txInterruptPending, "the Tx-empty latch sets on any data write (buffer full→empty)")
    #expect(!ch.irqAsserted, "but /INT is not asserted while Tx interrupts / MIE are off")
}

// MARK: - M7 Task 4: Level-6 Tx-empty interrupt state machine (the live
// print's transport). Grounded in the rsASM XMIT ISR (§11.4 step 5): the
// driver sends the first byte polled, then each Tx-empty interrupt drives the
// next byte until the transfer completes.

@Test func txEmptyInterruptAssertsGatedByWR1AndMIE() {
    let ch = SCCChannel(id: .b)
    ch.printerPort = CapturePrinterPort()

    // dinit: WR9 = $4A (channel-B reset + MIE + NV). Our reset preserves the
    // mode bits (MIE) programmed in that same write.
    writeReg(ch, 9, 0x4A)
    #expect(ch.wr[9] & 0x08 == 0x08, "WR9=$4A leaves MIE (bit3) set after the channel reset")
    writeReg(ch, 1, 0x17)          // Tx/Rx/status interrupts enabled

    // First byte (polled RSOUT) latches Tx-empty; with WR1 bit1 + MIE, /INT asserts.
    ch.writeData(0x41)
    #expect(ch.irqAsserted, "a byte sent with Tx ints + MIE enabled asserts Level 6")

    // XMIT ISR: WR0=$29 (reset Tx int pending) → /INT drops; WR1=0 (disable);
    // WR0=$38 (reset IUS). Then RSOUT sends the next byte WHILE WR1=0.
    ch.writeControl(0x29)
    #expect(!ch.irqAsserted, "WR0=$29 clears the latch, dropping /INT inside the ISR")
    ch.writeControl(0x00)          // WR1 = 0
    ch.writeControl(0x38)
    ch.writeData(0x42)             // next byte, Tx int currently disabled
    #expect(!ch.irqAsserted, "the next byte re-latches but /INT stays low while WR1 bit1 is 0")

    // RESTORE writes WR1=$17 → the pending Tx-empty latch re-asserts /INT,
    // driving the following byte. This is the per-byte re-arm the ISR relies on.
    writeReg(ch, 1, 0x17)
    #expect(ch.irqAsserted, "RESTORE re-enabling WR1=$17 re-asserts /INT for the next byte")

    // Completion: the ISR clears the latch (WR0=$29) and sends NO further byte,
    // so /INT stays low even with WR1=$17 still enabled — no interrupt storm.
    ch.writeControl(0x29)
    #expect(!ch.irqAsserted, "with the latch cleared and no new byte, /INT stays low at end of transfer")
}

// MARK: - M7 Task 4 fix round 1: RR2 modified interrupt vector (the register
// the OS Level-6 RSINT handler dispatches on, source-mover:828-833). Modeled
// explicitly so dispatch is documented, can't silently break, and RR2 reads
// don't saturate the unknown-access log (one entry per print byte otherwise).

@Test func rr2OnChannelBDecodesAsTxEmptyAndDoesNotSpamTheUnknownLog() {
    let ch = SCCChannel(id: .b)
    ch.printerPort = CapturePrinterPort()
    writeReg(ch, 9, 0x4A)                  // MIE
    writeReg(ch, 1, 0x17)                  // Tx int enabled
    ch.writeData(0x55)                     // a pending ch-B Tx-empty interrupt
    #expect(ch.irqAsserted, "precondition: a channel-B Tx-empty interrupt is pending")

    // RSINT: select RR2, read, mask $0E. For ch-B Tx-empty (V3V2V1=000) the
    // masked value is 0 -> "port B, output interrupt" -> XMIT.
    ch.writeControl(0x02)                  // point at RR2
    let rr2 = ch.readControl()
    #expect(rr2 & 0x0E == 0x00, "RR2 masked $0E must decode as channel-B Tx-empty (INTPAR 0 -> XMIT)")

    // The whole point of modeling it: RR2 reads are NOT logged as unknown.
    #expect(ch.unknownAccesses.allSatisfy { $0.register != 2 })
    #expect(ch.unknownAccesses.isEmpty, "no unknown-access spam from RR2 reads")
}

@Test func rr2ModifiesOnlyTheStatusBitsOfTheBaseVector() {
    // The base interrupt vector (WR2) passes through except bits 3-1, which the
    // channel-B modified read forces to the Tx-empty status code (000).
    let ch = SCCChannel(id: .b)
    writeReg(ch, 2, 0xFF)                  // base vector all-ones
    ch.writeControl(0x02)
    let rr2 = ch.readControl()
    #expect(rr2 == 0xF1, "bits 3-1 forced to 000 (ch-B Tx-empty); other vector bits preserved")
    #expect(rr2 & 0x0E == 0x00)
}

@Test func rr2OnChannelAReadsTheUnmodifiedBaseVector() {
    // Channel A returns the base vector unmodified (only channel B carries the
    // status modification on the real Z8530).
    let ch = SCCChannel(id: .a)
    writeReg(ch, 2, 0xFF)
    ch.writeControl(0x02)
    #expect(ch.readControl() == 0xFF, "channel A RR2 is the unmodified WR2 base vector")
}

@Test func sccIRQAssertedIsTheORofBothChannels() {
    let scc = SCC8530()
    #expect(!scc.irqAsserted, "idle: neither channel asserts")
    writeReg(scc.channelB, 9, 0x4A)   // MIE
    writeReg(scc.channelB, 1, 0x17)   // Tx int enable
    scc.channelB.writeData(0x55)
    #expect(scc.irqAsserted, "channel B's Tx-empty interrupt propagates to the chip-level /INT")
}

// MARK: - Unknown-register bounded log

@Test func unknownRegisterWritesAreLoggedAndCapped() {
    let ch = SCCChannel(id: .b)

    // WR7 (a sync-char register the built-in driver never touches) is outside
    // the modeled subset: writing it is inert but logged.
    writeReg(ch, 7, 0x55)
    #expect(ch.wr[7] == 0x00, "unmodeled register is not stored")
    #expect(ch.unknownAccesses == [SCCChannel.UnknownAccess(register: 7, value: 0x55, isWrite: true)])

    // Flood well past the cap and confirm the drop counter takes over.
    for _ in 0..<1000 { writeReg(ch, 6, 0xFF) }
    #expect(ch.unknownAccesses.count <= 256, "log is bounded (cap 256)")
    #expect(ch.unknownDropped > 0, "overflow increments the drop counter, never grows unbounded")
}

// MARK: - §11.1 address decode + §11.5 POST mirror through IODispatcher/Bus

@Test func addressDecodeSelectsChannelAndControlVersusData() {
    let scc = SCC8530()
    let portB = CapturePrinterPort()
    let portA = CapturePrinterPort()
    scc.channelB.printerPort = portB
    scc.channelA.printerPort = portA

    // §11.1: bit1 = channel (0=B, 1=A), bit2 = data (0=ctrl, 1=data). Offsets
    // are the low-17-bit form IODispatcher sees ($FCD2xx -> $D2xx).
    scc.write(address: 0x0000_D205, 0xB1)   // channel B data
    scc.write(address: 0x0000_D207, 0xA1)   // channel A data
    #expect(portB.bytes == [0xB1], "B-data $FCD205 -> channel B")
    #expect(portA.bytes == [0xA1], "A-data $FCD207 -> channel A")

    // Control ports select independently: program WR5 on each channel.
    scc.write(address: 0x0000_D201, 0x05)   // B ctrl: select WR5
    scc.write(address: 0x0000_D201, 0x11)   // B ctrl: WR5 = $11
    scc.write(address: 0x0000_D203, 0x05)   // A ctrl: select WR5
    scc.write(address: 0x0000_D203, 0x22)   // A ctrl: WR5 = $22
    #expect(scc.channelB.wr[5] == 0x11)
    #expect(scc.channelA.wr[5] == 0x22)

    // Control read returns RR0 = 0x04 (§11.4).
    #expect(scc.read(address: 0x0000_D201) == 0x04, "B ctrl bare read = RR0")
    #expect(scc.read(address: 0x0000_D203) == 0x04, "A ctrl bare read = RR0")
}

@Test func romPostProbeReplayAtMirrorIsPostPassing() {
    // §11.5: the Rev H ROM POST touches the SCC once, at $FE10D0, via the
    // undecoded mirror $FCD241 (= $FCD201 | $40, same channel-B-control
    // register): read RR0, write the table $02,$00,$09,$C0,$05,$82
    // (WR2=$00, WR9=$C0 force-reset, WR5=$82), read RR0 again. Values are never
    // compared; POST passes iff the address ACKs (no bus error). Replay it
    // through the real Bus at the physical mirror address.
    let bus = Bus(ramSize: 0x1000)
    #expect(bus.setupMode, "power-on: flat $FCxxxx addressing reaches IODispatcher")

    let mirror: UInt32 = 0xFC_D241
    let pre = bus.read8(mirror)                 // R $FF on the stub; RR0 now
    #expect(pre == 0x04, "the mirror is served by the SCC (RR0), replacing the 0xFF stub -- still an ACK")

    for byte: UInt8 in [0x02, 0x00, 0x09, 0xC0, 0x05, 0x82] {
        bus.write8(mirror, byte)                // move.b (A2)+,(A0)
    }
    let post = bus.read8(mirror)
    #expect(post == 0x04, "post-probe read is served (ACK), POST proceeds -- value is not compared by POST")

    // The probe programmed channel B (the mirror decodes to B-control): WR9=$C0
    // force-reset ran mid-sequence (clearing the file), then WR5=$82 landed.
    #expect(bus.scc.channelB.wr[5] == 0x82, "WR5=$82 written after the WR9=$C0 reset")
    #expect(bus.scc.channelA.wr == [UInt8](repeating: 0, count: 16), "channel A untouched by the channel-B mirror probe")
    #expect(bus.busErrorPulseCount == 0, "no bus error anywhere in the probe (POST-passing)")
}

@Test func sccWindowRoutesAcrossTheWholeD2xxRangeIncludingAliases() {
    // Higher address bits undecoded (§11.1): every $FCD2xx address is the SCC.
    // Spot-check a few aliases of channel-B control ($FCD201, $FCD241, $FCD2C1
    // -- all bit1=0, bit2=0) route to the same register file.
    let bus = Bus(ramSize: 0x1000)
    for alias: UInt32 in [0xFC_D201, 0xFC_D241, 0xFC_D2C1] {
        bus.write8(alias, 0x03)          // select WR3
        bus.write8(alias, 0xC1)          // WR3 = $C1
        #expect(bus.scc.channelB.wr[3] == 0xC1, "alias \(String(alias, radix: 16)) reaches channel-B control")
        #expect(bus.read8(alias) == 0x04, "alias read returns RR0 (ACK)")
        bus.scc.channelB.softReset()
    }
}

// MARK: - Peek path + reset

@Test func peekDoesNotDisturbThePointer() {
    let scc = SCC8530()
    // Select RR1 on channel B, then peek repeatedly: a peek must NOT reset the
    // pointer (the side-effect-free Bus.withPeek path), unlike a real read.
    scc.channelB.writeControl(0x01)                 // select register 1
    #expect(scc.peek(address: 0x0000_D201) == 0x00, "peek returns RR1 without resetting the pointer")
    #expect(scc.peek(address: 0x0000_D201) == 0x00, "still RR1 -- pointer undisturbed by peek")
    #expect(scc.channelB.pointer == 1, "peek left the pointer at 1")
    #expect(scc.read(address: 0x0000_D201) == 0x00, "a real read finally consumes RR1 and resets the pointer")
    #expect(scc.channelB.pointer == 0)
}

@Test func resetClearsRegistersButKeepsPrinterPort() {
    let scc = SCC8530()
    let port = CapturePrinterPort()
    scc.channelB.printerPort = port
    scc.channelB.writeControl(0x05)
    scc.channelB.writeControl(0xEA)      // WR5 = $EA
    scc.channelB.writeData(0x99)         // one byte through

    scc.reset()

    #expect(scc.channelB.wr == [UInt8](repeating: 0, count: 16), "reset returns the WR file to power-on")
    #expect(scc.channelB.transmittedCount == 0, "reset clears the diagnostic counters")
    #expect(scc.channelB.printerPort === port, "the attached sink survives a warm reset (like floppy media)")
}

@Test func machineResetReinitializesTheSCC() throws {
    // The SCC is wired into Machine.reset() alongside the other HLE devices.
    let m = Machine(ramSize: 0x2000)
    let port = CapturePrinterPort()
    m.bus.scc.channelB.printerPort = port
    m.bus.write8(0xFC_D201, 0x05)
    m.bus.write8(0xFC_D201, 0xEA)        // WR5 = $EA
    #expect(m.bus.scc.channelB.wr[5] == 0xEA)

    m.reset()
    #expect(m.bus.scc.channelB.wr[5] == 0x00, "Machine.reset() re-initializes the SCC registers")
    #expect(m.bus.scc.channelB.printerPort === port, "the sink survives Machine.reset()")
}
