import Foundation
import Testing
@testable import LisaCore

// MARK: - Pure interleave (CPU-free; no MusashiSuites needed)

@Test func interleaveProducesExpected16ByteOutput() throws {
    let even = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
    let odd  = Data([0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87])
    let result = try ROMImage.interleave(even: even, odd: odd)
    #expect(result == [
        0x00, 0x80, 0x01, 0x81, 0x02, 0x82, 0x03, 0x83,
        0x04, 0x84, 0x05, 0x85, 0x06, 0x86, 0x07, 0x87,
    ])
}

@Test func interleaveThrowsOnLengthMismatch() {
    let even = Data([0x00, 0x01, 0x02])
    let odd = Data([0x80, 0x81])
    #expect(throws: ROMImage.Error.self) {
        _ = try ROMImage.interleave(even: even, odd: odd)
    }
}

// MARK: - Real ROM (env-gated; CPU-free -- just bytes)

private let romDir = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]

@Suite(.enabled(if: romDir != nil, "Set LISAEMU_ROM_DIR to run real-ROM tests"))
struct RealLisaROMTests {
    @Test func loadedROMIs16KBAndContainsServiceModeLandmark() throws {
        let rom = try ROMImage.load(directory: URL(fileURLWithPath: romDir!))
        #expect(rom.count == 0x4000)

        let landmark = Array("SERVICE MODE".utf8)
        var found = false
        let lastStart = rom.count - landmark.count
        for start in 0...lastStart {
            let end = start + landmark.count
            if Array(rom[start..<end]) == landmark {
                found = true
                break
            }
        }
        #expect(found, "expected \"SERVICE MODE\" ASCII string somewhere in the interleaved ROM")
    }
}
