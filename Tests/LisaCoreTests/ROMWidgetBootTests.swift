import Foundation
import Testing
@testable import LisaCore

/// **M5 Task 4 -- "Checkpoint K: boot the installed OS from the Widget."** The
/// real Rev H boot ROM, driven through its own STARTUP FROM menu, boots the
/// **installed** Office System off the Widget hard-disk HLE: its parallel-port
/// boot routine (`prof_entry` = $FE1F70) probes the ProFile at VIA1 base
/// $FCD901, reads block 0 (the LFS boot block, `4E FA ...`), jumps into it, and
/// the OS loader + OS come up entirely off the Widget -- reaching the Office
/// System desktop (menu bar + icons) with live mouse. See
/// docs/rom-trace-notes.md "Checkpoint K" and docs/m5-demo.md.
///
/// Env-gated on BOTH `LISAEMU_ROM_DIR` (the interleaved ROM) and
/// `LISAEMU_WIDGET_DIR` (a directory holding `OS31-installed.widget`, the
/// user's installed image built by the M5 Task 3 installer -- Apple-derived,
/// never committed). A boot WRITES to the volume (the OS marks it in-use), so
/// the test always works on a COPY in the temp dir; the canonical installed
/// image is never mutated.
///
/// Nested under `MusashiSuites` because it builds a `Machine` (Musashi is a
/// process-global singleton; only one live `Machine` per test).
private let wRomDir = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]
private let wWidgetDir = ProcessInfo.processInfo.environment["LISAEMU_WIDGET_DIR"]
private let wWidgetImagePath = wWidgetDir.map { $0 + "/OS31-installed.widget" }
// Fold the image's existence into the enable predicate so a set-but-empty
// LISAEMU_WIDGET_DIR yields an explicit SKIP (reported as such), not a silently
// green test that returned early without asserting anything.
private let wWidgetImageExists =
    wWidgetImagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false

extension MusashiSuites {
    @Suite(.enabled(if: wRomDir != nil && wWidgetImageExists,
                    "Set LISAEMU_ROM_DIR and LISAEMU_WIDGET_DIR to a directory holding OS31-installed.widget to run Widget-boot tests"))
    struct ROMWidgetBootTests {
        private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
            return h
        }

        /// Walks the ROM's on-screen boot-menu cursor (`$496`/`$498`) to
        /// `(tx,ty)` by feeding relative mouse-delta packets through
        /// `COPS.postMouse` -- the same technique as ROMFloppyBootTests.
        private func moveCursor(_ m: Machine, to tx: Int, _ ty: Int) {
            for _ in 0..<24 {
                let cx = Int(m.bus.read16(0x496)), cy = Int(m.bus.read16(0x498))
                if abs(cx - tx) <= 1 && abs(cy - ty) <= 1 { return }
                m.bus.cops.postMouse(dx: Int8(max(-120, min(120, tx - cx))),
                                     dy: Int8(max(-120, min(120, ty - cy))))
                m.run(until: m.cycles + 250_000)
            }
        }
        private func click(_ m: Machine) {
            m.bus.cops.postKey(code: 0x06, down: true)
            m.run(until: m.cycles + 300_000)
            m.bus.cops.postKey(code: 0x06, down: false)
            m.run(until: m.cycles + 300_000)
        }

        /// Loads the ROM, attaches a throwaway COPY of the installed Widget
        /// image, and reaches the boot menu.
        private func machineWithInstalledWidgetCopy() throws -> Machine {
            let rom = try ROMImage.load(directory: URL(fileURLWithPath: wRomDir!))
            let m = Machine(ramSize: 0x20_0000)
            m.bus.loadROM(rom)
            m.reset()
            let src = URL(fileURLWithPath: wWidgetDir! + "/OS31-installed.widget")
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("widgetboot-\(UUID().uuidString).widget")
            try FileManager.default.copyItem(at: src, to: copy)
            let image = try WidgetImage(contentsOf: copy)
            m.bus.widget.attach(image)
            return m
        }

        /// **The Widget boot proof.** With the installed image attached, the
        /// ROM's STARTUP FROM list gains the hard-disk item (before the M5
        /// Task 4 $FCD901-forward fix it listed only the floppy); clicking it
        /// runs `prof_entry`, which reads block 0 off the Widget and boots the
        /// installed OS. Asserted from the emulator state (not an exact
        /// framebuffer, which shifts with the click-feedback timing): the
        /// Widget served many ProFile read commands, the CPU left ROM into
        /// loaded RAM code, and the OS drew substantial UI -- the boot ran off
        /// the hard disk, live, with no halt.
        @Test func checkpointK_romBootsInstalledOSOffTheWidget() throws {
            // Image presence is guaranteed by the suite's .enabled(if:) predicate
            // (wWidgetImageExists), so no silent early-return guard here.
            let m = try machineWithInstalledWidgetCopy()
            m.run(until: 18_000_000)                              // POST -> boot menu
            moveCursor(m, to: 420, 182); click(m)                // "STARTUP FROM..."
            m.run(until: m.cycles + 6_000_000)                   // device list drawn
            moveCursor(m, to: 88, 33); click(m)                  // top item = the Widget (⌘1)

            // Run until the Widget's read traffic settles (the OS has loaded
            // its boot code + LFS off the disk and reached its UI), or a cap.
            // Track whether the CPU was ever observed executing OUTSIDE the ROM
            // window ($FE0000-$FEFFFF) -- the boot menu never leaves ROM, so a
            // single non-ROM sample proves booted code ran (the OS legitimately
            // re-enters ROM routines for interrupts, so the FINAL instant is not
            // a reliable indicator; a sticky "ever saw loaded code" flag is).
            var lastCmds = -1, idle = 0, sawLoadedCode = false
            for _ in 0..<40 {
                m.run(until: m.cycles + 8_000_000)
                let pc = m.cpu[.pc]
                if pc < 0x00FE_0000 || pc > 0x00FE_FFFF { sawLoadedCode = true }
                let c = m.bus.widget.completedCommands
                idle = (c == lastCmds) ? idle + 1 : 0
                lastCmds = c
                if idle >= 4 && c > 100 { break }
                if m.halted { break }
            }

            #expect(!m.halted, "the OS runs live off the Widget boot -- no halt")
            // prof_entry read block 0 and the OS loader pulled its code + the
            // LFS off the disk: hundreds of single-block ProFile reads. The boot
            // menu never touches the Widget, so this alone distinguishes a real
            // boot from parking in the menu.
            #expect(m.bus.widget.completedCommands > 100,
                    "the ROM + OS read the installed system off the Widget; got \(m.bus.widget.completedCommands) commands")
            #expect(sawLoadedCode,
                    "the CPU executed booted code outside the ROM window (left the boot menu)")
            // The screen is no longer the boot menu -- the OS repainted it with
            // its own UI (boot progress / first Office System dialog).
            let fb = m.bus.framebufferSnapshot()
            let set = fb.reduce(0) { $0 + $1.nonzeroBitCount }
            #expect(fnv1a(fb) != 0xd092_34d2_5516_d0b8 && set != 78100,
                    "the framebuffer must have left the boot-menu anchor; set pixels = \(set)")
            #expect(set > 2000, "the OS drew substantial UI off the Widget boot; set pixels = \(set)")
        }
    }
}
