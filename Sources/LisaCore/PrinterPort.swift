/// The seam between the SCC's **channel-B transmitter** and whatever consumes
/// the outbound serial byte stream. On the real Lisa, Serial B (`$FCD205`
/// data / `$FCD201` control -- docs/hardware-notes.md §11.1) is the printer
/// port; the OS RS-232 driver's `RSOUT` pushes one byte at a time to the
/// Z8530's Tx buffer (§11.4). This protocol is the destination those bytes
/// reach once `SCC8530` has decoded a channel-B data write.
///
/// M7 wires this to the ImageWriter interpreter (a later task); the unit tests
/// use a capture double (`CapturePrinterPort`) that records the byte stream and
/// can pin the ready line. The SCC keeps a `PrinterPort?` on `channelB`
/// (`SCCChannel.printerPort`) -- `nil` = nothing attached (bytes are absorbed
/// and dropped, faithful to an idle/unterminated port), non-`nil` = a live
/// sink.
///
/// `isReady` models the receiver's flow-control state. The Lisa driver gates
/// transmit on the SCC's own RR0 status bits (Tx buffer empty + CTS, §11.4),
/// which the SCC synthesizes -- so `isReady` is advisory here (a host sink is
/// modeled as infinitely fast, so it defaults to always ready). It exists so a
/// future back-pressuring sink can report "not ready" and so tests can assert
/// the seam's shape.
public protocol PrinterPort: AnyObject {
    /// Consume one transmitted byte (channel-B data-register write, §11.4 step 4).
    func transmit(_ byte: UInt8)
    /// Whether the sink can currently accept a byte. A host sink is infinitely
    /// fast, so real implementations typically return `true` always.
    var isReady: Bool { get }
}
