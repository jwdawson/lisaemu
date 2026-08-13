import Foundation
import Testing
@testable import LisaShell
import LisaCore

/// `PrinterPipeline` glues the `PrinterPort` adapter → interpreter → spooler.
/// These exercise the seam host-free (no ROM/CPU): bytes pushed through the
/// `PrinterPort` (exactly as `SCC8530` channel-B does) come out as grouped
/// jobs, with the same injected-clock idle semantics the spooler defines.
@Suite
struct PrinterPipelineTests {
    /// One inked graphics band + form-feed = one page, reusing the byte
    /// grammar `PrintJobSpoolerTests` documents (`ESC G 0001 <col>` then `FF`).
    static func inkOnePageThenFormFeed(_ port: PrinterPort) {
        let esc: UInt8 = 27, ff: UInt8 = 12
        for b in [esc, UInt8(ascii: "G"), 0x30, 0x30, 0x30, 0x31, 0x80] { port.transmit(b) }
        port.transmit(ff)
    }

    @Test
    func bytesThroughThePortBecomeAGroupedJobOnIdle() {
        let pipeline = PrinterPipeline()
        var jobs: [[PrinterPage]] = []
        pipeline.onJob = { jobs.append($0) }

        pipeline.tick(now: 0)
        Self.inkOnePageThenFormFeed(pipeline.printerPort)   // page 1
        Self.inkOnePageThenFormFeed(pipeline.printerPort)   // page 2
        #expect(pipeline.spooler.hasOpenJob)
        #expect(jobs.isEmpty, "no job before the idle window elapses")

        pipeline.tick(now: 2.0)                             // idle → close
        #expect(jobs.count == 1)
        #expect(jobs[0].count == 2, "both form-fed pages land in one job")
    }

    @Test
    func flushForceClosesAPartialPageAndJobImmediately() {
        let pipeline = PrinterPipeline()
        var jobs: [[PrinterPage]] = []
        pipeline.onJob = { jobs.append($0) }

        pipeline.tick(now: 0)
        // Ink a band but DON'T form-feed — the page is dirty but unclosed.
        let esc: UInt8 = 27
        for b in [esc, UInt8(ascii: "G"), 0x30, 0x30, 0x30, 0x31, 0x80] { pipeline.printerPort.transmit(b) }
        #expect(jobs.isEmpty)

        pipeline.flush()                                    // emit partial + close
        #expect(jobs.count == 1)
        #expect(jobs[0].count == 1, "the partial page is flushed as one page")
    }

    @Test
    func portReportsReadyAndForwardsEveryByteInOrder() {
        // The adapter is an infinitely-fast sink (matches SCC RR0 Tx-empty).
        let pipeline = PrinterPipeline()
        #expect(pipeline.printerPort.isReady)
        // A page's worth of bytes all reach the interpreter (transmit never
        // drops): feed a full band and confirm one page emerges on flush.
        var jobs: [[PrinterPage]] = []
        pipeline.onJob = { jobs.append($0) }
        pipeline.tick(now: 0)
        Self.inkOnePageThenFormFeed(pipeline.printerPort)
        pipeline.flush()
        #expect(jobs.count == 1 && jobs[0].count == 1)
    }
}
