import Foundation
import Testing
@testable import LisaShell
import LisaCore

// MARK: - EmulationController lifecycle (CPU-driving, ROM-gated)

/// Musashi is a process-global C core (`Sources/LisaCore/M68K.swift`'s
/// `assertOwner`); every CPU-driving test here (anything constructing an
/// `EmulationController`, which creates a `Machine` on its own dedicated
/// thread) must not overlap another such test anywhere in this process.
/// `Tests/LisaCoreTests/MusashiSerialized.swift` establishes the identical
/// discipline for LisaCoreTests' own `MusashiSuites` root -- SwiftPM test
/// targets cannot share a Swift Testing suite declaration across modules
/// (LisaCoreTests is a `.testTarget`, not an importable product), so this
/// is a SEPARATE serialized root with the same intent, cross-referenced
/// here rather than literally shared. See task-1-report.md "Process
/// isolation" for what this repo's `swift test` was empirically found to
/// do when both roots' tests run in the same invocation, and why that
/// finding makes this cross-reference sufficient as a mitigation (short
/// version: `swift test` runs each test target as its own fully separate
/// Swift Testing session, one after another -- confirmed by two distinct
/// "Test run started" banners with zero interleaving between them, which
/// is even stronger than the "separate processes" outcome the plan called
/// merely "fine").
@Suite(.serialized)
enum LisaShellMusashiSuites {}

private let romDir = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]

extension LisaShellMusashiSuites {
    @Suite(.enabled(if: romDir != nil, "Set LISAEMU_ROM_DIR to run controller lifecycle tests"))
    struct EmulationControllerLifecycleTests {
        private func makeController() throws -> EmulationController {
            try EmulationController(romDirectory: URL(fileURLWithPath: romDir!))
        }

        /// Polls status via `onStatus` until `predicate` is satisfied or
        /// `timeout` elapses; returns whether it was satisfied in time.
        @discardableResult
        private func waitForStatus(_ controller: EmulationController, timeout: TimeInterval = 30,
                                    _ predicate: @escaping (EmuStatus) -> Bool) -> Bool {
            let sem = DispatchSemaphore(value: 0)
            controller.onStatus = { status in
                if predicate(status) { sem.signal() }
            }
            let result = sem.wait(timeout: .now() + timeout)
            controller.onStatus = nil
            return result == .success
        }

        // MARK: boots to menu, unthrottled

        /// Reuses the ROMBootTests-documented 20M-cycle POST-to-menu budget
        /// (`Tests/LisaCoreTests/ROMBootTests.swift`
        /// `romCompletesPOSTAndReachesBootMenu`) and its ">1% black
        /// pixels" weaker invariant (the exact-hash anchor is deliberately
        /// NOT re-asserted here -- this is a shell-plumbing test, not a
        /// second copy of the ROM-boot fidelity test).
        @Test
        func bootsToMenuUnthrottled() throws {
            let controller = try makeController()
            controller.throttled = false

            let framesLock = NSLock()
            var frames: [Frame] = []
            controller.framePublisher.onFrame = { frame in
                framesLock.lock(); frames.append(frame); framesLock.unlock()
            }

            controller.start()
            let reached = waitForStatus(controller, timeout: 30) { $0.cycles >= 20_000_000 }
            #expect(reached, "expected to reach the 20M-cycle POST-to-menu budget within 30s")

            framesLock.lock(); let captured = frames; framesLock.unlock()
            #expect(!captured.isEmpty, "vsync frames should have been published by the boot menu")

            let sequences = captured.map(\.sequence)
            #expect(sequences == sequences.sorted(), "frame sequence must never decrease")
            #expect(Set(sequences).count == sequences.count, "frame sequence must strictly increase")

            let last = try #require(captured.last)
            #expect(last.width == Bus.framebufferWidth)
            #expect(last.height == Bus.framebufferHeight)
            let blackPixels = last.bits.reduce(0) { $0 + $1.nonzeroBitCount }
            let totalPixels = last.bits.count * 8
            #expect(Double(blackPixels) / Double(totalPixels) > 0.01,
                    ">1% of pixels set once the boot menu is drawn, per the M1b invariant; got \(blackPixels)/\(totalPixels)")
        }

