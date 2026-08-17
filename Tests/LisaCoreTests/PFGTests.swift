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
