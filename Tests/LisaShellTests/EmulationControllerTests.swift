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

// MARK: - Mouse-button keycap constant (no ROM/CPU needed -- runs in every
// `swift test`, ROM-gated or not; see `COPSTests
// .mouseButtonKeycapProducesTheDocumentedCOPSBytes` for the byte-level
// version of the same regression pin, one layer down)

/// Cheap constant regression pin, mirroring the reasoning in
/// `COPSTests.mouseButtonKeycapProducesTheDocumentedCOPSBytes`: this
/// constant briefly regressed to Task 1's placeholder (`$7F`) during M1c
/// Task 4 and was only caught by a ROM-gated integration test. Doesn't
/// need `makeController()`/a ROM/a `Machine` at all -- just asserts the
/// constant `EmulationController.apply(_:to:)` posts for `.mouseButton`
/// matches hardware-notes.md §8's researched value.
@Test func mouseButtonKeycapConstantMatchesHardwareNotesSection8() {
    #expect(EmulationController.mouseButtonKeycap == 0x06)
}

// MARK: - haltedStatusPublish (Important finding: "HALTED status almost
// never published"; no ROM/CPU/thread needed -- pure decision function)

/// Driving a genuine double-fault halt THROUGH `EmulationController` was
/// judged impractical for this regression: unlike `BusErrorTests`
/// (`Tests/LisaCoreTests/BusErrorTests.swift`), which constructs a bare
/// `Machine` directly and hand-loads a two-instruction double-fault program
/// at a chosen PC/SSP, `EmulationController` only ever creates its
/// `Machine` internally (`makeMachine`, private) and boots the REAL ROM
/// from `romDirectory` -- there is no seam to inject a synthetic program
/// before the ROM's own boot code starts running. **M3 Task 3 revisit:**
/// tried anyway, per the M1c re-review's sketch (boot to menu, then via
/// `debugSync` write a double-fault program + point PC/A7 into an absent
/// segment) -- see `EmulationControllerFloppyIntegrationTests`-adjacent
/// `HaltedStatusIntegrationTests`, below, which found the seam DOES exist
/// after all (the ROM-gated suite already boots a real `Machine` on a real
/// thread; `debugSync` can clobber its low-core vectors and PC once parked
/// at the idle-wait poll, exactly like `BusErrorTests`' bare-`Machine`
/// repro, just reached through the controller's public/test surface
/// instead of a hand-built `Machine`). Per the finding's own fallback
/// guidance, the transition-publish DECISION is ALSO extracted into
/// `EmulationController.haltedStatusPublish(machineHalted:alreadyPublished:
/// secondsSinceLastPublish:)`, a pure function taking no `Machine` at all,
/// and tested directly here -- this pins the exact logic bug (the old
/// code's publish was reachable only from the `running` branch, so once
/// `guard running, !machine.halted` started failing every iteration, the
/// transition published only if it happened to also cross the independent
/// 0.25s gate in the one iteration where the halt was discovered --
/// empirically ~7% of transitions) without needing a live halt to
/// reproduce it, and (M3 Task 3) additionally pins the parked-debt fix
/// itself: status must keep publishing periodically while halted, not just
/// once at the transition, so throttled-flag changes and cycle counts
/// (e.g. a later `reset()` or `setThrottled` while paused at HALT) stay
/// visible to the app instead of going stale forever.
@Suite
struct HaltedStatusPublishTests {
    @Test func firstIterationAfterHaltAlwaysForcesAPublish() {
        #expect(EmulationController.haltedStatusPublish(machineHalted: true, alreadyPublished: false,
                                                          secondsSinceLastPublish: 0))
    }

    @Test func doesNotRepublishBeforeTheIntervalElapses() {
        #expect(!EmulationController.haltedStatusPublish(machineHalted: true, alreadyPublished: true,
                                                           secondsSinceLastPublish: 0.1))
    }

    /// M3 Task 3 (M1c parked debt): the whole point of the fix -- unlike the
    /// old "exactly once, ever" behavior, once the interval has elapsed the
    /// halted branch must publish AGAIN, so a periodic ~4Hz-equivalent
    /// cadence continues while halted, matching the running branch's own
    /// `now - lastStatusPublish >= EmulationController.statusPublishInterval`
    /// gate (`EmulationController.statusPublishInterval`, below).
    @Test func republishesOnceTheIntervalElapsesWhileStillHalted() {
        #expect(EmulationController.haltedStatusPublish(
            machineHalted: true, alreadyPublished: true,
            secondsSinceLastPublish: EmulationController.statusPublishInterval))
        #expect(EmulationController.haltedStatusPublish(
            machineHalted: true, alreadyPublished: true,
            secondsSinceLastPublish: EmulationController.statusPublishInterval + 1))
    }

    @Test func neverForcesAPublishWhileNotHalted() {
        #expect(!EmulationController.haltedStatusPublish(machineHalted: false, alreadyPublished: false,
                                                           secondsSinceLastPublish: 999))
        #expect(!EmulationController.haltedStatusPublish(machineHalted: false, alreadyPublished: true,
                                                           secondsSinceLastPublish: 999))
    }

    /// The old bug's exact shape, pinned as a regression, EXTENDED for the
    /// periodic-republish fix: a decision made EVERY iteration while halted
    /// (as the guard-continue branch now is) must publish once IMMEDIATELY
    /// at the transition, then again on a fixed cadence thereafter -- never
    /// twice within one interval, never zero times across a long halt.
    /// Simulates 5 simulated seconds of iterations at a fine-grained
    /// (10ms) polling cadence -- finer than the real 5ms `Thread.sleep`
    /// this decision gates, so no publish opportunity is skipped -- and
    /// checks both bounds.
    @Test func publishesImmediatelyThenOnAFixedCadenceAcrossManyIterationsOfTheSameHalt() {
        var alreadyPublished = false
        var lastPublishTime: Double = 0
        var publishTimes: [Double] = []
        var now: Double = 0
        let step = 0.01
        while now < 5.0 {
            now += step
            if EmulationController.haltedStatusPublish(machineHalted: true, alreadyPublished: alreadyPublished,
                                                         secondsSinceLastPublish: now - lastPublishTime) {
                publishTimes.append(now)
                alreadyPublished = true
                lastPublishTime = now
            }
        }
        #expect(!publishTimes.isEmpty)
        #expect(publishTimes.first! <= step, "the first publish must happen on essentially the first iteration")
        for i in 1..<publishTimes.count {
            let gap = publishTimes[i] - publishTimes[i - 1]
            #expect(gap >= EmulationController.statusPublishInterval,
                    "no two publishes may land inside the same interval; got gap \(gap)")
        }
        // Over 5 simulated seconds at a 0.25s cadence, expect roughly 20
        // republishes (allow slack for the 0.01s simulation quantum).
        #expect(publishTimes.count >= Int(5.0 / EmulationController.statusPublishInterval) - 2)
    }
}

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

        /// M2 Task 2: `reset()` now performs a true hardware warm reset
        /// (`machine.reset()` posted through the mailbox), not the M1c
        /// interim recreate-the-Machine behavior. From this test's vantage
        /// point the externally observable outcome is the same either way
        /// (cycles back to 0, boots to the menu again) -- see
        /// `resetKeepsTheSameMachineAndBusIdentity` below for the
        /// assertion that actually distinguishes "warm reset" from
        /// "recreate".
        @Test
        func resetWarmResetsAndRebootsMachine() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles >= 3_000_000 })

            controller.reset()
            // reset() leaves the Machine paused (does not auto-resume) --
            // give the mailbox a moment to process it, then confirm cycles
            // are back at 0.
            var cyclesAfterReset: UInt64 = 0
            for _ in 0..<200 {
                cyclesAfterReset = controller.debugSync { $0.cycles }
                if cyclesAfterReset == 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(cyclesAfterReset == 0, "reset() should bring the Machine back to cycles == 0")

            controller.start()
            #expect(waitForStatus(controller, timeout: 30) { $0.cycles >= 20_000_000 },
                    "the warm-reset Machine should boot to the menu again, same as a fresh controller")
        }

        /// The assertion that actually distinguishes a warm reset from the
        /// M1c interim "recreate the Machine" behavior this task replaces:
        /// `ObjectIdentifier(machine.bus)` must be UNCHANGED across
        /// `reset()`. This is the seam the task brief asked for in place of
        /// a media-survives-reset test (Task 4's floppy image doesn't exist
        /// yet) -- proving the `Bus` (hence every device hanging off it:
        /// VIAs, COPS, MMU, and whatever Task 4 attaches later) is the SAME
        /// object after `reset()`, not a fresh one, is exactly what
        /// guarantees any future Bus-attached media state will survive a
        /// controller reset by construction, without needing that state to
        /// exist yet to prove it.
        @Test
        func resetKeepsTheSameMachineAndBusIdentity() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller, timeout: 15) { $0.cycles >= 3_000_000 })

            let busBefore = controller.debugSync { ObjectIdentifier($0.bus) }

            controller.reset()
            var cyclesAfterReset: UInt64 = 0
            var busAfter = busBefore
            for _ in 0..<200 {
                cyclesAfterReset = controller.debugSync { $0.cycles }
                busAfter = controller.debugSync { ObjectIdentifier($0.bus) }
                if cyclesAfterReset == 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(cyclesAfterReset == 0, "precondition: reset() completed")
            #expect(busAfter == busBefore,
                    "reset() must warm-reset the live Machine, not recreate it -- Bus identity (and any Task 4 media state attached to it) must survive")
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

        // MARK: mouse + click drive the REAL ROM's boot menu (M1c Task 4
        // automated backstop -- the acceptance proof that input works
        // end-to-end without a human at the keyboard/mouse)

        /// Coordinates and cycle budgets below are all trace-derived
        /// (`swift build -c release --product lisadbg`, then `lisadbg
        /// --rom ~/Development/LisaROMs` with `g 25000000` to reach the
        /// documented stable boot-menu window -- same 25M-cycle anchor as
        /// `ROMBootTests.romCompletesPOSTAndReachesBootMenu`), not guessed:
        ///
        /// **Hit-test table** -- disassembling the menu's cursor hit-test
        /// routine (`d fe2e20 60`) shows, at `$FE2E46`:
        /// ```
        /// move.w  $496.w, D6      ; D6 = cursor X
        /// move.w  $498.w, D7      ; D7 = cursor Y
        /// lea     $53a.w, A0      ; A0 -> hit-test table
        /// move.w  (A0)+, D0       ; D0 = entry count
        /// ...loop: movem.w (A0)+, D1-D5   ; D1=id, D2=xMin, D3=yMin, D4=xMax, D5=yMax
        ///          cmp.w D2,D6 / D4,D6 / D3,D7 / D5,D7   ; xMin<=X<=xMax && yMin<=Y<=yMax
        /// ```
        /// **Live table dump** at cycle 25,000,000 (`m 53a 60`) -- count
        /// `$0003` at `$53A`, then 3 five-word entries from `$53C`:
        /// | id (`$53C`+n) | xMin | yMin | xMax | yMax | button (by Y, matches the on-screen layout top-to-bottom) |
        /// |---|---|---|---|---|---|
        /// | `$F4` | 416 | 69  | 496 | 96  | RESTART |
        /// | `$F1` | 416 | 117 | 496 | 144 | CONTINUE |
        /// | `$F2` | 416 | 165 | 496 | 192 | **STARTUP FROM** |
        ///
        /// **Cursor start position** at the same cycle (`m 490 20`):
        /// `$496`=360, `$498`=182 -- matches the mouse arrow's on-screen
        /// position in docs/rom-trace-notes.md's boot-menu screenshot. Y=182
        /// already falls inside STARTUP FROM's Y range (165-192); only X
        /// needs to move right, from 360 into [416, 496].
        ///
        /// **Mouse scaling, empirically measured**: the Lisa mouse driver
        /// applies its own acceleration curve to raw deltas
        /// (hardware-notes.md §8, "OS-side scaling modes exist; the
        /// emulator sends raw deltas only") -- a single `postMouse(dx: 96,
        /// dy: 0)` packet overshoots to X=504 (outside the button), while
        /// `dx: 40` lands exactly at X=420, inside [416, 496]. `dx: 40` is
        /// the value used below.
        @Test
        func mouseAndClickDriveTheRealBootMenu() throws {
            let controller = try makeController()
            _ = controller.debugSync { machine -> Int in
                machine.run(until: 25_000_000)
                return 0
            }

            func cursorPosition() -> (x: UInt16, y: UInt16) {
                controller.debugSync { m in (m.bus.read16(0x496), m.bus.read16(0x498)) }
            }
            // 64-bit FNV-1a over the framebuffer -- same fingerprint shape
            // as ROMBootTests' anchor, used here only to detect CHANGE, not
            // to assert a specific value.
            func framebufferHash() -> UInt64 {
                controller.debugSync { m in
                    var h: UInt64 = 0xcbf2_9ce4_8422_2325
                    for b in m.bus.framebufferSnapshot() { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
                    return h
                }
            }

            let start = cursorPosition()
            #expect(start == (360, 182), "boot-menu cursor should start at the trace-documented idle position")
            let hashBeforeMove = framebufferHash()

            // MARK: Proof 1 -- mouse movement reaches COPS and moves the
            // ROM's own cursor (the framebuffer changes because the ROM
            // redrew the cursor bitmap at a new position).
            controller.post(.mouseDelta(dx: 40, dy: 0))
            _ = controller.debugSync { machine -> Int in
                // 200k cycles: well past COPS.byteDeliveryDelayCycles (300)
                // and interruptReassertDelayCycles (4000), comfortably under
                // one vsync (VideoTiming.cyclesPerVsync == 83,333) so the
                // ROM's next cursor-redraw pass has certainly run.
                machine.run(until: machine.cycles + 200_000)
                return 0
            }
            let afterMove = cursorPosition()
            #expect(afterMove == (420, 182),
                    "cursor should have moved to X=420 (inside the STARTUP FROM button) after a dx=40 packet; got \(afterMove)")
            #expect(framebufferHash() != hashBeforeMove,
                    "framebuffer must change once the ROM redraws the moved cursor")

            // MARK: Proof 2 -- a click at STARTUP FROM's coordinates changes
            // menu state: PC leaves the idle-wait poll while handling the
            // click, the ROM draws a new "STARTUP FROM" device-list window
            // (framebuffer changes substantially), then settles back into
            // its (shared) idle-wait poll once that window is drawn.
            let hashBeforeClick = framebufferHash()
            controller.post(.mouseButton(down: true))
            _ = controller.debugSync { machine -> Int in
                machine.run(until: machine.cycles + 5_000)
                return 0
            }
            let pcDuringClick = controller.debugSync { $0.cpu[.pc] }
            #expect(!(0x00FE_2DBE...0x00FE_2DD6).contains(pcDuringClick),
                    "PC should have left the boot-menu idle-wait poll while handling the click; got \(String(format: "%08X", pcDuringClick))")

            controller.post(.mouseButton(down: false))
            _ = controller.debugSync { machine -> Int in
                // 3M cycles: comfortably enough for the ROM to draw the
                // STARTUP FROM window and settle back into idle-wait
                // (empirically settles well within this budget).
                machine.run(until: machine.cycles + 3_000_000)
                return 0
            }
            let pcSettled = controller.debugSync { $0.cpu[.pc] }
            #expect((0x00FE_2DBE...0x00FE_2DD6).contains(pcSettled),
                    "ROM should settle back into the shared idle-wait poll once the STARTUP FROM window is drawn; got \(String(format: "%08X", pcSettled))")

            let hashAfterClick = framebufferHash()
            #expect(hashAfterClick != hashBeforeClick,
                    "clicking STARTUP FROM should draw a new window (device list), changing the framebuffer")
        }
    }
}

