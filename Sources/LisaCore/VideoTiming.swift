import Foundation

/// Vertical-retrace (vsync) timing source and framebuffer scanout
/// (docs/hardware-notes.md §2 "Display Specifications"/"Vertical Retrace").
///
/// Modeled as a self-rescheduling `Machine` event, the same shape as
/// `COPS`'s scheduled deliveries (see that type's doc comment): every
/// `cyclesPerVsync` cycles it fires, marking the status register's vsync
/// bit pending and -- if the interrupt has been armed via `$E01A` -- also
/// asserting the CPU's level-1 IRQ line. This is deliberately a STANDALONE,
/// dependency-injected class (no `Bus`/`Machine`/`IODispatcher` reference of
/// its own) so it can be driven and tested without a CPU, exactly like
/// `COPS`; `IODispatcher` owns the one instance and wires its closures onto
/// `Bus`.
///
/// ## Register semantics ($E018 VertReset/VRIRDIS vs $E01A VRIRENB)
///
/// hardware-notes.md §2 is internally in tension here: "VertReset: IOSpace +
/// $E018 (write re-arms/clears pending)" reads as though $E018 both clears
/// AND re-arms, but the same section separately labels $E018 "VRIRDIS
/// (V-Retrace Interrupt DISable)" and $E01A "VRIRENB (V-Retrace Interrupt
/// ENaBle)" -- disable/enable, not "clear/re-arm". This model follows the
/// DISABLE/ENABLE naming (matching `IODispatcher`'s pre-existing
/// `vsyncResetCount`/`vsyncEnableCount` split, present since before this
/// task): `$E018` DISARMS the interrupt and clears the pending status bit;
/// `$E01A` ARMS it (and, if the status bit is already pending from an
/// earlier vsync the CPU hasn't acknowledged yet, asserts the IRQ
/// immediately rather than waiting for the next vsync tick). See
/// docs/rom-trace-notes.md "Trace checkpoint B" for the ROM-observed access
/// pattern this was validated against.
public final class VideoTiming {
    /// 5,000,000 Hz CPU clock / 60 Hz refresh = 83,333.33... cycles/vsync
    /// (docs/hardware-notes.md §2 "Refresh rate: ~60 Hz"); truncated to a
    /// whole cycle count per the task brief ("refine only with evidence") --
    /// no ROM timing loop has been observed to depend on the fractional
    /// remainder, so this model's cumulative long-run drift against a real
    /// 60.000...Hz refresh is intentionally unaddressed.
    public static let cyclesPerVsync: UInt64 = 83_333

    private let scheduleEvent: (UInt64, @escaping () -> Void) -> Void
    /// Reaches `Machine.vsyncPending` (the level-1 IRQ source) through
    /// `Bus.vsyncInterruptHandler` -- see that property's doc comment for
    /// why this is a closure rather than a direct reference (mirrors
    /// `COPS`'s `raiseInterrupt`/`clearInterrupt` injection).
    private let setIRQPending: (Bool) -> Void

    /// M1c shell hook (docs/superpowers/plans/2026-08-05-m1c-app-shell.md
    /// Task 1): fires on EVERY vsync tick, unconditionally -- unlike
    /// `setIRQPending`, which only reaches `Machine.vsyncPending` when the
    /// interrupt has been armed via `$E01A` (see `fireVsync` below). The
    /// shell's `FramePublisher` needs a "a vsync just happened, snapshot the
    /// framebuffer now" cadence independent of whether the ROM currently has
    /// the vsync interrupt armed, so this is a second, narrower closure
    /// rather than overloading `setIRQPending`'s semantics. `Machine` wires
    /// this to its own `onVsync` closure (see that property's doc comment).
    public var onVsyncTick: (() -> Void)?

