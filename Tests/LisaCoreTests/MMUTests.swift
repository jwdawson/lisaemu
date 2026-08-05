import Testing
@testable import LisaCore

private func mmuWith(_ seg: Int, _ reg: SegmentRegister, domain: Int = 0) -> MMU {
    var mmu = MMU()
    mmu.domains[domain][seg] = reg
    return mmu
}

// MARK: - Brief Step 1 tests (verbatim)

@Test func rawReadWriteSegmentDecodes() {
    var mmu = MMU()
    // origin page 0x200 (=phys 0x40000), readWrite, limit 16 pages (8KB): slim low byte = 0x100-16 = 0xF0
    mmu.domains[0][1] = SegmentRegister(sorg: 0x200, slim: 0x7F0)
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x40000))
    #expect(mmu.translate(0x2_0000 + 16*512 - 1, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x40000 + 16*512 - 1))
    if case .fault(let f) = mmu.translate(0x2_0000 + 16*512, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .limitViolation)
    } else { Issue.record("expected limit fault") }
}

@Test func fullSegmentLimitZeroMeans256Pages() {
    var mmu = MMU()
    mmu.domains[0][0] = SegmentRegister(sorg: 0, slim: 0x700)   // limit byte 0 → 256 pages → full 128KB
    #expect(mmu.translate(0x1_FFFF, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x1_FFFF))
}

@Test func ioSegmentRoutesToIO() {
    var mmu = MMU()
    mmu.domains[0][126] = SegmentRegister(sorg: 0, slim: 0x800)  // access $8 = io
    #expect(mmu.translate(126 << 17 | 0xE010, domain: 0, isSupervisor: true, isWrite: false) == .io(0xE010))
}

@Test func absentSegmentFaults() {
    let mmu = MMU()   // default slim 0 → nibble 0 → absent
    if case .fault(let f) = mmu.translate(0, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .invalidSegment)
    } else { Issue.record("expected fault") }
}

// MARK: - ROM-discovered special-space nibbles $F (prom) / $9 (iospace)
//
// docs/rom-trace-notes.md OQ2: the Rev H boot ROM programs seg127 SLIM =
// $F00 and seg126 SLIM = $901 at $FE0120/$FE0118, refuting the M1a ledger's
// $8-routed prommmu hypothesis. Both nibbles are hardwired special-space
// decodes, not page-limited memory-type windows like $5/$6/$7/$8: modeled
// as full-segment (entire 128KB), limit byte ignored. Tested near both ends
// of the window per the task-1 brief.

@Test func specialNibbleFDecodesFullSegmentIgnoringLimitByte() {
    var mmu = MMU()
    mmu.domains[0][127] = SegmentRegister(sorg: 0, slim: 0xF00)   // ROM's actual programmed value
    let base: UInt32 = 127 << 17
    #expect(mmu.translate(base, domain: 0, isSupervisor: true, isWrite: false) == .special(0))
    #expect(mmu.translate(base + 0x1_FFFF, domain: 0, isSupervisor: true, isWrite: false) == .special(0x1_FFFF))
}

@Test func iospaceNibble9DecodesFullSegmentIgnoringLimitByte() {
    var mmu = MMU()
    mmu.domains[0][126] = SegmentRegister(sorg: 0, slim: 0x901)   // ROM's actual programmed value
    let base: UInt32 = 126 << 17
    #expect(mmu.translate(base, domain: 0, isSupervisor: true, isWrite: false) == .io(0))
    #expect(mmu.translate(base + 0x1_FFFF, domain: 0, isSupervisor: true, isWrite: false) == .io(0x1_FFFF))
}

@Test func unassignedNibbleCIsAbsent() {
    // $C is the hardware's own "absent" code (docs/hardware-notes.md §1),
    // but every other unassigned nibble must decode as absent too.
    var mmu = MMU()
    mmu.domains[0][0] = SegmentRegister(sorg: 0x10, slim: 0xC40)
    if case .fault(let f) = mmu.translate(0, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .invalidSegment)
    } else { Issue.record("expected fault") }
}

// MARK: - Read-only write fault

@Test func readOnlyRejectsWrites() {
    let mmu = mmuWith(0, .make(originPage: 0, limitPages: 256, access: .readOnly))
    #expect(mmu.translate(0x10, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x10))
    if case .fault(let f) = mmu.translate(0x10, domain: 0, isSupervisor: true, isWrite: true) {
        #expect(f.reason == .writeToReadOnly)
    } else { Issue.record("expected read-only fault") }
}

// MARK: - Stack decode: hand-derived window math
//
// See the derivation in MMU.translate's doc comment. Summary: do_an_mmu
// stores the hardware SORG already adjusted (origin_smt + length - $100),
// and SLIM's low byte as a DIRECT (length - 1) -- not two's-complement.
// Decoding therefore uses `limitPages = (slim & 0xFF) + 1`, and the
// uniform `physical = (sorg << 9) + offset` formula puts the backing
// `limitPages`-page RAM window at the TOP of the 256-page (128KB) logical
// segment (grow-down: SP starts high, descends toward the backing region).

