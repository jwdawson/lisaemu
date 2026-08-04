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
    private var peeking = false
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
        switch mmu.translate(a, domain: domain, isWrite: isWrite) {
        case .success(let p): return Int(p)
        case .failure(let fault):
            if !peeking { lastFault = fault }
            return nil
        }
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
