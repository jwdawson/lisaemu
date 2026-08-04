public final class Machine {
    public let bus: Bus
    public let cpu: M68K
    public private(set) var cycles: UInt64 = 0
    /// True once the core has taken a fatal double-bus-fault HALT (see
    /// `M68K.isHalted`). A STOP instruction (low-power wait that resumes on
    /// interrupt) is *not* halted and does not set this flag. Cleared by
    /// `reset()`.
    public private(set) var halted = false

    private struct Event {
        let cycle: UInt64
        let seq: UInt64
        let action: (Machine) -> Void
    }
    private var queue: [Event] = []   // kept sorted by (cycle, seq)
    private var nextSeq: UInt64 = 0

    public init(ramSize: Int = 0x20_0000) {
        bus = Bus(ramSize: ramSize)
        cpu = M68K(bus: bus)
        bus.supervisorProvider = { [weak cpu] in cpu?.isSupervisor ?? true }
        bus.busErrorHandler = { [weak cpu] address, isWrite in
            cpu?.pulseBusError(address: address, isWrite: isWrite)
        }
    }

    public func reset() {
        cpu.reset()
        cycles = 0
        halted = false
        queue.removeAll()
    }

    public func schedule(at cycle: UInt64, _ action: @escaping (Machine) -> Void) {
        let e = Event(cycle: cycle, seq: nextSeq, action: action)
        nextSeq += 1
        let i = queue.firstIndex { ($0.cycle, $0.seq) > (e.cycle, e.seq) } ?? queue.count
        queue.insert(e, at: i)
    }

    /// Computes how many cycles to request from the CPU core for the next
    /// slice of `run(until:)`, clamped to `Int32.max` so the trapping
    /// `Int32(cycles)` conversion inside `M68K.run(cycles:)` never overflows
    /// even when `stop - cycles` is far larger than `Int32` can hold.
    /// Pure and side-effect free so it can be unit-tested directly without
    /// running a multi-billion-cycle CPU loop.
    static func boundedSlice(from cycles: UInt64, to stop: UInt64) -> Int {
        let remaining = stop - cycles
        let bounded = min(remaining, UInt64(Int32.max))
        return max(1, Int(bounded))
    }

    public func run(until targetCycle: UInt64) {
        while cycles < targetCycle {
            let stop = min(targetCycle, queue.first?.cycle ?? targetCycle)
            let slice = Machine.boundedSlice(from: cycles, to: stop)
            let executed = cpu.run(cycles: slice)
            cycles &+= UInt64(executed)
            while let first = queue.first, first.cycle <= cycles {
                queue.removeFirst()
                first.action(self)
            }
            if cpu.isHalted {
                halted = true
                return
            }
            if executed == 0 {
                // Defensive only: Musashi's m68k_execute returns the full
                // requested slice even when STOPPED or double-fault HALTed
                // (once the post-reset RESET_CYCLES flush has happened), so
                // this should be unreachable in practice. Kept as a guard
                // against a runaway loop if that assumption ever changes.
                halted = true
                return
            }
        }
    }

    /// Executes a single CPU instruction, advancing `cycles` by the amount
    /// executed and draining any events now due, in (cycle, seq) order.
    /// Returns 0 immediately -- without touching the CPU -- once `halted`.
    @discardableResult
    public func step() -> Int {
        guard !halted else { return 0 }
        let executed = cpu.step()
        cycles &+= UInt64(executed)
        while let first = queue.first, first.cycle <= cycles {
            queue.removeFirst()
            first.action(self)
        }
        if cpu.isHalted {
            halted = true
        } else if executed == 0 {
            // Defensive only; see the comment in run(until:).
            halted = true
        }
        return executed
    }
}
