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

        /// Drives the same menu selection as the checkpoint-C springboard, then
        /// runs the boot block ("ldsony"/ldmicro loader-loader, source-ldmicro)
        /// into the OS loader and stops the instant the loader installs its own
        /// TRAP #6 vector -- the point of maximal, stable progress. Returns the
        /// booted machine parked there; the loader-execution markers are then
        /// asserted by the caller. See docs/rom-trace-notes.md "OS loader
        /// (Task 6)" for the full journey narrative + citations.
        private func bootIntoLoader() throws -> Machine {
            let m = try bootedWithDisk()
            m.run(until: 18_000_000)
            moveCursor(m, to: 420, 182); click(m)         // "STARTUP FROM..."
            m.run(until: m.cycles + 3_000_000)
            moveCursor(m, to: 88, 33); click(m)           // top device item
            // Step into the loaded boot block at $020000.
            let lim0 = m.cycles + 40_000_000
            while m.cycles < lim0 && !m.halted && m.cpu[.pc] != 0x0002_0000 { _ = m.step() }
            // Follow the loader until it dispatches through its own
            // (unrelocated) TRAP #6 segment-call gate, i.e. PC reaches the
            // placeholder segment base $A84000. By this instant ldmicro has
            // relocated itself to $100000, read its remaining code blocks + the
            // LFS MDDF, written the loader hand-off cells, mapped its Pascal
            // code segment 84, and the compiled Pascal loader has overwritten
            // the PROM's TRAP #6 vector ($FE1D14) with $A84000 -- the point of
            // maximal, stable progress (docs/rom-trace-notes.md "OS loader
            // (Task 6)"). ~0.4M cycles past $020000.
            let lim1 = m.cycles + 5_000_000
            while m.cycles < lim1 && !m.halted && m.cpu[.pc] != 0x00A8_4000 { _ = m.step() }
            return m
        }

        /// **M2 EXIT CRITERION -- the OS loader executes from RAM and makes
        /// documented progress.** After the menu selection boots the floppy,
        /// the Rev H PROM's twig_entry RWTS reads block 0 (the "ldsony"
        /// loader-loader, source-ldmicro) to `$020000` and JMPs into it; the
        /// loader-loader then:
        ///   1. relocates itself to `prom_realsize/2` = `$100000`
        ///      (`ldbaseptr` cell `$21C`; source-ldmicro:77-79 / LDEQU:35,66),
        ///   2. reads its remaining code blocks **and the LFS MDDF** off the
        ///      floppy via twig_entry (`blocksRead` climbs to 24 -- 23 code
        ///      blocks + block 28, the MDDF the loader's own `fs_block0` field
        ///      names), every read `lastError == 0`,
        ///   3. writes the loader hand-off cells: `dev_type` (`$22E`) = 2
        ///      (`dev_sony`; source-ldmicro:124 / LDEQU:32,40), `ld_fs_block0`
        ///      (`$210`) = `$1C` (MDDF block; LDEQU:29), `log_volume` (`$212`)
        ///      = 1 (LDEQU:30),
        ///   4. maps its MMU-utility code segment 84 (logical `$A80000`) live
        ///      via the MMU and enters the compiled Pascal loader, then reaches
        ///      its first inter-segment `trap #6` -- the OS **MMU-programming
        ///      trap** `do_an_mmu`, whose handler `initmmutil` relocated into
        ///      segment 84 and pointed vector `$98` at (`$A84000`, BY DESIGN --
        ///      NOT an "unrelocated placeholder").
        /// M3 Task 1 DIAGNOSED the stop here as an emulation divergence (a
        /// missing 12-bit MMU page-wrap: `$A84000` decoded to phys `$200800`
        /// past 2 MB instead of `$800`) and FIXED it; the gate now falls and
        /// the boot advances to a new stop in ROM (Task 2's frontier). See
        /// rom-trace-notes.md "Gate diagnosis (M3 Task 1)". This test still
        /// parks AT `$A84000` (the last common anchor) and asserts the
        /// loader-execution markers reached there; robust invariants alongside
        /// the exact deterministic anchors.
        @Test func osLoaderExecutesFromRAMAndReachesPascalSegmentGate() throws {
            let m = try bootIntoLoader()

            // The loader relocated itself to the RAM midpoint and ran there.
            #expect(m.bus.read32(0x21C) == 0x0010_0000,
                    "ldbaseptr ($21C) should be prom_realsize/2 = $100000")
            #expect(m.bus.read32(0x2A8) == 0x0020_0000,
                    "the PROM should have reported prom_realsize ($2A8) = 2 MB")

            // It read its own code blocks + the LFS MDDF off the floppy.
            #expect(m.bus.floppy.blocksRead >= 20,
                    "the loader should read many blocks off the floppy (loading itself + the MDDF); got \(m.bus.floppy.blocksRead)")
            #expect(m.bus.floppy.blocksRead == 24,
                    "exact anchor: 23 loader code blocks + block 28 (MDDF) = 24")
            #expect(m.bus.floppy.lastError == 0,
                    "every loader block read should succeed (DISKERR 0)")

            // It wrote the loader hand-off cells (source-ldmicro:121-125).
            #expect(m.bus.read16(0x22E) == 2,
                    "dev_type ($22E) should be dev_sony (2)")
            #expect(m.bus.read16(0x210) == 0x001C,
                    "ld_fs_block0 ($210) should be the MDDF block $1C")
            #expect(m.bus.read16(0x212) == 1,
                    "log_volume ($212) should be drive 1")

            // It entered the loader and reached its first TRAP #6: the OS's
            // MMU-programming trap. `initmmutil` relocated `do_an_mmu` into
            // segment 84 and pointed vector $98 at its virtual home $A84000
            // (BY DESIGN -- see rom-trace-notes.md "Gate diagnosis"), over the
            // PROM's $FE1D14.
            #expect(m.bus.read32(0x98) == 0x00A8_4000,
                    "the loader should install its relocated do_an_mmu TRAP #6 vector ($A84000) over the PROM's ($FE1D14)")

            // It programmed a new MMU segment (84, its Pascal code segment)
            // live -- more SLIM/SORG writes than the 4384 POST leaves behind.
            #expect(m.bus.mmuPortWrites > 4384,
                    "the loader should program its Pascal code segment via the MMU; got \(m.bus.mmuPortWrites)")

            // The loader draws nothing before the segment gate: the boot-menu
            // framebuffer content is still present (not blanked/redrawn).
            let px = m.bus.framebufferSnapshot().reduce(0) { $0 + $1.nonzeroBitCount }
            #expect(px > 70_000,
                    "the menu framebuffer should still be present (loader draws nothing pre-gate); got \(px)")

            #expect(!m.halted, "the loader run is a live progression, not a halt")
        }

        /// **M3 Task 2 -- the fallen gate has a boot-level guard.** The prior
        /// test parks AT `$A84000`; this one steps THROUGH it to prove the M3
        /// Task 1 MMU-wrap fix (plus the setup-latch translation fix, M3 Task 2)
        /// let `do_an_mmu` actually EXECUTE at its wrapped home and RETURN.
        /// `do_an_mmu` (LDASM:305-446) runs entirely in seg-84 (logical
        /// `$A84xxx` -> phys `$800`), toggling SETUP on inside its own loop
        /// while it keeps fetching its code and reading the SMT from that same
        /// window -- which only works because SETUP does not disturb live
        /// translation (Bus.swift setup-mode translate-else-flat; docs/
        /// hardware-notes.md §1 "Setup Latch", rom-trace-notes.md "Checkpoint
        /// D"). It then `rte`s to the loader's `prog_mmu` return site,
        /// `$10041A` (the trap frame's stacked PC), with NO bus error -- the
        /// gate is gone. Without either fix the CPU derailed off seg-84 into
        /// garbage and bombed to the ROM error entry `$FE0030`.
        @Test func doAnMmuExecutesAtItsWrappedHomeAndReturnsToLoader() throws {
            let m = try bootIntoLoader()
            #expect(m.cpu[.pc] == 0x00A8_4000, "bench parks at the trap #6 gate")
            #expect(m.bus.busErrorPulseCount == 0, "no fault reaching the gate")

            // Step through do_an_mmu until control re-enters the relocated
            // loader ($100000-$10FFFF); it must be the trap-#6 return site.
            var backInLoader: UInt32? = nil
            for _ in 0..<4000 {
                _ = m.step()
                let pc = m.cpu[.pc]
                if pc >= 0x0010_0000 && pc < 0x0011_0000 { backInLoader = pc; break }
            }
            #expect(backInLoader == 0x0010_041A,
                    "do_an_mmu should rte to prog_mmu's return site $10041A; got \(backInLoader.map { String(format: "$%06X", $0) } ?? "none")")
            #expect(m.bus.busErrorPulseCount == 0,
                    "do_an_mmu executes cleanly at its wrapped home -- no bus error, no $FE0030 bounce")
            #expect(!m.halted, "the boot advances past the gate, it does not halt at it")
            // The wrapped-home execution really programmed a segment: SLIM/SORG
            // writes climbed past the count captured at the gate.
            #expect(m.bus.mmuPortWrites > 4386,
                    "do_an_mmu programmed at least one segment past the gate; got \(m.bus.mmuPortWrites)")
        }

        /// **M3 Task 2 -- Checkpoint D frontier: the loader's full domain-0 MMU
        /// build, then the domain-1 crossover (OQ1 forcing point).** Past the
        /// gate the loader drives `do_an_mmu` (via `prog_mmu`, LDASM:257-275)
        /// once per segment to program **all of domain 0** -- ~127 trap-#6 calls
        /// walking segment indices up through `$7F` -- then issues a call
        /// targeting **domain 1, segment 0** (`d2=1, d3=0`). `do_an_mmu`
        /// switches the live context to domain 1 (`ctbit1on`, `$A8402E`) and
        /// keeps executing its own seg-84 code there; but domain 1 is still
        /// empty (the loader has only just begun building it), so the in-handler
        /// fetch/exception-vector access finds nothing mapped and the CPU
        /// double-faults to a halt. THIS is the documented Checkpoint-D
        /// frontier: a genuine multi-domain-bootstrap boundary and OQ1's
        /// long-predicted forcing point (per-domain vs. global segment
        /// semantics -- see rom-trace-notes.md "Checkpoint D" / OQ1). Anchored
        /// on robust invariants of that furthest reproducible state; no floppy
        /// writes occur anywhere on this path (Deliverable #3: none observed).
        @Test func loaderBuildsDomain0MMUThenHaltsAtTheDomain1Crossover() throws {
            let m = try bootIntoLoader()
            let mmuAtGate = m.bus.mmuPortWrites

            var trap6Calls = 0
            var sawDomain1 = false
            var prevPC: UInt32 = 0
            for _ in 0..<400_000 {
                let pc = m.cpu[.pc]
                if pc == 0x00A8_4000 && prevPC != 0x00A8_4000 { trap6Calls += 1 }
                if m.bus.domain == 1 { sawDomain1 = true }
                prevPC = pc
                _ = m.step()
                if m.halted { break }
            }

            #expect(m.halted, "the boot halts at the multi-domain bootstrap boundary (Checkpoint D frontier)")
            #expect(trap6Calls >= 120,
                    "the loader programs ~all of domain 0 via many do_an_mmu calls; got \(trap6Calls)")
            #expect(m.bus.mmuPortWrites > mmuAtGate,
                    "each do_an_mmu programmed segments -- SLIM/SORG writes climbed past the gate (\(mmuAtGate) -> \(m.bus.mmuPortWrites))")
            #expect(sawDomain1,
                    "the loader crosses into domain 1 -- the OQ1 forcing point -- before halting")
            #expect(m.bus.floppy.writeAttempts == 0,
                    "no floppy WRITE is issued anywhere on the Checkpoint-D path (no-writes-observed)")
        }
    }
}
