import Testing
@testable import LisaCore

/// The PFG (Programmable Frequency Generator) responder — the optional board
/// MacWorks Plus II 2.5 requires in the SCC socket. See `PFG` for the
/// protocol and its provenance.
///
/// The most important tests here are the DETACHED ones: a stock Lisa has no
/// PFG, and nothing about the SCC may change when none is installed.
@Suite struct PFGTests {

    // MARK: - Detached (a stock Lisa) -- nothing may change

    @Test func detachedSCCReportsTheSameRR0AsBefore() {
        let scc = SCC8530()
        // $04: bit2 Tx-buffer-empty set, bit3 DCD clear, bit5 CTS clear.
        #expect(scc.read(address: 0xD201) == 0x04)
        #expect(scc.read(address: 0xD203) == 0x04)
    }

    @Test func detachedWR7WriteStillLandsInTheUnknownLog() {
        let scc = SCC8530()
        scc.write(address: 0xD203, 0x07)   // pointer = 7
        scc.write(address: 0xD203, 0x50)   // WR7 = $50
        #expect(scc.channelA.unknownAccesses.contains(
            SCCChannel.UnknownAccess(register: 7, value: 0x50, isWrite: true)))
    }

    // MARK: - Attached

    /// Drives the exact byte sequence captured from MacWorks Plus II 2.5.0's
    /// probe and checks the assembled 16-bit word -- in particular that its
    /// low nibble is `$A`, which is the whole thing the guest tests.
    @Test func attachedProbeAssemblesAnIdentityWhoseLowNibbleIsA() {
        let scc = SCC8530()
        scc.pfg = PFG()

        func writeWR7(_ value: UInt8) {
            scc.write(address: 0xD203, 0x07)   // ch-A pointer = 7
            scc.write(address: 0xD203, value)  // ch-A WR7 = value
        }
        func sampleDCD() -> Int {
            // ch-B bare control read = RR0; bit 3 is DCD.
            (scc.read(address: 0xD201) & 0x08) != 0 ? 1 : 0
        }

        writeWR7(PFG.openCommand)

        var assembled: UInt16 = 0
        for pair in 0..<8 {
            writeWR7(0x00)
            writeWR7(PFG.firstAddress + UInt8(2 * pair))
            assembled = (assembled << 1) | UInt16(sampleDCD())
            writeWR7(PFG.strobeCommand)
            assembled = (assembled << 1) | UInt16(sampleDCD())
        }

        #expect(assembled == 0x000A)
        #expect(assembled & 0x0F == 0x0A)   // the guest's `andi.w #$f` check
    }

    /// The identity is a property of the board, so a different one shifts out
    /// verbatim -- the seam for correcting the upper 12 bits if a guest is
    /// ever seen caring about them.
    @Test func identityIsShiftedOutMSBFirst() {
        let scc = SCC8530()
        let pfg = PFG()
        pfg.identity = 0xB35A
        scc.pfg = pfg

        func writeWR7(_ value: UInt8) {
            scc.write(address: 0xD203, 0x07)
            scc.write(address: 0xD203, value)
        }
        var assembled: UInt16 = 0
        writeWR7(PFG.openCommand)
        for pair in 0..<8 {
            writeWR7(0x00)
            writeWR7(PFG.firstAddress + UInt8(2 * pair))
            assembled = (assembled << 1) | UInt16((scc.read(address: 0xD201) & 0x08) != 0 ? 1 : 0)
            writeWR7(PFG.strobeCommand)
            assembled = (assembled << 1) | UInt16((scc.read(address: 0xD201) & 0x08) != 0 ? 1 : 0)
        }
        #expect(assembled == 0xB35A)
    }

    @Test func detachingRestoresTheIdleDCDLine() {
        let scc = SCC8530()
        scc.pfg = PFG()
        scc.write(address: 0xD203, 0x07)
        scc.write(address: 0xD203, 0x1C)   // select the pair carrying a 1 bit
        #expect(scc.read(address: 0xD201) & 0x08 == 0x08)

        scc.pfg = nil
        #expect(scc.read(address: 0xD201) == 0x04)
    }

    // MARK: - PRAM EEPROM (Microwire, 256 x 8)

    /// Drives a Microwire frame the way the guest does: CS asserted on every
    /// byte, data on bit 1, clocked by bit 3.
    private func microwire(_ pfg: PFG, bits: [Int]) -> [Int] {
        var out: [Int] = []
        for bit in bits {
            let di = UInt8(bit) << 1
            pfg.writeCommand(0x04 | di)          // CS high, SK low
            pfg.writeCommand(0x04 | 0x08 | di)   // CS high, SK rising
            out.append(pfg.dcdAsserted ? 1 : 0)
        }
        return out
    }

    private func frameBits(start: Int = 1, opcode: [Int], address: UInt8,
                           data: UInt8? = nil, trailing: Int = 0) -> [Int] {
        var bits = [0, 0, start] + opcode
        bits += (0..<8).map { Int((address >> (7 - $0)) & 1) }
        if let data { bits += (0..<8).map { Int((data >> (7 - $0)) & 1) } }
        bits += Array(repeating: 0, count: trailing)
        return bits
    }

    /// A factory-fresh EEPROM reads all-ones, and a READ shifts the byte out
    /// on DO MSB-first after the 93Cxx leading dummy zero.
    @Test func eepromReadOfAnErasedCellShiftsOutAllOnes() {
        let pfg = PFG()
        let out = microwire(pfg, bits: frameBits(opcode: [1, 0], address: 0x0C, trailing: 8))
        // The 8 data bits follow the dummy 0 that lands on the frame's last
        // address clock.
        #expect(out.suffix(8) == [1, 1, 1, 1, 1, 1, 1, 1])
    }

    /// The exact frame captured from MacWorks Plus II: 6 dummy clocks, start
    /// bit, opcode 10 (READ), address $0C -- see hardware-notes.md §13.
    @Test func eepromDecodesTheCapturedMacWorksReadFrame() {
        let pfg = PFG()
        pfg.eeprom[0x0C] = 0x5A
        var bits = Array(repeating: 0, count: 6) + [1, 1, 0]
        bits += (0..<8).map { Int((UInt8(0x0C) >> (7 - $0)) & 1) }
        bits += Array(repeating: 0, count: 8)
        let out = microwire(pfg, bits: bits)
        #expect(out.suffix(8) == [0, 1, 0, 1, 1, 0, 1, 0])   // $5A, MSB first
    }

    @Test func eepromWriteNeedsWriteEnableAndThenRoundTrips() {
        let pfg = PFG()

        // WRITE while not enabled: ignored (a real 93Cxx powers up disabled).
        _ = microwire(pfg, bits: frameBits(opcode: [0, 1], address: 0x20, data: 0x3C))
        #expect(pfg.eeprom[0x20] == 0xFF)

        // EWEN: opcode 00 with the top address bits 11.
        _ = microwire(pfg, bits: frameBits(opcode: [0, 0], address: 0xC0))
        _ = microwire(pfg, bits: frameBits(opcode: [0, 1], address: 0x20, data: 0x3C))
        #expect(pfg.eeprom[0x20] == 0x3C)

        let out = microwire(pfg, bits: frameBits(opcode: [1, 0], address: 0x20, trailing: 8))
        #expect(out.suffix(8) == [0, 0, 1, 1, 1, 1, 0, 0])   // $3C
    }

    /// The EEPROM is non-volatile: a reset clears the serial interface but
    /// not the stored bytes, exactly as the real board behaves.
    @Test func resetPreservesEEPROMContents() {
        let pfg = PFG()
        _ = microwire(pfg, bits: frameBits(opcode: [0, 0], address: 0xC0))   // EWEN
        _ = microwire(pfg, bits: frameBits(opcode: [0, 1], address: 0x11, data: 0x99))
        pfg.reset()
        #expect(pfg.eeprom[0x11] == 0x99)
    }

    /// The identity path and the EEPROM share one command port, split by
    /// bit 4 -- driving one must not disturb the other.
    @Test func identityStillWorksAfterAnEEPROMFrame() {
        let scc = SCC8530()
        scc.pfg = PFG()
        _ = microwire(scc.pfg!, bits: frameBits(opcode: [1, 0], address: 0x00, trailing: 8))

        func writeWR7(_ value: UInt8) {
            scc.write(address: 0xD203, 0x07)
            scc.write(address: 0xD203, value)
        }
        var assembled: UInt16 = 0
        writeWR7(PFG.openCommand)
        for pair in 0..<8 {
            writeWR7(0x00)
            writeWR7(PFG.firstAddress + UInt8(2 * pair))
            assembled = (assembled << 1) | UInt16((scc.read(address: 0xD201) & 0x08) != 0 ? 1 : 0)
            writeWR7(PFG.strobeCommand)
            assembled = (assembled << 1) | UInt16((scc.read(address: 0xD201) & 0x08) != 0 ? 1 : 0)
        }
        #expect(assembled & 0x0F == 0x0A)
    }

    @Test func commandLogIsBoundedAndCounts() {
        let pfg = PFG()
        for _ in 0..<600 { pfg.writeCommand(0x08) }
        #expect(pfg.commandLog.count == 512)
        #expect(pfg.commandLogDropped == 88)
    }

    /// Unsequenced strobes and unmodeled commands (the real board's timing
    /// commands among them) are accepted without effect -- we have no
    /// evidence for an error behavior and will not invent one.
    @Test func unmodeledCommandsAreAcceptedWithNoEffect() {
        let scc = SCC8530()
        scc.pfg = PFG()
        scc.write(address: 0xD203, 0x07)
        scc.write(address: 0xD203, 0xC3)   // not open/strobe/address
        #expect(scc.read(address: 0xD201) == 0x04)   // DCD still idle
        #expect(scc.pfg?.commandLog == [0xC3])
    }
}
