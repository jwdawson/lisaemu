import Foundation
import Testing
@testable import LisaCore

/// M2 Task 5 -- "Trace checkpoint C: the ROM meets the disk". The real Rev H
/// boot ROM, driven through its own startup menu, reads block 0 off an
/// inserted `.dc42` floppy image (via the `FloppyController` HLE) and executes
/// the boot block. Env-gated on BOTH `LISAEMU_ROM_DIR` (the interleaved ROM)
/// and `LISAEMU_DISK_DIR` (a directory holding `OS31_Install_1.dc42`); every
/// assertion here is anchored to an observation documented in
/// `docs/rom-trace-notes.md` "Floppy boot (checkpoint C)".
///
/// Nested under `MusashiSuites` because it builds a `Machine` (Musashi is a
/// process-global singleton; only one live `Machine` per test).
private let fRomDir = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]
private let fDiskDir = ProcessInfo.processInfo.environment["LISAEMU_DISK_DIR"]

extension MusashiSuites {
    @Suite(.enabled(if: fRomDir != nil && fDiskDir != nil,
                    "Set LISAEMU_ROM_DIR and LISAEMU_DISK_DIR to run floppy-boot tests"))
    struct ROMFloppyBootTests {
        private func bootedWithDisk() throws -> Machine {
            let rom = try ROMImage.load(directory: URL(fileURLWithPath: fRomDir!))
            let m = Machine(ramSize: 0x20_0000)
            m.bus.loadROM(rom)
            m.reset()
            let img = try DC42Image.load(url: URL(fileURLWithPath: fDiskDir! + "/OS31_Install_1.dc42"))
            m.bus.floppy.insert(img)
            return m
        }

        private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
            return h
        }

        /// Walks the ROM's on-screen cursor (`$496`/`$498`) to `(tx,ty)` by
        /// feeding relative mouse-delta packets through `COPS.postMouse`
        /// (the emulator's only mouse channel -- see EmulationController) --
        /// the same technique as the M1c input backstop test.
        private func moveCursor(_ m: Machine, to tx: Int, _ ty: Int) {
            for _ in 0..<24 {
                let cx = Int(m.bus.read16(0x496)), cy = Int(m.bus.read16(0x498))
                if abs(cx - tx) <= 1 && abs(cy - ty) <= 1 { return }
                m.bus.cops.postMouse(dx: Int8(max(-120, min(120, tx - cx))),
                                     dy: Int8(max(-120, min(120, ty - cy)))                )
                m.run(until: m.cycles + 250_000)
            }
        }

        /// A mouse click = button-down keycap `$06` then button-up (the menu
        /// hit-tests on the down and acts on the up; `mouseButtonKeycap` in
        /// EmulationController).
        private func click(_ m: Machine) {
            m.bus.cops.postKey(code: 0x06, down: true)
            m.run(until: m.cycles + 300_000)
            m.bus.cops.postKey(code: 0x06, down: false)
            m.run(until: m.cycles + 300_000)
        }

        /// **Deliverable #1/#5: a disk inserted at power-on does NOT auto-boot
        /// and does NOT change the menu.** The Rev H ROM never runs its
        /// FIND_BOOT dispatcher automatically -- it completes POST and parks
        /// in the same `$FE2DBE-$FE2DD6` boot-menu idle loop, drawing the same
        /// framebuffer (crossed-out ProFile "42" icon and all), whether or not
        /// a floppy is present. So the no-disk boot anchor
        /// (`ROMBootTests.romCompletesPOSTAndReachesBootMenu`) is UNMOVED by an
        /// inserted disk: identical FNV fingerprint and set-pixel count.
        @Test func diskInsertedAtPowerOnReachesTheIdenticalMenuAnchor() throws {
            let m = try bootedWithDisk()
            m.run(until: 25_000_000)
            #expect((0x00FE_2DBE...0x00FE_2DD6).contains(m.cpu[.pc]),
                    "with a disk inserted the ROM should still park in the boot-menu idle loop, not auto-boot; got \(String(format: "%08X", m.cpu[.pc]))")
            #expect(m.bus.floppy.blocksRead == 0,
                    "no floppy read should occur at power-on without a menu selection")
            let fb = m.bus.framebufferSnapshot()
            #expect(fnv1a(fb) == 0xd092_34d2_5516_d0b8,
                    "the disk-inserted power-on menu must be byte-identical to the no-disk anchor")
            #expect(fb.reduce(0) { $0 + $1.nonzeroBitCount } == 78100,
                    "same set-pixel count as the no-disk menu anchor")
        }

        /// **Deliverables #2/#3/#4: the ROM reads block 0 off the floppy and
        /// executes the boot block.** Booting the floppy requires a menu
        /// selection: click "STARTUP FROM..." (button `$F2`, rect
        /// `[416,165,496,192]` in the `$53a` hit-test table), which opens a
        /// device-list window, then click a device item. That runs the Sony
        /// loader (`$FE1BCC`) -> twig_entry read routine (`$FE1D76`), which
        /// issues the go-byte sequence (DISKPARM=0 readdisk, DISKCMD=$81
        /// excmd, wait completion on VIA2 PB4, clristat $85, wait handshake on
        /// VIA1 PB6), reads block 0's 512 data bytes + 12 tag bytes off the
        /// ODD lane of the shared-RAM window (settled ambiguity (a): buffer
        /// base $400, movep stride-2), verifies the `$AAAA` boot-block
        /// signature, and JMPs to the loaded block at **`$020000`** (first
        /// bytes `4E FA ...` = JMP). See docs/rom-trace-notes.md "Floppy boot
        /// (checkpoint C)" for the full disassembly citations.
        @Test func menuSelectionReadsBlockZeroAndExecutesTheBootBlock() throws {
            let m = try bootedWithDisk()
            m.run(until: 18_000_000)                 // POST done, menu idle
            moveCursor(m, to: 420, 182)              // onto "STARTUP FROM"
            click(m)
            m.run(until: m.cycles + 3_000_000)       // device-list window drawn
            moveCursor(m, to: 88, 33)                // onto the top device item
            click(m)

            // Run until the CPU leaves ROM into the loaded boot block (or a
            // generous cycle budget elapses). The loader reads block 0 ~8 M
            // cycles before the jump (a contrast-DAC delay sits between).
            var ramPC: UInt32? = nil
            let limit = m.cycles + 40_000_000
            while m.cycles < limit && !m.halted {
                let pc = m.cpu[.pc]
                if pc < 0xFE_0000 && pc >= 0x0800 { ramPC = pc; break }
                _ = m.step()
            }

            #expect(m.bus.floppy.blocksRead >= 1, "the ROM should have read at least block 0")
            #expect(m.bus.floppy.lastError == 0, "block-0 read should succeed with no DISKERR")
            #expect(ramPC == 0x0002_0000,
                    "the ROM should JMP into the boot block at $020000; got \(ramPC.map { String(format: "$%06X", $0) } ?? "none")")
            // Boot block starts 4E FA (JMP (d16,PC)); $AAAA signature at +4.
            #expect(m.bus.read8(0x0002_0000) == 0x4E && m.bus.read8(0x0002_0001) == 0xFA,
                    "boot block should begin with 4E FA (JMP)")
            #expect(m.bus.read16(0x0002_0004) == 0xAAAA,
                    "boot block should carry the $AAAA signature the loader verifies")
        }
    }
}