    /// `$F801` bit 2 (vertical retrace pending, docs/hardware-notes.md §5
    /// "Status Register"). Owned entirely here -- nothing else sets this
    /// bit -- and read by `IODispatcher.currentValue` to compose the full
    /// status byte.
    public private(set) var pending = false
    /// True once `$E01A` (VRIRENB) has armed the interrupt; `$E018`
    /// (VertReset/VRIRDIS) disarms it. Starts `false` (real hardware:
    /// nothing is armed at power-on until software enables it).
    public private(set) var armed = false

    public init(scheduleEvent: @escaping (UInt64, @escaping () -> Void) -> Void,
                setIRQPending: @escaping (Bool) -> Void) {
        self.scheduleEvent = scheduleEvent
        self.setIRQPending = setIRQPending
    }

    /// Resets all state and (re-)starts the self-rescheduling vsync event.
    /// Callers (`Machine.reset()`) MUST call this AFTER clearing whatever
    /// event queue backs `scheduleEvent` -- otherwise a reset would wipe out
    /// the very event it just scheduled here, exactly like `COPS.reset()`'s
    /// documented ordering requirement.
    public func reset() {
        pending = false
        armed = false
        setIRQPending(false)
        scheduleNextVsync()
    }

    private func scheduleNextVsync() {
        scheduleEvent(Self.cyclesPerVsync) { [weak self] in
            self?.fireVsync()
        }
    }

    private func fireVsync() {
        pending = true
        if armed {
            setIRQPending(true)
        }
        onVsyncTick?()
        scheduleNextVsync()
    }

    /// `$E018` access (VertReset/VRIRDIS) -- ANY access, data irrelevant,
    /// address-decoded exactly like the setup/context latches (see
    /// `IODispatcher.applyLatch`, which calls this). Disarms the interrupt
    /// and clears both the pending status bit and any currently-asserted
    /// IRQ level.
    public func handleVertResetAccess() {
        armed = false
        pending = false
        setIRQPending(false)
    }

    /// `$E01A` access (VRIRENB) -- arms the interrupt. If the status bit is
    /// already pending (a vsync fired before the CPU got around to arming),
    /// the IRQ asserts immediately rather than waiting for the next tick --
    /// this is the discriminating behavior checkpoint B's ROM trace was
    /// used to validate (docs/rom-trace-notes.md).
    public func handleVertEnableAccess() {
        armed = true
        if pending {
            setIRQPending(true)
        }
    }
}

extension Bus {
    /// The 720x364 1bpp framebuffer, 32,760 bytes (docs/hardware-notes.md
    /// §2 "Display Specifications"/"Framebuffer"), read directly from
    /// physical RAM starting at `videoPageLatch << 15` -- the video page
    /// latch is a 32KB-aligned physical page number (`$FCE800`, "VideoLatch:
    /// value = (ScrnPhys + MemoryBase) >> 15"). This is real hardware DMA
    /// straight off the physical bus, NOT a CPU logical address: it
    /// deliberately bypasses `MMU.translate`/`setupMode`/`domain` entirely
    /// and indexes `ram` directly, the same way the video controller
    /// hardware would, independent of whatever the CPU's own MMU is
    /// currently configured to see. Out-of-range bytes (a page latch value
    /// that would run past the end of a smaller-than-max `Bus.ram`) read as
    /// `0` rather than crashing -- there is no cited hardware behavior for
    /// this (it cannot occur on the real machine, which always has enough
    /// physical RAM behind the latch's addressable range), so this is a
    /// modeled convenience, not a documented fact.
    public func framebufferSnapshot() -> [UInt8] {
        let base = Int(videoPageLatch) << 15
        var out = [UInt8](repeating: 0, count: Self.framebufferByteCount)
        guard base >= 0, base < ram.count else { return out }
        let end = min(base + Self.framebufferByteCount, ram.count)
        for i in base..<end {
            out[i - base] = ram[i]
        }
        return out
    }

    /// 720 * 364 / 8 (docs/hardware-notes.md §2 "Framebuffer: 32,760
    /// bytes").
    public static let framebufferByteCount = 32_760
    public static let framebufferWidth = 720
    public static let framebufferHeight = 364
}