@Test func stackDecodeValidatesTopOfWindow() {
    // originPage 0x100 (raw SORG, i.e. physical backing anchor 0x100*512 =
    // 0x20000), stack, limit 16 pages (8KB): slim low byte = limitPages-1
    // = 15 = 0x0F (direct encoding, LDASM:403-411), slim = 0x600|0x0F = 0x60F.
    //
    // Valid page-offset window = [256-16, 256) = [240, 256), i.e. offsets
    // [0x1E000, 0x20000) -- the TOP 16 pages of the 256-page segment.
    let seg = SegmentRegister.make(originPage: 0x100, limitPages: 16, access: .stack)
    var mmu = MMU()
    mmu.domains[0][3] = seg
    let base: UInt32 = 3 << 17   // segment 3 logical base = 0x60000

    // Bottom of the valid window: offset 0x1E000 -> physical 0x20000+0x1E000 = 0x3E000
    #expect(mmu.translate(base + 0x1E000, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x3E000))
    // Top of the segment (last byte): offset 0x1FFFF -> physical 0x20000+0x1FFFF = 0x3FFFF
    #expect(mmu.translate(base + 0x1FFFF, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x3FFFF))
    // One byte below the window (offset 0x1DFFF, page 239 < 240): fault.
    if case .fault(let f) = mmu.translate(base + 0x1DFFF, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .limitViolation)
    } else { Issue.record("expected limit fault below stack window") }
}

@Test func stackDecodeFullWindowAllPagesValid() {
    // limit byte 0xFF -> limitPages = 0xFF + 1 = 256 -> the entire 128KB
    // segment is backed (no unbacked gap at the bottom); unlike the
    // memory-type encoding, stack has no "0 means 256" special case
    // because it is a direct (not two's-complement) count.
    let mmu = mmuWith(5, SegmentRegister(sorg: 0, slim: 0x6FF))
    #expect(mmu.translate(5 << 17, domain: 0, isSupervisor: true, isWrite: true) == .memory(0))
    #expect(mmu.translate((5 << 17) + 0x1_FFFF, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x1_FFFF))
}

@Test func stackDecodeMinimalOnePageWindow() {
    // slim low byte 0 -> limitPages = 0 + 1 = 1: only the very last page
    // of the segment (offset 0x1FE00...0x1FFFF) is valid.
    let seg = SegmentRegister.make(originPage: 0x40, limitPages: 1, access: .stack)
    var mmu = MMU()
    mmu.domains[0][7] = seg
    let base: UInt32 = 7 << 17

    #expect(mmu.translate(base + 0x1_FE00, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x8000 + 0x1_FE00))
    if case .fault(let f) = mmu.translate(base + 0x1_FDFF, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .limitViolation)
    } else { Issue.record("expected limit fault") }
}

// MARK: - Ported M0-era tests (raw model via the factory)

@Test func translatesReadWriteSegment() {
    let mmu = mmuWith(1, .make(originPage: 0x200, limitPages: 256, access: .readWrite))
    // logical 0x2_0000 = segment 1, offset 0
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x40000))
    #expect(mmu.translate(0x2_0004, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x40004))
}

@Test func limitViolationFaults() {
    // origin page 0x200 (phys 0x40000), limit 1 page (512 bytes): only
    // offset 0 is valid; offset 0x200 (page 1) must fault.
    let mmu = mmuWith(1, .make(originPage: 0x200, limitPages: 1, access: .readWrite))
    if case .fault(let f) = mmu.translate(0x2_0200, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .limitViolation)
    } else { Issue.record("expected limit fault") }
}

@Test func domainsAreIsolated() {
    var mmu = MMU()
    mmu.domains[1][0] = .make(originPage: 0x80, limitPages: 256, access: .readWrite)  // 0x80*512 = 0x10000
    #expect(mmu.translate(0x0, domain: 1, isSupervisor: true, isWrite: false) == .memory(0x10000))
    if case .fault(let f) = mmu.translate(0x0, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .invalidSegment)
    } else { Issue.record("expected fault") }
}

@Test func translateAcceptsSupervisorParameter() {
    let mmu = mmuWith(1, .make(originPage: 0x200, limitPages: 256, access: .readWrite))
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: false, isWrite: false)
            == mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false))
}

@Test func busTranslatesWhenSetupModeOff() {
    let bus = Bus(ramSize: 0x100000)
    bus.write8(0x40000, 0x5A)                 // physical, while in setup mode
    bus.mmu.domains[0][0] = .make(originPage: 0x200, limitPages: 256, access: .readWrite)  // 0x200*512 = 0x40000
    bus._setSetupModeForTesting(false)
    #expect(bus.read8(0x0) == 0x5A)           // logical 0 → physical 0x40000
    _ = bus.read8(0x2_0000)                   // segment 1 is invalid
    #expect(bus.lastFault == MMUFault(logical: 0x2_0000, reason: .invalidSegment))
}
