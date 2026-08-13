import Foundation
import LisaCore

/// Bundles the three M7 printer pieces — a `PrinterPort` adapter, the
/// `ImageWriterInterpreter`, and the `PrintJobSpooler` — into one attachable
/// unit, so every host (the app's `EmulationController` and `lisadbg`) wires
/// the pipeline exactly once, the same way.
///
/// Data flow (all on the single emulation thread that owns the SCC):
/// `SCC8530 channel-B data write → printerPort.transmit(_:) → interpreter
/// .feed(_:) → interpreter.onPage → spooler.feed(page:)`, and closed jobs come
/// out of `spooler.onJob` — republished cross-thread by the host (the
/// `FramePublisher` idiom; the app hops to main inside its `onJob` closure).
///
/// ## Attaching
/// `bus.scc.channelB.printerPort = pipeline.printerPort` routes channel-B bytes
/// here. The SCC keeps that `PrinterPort` across `Machine.reset()` (see
/// `SCC8530.reset`'s doc comment — a reset line does not unplug the printer),
/// so the pipeline survives a warm reset by construction, matching the floppy/
/// Widget media it hangs alongside.
///
/// ## Clock and end-of-job
/// A job closes when the printer's **byte stream goes quiet** for `idleWindow`
/// — there is no form-feed byte, so "the wire stopped" is the only end-of-job
/// signal (docs/hardware-notes.md §12.5). Idle is observed at the **byte**
/// level via `tick(now:)`, called regularly with **host wall-clock** time (the
/// same `ProcessInfo.processInfo.systemUptime` source `EmulationController`
/// already uses for pacing — the idle window is a real-time gap, not an
/// emulated-cycle one).
///
/// Crucially, an idle close **flushes the interpreter first**: a real print
/// whose last page never reaches an LF page-length overflow (e.g. a one-line
/// document) leaves a *dirty partial page* in the interpreter that only
/// `flush()` emits. Ticking the spooler alone would close nothing (the page
/// never reached it). So idle-close = `interpreter.flush()` (emit the partial
/// page) → `spooler.close()` (deliver the whole job). `flush()` also exposes
/// that as a deterministic manual end-of-stream (emulator shutdown, or
/// `lisadbg`'s `printer` command).
///
/// Not thread-safe for `feed`/`tick`/`flush` (single-threaded, like the
/// interpreter it wraps); only `onJob` is assignable cross-thread (the
/// spooler's own lock guards it).
public final class PrinterPipeline {
    public let interpreter: ImageWriterInterpreter
    public let spooler: PrintJobSpooler
    private let adapter: Adapter
    /// Host-seconds of byte-stream silence after which the open job closes.
    public let idleWindow: TimeInterval

    // Byte-idle tracking (emulation-thread-only, like the interpreter).
    /// Host time of the most recent tick that observed transmitted bytes.
    private var lastActivity: TimeInterval = 0
    /// True once bytes have been transmitted but not yet flushed into a closed
    /// job — the "there is outstanding output to eventually eject" flag.
    private var hasOutstandingOutput = false

    /// Called once per closed job with that job's pages, in feed order.
    /// Forwards to the spooler's own lock-guarded `@Sendable` sink, so it may
    /// be assigned from any thread while `feed`/`tick` run on the emulation
    /// thread (the `FramePublisher` idiom).
    public var onJob: (@Sendable ([PrinterPage]) -> Void)? {
        get { spooler.onJob }
        set { spooler.onJob = newValue }
    }

    public init(config: ImageWriterInterpreter.Config = .imageWriterPortraitHiRes,
                idleWindow: TimeInterval = 2.0) {
        let interpreter = ImageWriterInterpreter(config: config)
        let spooler = PrintJobSpooler(idleWindow: idleWindow)
        // interpreter → spooler; captured strongly (no cycle: the spooler
        // never references the interpreter back).
        interpreter.onPage = { [spooler] page in spooler.feed(page: page) }
        self.interpreter = interpreter
        self.spooler = spooler
        self.idleWindow = idleWindow
        self.adapter = Adapter(interpreter: interpreter)
    }

    /// Attach this to `bus.scc.channelB.printerPort`.
    public var printerPort: PrinterPort { adapter }

    /// Advance the idle clock. If the byte stream has been quiet for
    /// `idleWindow` and there is outstanding output, flush the interpreter's
    /// partial page and close the job. Call regularly from the thread that
    /// owns the SCC.
    public func tick(now: TimeInterval) {
        if adapter.consumeSawByte() {
            lastActivity = now
            hasOutstandingOutput = true
        } else if hasOutstandingOutput && now - lastActivity >= idleWindow {
            flush()
        }
    }

    /// Emit any partial page and force-close the open job immediately —
    /// end-of-stream / emulator shutdown / an explicit `lisadbg` flush. No-op
    /// if nothing is inked and no job is open.
    public func flush() {
        interpreter.flush()   // emit the dirty partial page → spooler.feed
        spooler.close()       // close the job → onJob
        hasOutstandingOutput = false
        // Drop any byte-activity that arrived during this flush window; the
        // next real byte re-arms outstanding output.
        _ = adapter.consumeSawByte()
    }

    /// The thin `PrinterPort` conformance: channel-B bytes in, interpreter
    /// fed in order, with a byte-activity flag the pipeline polls each tick.
    /// Modeled as an infinitely-fast sink (`isReady` always true), matching the
    /// SCC's pinned Tx-buffer-empty status (§11.4).
    private final class Adapter: PrinterPort {
        private let interpreter: ImageWriterInterpreter
        private var sawByte = false
        init(interpreter: ImageWriterInterpreter) { self.interpreter = interpreter }
        func transmit(_ byte: UInt8) { interpreter.feed(byte); sawByte = true }
        /// Returns whether a byte arrived since the last call, and clears it.
        func consumeSawByte() -> Bool { let s = sawByte; sawByte = false; return s }
        var isReady: Bool { true }
    }
}
