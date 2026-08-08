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

        /// **M3 Task 4 -- the domain-1 crossover SURVIVES (OQ1′ resolved) and
        /// the boot loads the OS image, reaching the OS's own COPS driver.**
        ///
        /// Past the gate the loader drives `do_an_mmu` once per segment to
        /// program all of domain 0, then issues the pivot call targeting
        /// **domain 1** (`d2=1`). `do_an_mmu` switches the live context to
        /// domain 1 (`ctbit1on`, `$A8402E`) with SETUP OFF and keeps executing
        /// its own seg-84 code there. Under M3 Task 2 this **double-faulted to
        /// a halt** because our per-domain-independent model left domain 1
        /// empty. OQ1′ (M3 Task 4) resolved it: **supervisor-mode translation
        /// uses the OS domain (0) regardless of the context latch** -- domains
        /// 1-3 are user-process domains, and `do_an_mmu`/`SET_DOMAIN` flip the
        /// latch while in supervisor and keep running domain-0 code (see
        /// `Bus.translationDomain`, rom-trace-notes.md "Kernel push (M3 Task
        /// 4)"). With the pivot surviving, the loader BUILDS domain 1's
        /// register file (SLIM/SORG writes climb well past the 4638 gate), the
        /// loader completes and **reads the OS image off the floppy**
        /// (`blocksRead` 24 -> 75, all via the PROM read routine `$FE1E4C`),
        /// and control enters loaded OS code at `$520000` -- specifically the
        /// OS's own **COPS command-send driver** (`$520824`, the same
        /// stage-to-IORA2 / drive-via-DDRA2 / poll-CRDY protocol the ROM uses,
        /// COPS.swift type doc "command-send protocol"). That driver is the M3
        /// Task 4 STOP: it spins on CRDY because our simplified COPS model
        /// drops CRDY on the register-15 *no-handshake* staging write it issues
        /// every poll iteration -- a genuinely-new subsystem boundary (the
        /// OS-driven COPS, vs the ROM's) documented as an M4 requirement
        /// (rom-trace-notes.md "Kernel push" / hardware-notes.md §4).
        ///
        /// Anchored on robust invariants + exact deterministic markers of that
        /// furthest reproducible state; NO bus error, NO halt, NO floppy write
        /// anywhere on the path.
        @Test func domain1CrossoverSurvivesLoaderLoadsOSImageAndReachesTheCOPSDriver() throws {
            let m = try bootIntoLoader()
            let mmuAtGate = m.bus.mmuPortWrites

            var trap6Calls = 0
            var sawDomain1 = false
            var returnedToDomain0AfterD1 = false
            var reachedCopsDriver = false
            var prevPC: UInt32 = 0
            for _ in 0..<400_000 {
                let pc = m.cpu[.pc]
                if pc == 0x00A8_4000 && prevPC != 0x00A8_4000 { trap6Calls += 1 }
                if m.bus.domain == 1 { sawDomain1 = true }
                if sawDomain1 && m.bus.domain == 0 { returnedToDomain0AfterD1 = true }
                // The OS COPS command-send driver lives at $520800-$5208FF.
                if pc >= 0x0052_0800 && pc <= 0x0052_08FF { reachedCopsDriver = true; break }
                prevPC = pc
                _ = m.step()
                if m.halted { break }
            }

            // OQ1′: the pivot survives -- no double fault, no halt.
            #expect(!m.halted,
                    "the domain-1 crossover no longer double-faults to a halt (OQ1′ resolved)")
            #expect(m.bus.busErrorPulseCount == 0,
                    "no bus error anywhere across the domain-1 crossover; got \(m.bus.busErrorPulseCount)")
            #expect(sawDomain1,
                    "the loader crosses the live context into domain 1 (the OQ1′ pivot)")
            #expect(returnedToDomain0AfterD1,
                    "do_an_mmu establishes domain 1, programs it, and restores domain 0 -- it RETURNS, it does not derail")

            // The loader built domain 0 (many trap-#6 calls) and then domain 1
            // (SLIM/SORG writes climb well past the 4638 gate value).
            #expect(trap6Calls >= 120,
                    "the loader programs ~all of domain 0 via many do_an_mmu calls; got \(trap6Calls)")
            #expect(m.bus.mmuPortWrites > mmuAtGate,
                    "domain-1 build: SLIM/SORG writes climbed past the gate (\(mmuAtGate) -> \(m.bus.mmuPortWrites))")

            // The loader completed and read the OS image off the floppy.
            #expect(m.bus.floppy.blocksRead >= 70,
                    "the loader reads the OS image off the floppy; got \(m.bus.floppy.blocksRead)")
            #expect(m.bus.floppy.blocksRead == 75,
                    "exact anchor: 24 (loader + MDDF) + 51 OS-image blocks = 75")
            #expect(m.bus.floppy.lastError == 0,
                    "every OS-image block read succeeds (DISKERR 0)")

            // Control reached loaded OS code -- the OS's own COPS command-send
            // driver (the M3 Task 4 documented STOP / M4 boundary).
            #expect(reachedCopsDriver,
                    "the boot reaches loaded OS code -- the COPS command-send driver at $520800-$5208FF")
            #expect((0x0052_0800...0x0052_08FF).contains(m.cpu[.pc]),
                    "furthest state: parked in the OS COPS driver; got \(String(format: "$%06X", m.cpu[.pc]))")

            // No floppy WRITE is ever issued on the whole path.
            #expect(m.bus.floppy.writeAttempts == 0,
                    "no floppy WRITE anywhere on the kernel-push path (no-writes-observed)")
        }

        /// **M4 Task 3 — Checkpoint E: THE UNMASKING and the first live
        /// interrupts; the OS comes alive.** Past the COPS driver (M4 Task 1
        /// opened the handshake) the OS's `DriverInit`/`INITSYS` program VIA1
        /// T1 (the ms tick), enable the level-2 COPS line, install the Level1
        /// ($0064) and Level2 ($0068) autovectors (LIBHW-DRIVERS `DriverInit`),
        /// and drop SR below `$2700`. At that instant level-1 (VIA1 T1 ms-tick)
        /// AND level-2 (COPS/VIA2) interrupts begin delivering to the OS's own
        /// handlers -- `Level1` at `$5208A6` (poll retrace/timer/floppy) and
        /// `Level2` at `$520A52`. The OS then runs its scheduler across many
        /// loaded segments in user mode (SR reaches `$0000`) and settles into a
        /// steady user-mode event-wait loop (`$4C0276`, polling an in-RAM state
        /// for `2`). See docs/rom-trace-notes.md "Checkpoint E".
        ///
        /// This furthest stable state is unlocked by the M4 Task 3 fix: `$F801`
        /// bit 2 (vertical-retrace) is **active-low** (0 == pending) per the OS
        /// source, not active-high -- our old model made the Level1 handler read
        /// "no retrace", never ack via `VertRetrace`, and `vsyncPending` stormed
        /// level 1 forever. Every ROM anchor is unmoved (the ROM's own bit-2
        /// self-test is soft-fail either way -- rom-trace-notes "Trace
        /// checkpoint B").
        @Test func checkpointE_unmaskingAndFirstLiveInterrupts() throws {
            let m = try bootIntoLoader()
            // Reach loaded OS code, then single-step so interrupt delivery is
            // exact to the instruction boundary while we watch for the unmask.
            let lim0 = m.cycles + 30_000_000
            while m.cycles < lim0 && !m.halted && !(0x0052_0000...0x0052_FFFF).contains(m.cpu[.pc]) {
                _ = m.step()
            }
            #expect((0x0052_0000...0x0052_FFFF).contains(m.cpu[.pc]),
                    "reached loaded OS code; got \(String(format: "$%06X", m.cpu[.pc]))")

            var minSR: UInt16 = 0xFFFF
            var sawLevel1Handler = false     // $5208A6 Level1 (LIBHW-DRIVERS)
            var sawLevel2Handler = false     // $520A52 Level2
            var sawUserMode = false          // SR S-bit clear (scheduler ran a user process)
            var restingRegion = false        // the $4C02xx / $2E2Bxx event-wait loop
            for _ in 0..<4_000_000 where !m.halted {
                let pc = m.cpu[.pc]
                let sr = UInt16(m.cpu[.sr])
                if sr < minSR { minSR = sr }
                if pc == 0x0052_08A6 { sawLevel1Handler = true }
                if pc == 0x0052_0A52 { sawLevel2Handler = true }
                if (sr & 0x2000) == 0 { sawUserMode = true }
                if (0x004C_0270...0x004C_028F).contains(pc) { restingRegion = true }
                if restingRegion && sawLevel1Handler && sawLevel2Handler && sawUserMode
                    && minSR < 0x0700 { break }
                _ = m.step()
            }

            // THE UNMASKING: SR dropped below the level-7 mask it held the whole
            // boot -- in fact all the way to user mode.
            #expect(minSR < 0x2700, "SR dropped below $2700 -- the OS unmasked; minSR=\(String(format: "$%04X", minSR))")
            #expect(sawUserMode, "the scheduler ran a process in user mode (SR S-bit clear)")
            // FIRST LIVE INTERRUPTS delivered to the OS's own handlers.
            #expect(sawLevel1Handler, "level-1 (VIA1 T1 ms-tick / retrace) delivered to Level1 @ $5208A6")
            #expect(sawLevel2Handler, "level-2 (COPS/VIA2) delivered to Level2 @ $520A52")
            // The OS is alive and idles in its scheduler event-wait loop.
            #expect(restingRegion, "the OS settles into its user-mode event-wait loop @ $4C0270")
            #expect(!m.halted, "the OS runs live -- no halt")
            #expect(m.bus.busErrorPulseCount == 0, "no bus error across the unmasking")
            #expect(m.bus.floppy.writeAttempts == 0, "still no floppy WRITE observed at Checkpoint E")
            // M4 Task 4 round 4 re-anchor: 323 -> 344. With $FCC031 now
            // presenting the Pepsi-class DiskROMId ($88), BOOT_IO_INIT's
            // INIT_BOOT_CDS takes the real Lisa-2 config path BEFORE the
            // unmasking: INIT_CONFIG reads the boot volume's MDDF PM-snapshot
            // and FIND_CDDS/LOADEM read 'SYSTEM.CDD' + the Sony boot CD
            // 'SYSTEM.CD_*' off the disk via the loader's synchronous reads
            // (SOURCE-STARTUP:1103-1154, 1613-1663) -- 21 additional blocks.
            #expect(m.bus.floppy.blocksRead == 344,
                    "boot blocks (75 -> 323) + INIT_BOOT_CDS's SYSTEM.CDD/CD reads before unmasking; got \(m.bus.floppy.blocksRead)")
        }

        /// **M4 Task 4 (round 4) — Checkpoint G: the Office System installer UI
        /// draws.** Supersedes `checkpointF_blockedOnDriverIOCompletion`
        /// (rounds 1-3), whose frontier -- the FS-mount read orphaned on a stub
        /// driver devrec "#14#1" (nil `cb_addr`, `entry_pt` -> the compiled-out
        /// TWIGIO body) -- is now ROOT-CAUSED and FIXED
        /// (docs/rom-trace-notes.md "Checkpoint G (round 4)"):
        ///
        ///  1. `$FCC031` (DiskROMId, LIBHW-DRIVERS:135) was a `0x00` stub, so
        ///     BOOT_IO_INIT decoded our machine as a Twiggy Lisa 1
        ///     (SOURCE-STARTUP:1876-1878) and installed the vestigial TWIGIO
        ///     stub (SOURCE-CD:750; source-twiggy:1235/1237 -- body compiled
        ///     out under `(*$IFC TWIGGYBUILD*)`) on the boot floppy devrecs.
        ///     Fixed: `$C031` = `$88` (Pepsi-class) -> iomodel = iob_pepsi ->
        ///     INIT_BOOT_CDS installs the REAL Sony CD driver from the disk.
        ///  2. Floppy writes now happen (PM-snapshot rewrite, FS metadata):
        ///     `FloppyController` stores them in a session-scoped in-memory
        ///     overlay (never mutating the .dc42).
        ///  3. The OS's recoverable-bus-error machinery (SOURCE-EXCEPASM
        ///     :434-505 `BUS_ERR`) re-runs faulting JSR/JMP/RTS syscall and
        ///     segment-swap gates by decoding the group-0 frame's IR + PC;
        ///     Musashi's stock jump semantics (complete the jump, fault at the
        ///     next fetch) corrupted a syscall parameter frame with a second
        ///     return address (the fatal 10201 `e_hardsyscode`,
        ///     source-EXCEPRIM:70). Fixed in the vendored core: target-prefetch
        ///     faults now push real-68000 frames (see BusErrorFrameTests).
        ///
        /// With all three in place the boot now runs: mount read COMPLETES
        /// (`unblk_req` executes), SYS_PROC_INIT creates processes (A5
        /// changes), the scheduler dispatches user-mode code in domain 1 (the
        /// first non-zero-domain execution -- OQ1'' evidence: the forced
        /// supervisor->domain-0 translation model HOLDS through live
        /// multi-domain scheduling), dozens of $A0xxxxxx-tagged gate faults
        /// are taken and recovered by design, and the **Lisa 7/7 Office
        /// System 3.0 installer dialog draws** (Finished/Repair/Install/
        /// Restore) -- the machine idles in the installer's event-wait loop
        /// awaiting input. Screenshots:
        /// ~/Development/LisaEmu-artifacts/m4-checkpoint-g-desktop-background.png
        /// and m4-checkpoint-g-installer-ui.png.
        @Test func checkpointG_officeSystemInstallerUIDraws() throws {
            let m = try bootIntoLoader()
            let a5Boot = m.cpu[.a5]
            var sawUnblkReq = false, a5Changed = false, sawUserDomain1 = false
            var steps = 0
            while steps < 10_000_000 && !m.halted {
                let pc = m.cpu[.pc]
                if pc == 0x002E_2BFC { sawUnblkReq = true }
                if m.cpu[.a5] != a5Boot { a5Changed = true }
                if (UInt16(m.cpu[.sr]) & 0x2000) == 0 && m.bus.domain == 1 { sawUserDomain1 = true }
                _ = m.step(); steps += 1
            }

            #expect(!m.halted, "the OS runs live through the whole window -- no halt, no double fault")
            // The round-1/2/3 stall mechanism is gone: driver I/O completions run.
            #expect(sawUnblkReq, "unblk_req ($2E2BFC) EXECUTES -- the FS-mount reqblk completes (rounds 1-3: it never ran)")
            // Single-process STARTUP is over: SYS_PROC_INIT ran, processes exist.
            #expect(a5Changed, "A5 changes -- SYS_PROC_INIT created processes and the scheduler dispatched them")
            // OQ1'' -- first context switch into a non-zero domain, observed:
            // user-mode execution with the domain latch = 1 (the supervisor->
            // domain-0 forced translation model survives real multi-domain
            // scheduling; docs/rom-trace-notes.md "Checkpoint G (round 4)").
            #expect(sawUserDomain1, "user-mode code executes in domain 1 -- live multi-domain scheduling")
            // Recoverable bus errors are the OS's DESIGN at this stage
            // (SOURCE-EXCEPASM:434-505 gate re-runs) -- the old "no bus error"
            // pin is re-anchored: pulses now occur and are all RECOVERED.
            #expect(m.bus.busErrorPulseCount > 0, "the $A0xxxxxx segment/syscall gate faults fire and are recovered by design")
            // Session write-through: the OS writes the boot floppy (PM
            // snapshot, FS metadata) and every write is stored in the
            // in-memory overlay -- none dropped, the .dc42 never mutated.
            #expect(m.bus.floppy.writeAttempts > 0, "the OS writes the boot floppy at Checkpoint G")
            #expect(m.bus.floppy.blocksWritten == m.bus.floppy.writeAttempts,
                    "every writedisk stored in the session overlay; \(m.bus.floppy.blocksWritten)/\(m.bus.floppy.writeAttempts)")
            #expect(m.bus.floppy.blocksRead >= 600,
                    "the OS keeps reading (segment swap-ins, installer resources); got \(m.bus.floppy.blocksRead)")

            // THE ANCHOR: the Lisa 7/7 Office System 3.0 installer dialog is
            // on screen (Finished/Repair/Install/Restore), stable across the
            // idle event-wait loop.
            let fb = m.bus.framebufferSnapshot()
            #expect(fnv1a(fb) == 0x04a1_9e4e_b597_04f4,
                    "installer-dialog framebuffer FNV; got \(String(format: "0x%016llx", fnv1a(fb)))")
            #expect(fb.reduce(0) { $0 + $1.nonzeroBitCount } == 60107,
                    "installer-dialog set-pixel count; got \(fb.reduce(0) { $0 + $1.nonzeroBitCount })")
        }

        // M5 Task 2 -- Q1 live $FCD801 probe + the M2-precedent boot-menu
        // watch, in one test. Attaches a Widget hard disk and boots the SAME
        // window as checkpointG. Two assertions:
        //  (1) The OS ProFile/Widget driver never drives the `$FCD801`/`$FCDC01`
        //      region on the boot-to-installer path -- `widgetRegionAccesses`
        //      stays 0 -- confirming §10.9 live: PROF_INIT never runs because
        //      no `cd_intdisk` devrec exists (attaching hardware alone does not
        //      create the devrec). This is the OBSERVED-vs-contract record the
        //      Task 1 Q1 hand-off asked for, and the Task 3 frontier anchor
        //      (the moment it first goes non-zero).
        //  (2) The installer dialog is BYTE-IDENTICAL with a Widget attached
        //      (same FNV as checkpointG) -- so attaching a Widget does NOT move
        //      the boot menu / installer UI (unlike the M2 floppy-devrec
        //      precedent). No re-anchoring needed; documented here + in
        //      docs/rom-trace-notes.md "Checkpoint H prep".
        @Test func checkpointH_widgetAttachedDoesNotDriveTheRegionOrMoveTheInstaller() throws {
            let m = try bootIntoLoader()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("checkpointH-\(UUID().uuidString).widget")
            defer { try? FileManager.default.removeItem(at: url) }
            let widget = try WidgetImage(createBlankAt: url, blockCount: 512)
            m.bus.widget.attach(widget)

            var steps = 0
            while steps < 10_000_000 && !m.halted {
                _ = m.step(); steps += 1
            }

            #expect(!m.halted, "the OS runs live through the window with a Widget attached -- no halt")
            #expect(m.bus.widgetRegionAccesses == 0,
                    "OBSERVED: the OS/ROM never touches the $FCD801/$FCDC01 Widget region on the boot-to-installer path (PROF_INIT never runs, §10.9); got \(m.bus.widgetRegionAccesses) access(es), first at cycle \(String(describing: m.bus.firstWidgetRegionAccessCycle))")
            #expect(m.bus.widget.completedCommands == 0,
                    "OBSERVED: no Widget command completes -- the driver never handshakes")

            // The installer dialog is unchanged by attaching a Widget.
            let fb = m.bus.framebufferSnapshot()
            #expect(fnv1a(fb) == 0x04a1_9e4e_b597_04f4,
                    "attaching a Widget must not move the installer dialog; got \(String(format: "0x%016llx", fnv1a(fb)))")
        }
    }
}