// MARK: - M3 Task 3 (M1c parked debt, "halted-status staleness"): the
// debugSync-based GENUINE halt this task's ledger asked us to try, per the
// M1c re-review's sketch -- boot the real ROM to the menu, then via
// `debugSync` write a double-fault program and point PC/A7 into an absent
// segment. `HaltedStatusPublishTests` above judged this impractical for the
// ORIGINAL "almost never published" bug (no seam existed to inject a
// program before the ROM's own boot code ran); revisited here because the
// seam DOES exist once the Machine is already live and parked at the
// boot-menu idle-wait poll -- `debugSync` gives the same raw `Machine`
// access `BusErrorTests` uses on a bare `Machine`, just reached through the
// controller's already-booted one instead of a hand-built one.

extension LisaShellMusashiSuites {
    @Suite(.enabled(if: romDir != nil, "Set LISAEMU_ROM_DIR to run the genuine-halt integration test"))
    struct HaltedStatusIntegrationTests {
        private func makeController() throws -> EmulationController {
            try EmulationController(romDirectory: URL(fileURLWithPath: romDir!))
        }

        /// **The M3 Task 3 acceptance test for item 1**: drives a REAL
        /// double bus fault through the controller's live, already-booted
        /// `Machine`, then observes the CONTROLLER's own background loop --
        /// not the pure `haltedStatusPublish` decision function
        /// `HaltedStatusPublishTests` exercises -- republish HALTED status
        /// periodically. Before this task's fix, the transition publish was
        /// the ONLY publish ever delivered for a given halt; this test
        /// would have hung on its second `publishSem.wait` (timing out
        /// after 5s) against the pre-fix code.
        @Test
        func haltedStatusRepublishesPeriodicallyAfterAGenuineDoubleFault() throws {
            let controller = try makeController()

            // Boot to the menu's idle-wait poll -- same 25M-cycle anchor as
            // `mouseAndClickDriveTheRealBootMenu`, above. Driven entirely
            // through `debugSync`, with the controller's `start()` never
            // called: the background thread's mailbox-drain loop (and its
            // halted-branch status publish) is already spinning from the
            // moment `makeController()` returns regardless of `running`, so
            // once the live `Machine` flips `halted` under it (below), that
            // loop discovers it on its very next iteration exactly as it
            // would during a real `start()`-driven run.
            controller.debugSync { m in m.run(until: 25_000_000) }

            // Genuine double bus fault -- same mechanism as `BusErrorTests
            // .doubleBusFaultDuringExceptionStackingHalts`
            // (Tests/LisaCoreTests/BusErrorTests.swift), reached here on the
            // live, already-booted Machine instead of a hand-built one:
            // force two segments in the CPU's currently-active domain
            // absent (explicitly, regardless of what the ROM's boot-to-menu
            // path happened to map -- segments 100/101 are unused by it in
            // any case, per docs/rom-trace-notes.md "OQ2"'s segment
            // inventory), point PC at one and both stack-pointer registers
            // at the other, then step. Instruction fetch at PC faults
            // (segment absent); pushing the resulting exception frame
            // through the also-absent supervisor stack pointer faults a
            // SECOND time while already stacking -- a genuine double bus
            // fault, which `Bus`'s consecutive-fault tracking turns into
            // `cpu.forceHalt()`.
            let halted = controller.debugSync { m -> Bool in
                let domain = m.bus.domain
                m.bus.mmu.domains[domain][100] = SegmentRegister()
                m.bus.mmu.domains[domain][101] = SegmentRegister()
                let faultingPC = UInt32(100) * MMU.segmentSize
                let faultingSSP = UInt32(101) * MMU.segmentSize
                m.cpu[.sr] |= 0x2000       // force supervisor mode (already true at the boot menu)
                m.cpu[.isp] = faultingSSP  // whichever stack pointer the exception path uses...
                m.cpu[.a7] = faultingSSP   // ...both point into the absent segment.
                m.cpu[.pc] = faultingPC
                for _ in 0..<10 where !m.halted { _ = m.step() }
                return m.halted
            }
            #expect(halted, "the crafted double-fault program should have halted the live, already-booted Machine")

            // Observe the CONTROLLER's background loop -- not the pure
            // function -- publish HALTED status more than once.
            let publishSem = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var statuses: [EmuStatus] = []
            controller.onStatus = { status in
                lock.lock(); statuses.append(status); lock.unlock()
                publishSem.signal()
            }

            // First (transition) publish: immediate, no interval gate --
            // this part alone was already fixed before M3 Task 3 (the
            // "HALTED status almost never published" finding).
            #expect(publishSem.wait(timeout: .now() + 5) == .success,
                    "the transition publish should fire promptly")