        // MARK: pause/start round-trip

        @Test
        func pauseStopsCycleAdvancementThenStartResumes() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles > 0 })

            controller.pause()
            let afterPause = controller.debugSync { $0.cycles }
            Thread.sleep(forTimeInterval: 0.05)
            let stillAfterPause = controller.debugSync { $0.cycles }
            #expect(stillAfterPause == afterPause, "cycles must not advance while paused")

            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles > stillAfterPause },
                    "cycles should resume advancing after start() following a pause")
        }

        // MARK: reset() -> boots again

        /// Interim semantic (docs/superpowers/plans/2026-08-05-m1c-app-shell.md
        /// Task 1 "reset() interim semantics"): `reset()` tears down and
        /// recreates the `Machine`; warm reset is an M2 task.
        @Test
        func resetTearsDownAndRebootsMachine() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles >= 3_000_000 })

            controller.reset()
            // reset() leaves the fresh Machine paused (does not
            // auto-resume) -- give the mailbox a moment to process it, then
            // confirm cycles are back at 0.
            var cyclesAfterReset: UInt64 = 0
            for _ in 0..<200 {
                cyclesAfterReset = controller.debugSync { $0.cycles }
                if cyclesAfterReset == 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(cyclesAfterReset == 0, "reset() should recreate the Machine at cycles == 0")

            controller.start()
            #expect(waitForStatus(controller, timeout: 30) { $0.cycles >= 20_000_000 },
                    "the recreated Machine should boot to the menu again, same as a fresh controller")
        }

        // MARK: input events reach COPS

        /// Least-invasive observable, chosen over an ioTrace-based
        /// alternative -- see `COPS.pendingInputCount`'s doc comment
        /// (Sources/LisaCore/COPS.swift) for the full justification: this
        /// gives a deterministic, instant, zero-cycle-advance signal that
        /// `postKey`/`postMouse` reached COPS, without racing real ROM
        /// polling timing. Deliberately does NOT `start()` the controller
        /// (cycles stay at 0), so COPS's delivery-scheduling machinery
        /// never fires and the FIFO count only ever grows from what we
        /// post -- see that property's doc comment for why this makes the
        /// count change deterministic regardless of timing.
        @Test
        func postedInputEventsReachCOPS() throws {
            let controller = try makeController()

            let before = controller.debugSync { $0.bus.cops.pendingInputCount }
            controller.post(.keyDown(0x41))
            controller.post(.mouseDelta(dx: 3, dy: -2))
            let after = controller.debugSync { $0.bus.cops.pendingInputCount }

            #expect(after == before + 1 + 3,
                    "1 keyDown byte + 3 mouseDelta bytes (marker+dx+dy) should be queued into COPS")
        }

        // MARK: onFrame cross-thread reassignment (data-race fix regression)

        /// Structural regression test for `FramePublisher.onFrame`'s
        /// lock-protected get/set (a plain unsynchronized `var` there was a
        /// genuine data race: written from any caller thread, read+invoked
        /// from the emulation thread every vsync). Reassigns `onFrame`
        /// repeatedly from THIS thread while the emulation thread is
        /// running unthrottled and concurrently invoking whatever
        /// `onFrame` currently holds on every vsync -- exercises the exact
        /// concurrent access pattern the lock exists to make safe.
        ///
        /// This does not (and no single test run could) deterministically
        /// PROVE the absence of a race -- that needs a sanitizer run under
        /// contention, not a `Test` assertion. What it does verify: the
        /// reassignment itself doesn't crash/deadlock under real concurrent
        /// pressure, and -- the actually-observable correctness property --
        /// the LAST assignment wins and keeps receiving subsequent frames
        /// (which a torn/lost write from an unsynchronized `var` could
        /// plausibly break).
        @Test
        func reassigningOnFrameWhileRunningIsRaceFree() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles > 0 })

            for i in 0..<200 {
                controller.framePublisher.onFrame = { _ in _ = i }
            }

            let sem = DispatchSemaphore(value: 0)
            controller.framePublisher.onFrame = { _ in sem.signal() }
            let received = sem.wait(timeout: .now() + 10) == .success
            #expect(received, "the final onFrame assignment should still receive subsequent frames")
        }
    }
}
