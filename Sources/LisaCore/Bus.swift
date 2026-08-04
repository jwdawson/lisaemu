public final class Bus {
    public var setupMode = true
    public private(set) var unmappedAccesses: [UInt32] = []
    var ram: [UInt8]

    public init(ramSize: Int) {
        ram = [UInt8](repeating: 0, count: ramSize)
    }

    public func load(_ bytes: [UInt8], at address: UInt32) {
        let base = Int(address & 0xFF_FFFF)
        ram.replaceSubrange(base ..< base + bytes.count, with: bytes)
    }

    public func read8(_ address: UInt32) -> UInt8 {
        let a = Int(address & 0xFF_FFFF)
        guard a < ram.count else {
            unmappedAccesses.append(address & 0xFF_FFFF)
            return 0xFF
        }
        return ram[a]
    }

    public func write8(_ address: UInt32, _ value: UInt8) {
        let a = Int(address & 0xFF_FFFF)
        guard a < ram.count else {
            unmappedAccesses.append(address & 0xFF_FFFF)
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