            // Toggle throttled mid-halt -- proves the second publish isn't
            // some other coincidental signal: it must reflect mailbox state
            // that changed strictly AFTER the transition publish, which
            // only a genuine PERIODIC republish (not a one-shot) can ever
            // surface to the app.
            controller.throttled = true

            // Second, periodic republish -- this is the M3 Task 3 fix under
            // test. Pre-fix, `haltedStatusPublish` never answered `true`
            // again for the same halt, so this would time out.
            #expect(publishSem.wait(timeout: .now() + 5) == .success,
                    "a periodic republish should follow ~statusPublishInterval after the transition publish")

            lock.lock(); let captured = statuses; lock.unlock()
            #expect(captured.count >= 2)
            #expect(captured.allSatisfy { $0.halted }, "every published status while halted must report halted == true")
            #expect(captured.last?.throttled == true,
                    "the periodic republish should reflect the throttle toggle issued after the transition publish")
        }
    }
}

// MARK: - M2 Task 7: insertFloppy/ejectFloppy through EmulationController's
// public mailbox API (ROM-gated only -- these use a small hand-built
// synthetic DC42 image written to a temp file, not a real Lisa disk image,
// so LISAEMU_DISK_DIR is not required). The ROM+DISK-gated integration test
// proving the full app-facing boot-into-loader path lives in
// `EmulationControllerFloppyIntegrationTests`, below.

