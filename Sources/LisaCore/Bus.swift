public final class Bus {
    public var setupMode = true
    public var mmu = MMU()
    private var _domain = 0
    public var domain: Int {
        get { _domain }
        set {
            precondition((0...3).contains(newValue), "Bus.domain out of range")
            _domain = newValue
        }
    }
    public private(set) var lastFault: MMUFault?
    public private(set) var unmappedAccesses: [UInt32] = []
    public private(set) var unmappedDropped = 0
    /// Reports the CPU's current supervisor/user mode to `mmu.translate`.
    /// Defaults to always-supervisor; `Machine.init` wires this to the live
    /// CPU state.
    public var supervisorProvider: () -> Bool = { true }
    /// Invoked (address, isWrite) whenever `mmu.translate` faults on a real
    /// access while translation is active (`setupMode == false`) and the
    /// access is not a `withPeek` peek. `Machine.init` wires this to
    /// `cpu.pulseBusError(address:isWrite:)`, which raises a genuine
    /// Musashi 68000 bus-error exception -- but only when the CPU is
    /// actually inside `m68k_execute` (see `M68K.insideCpuCallback`); calls
    /// arriving from peeks or direct test/tooling reads are no-ops there.
    /// Either way, `Bus` itself still records `lastFault` and returns
    /// 0xFF/drops the write below, exactly as before this handler existed.
    public var busErrorHandler: ((UInt32, Bool) -> Void)?
    /// Invoked (no arguments) when a translated CPU access faults while a
    /// *previous* fault's exception frame is still being pushed -- i.e. no
    /// successful translated access happened between the two faults. That
    /// shape means the fault occurred while Musashi was writing the
    /// bus-error exception's own stack frame (vector fetch + pushes), which
    /// on real 68000 hardware is a double bus fault: fatal, and the CPU
    /// halts rather than taking another exception. `Machine.init` wires
    /// this to `cpu.forceHalt()`.
    ///
    /// This exists because pulsing a *second* bus error into Musashi here
    /// would be unsafe, not just redundant: `m68ki_exception_bus_error`'s
    /// "already processing a bus/address error" branch
    /// (`RUN_MODE_BERR_AERR_RESET_WSF`) itself performs a live bus read
    /// (`m68k_read_memory_8(0x00ffff01)`) *before* it sets `CPU_STOPPED` --
    /// so if the supervisor stack is unmapped (a routine early-boot state
    /// before the OS has set up its stack segment), that read faults too,
    /// re-entering this same path with no base case. Detecting the
    /// consecutive-fault condition in Swift and halting directly (via the
    /// `lisa_cpu_force_halt` shim, not another pulse) avoids ever taking
    /// that recursive branch.
    public var forceHaltHandler: (() -> Void)?
    private var peeking = false
    /// True from the moment a translated CPU access faults and pulses a
    /// bus error, until either a translated access succeeds (exception
    /// stacking completed -- the CPU is now cleanly executing the handler)
    /// or another fault arrives first (exception stacking itself faulted --
    /// a double bus fault). See `forceHaltHandler`.
    private var faultPendingResolution = false
    var ram: [UInt8]

    public init(ramSize: Int) {
        ram = [UInt8](repeating: 0, count: ramSize)
    }

    public func withPeek<T>(_ body: () -> T) -> T {
        let oldPeeking = peeking
        peeking = true
        defer { peeking = oldPeeking }
        return body()
    }

    private func physical(_ address: UInt32, isWrite: Bool) -> Int? {
        let a = address & 0xFF_FFFF
        guard !setupMode else { return Int(a) }
        switch mmu.translate(a, domain: domain, isSupervisor: supervisorProvider(), isWrite: isWrite) {
        case .memory(let p):
            if !peeking { faultPendingResolution = false }
            return Int(p)
        case .io(let offset):
            if !peeking { faultPendingResolution = false }
            // IODispatcher lands in Task 5. Until then, .io is treated like
            // an unmapped physical address: reads return 0xFF, writes are
            // dropped, and the access is recorded via the same
            // unmappedAccesses bookkeeping as any other out-of-range
            // address (guaranteed out of range here since it's offset from
            // ram.count, regardless of ram size).
            return ram.count + Int(offset)
        case .fault(let fault):
            if !peeking {
                lastFault = fault
                if faultPendingResolution {
                    // A fault arrived with no successful access since the
                    // previous one pulsed -- exception stacking for that
                    // prior fault never completed. Real double bus fault:
                    // halt, don't pulse again (see forceHaltHandler).
                    forceHaltHandler?()
                } else {
                    faultPendingResolution = true
                    busErrorHandler?(address, isWrite)
                }
            }
            return nil
        }
    }

    /// Clears the consecutive-fault tracking used by `forceHaltHandler`.
    /// Called by `M68K.run(cycles:)`/`step()` at the start of each CPU
    /// slice, belt-and-suspenders alongside `insideCpuCallback`, so stale
    /// state from a previous slice can never bleed into the next one.
    func resetFaultTracking() {
        faultPendingResolution = false
    }

    public func load(_ bytes: [UInt8], at address: UInt32) {
        for (offset, byte) in bytes.enumerated() {
            write8(address &+ UInt32(offset), byte)
        }
    }

    public func read8(_ address: UInt32) -> UInt8 {
        guard let a = physical(address, isWrite: false) else { return 0xFF }
        guard a < ram.count else {
            if !peeking {
                if unmappedAccesses.count < 1024 {
                    unmappedAccesses.append(address & 0xFF_FFFF)
                } else {
                    unmappedDropped += 1
                }
            }
            return 0xFF
        }
        return ram[a]
    }

    public func write8(_ address: UInt32, _ value: UInt8) {
        guard let a = physical(address, isWrite: true) else { return }
        guard a < ram.count else {
            if !peeking {
                if unmappedAccesses.count < 1024 {
                    unmappedAccesses.append(address & 0xFF_FFFF)
                } else {
                    unmappedDropped += 1
                }
            }
            return
        }
        ram[a] = value
    }

    public func read16(_ a: UInt32) -> UInt16 {
        UInt16(read8(a)) << 8 | UInt16(read8(a &+ 1))
    }
    public func read32(_ a: UInt32) -> UInt32 {
        UInt32(read16(a)) << 16 | UInt32(read16(a &+ 2))
    }
    public func write16(_ a: UInt32, _ v: UInt16) {
        write8(a, UInt8(v >> 8)); write8(a &+ 1, UInt8(v & 0xFF))
    }
    public func write32(_ a: UInt32, _ v: UInt32) {
        write16(a, UInt16(v >> 16)); write16(a &+ 2, UInt16(v & 0xFFFF))
    }
}
