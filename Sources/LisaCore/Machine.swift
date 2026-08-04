public final class Machine {
    public let bus: Bus
    public let cpu: M68K
    public private(set) var cycles: UInt64 = 0
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

    public func run(until targetCycle: UInt64) {
        while cycles < targetCycle {
            let stop = min(targetCycle, queue.first?.cycle ?? targetCycle)
            let slice = max(1, Int(stop - cycles))
            let executed = cpu.run(cycles: slice)
            if executed == 0 {
                halted = true
                return
            }
            cycles &+= UInt64(executed)
            while let first = queue.first, first.cycle <= cycles {
                queue.removeFirst()
                first.action(self)
            }
        }
    }
}