extension LisaShellMusashiSuites {
    @Suite(.enabled(if: romDir != nil, "Set LISAEMU_ROM_DIR to run floppy controller tests"))
    struct EmulationControllerFloppyTests {
        private func makeController() throws -> EmulationController {
            try EmulationController(romDirectory: URL(fileURLWithPath: romDir!))
        }

        @discardableResult
        private func waitForStatus(_ controller: EmulationController, timeout: TimeInterval = 15,
                                    _ predicate: @escaping (EmuStatus) -> Bool) -> Bool {
            let sem = DispatchSemaphore(value: 0)
            controller.onStatus = { status in
                if predicate(status) { sem.signal() }
            }
            let result = sem.wait(timeout: .now() + timeout)
            controller.onStatus = nil
            return result == .success
        }

        /// Hand-builds a minimal-but-valid DC42 container (small block
        /// count -- no need for a full 800-block image just to exercise
        /// insert/eject plumbing) and writes it to a fresh temp file, per
        /// block, mirroring `FloppyControllerTests.makeSyntheticImage`'s
        /// container-assembly shape one layer down (LisaCoreTests can't be
        /// imported from here -- separate SwiftPM test target -- so this is
        /// a deliberate small duplicate, not a shared helper).
        private func makeSyntheticDC42File(blockCount: Int = 4) throws -> URL {
            var dataPlane = [UInt8](repeating: 0, count: blockCount * 512)
            var tagPlane = [UInt8](repeating: 0, count: blockCount * 12)
            for block in 0..<blockCount {
                for i in 0..<512 { dataPlane[block * 512 + i] = UInt8(truncatingIfNeeded: block &* 7 &+ i) }
                for i in 0..<12 { tagPlane[block * 12 + i] = UInt8(truncatingIfNeeded: block &* 3 &+ i &+ 1) }
            }
            var container = Data()
            let name = "TEST"
            var pascalString = Data([UInt8(name.utf8.count)])
            pascalString.append(contentsOf: Array(name.utf8))
            container.append(pascalString)
            container.append(Data(repeating: 0, count: 64 - pascalString.count))
            var dataLen = UInt32(dataPlane.count).bigEndian
            container.append(Data(bytes: &dataLen, count: 4))
            var tagLen = UInt32(tagPlane.count).bigEndian
            container.append(Data(bytes: &tagLen, count: 4))
            container.append(Data(repeating: 0, count: 8))
            container.append(Data(repeating: 0, count: 4))
            container.append(Data(dataPlane))
            container.append(Data(tagPlane))

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmulationControllerFloppyTests-\(UUID().uuidString).dc42")
            try container.write(to: url)
            return url
        }

