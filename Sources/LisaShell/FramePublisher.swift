import Foundation

/// Immutable snapshot of one vsync's framebuffer, published to the app.
///
/// `bits` is the raw 1bpp packed snapshot straight from
/// `Bus.framebufferSnapshot()` (MSB-first, per the established M1b
/// convention -- see `ROMBootTests`' `blackPixels` computation via
/// `UInt8.nonzeroBitCount`, which this type's producers reuse the same way).
/// Expansion to 8bpp/CGImage pixels is LisaApp's job (Task 3's
/// `expand1bppRow`), deliberately NOT done here: this type and its producer
/// live in the Foundation-only `LisaShell` target, which must stay free of
/// AppKit/CoreGraphics/vImage (see the plan's Global Constraints).
public struct Frame: Sendable {
    public let bits: [UInt8]
    public let width: Int
    public let height: Int
    /// Monotonically increasing, starting at 1 for the first published
    /// frame (0 is reserved as an app-side "no frame yet" sentinel).
    public let sequence: UInt64
}

/// Publishes one `Frame` per emulated vsync.
///
/// `onFrame` is called ON THE EMULATION THREAD -- see
/// `EmulationController`'s "Threading" doc comment: the app is responsible
/// for hopping to whatever thread it needs (typically main) inside its
/// `onFrame` closure; this type never does that hop itself, matching the
/// plan's "Frame publication" bullet verbatim.
///
/// `onFrame` ITSELF, however, is set from any caller thread (the app
/// assigns it once, typically at startup, from whatever thread constructed
/// the controller) while being read+invoked from the emulation thread on
/// every vsync -- an unsynchronized `var` here would be a genuine data race
/// under Swift's memory model. Guarded by `lock`, the same NSLock-backed
/// get/set shape `EmulationController`'s `Shared.onStatus` already uses:
/// the emulation thread takes the lock only long enough to copy the closure
/// reference out, then invokes it outside the lock (so a slow/reentrant
/// `onFrame` implementation can't hold up a concurrent `onFrame =` from
/// another thread).
///
/// Typed `@Sendable`: this is invoked ON THE EMULATION THREAD, not
/// whatever actor/thread assigned it -- without `@Sendable`, a closure
/// literal written inside a `@MainActor`-isolated method (as `LisaApp`'s
/// `AppModel.wire` does) infers MainActor isolation from its lexical
/// context by default under Swift 6, and invoking it from a different
/// thread traps at runtime (`_swift_task_checkIsolatedSwift`/`SIGTRAP`) --
/// caught the hard way during M1c Task 3's manual verification checkpoint
/// (see task-3-report.md). `@Sendable` forces the closure to be
/// non-isolated so it's actually legal to call cross-thread, matching this
/// doc comment's contract.
///
/// Deliberately has no `Machine`/`Bus` reference of its own -- framebuffer
/// capture is the controller's job (see `EmulationController.makeMachine`'s
/// `Machine.onVsync` wiring). This mirrors `COPS`/`VideoTiming`'s
/// dependency-injected, `Machine`-free shape in `LisaCore`, keeping this
/// type trivially constructible and testable in isolation.
public final class FramePublisher {
    private let lock = NSLock()
    private var _onFrame: (@Sendable (Frame) -> Void)?
    public var onFrame: (@Sendable (Frame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); defer { lock.unlock() }; _onFrame = newValue }
    }

    /// Only ever read/written from the emulation thread (`publish(...)`,
    /// called from `Machine.onVsync`, and `EmulationController`'s
    /// `.screenshot` mailbox handler, which reads `currentSequence` --
    /// both run exclusively on that one thread), so unlike `onFrame` this
    /// needs no lock of its own.
    private var sequence: UInt64 = 0

    /// The most recently published frame's sequence number (0 if none has
    /// been published yet -- the same "no frame yet" sentinel `Frame`'s own
    /// doc comment establishes). `EmulationController.requestScreenshot`
    /// uses this so an ad-hoc screenshot's `Frame.sequence` reflects the
    /// real current sequence rather than colliding with that sentinel.
    var currentSequence: UInt64 { sequence }

    public init() {}

    /// Builds and publishes the next `Frame`. Called by the emulation
    /// thread's `Machine.onVsync` hook once per vsync tick.
    func publish(bits: [UInt8], width: Int, height: Int) {
        sequence += 1
        onFrame?(Frame(bits: bits, width: width, height: height, sequence: sequence))
    }
}
