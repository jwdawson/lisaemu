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
/// ## Clock
/// A job closes only when the printer goes idle for `idleWindow` (there is no
/// form-feed byte — docs/hardware-notes.md §12.5), observed via `tick(now:)`.
/// The host must call `tick(now:)` regularly with **host wall-clock** time
/// (the same `ProcessInfo.processInfo.systemUptime` source
/// `EmulationController` already uses for pacing) — the idle window is a
/// real-time gap, not an emulated-cycle one. `flush()` force-closes for a
/// deterministic end-of-stream (emulator shutdown, or `lisadbg`'s `printer`
/// command).
///
/// Not thread-safe for `feed`/`tick`/`flush` (single-threaded, like the
/// interpreter it wraps); only `onJob` is assignable cross-thread (the
/// spooler's own lock guards it).
public final class PrinterPipeline {
    public let interpreter: ImageWriterInterpreter
    public let spooler: PrintJobSpooler
    private let adapter: Adapter

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
        self.adapter = Adapter(interpreter: interpreter)
    }

    /// Attach this to `bus.scc.channelB.printerPort`.
    public var printerPort: PrinterPort { adapter }

    /// Advance the idle clock; closes the open job after `idleWindow` of
    /// host-time silence. Call regularly from the thread that owns the SCC.
    public func tick(now: TimeInterval) { spooler.tick(now: now) }

    /// Emit any partial page and force-close the open job immediately —
    /// end-of-stream / emulator shutdown / an explicit `lisadbg` flush. No-op
    /// if nothing is inked and no job is open.
    public func flush() {
        interpreter.flush()
        spooler.close()
    }

    /// The thin `PrinterPort` conformance: channel-B bytes in, interpreter
    /// fed in order. Modeled as an infinitely-fast sink (`isReady` always
    /// true), matching the SCC's pinned Tx-buffer-empty status (§11.4).
    private final class Adapter: PrinterPort {
        private let interpreter: ImageWriterInterpreter
        init(interpreter: ImageWriterInterpreter) { self.interpreter = interpreter }
        func transmit(_ byte: UInt8) { interpreter.feed(byte) }
        var isReady: Bool { true }
    }
}