        // MARK: insertFloppy -> Bus/FloppyController state + EmuStatus.diskInserted

        @Test
        func insertFloppyAttachesImageAndStatusReportsDiskInserted() throws {
            let controller = try makeController()
            let diskURL = try makeSyntheticDC42File()

            controller.insertFloppy(url: diskURL)
            let inserted = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(inserted, "insertFloppy(url:) should attach the image to the live Machine's FloppyController")

            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller) { $0.diskInserted },
                    "EmuStatus.diskInserted should reflect the attached image")
        }

        /// Same shape as `makeSyntheticDC42File`, but tagless (`tagLen == 0`,
        /// no tag-plane bytes) -- the through-the-controller regression case
        /// for M2 review Finding 1: a valid but tagless DC42 container
        /// (common for wild Mac-disk DC42s -- exactly what drag-and-drop
        /// invites) used to crash the emulation thread on its first block
        /// read (`DC42Image` stored an empty tag plane, and
        /// `FloppyController.performRead`'s `image.tag(block:)` trapped on
        /// it). `DC42Image.init` now synthesizes zero tags for a tagless
        /// container instead, so insertion must succeed cleanly here.
        private func makeTaglessSyntheticDC42File(blockCount: Int = 4) throws -> URL {
            var dataPlane = [UInt8](repeating: 0, count: blockCount * 512)
            for block in 0..<blockCount {
                for i in 0..<512 { dataPlane[block * 512 + i] = UInt8(truncatingIfNeeded: block &* 7 &+ i) }
            }
            var container = Data()
            let name = "TAGLESS"
            var pascalString = Data([UInt8(name.utf8.count)])
            pascalString.append(contentsOf: Array(name.utf8))
            container.append(pascalString)
            container.append(Data(repeating: 0, count: 64 - pascalString.count))
            var dataLen = UInt32(dataPlane.count).bigEndian
            container.append(Data(bytes: &dataLen, count: 4))
            var tagLen: UInt32 = 0
            container.append(Data(bytes: &tagLen, count: 4))
            container.append(Data(repeating: 0, count: 8))
            container.append(Data(repeating: 0, count: 4))
            container.append(Data(dataPlane))
            // Deliberately no tag-plane bytes -- tagless container.

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmulationControllerFloppyTests-tagless-\(UUID().uuidString).dc42")
            try container.write(to: url)
            return url
        }

        // MARK: insertFloppy of a tagless image -> no crash, disk shows inserted
        // (M2 review Finding 1 -- through-the-controller regression test)

        @Test
        func insertFloppyWithTaglessImageDoesNotCrashAndReportsDiskInserted() throws {
            let controller = try makeController()
            let diskURL = try makeTaglessSyntheticDC42File()

            controller.insertFloppy(url: diskURL)
            let inserted = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(inserted, "a tagless-but-otherwise-valid DC42 container should insert successfully")

            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller) { $0.diskInserted },
                    "EmuStatus.diskInserted should reflect the attached tagless image")

            // Never a crash: drive an actual block read through the go-byte
            // protocol (the exact path that used to trap on the empty tag
            // plane) and confirm the emulation thread is still alive and
            // answering afterward. Same literal-offset technique as
            // `diskActivityFlipsTrueWhenFloppyProcessesACommand` above
            // (`LisaCore.FloppyController.Cell`/`GoByte`/`SubCommand` are
            // internal, not visible from this module's non-`@testable`
            // `import LisaCore`): DISKPARM=$03 readdisk(0), DISKHEAD=$07,
            // DISKSEC=$09, DISKTRAK=$0B, DISKCMD=$01 excmd($81).
            controller.debugSync { m in
                m.bus.write8(0x00FC_C003, 0)      // DISKPARM = readdisk
                m.bus.write8(0x00FC_C007, 0)      // DISKHEAD
                m.bus.write8(0x00FC_C009, 0)      // DISKSEC
                m.bus.write8(0x00FC_C00B, 0)      // DISKTRAK
                m.bus.write8(0x00FC_C001, 0x81)   // DISKCMD = excmd
            }
            #expect(waitForStatus(controller) { $0.diskActivity },
                    "the read command should complete (and not crash the emulation thread) on a tagless image")
            let cycles = controller.debugSync { $0.cycles }
            #expect(cycles > 0, "the emulation thread should still be alive and answering debugSync after the read")
        }

        // MARK: ejectFloppy -> Bus/FloppyController state + EmuStatus.diskInserted

        @Test
        func ejectFloppyDetachesImageAndStatusReportsDiskNotInserted() throws {
            let controller = try makeController()
            let diskURL = try makeSyntheticDC42File()

            controller.insertFloppy(url: diskURL)
            #expect(controller.debugSync { $0.bus.floppy.isInserted })

            controller.ejectFloppy()
            let stillInserted = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(!stillInserted, "ejectFloppy() should detach the image")

            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller) { !$0.diskInserted },
                    "EmuStatus.diskInserted should reflect the ejection")
        }

        // MARK: media survives reset() -- Task 2's warm-reset design, proven
        // end-to-end through the app-facing insertFloppy/reset() API (the
        // ledger's explicit ask for this task)

        @Test
        func insertedMediaSurvivesReset() throws {
            let controller = try makeController()
            let diskURL = try makeSyntheticDC42File()

            controller.insertFloppy(url: diskURL)
            #expect(controller.debugSync { $0.bus.floppy.isInserted },
                    "precondition: disk inserted before reset")

            controller.reset()
            // `debugSync` is itself the deterministic drain barrier proving
            // `reset()` was processed: per its own doc comment, it blocks
            // until the mailbox has been drained "up to and including this
            // request" -- `.reset` was posted strictly before this `.debug`
            // command, so FIFO draining guarantees `machine.reset()` has
            // already run by the time this closure executes. (Fix, code
            // review: the previous version polled `cycles == 0` in a loop
            // as a proxy for "reset happened," but this controller is never
            // started here -- cycles are 0 the whole time regardless of
            // whether reset ran -- so that loop always exited on its first
            // iteration and proved nothing. `debugSync`'s own FIFO ordering
            // guarantee is the real proof, not an observed side effect.)
            let insertedAfterReset = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(insertedAfterReset,
                    "media must survive reset() by construction (Task 2's warm-reset design; Bus/FloppyController identity never changes) -- proven here through the app-facing insertFloppy()/reset() API")
        }

        // MARK: insertFloppy load failure -> onDiskError, never a crash

        @Test
        func insertFloppyWithBadURLReportsErrorInsteadOfCrashing() throws {
            let controller = try makeController()
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("does-not-exist-\(UUID().uuidString).dc42")

            // Lock-guarded, mirroring `mouseAndClickDriveTheRealBootMenu`'s
            // `framesLock` pattern above: `onDiskError` fires on the
            // emulation thread, this closure reads back on the test thread.
            let sem = DispatchSemaphore(value: 0)
            let messageLock = NSLock()
            var message: String?
            controller.onDiskError = { msg in
                messageLock.lock(); message = msg; messageLock.unlock()
                sem.signal()
            }

            controller.insertFloppy(url: missingURL)
            let received = sem.wait(timeout: .now() + 10) == .success
            #expect(received, "onDiskError should fire for a load failure")
            messageLock.lock(); let capturedMessage = message; messageLock.unlock()
            #expect(capturedMessage?.contains(missingURL.lastPathComponent) == true,
                    "the error message should reference the offending path; got \(capturedMessage ?? "nil")")

            // Never a crash: the controller stays fully functional afterward.
            let stillInserted = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(!stillInserted, "a failed insert must not leave a partial/inserted image")
            let cycles = controller.debugSync { $0.cycles }
            #expect(cycles == 0, "the emulation thread should still be alive and answering debugSync after a failed insert")
        }

        // MARK: EmuStatus.diskActivity -- flips true once the floppy
        // processes a go-byte command, independent of a real disk image or
        // ROM menu interaction: drives the memory-mapped protocol directly
        // (docs/hardware-notes.md §9, DISKCMD offset $01 within the
        // $FCC000-$FCC7FF window) through the public `Bus.write8` API.

        @Test
        func diskActivityFlipsTrueWhenFloppyProcessesACommand() throws {
            let controller = try makeController()
            controller.throttled = false
            controller.start()
            #expect(waitForStatus(controller) { $0.cycles > 0 })

            // nulcmd ($80) go-byte at DISKCMD ($FCC001) -- a handshake-only
            // command (no disk needed), processed `commandDelayCycles`
            // later and counted by `FloppyController.commandsProcessed`.
            controller.debugSync { m in m.bus.write8(0x00FC_C001, 0x80) }

            let sawActivity = waitForStatus(controller) { $0.diskActivity }
            #expect(sawActivity, "diskActivity should flip true once the floppy finishes processing the nulcmd go-byte")
        }

        // MARK: M5 Task 2 -- attachWidget/detachWidget through the mailbox seam

        /// A raw N x 532-byte all-zero Widget image file (512 data + 20 tag
        /// per block), written by hand -- LisaShellTests can't reach
        /// `LisaCore.WidgetImage` through its non-`@testable import LisaCore`,
        /// so this mirrors `makeSyntheticDC42File`'s hand-built-bytes shape.
        private func makeBlankWidgetFile(blockCount: Int = 4) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmulationControllerWidgetTests-\(UUID().uuidString).widget")
            try Data(count: blockCount * 532).write(to: url)
            return url
        }

        @Test
        func attachWidgetOpensExistingImageAndDetachReleasesIt() throws {
            let controller = try makeController()
            let widgetURL = try makeBlankWidgetFile()
            defer { try? FileManager.default.removeItem(at: widgetURL) }

            controller.attachWidget(url: widgetURL)
            #expect(controller.debugSync { $0.bus.widget.isAttached },
                    "attachWidget(url:) should attach the image to the live Machine's WidgetDrive")

            controller.detachWidget()
            #expect(controller.debugSync { !$0.bus.widget.isAttached },
                    "detachWidget() should release the image")
        }

        @Test
        func attachWidgetCreatesBlankImageOnDemandWhenFileIsMissing() throws {
            let controller = try makeController()
            let widgetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmulationControllerWidgetTests-new-\(UUID().uuidString).widget")
            defer { try? FileManager.default.removeItem(at: widgetURL) }
            #expect(!FileManager.default.fileExists(atPath: widgetURL.path))

            controller.attachWidget(url: widgetURL)   // path does not exist -> blank on demand (§10.10)
            #expect(controller.debugSync { $0.bus.widget.isAttached })
            #expect(FileManager.default.fileExists(atPath: widgetURL.path),
                    "a missing Widget path should be created as an all-zero blank image (§10.10)")
            let size = try FileManager.default.attributesOfItem(atPath: widgetURL.path)[.size] as? Int
            #expect(size == 19456 * 532, "the on-demand blank should be the default Widget-10 geometry")
        }

        @Test
        func attachedWidgetSurvivesReset() throws {
            let controller = try makeController()
            let widgetURL = try makeBlankWidgetFile()
            defer { try? FileManager.default.removeItem(at: widgetURL) }

            controller.attachWidget(url: widgetURL)
            #expect(controller.debugSync { $0.bus.widget.isAttached })

            controller.reset()   // warm reset -- media survives by construction
            #expect(controller.debugSync { $0.bus.widget.isAttached },
                    "an attached Widget must survive reset() (same warm-reset design as the floppy)")
        }
    }
}

