import Foundation

/// Groups the `ImageWriterInterpreter`'s per-page output into *print jobs* and
/// publishes each closed job to a consumer thread-safely.
///
/// A job is the run of pages fed with no more than `idleWindow` seconds of
/// host-time gap between them: pages accumulate, and the job **closes when the
/// printer goes idle** — no new page for `idleWindow` of host time, observed
/// via `tick(now:)` (docs/hardware-notes.md §12.5: the OS ejects each page
/// with line feeds, so "the stream stopped" is the only end-of-job signal
/// there is). Feeding a page after a close reopens a fresh job.
///
/// Time is injected: `feed(page:)` timestamps activity from the most recent
/// `tick(now:)` value, and `tick(now:)` is the sole clock. This keeps the type
/// deterministically testable with no real sleeps — the same dependency-injection
/// shape `Governor` uses for pacing.
///
/// Threading mirrors `FramePublisher`: `feed`/`tick`/`close` run on the single
/// emulation thread that owns the interpreter, while `onJob` may be assigned
/// from any thread (typically the app at startup). Only `onJob` needs a lock;
/// the closure reference is copied out under the lock and invoked *outside* it,
/// so a slow/reentrant consumer can't stall a concurrent `onJob =`.
public final class PrintJobSpooler {
    private let lock = NSLock()
    private var _onJob: (@Sendable ([PrinterPage]) -> Void)?
    /// Called once per closed job with that job's pages, in feed order.
    ///
    /// Typed `@Sendable` for the same reason `FramePublisher.onFrame` is: it is
    /// assigned from any thread (the app at startup) but invoked on the
    /// emulation thread inside `closeJob()`, so it must be legal to call
    /// cross-thread.
    public var onJob: (@Sendable ([PrinterPage]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onJob }
        set { lock.lock(); defer { lock.unlock() }; _onJob = newValue }
    }

    /// Idle gap (host seconds) after which an open job closes. Default 2.0
    /// (the brief's 2000 ms).
    public let idleWindow: TimeInterval

    // Emulation-thread-only state (see the type's Threading note).
    private var pending: [PrinterPage] = []
    /// Most recent time seen from `tick(now:)`; also the timestamp stamped
    /// onto a `feed` (starts at 0 so a feed before any tick anchors at 0).
    private var now: TimeInterval = 0
    /// Host time of the last `feed`, or nil when no job is open.
    private var lastActivity: TimeInterval?

    public init(idleWindow: TimeInterval = 2.0) {
        self.idleWindow = idleWindow
    }

    /// True while a job is accumulating (pages fed, not yet closed). Read from
    /// the emulation thread; handy for tests and diagnostics.
    public var hasOpenJob: Bool { !pending.isEmpty }

    /// Add one finished page to the current job (opening one if none is open).
    public func feed(page: PrinterPage) {
        pending.append(page)
        lastActivity = now
    }

    /// Advance the injected clock to `now`. Closes the open job if it has been
    /// idle for at least `idleWindow`.
    public func tick(now: TimeInterval) {
        self.now = now
        guard let last = lastActivity, !pending.isEmpty else { return }
        if now - last >= idleWindow {
            closeJob()
        }
    }

    /// Force the open job closed immediately (e.g. emulator shutdown / stream
    /// end), regardless of idle time. No-op if no job is open.
    public func close() {
        if !pending.isEmpty { closeJob() }
    }

    private func closeJob() {
        let job = pending
        pending.removeAll(keepingCapacity: true)
        lastActivity = nil
        // Copy the sink out under the lock, invoke outside it (FramePublisher
        // idiom) so a reentrant/slow consumer can't hold up a concurrent set.
        lock.lock()
        let sink = _onJob
        lock.unlock()
        sink?(job)
    }
}
