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
public struct Frame {
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
/// Deliberately has no `Machine`/`Bus` reference of its own -- framebuffer
/// capture is the controller's job (see `EmulationController.makeMachine`'s
/// `Machine.onVsync` wiring). This mirrors `COPS`/`VideoTiming`'s
/// dependency-injected, `Machine`-free shape in `LisaCore`, keeping this
/// type trivially constructible and testable in isolation.
public final class FramePublisher {
    public var onFrame: ((Frame) -> Void)?

    private var sequence: UInt64 = 0

    public init() {}

    /// Builds and publishes the next `Frame`. Called by the emulation
    /// thread's `Machine.onVsync` hook once per vsync tick.
    func publish(bits: [UInt8], width: Int, height: Int) {
        sequence += 1
        onFrame?(Frame(bits: bits, width: width, height: height, sequence: sequence))
    }
}