// MARK: - M2 Task 7: ROM+DISK-gated integration test -- the M2 demo, made
// automatic through the app-facing (EmulationController public) surface.

private let floppyIntegrationDiskDir = ProcessInfo.processInfo.environment["LISAEMU_DISK_DIR"]

extension LisaShellMusashiSuites {
    @Suite(.enabled(if: romDir != nil && floppyIntegrationDiskDir != nil,
                    "Set LISAEMU_ROM_DIR and LISAEMU_DISK_DIR to run the floppy-boot app-integration test"))
    struct EmulationControllerFloppyIntegrationTests {
        private func makeController() throws -> EmulationController {
            try EmulationController(romDirectory: URL(fileURLWithPath: romDir!))
        }

        /// Same technique as `ROMFloppyBootTests.moveCursor`
        /// (`Tests/LisaCoreTests/ROMFloppyBootTests.swift`), routed through
        /// `EmulationController.post(_:)`/`debugSync(_:)` instead of a bare
        /// `Machine` -- the app-facing path this task integrates.
        private func moveCursor(_ controller: EmulationController, to tx: Int, _ ty: Int) {
            for _ in 0..<24 {
                let (cx, cy) = controller.debugSync { m in (Int(m.bus.read16(0x496)), Int(m.bus.read16(0x498))) }
                if abs(cx - tx) <= 1 && abs(cy - ty) <= 1 { return }
                controller.post(.mouseDelta(dx: Int8(max(-120, min(120, tx - cx))),
                                             dy: Int8(max(-120, min(120, ty - cy)))))
                controller.debugSync { m in m.run(until: m.cycles + 250_000) }
            }
        }

