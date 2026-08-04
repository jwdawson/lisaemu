public enum SegmentAccess: Equatable { case invalid, readWrite, readOnly, stack, io }

public struct SegmentRegister {
    public var origin: UInt32
    public var limitBytes: UInt32
    public var access: SegmentAccess
    public init(origin: UInt32 = 0, limitBytes: UInt32 = 0,
                access: SegmentAccess = .invalid) {
        self.origin = origin; self.limitBytes = limitBytes; self.access = access
    }
}

public struct MMUFault: Error, Equatable {
    public enum Reason: Equatable { case invalidSegment, limitViolation, writeToReadOnly }
    public let logical: UInt32
    public let reason: Reason
    public init(logical: UInt32, reason: Reason) {
        self.logical = logical; self.reason = reason
    }
}

public struct MMU {
    public static let segmentSize: UInt32 = 0x2_0000   // 128 KB (OS: maxmmusize)
    public var domains: [[SegmentRegister]] =
        Array(repeating: Array(repeating: SegmentRegister(), count: 128), count: 4)

    public func translate(_ logical: UInt32, domain: Int,
                          isWrite: Bool) -> Result<UInt32, MMUFault> {
        let addr = logical & 0xFF_FFFF
        let seg = Int(addr >> 17)
        let offset = addr & (Self.segmentSize - 1)
        let r = domains[domain][seg]
        switch r.access {
        case .invalid:
            return .failure(.init(logical: addr, reason: .invalidSegment))
        case .readOnly where isWrite:
            return .failure(.init(logical: addr, reason: .writeToReadOnly))
        case .stack:
            guard offset >= Self.segmentSize - r.limitBytes else {
                return .failure(.init(logical: addr, reason: .limitViolation))
            }
        case .readWrite, .readOnly, .io:
            guard offset < r.limitBytes else {
                return .failure(.init(logical: addr, reason: .limitViolation))
            }
        }
        return .success(r.origin &+ offset)
    }
}
