import Foundation
import Testing
@testable import LisaShell

/// Job-boundary semantics for `PrintJobSpooler`. All timing is via the
/// injected `tick(now:)` clock — **no real sleeps**.
@Suite
struct PrintJobSpoolerTests {

    /// A trivial distinct page (geometry doesn't matter for grouping).
    static func page(_ w: Int = 8) -> PrinterPage {
        PrinterPage(width: w, height: 1, bits: [UInt8](repeating: 0, count: (w + 7) / 8),
                    dpi: (h: 160, v: 144))
    }

    static func makeSpooler(idle: TimeInterval = 2.0)
        -> (PrintJobSpooler, () -> [[PrinterPage]]) {
        let spooler = PrintJobSpooler(idleWindow: idle)
        var jobs: [[PrinterPage]] = []
        spooler.onJob = { jobs.append($0) }
        return (spooler, { jobs })
    }

    @Test
    func pagesBeforeIdleGroupIntoOneJob() {
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.feed(page: Self.page())
        s.feed(page: Self.page())
        s.tick(now: 1.0)          // 1s < 2s idle → still open
        #expect(jobs().isEmpty)
        #expect(s.hasOpenJob)
        s.tick(now: 2.0)          // exactly the window → close
        #expect(jobs().count == 1)
        #expect(jobs()[0].count == 3)
        #expect(!s.hasOpenJob)
    }

    @Test
    func idleBelowWindowDoesNotClose() {
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.tick(now: 1.99)
        #expect(jobs().isEmpty)
        #expect(s.hasOpenJob)
    }

    @Test
    func newPagesAfterCloseReopenASecondJob() {
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.tick(now: 3.0)          // close job 1
        #expect(jobs().count == 1)
        // Reopen: activity now anchors at the current clock (3.0).
        s.feed(page: Self.page())
        s.feed(page: Self.page())
        s.tick(now: 4.0)          // 1s since 3.0 → still open
        #expect(jobs().count == 1)
        s.tick(now: 5.0)          // 2s since 3.0 → close job 2
        #expect(jobs().count == 2)
        #expect(jobs()[1].count == 2)
    }

    @Test
    func ticksWithNoPagesNeverEmit() {
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.tick(now: 10)
        s.tick(now: 100)
        #expect(jobs().isEmpty)
        #expect(!s.hasOpenJob)
    }

    @Test
    func feedBeforeAnyTickAnchorsAtZero() {
        let (s, jobs) = Self.makeSpooler()
        s.feed(page: Self.page())   // now == 0 by default
        s.tick(now: 1.0)
        #expect(jobs().isEmpty)     // 1s < 2s
        s.tick(now: 2.0)
        #expect(jobs().count == 1)
    }

    @Test
    func closeForcesImmediateEmissionRegardlessOfIdle() {
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.feed(page: Self.page())
        s.close()                   // no idle elapsed
        #expect(jobs().count == 1)
        #expect(jobs()[0].count == 2)
        #expect(!s.hasOpenJob)
    }

    @Test
    func closeWithNoOpenJobIsNoOp() {
        let (s, jobs) = Self.makeSpooler()
        s.close()
        s.tick(now: 5)
        s.close()
        #expect(jobs().isEmpty)
    }

    @Test
    func aLateFeedWithinWindowKeepsJobOpen() {
        // Idle resets on each feed: pages dribbling in under the window stay
        // in one job even across a long total span.
        let (s, jobs) = Self.makeSpooler()
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.tick(now: 1.5)
        s.feed(page: Self.page())   // resets activity to 1.5
        s.tick(now: 3.0)            // 1.5s since 1.5 → still open
        #expect(jobs().isEmpty)
        s.tick(now: 3.5)            // 2.0s since 1.5 → close
        #expect(jobs().count == 1)
        #expect(jobs()[0].count == 2)
    }

    @Test
    func customIdleWindowIsHonored() {
        let (s, jobs) = Self.makeSpooler(idle: 0.5)
        s.tick(now: 0)
        s.feed(page: Self.page())
        s.tick(now: 0.4)
        #expect(jobs().isEmpty)
        s.tick(now: 0.5)
        #expect(jobs().count == 1)
    }

    @Test
    func endToEndInterpreterToSpooler() {
        // Interpreter emits pages; spooler groups them into a job on idle.
        let interp = ImageWriterInterpreter()
        let (s, jobs) = Self.makeSpooler()
        interp.onPage = { s.feed(page: $0) }

        s.tick(now: 0)
        let esc: UInt8 = 27, ff: UInt8 = 12
        func band() -> [UInt8] {
            [esc, UInt8(ascii: "G"), 0x30, 0x30, 0x30, 0x31, 0x80]  // ESC G 0001 <col>
        }
        for _ in 0..<3 {            // three form-fed pages
            interp.feed(band())
            interp.feed(ff)
        }
        #expect(s.hasOpenJob)
        s.tick(now: 2.0)            // idle → one job of 3 pages
        #expect(jobs().count == 1)
        #expect(jobs()[0].count == 3)
    }
}