        /// Same technique as `ROMFloppyBootTests.click`.
        private func click(_ controller: EmulationController) {
            controller.post(.mouseButton(down: true))
            controller.debugSync { m in m.run(until: m.cycles + 300_000) }
            controller.post(.mouseButton(down: false))
            controller.debugSync { m in m.run(until: m.cycles + 300_000) }
        }

        /// Drives the identical scripted sequence as `ROMFloppyBootTests
        /// .bootIntoLoader()` -- POST to the menu, click "STARTUP FROM…",
        /// click the top device item, step into the boot block at
        /// `$020000`, then step until the loader's TRAP #6 segment gate
        /// (`$A84000`) is reached -- but entirely through
        /// `EmulationController`'s PUBLIC surface: `insertFloppy(url:)`
        /// (not `machine.bus.floppy.insert(_:)` directly), `post(_:)` for
        /// input, and `debugSync(_:)` for the same test-observability/
        /// cycle-driving seam every other `EmulationControllerTests` test in
        /// this file already uses (see e.g. `mouseAndClickDriveTheRealBootMenu`,
        /// above). This is "the M2 demo, made automatic" through the
        /// app-facing path, per the task brief.
        private func bootIntoLoader(_ controller: EmulationController, diskURL: URL) {
            controller.insertFloppy(url: diskURL)
            // FIFO mailbox ordering + debugSync's "drained up to and
            // including this request" contract (its own doc comment)
            // guarantees the insert above has already been applied by the
            // time this closure runs.
            controller.debugSync { m in m.run(until: 18_000_000) }
            moveCursor(controller, to: 420, 182); click(controller)          // "STARTUP FROM…"
            controller.debugSync { m in m.run(until: m.cycles + 3_000_000) }
            moveCursor(controller, to: 88, 33); click(controller)            // top device item
            controller.debugSync { m in
                let lim0 = m.cycles + 40_000_000
                while m.cycles < lim0 && !m.halted && m.cpu[.pc] != 0x0002_0000 { _ = m.step() }
            }
            controller.debugSync { m in
                let lim1 = m.cycles + 5_000_000
                while m.cycles < lim1 && !m.halted && m.cpu[.pc] != 0x00A8_4000 { _ = m.step() }
            }
        }

