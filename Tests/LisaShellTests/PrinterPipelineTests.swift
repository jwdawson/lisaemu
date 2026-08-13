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
    func bytesThroughThePortBecomeAGroupedJobOnByteIdle() {
        let pipeline = PrinterPipeline()
        var jobs: [[PrinterPage]] = []
        pipeline.onJob = { jobs.append($0) }

        Self.inkOnePageThenFormFeed(pipeline.printerPort)   // page 1
        Self.inkOnePageThenFormFeed(pipeline.printerPort)   // page 2
        pipeline.tick(now: 0)                               // observes the bytes → activity at t=0
        #expect(jobs.isEmpty, "no job while bytes are still recent")

        pipeline.tick(now: 1.0)                             // 1s idle < 2s → still open
        #expect(jobs.isEmpty)
        pipeline.tick(now: 2.0)                             // 2s byte-idle → flush + close
        #expect(jobs.count == 1)
        #expect(jobs[0].count == 2, "both form-fed pages land in one job")
    }

    /// The M7 Task 4 regression this pipeline exists to prevent: a print whose
    /// last page never reaches an LF page-length overflow (a one-line document)
    /// leaves a DIRTY PARTIAL page in the interpreter that only a flush emits.
    /// Byte-idle must flush the interpreter, not just tick the spooler — else
    /// the job never closes (the live-print bug: bytes flowed, no PNG/panel).
    @Test
    func aPartialUnejectedPageIsFlushedAndClosedOnByteIdle() {
        let pipeline = PrinterPipeline()
        var jobs: [[PrinterPage]] = []
        pipeline.onJob = { jobs.append($0) }

        // Ink a band but send NO form-feed and NO page-length LFs — exactly the
        // one-line-print shape. The page is dirty but never emitted on its own.
        let esc: UInt8 = 27
        for b in [esc, UInt8(ascii: "G"), 0x30, 0x30, 0x30, 0x31, 0x80] { pipeline.printerPort.transmit(b) }
        pipeline.tick(now: 0)                               // activity
        #expect(jobs.isEmpty, "nothing closed while the page is only partial")

        pipeline.tick(now: 2.0)                             // byte-idle → flush the partial page + close
        #expect(jobs.count == 1, "the unejected partial page still becomes a job on idle")
        #expect(jobs[0].count == 1)
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