        /// **M2 EXIT CRITERION, through the app-facing path.** Asserts the
        /// same loader-execution markers `ROMFloppyBootTests
        /// .osLoaderExecutesFromRAMAndReachesPascalSegmentGate` documents
        /// (`Tests/LisaCoreTests/ROMFloppyBootTests.swift`; full narrative
        /// in `docs/rom-trace-notes.md` "OS loader (Task 6)"): the loader
        /// relocates to `$100000`, reads >=20 blocks off the floppy (exact
        /// anchor 24: 23 code blocks + block 28 MDDF), writes `dev_type
        /// ($22E)` = 2 (`dev_sony`), and installs its own TRAP #6 segment
        /// gate at `$A84000` -- reached here via `insertFloppy(url:)` +
        /// the proven scripted menu-selection sequence instead of reaching
        /// into `Machine`/`Bus` directly.
        @Test
        func insertFloppyThenScriptedBootReachesTaskSixLoaderMarkers() throws {
            let controller = try makeController()
            let diskURL = URL(fileURLWithPath: floppyIntegrationDiskDir! + "/OS31_Install_1.dc42")

            bootIntoLoader(controller, diskURL: diskURL)

            let ldbaseptr = controller.debugSync { $0.bus.read32(0x21C) }
            #expect(ldbaseptr == 0x0010_0000, "ldbaseptr ($21C) should be prom_realsize/2 = $100000")

            let blocksRead = controller.debugSync { $0.bus.floppy.blocksRead }
            #expect(blocksRead >= 20, "the loader should read many blocks off the floppy; got \(blocksRead)")
            #expect(blocksRead == 24, "exact anchor: 23 loader code blocks + block 28 (MDDF) = 24")

            let lastError = controller.debugSync { $0.bus.floppy.lastError }
            #expect(lastError == 0, "every loader block read should succeed (DISKERR 0)")

            let devType = controller.debugSync { $0.bus.read16(0x22E) }
            #expect(devType == 2, "dev_type ($22E) should be dev_sony (2)")

            let vec98 = controller.debugSync { $0.bus.read32(0x98) }
            #expect(vec98 == 0x00A8_4000,
                    "the loader should install its own TRAP #6 handler ($A84000) over the PROM's ($FE1D14)")

            let halted = controller.debugSync { $0.halted }
            #expect(!halted, "the loader run is a live progression, not a halt")

            // App-facing surface: the disk this task's `insertFloppy(url:)`
            // attached is still reported inserted through `Bus.floppy`
            // directly (the same object `EmuStatus.diskInserted` samples).
            let stillInserted = controller.debugSync { $0.bus.floppy.isInserted }
            #expect(stillInserted, "the disk inserted via the public API should still be attached at the loader gate")
        }
    }
}
