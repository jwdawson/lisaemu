import Foundation
import Testing
@testable import LisaCore

/// One CPU register/memory snapshot, as encoded by TomHarte/ProcessorTests
/// 680x0/68000/v1 vectors (see `initial`/`final` in each test case).
private struct THState: Decodable {
    let d0: UInt32, d1: UInt32, d2: UInt32, d3: UInt32
    let d4: UInt32, d5: UInt32, d6: UInt32, d7: UInt32
    let a0: UInt32, a1: UInt32, a2: UInt32, a3: UInt32
    let a4: UInt32, a5: UInt32, a6: UInt32
    let usp: UInt32, ssp: UInt32, sr: UInt32, pc: UInt32
    let prefetch: [UInt32]
    let ram: [[UInt32]]
}

private struct THCase: Decodable {
    let name: String
    let initial: THState
    let final: THState
    // Vectors also carry `length` (bytes) and `transactions` (bus-cycle
    // trace) fields we don't need; JSONDecoder ignores unrecognized keys.
}

private let thDir = ProcessInfo.processInfo.environment["LISAEMU_TH_DIR"]

private let knownFailures: Set<String> = {
    guard let url = Bundle.module.url(forResource: "TomHarteKnownFailures",
                                      withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n").map(String.init)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}()

extension MusashiSuites {
    @Suite(.enabled(if: thDir != nil, "Set LISAEMU_TH_DIR to run TomHarte vectors"))
    struct TomHarteTests {

        private func apply(_ s: THState, to cpu: M68K, bus: Bus) {
            // Musashi is a process-global singleton core: a previous test
            // case (in this suite or another one under MusashiSuites) may
            // have left CPU_STOPPED, pending interrupts, or other internal
            // state set from whatever opcode it last executed. `M68K.init`
            // does not clear that (it only re-installs C callbacks), so we
            // pulse reset once per case to clear it before overwriting every
            // register and memory byte the test cares about below.
            // `M68K.reset()` flushes Musashi's RESET_CYCLES bookkeeping via
            // `m68k_execute(0)` immediately, so it costs no instructions and
            // consumes no bus cycles that would show up in this test's step.
            cpu.reset()

            cpu[.sr] = s.sr          // set S-bit first so A7 aliasing is correct
            let regs: [(M68K.Register, UInt32)] = [
                (.d0, s.d0), (.d1, s.d1), (.d2, s.d2), (.d3, s.d3),
                (.d4, s.d4), (.d5, s.d5), (.d6, s.d6), (.d7, s.d7),
                (.a0, s.a0), (.a1, s.a1), (.a2, s.a2), (.a3, s.a3),
                (.a4, s.a4), (.a5, s.a5), (.a6, s.a6),
                (.usp, s.usp), (.isp, s.ssp), (.pc, s.pc),
            ]
            for (r, v) in regs { cpu[r] = v }
            for pair in s.ram { bus.write8(pair[0], UInt8(pair[1])) }
            // Non-prefetch core: place the already-fetched words at PC.
            for (i, word) in s.prefetch.enumerated() {
                bus.write16(s.pc &+ UInt32(i * 2), UInt16(word))
            }
        }

        private func check(_ s: THState, name: String, cpu: M68K, bus: Bus) -> [String] {
            var mismatches: [String] = []
            func eq(_ r: M68K.Register, _ want: UInt32, _ label: String) {
                if cpu[r] != want {
                    mismatches.append("\(label): got \(String(cpu[r], radix: 16)), want \(String(want, radix: 16))")
                }
            }
            eq(.d0, s.d0, "d0"); eq(.d1, s.d1, "d1"); eq(.d2, s.d2, "d2"); eq(.d3, s.d3, "d3")
            eq(.d4, s.d4, "d4"); eq(.d5, s.d5, "d5"); eq(.d6, s.d6, "d6"); eq(.d7, s.d7, "d7")
            eq(.a0, s.a0, "a0"); eq(.a1, s.a1, "a1"); eq(.a2, s.a2, "a2"); eq(.a3, s.a3, "a3")
            eq(.a4, s.a4, "a4"); eq(.a5, s.a5, "a5"); eq(.a6, s.a6, "a6")
            eq(.usp, s.usp, "usp"); eq(.isp, s.ssp, "ssp")
            eq(.pc, s.pc, "pc"); eq(.sr, s.sr, "sr")
            for pair in s.ram where bus.read8(pair[0]) != UInt8(pair[1]) {
                mismatches.append("ram[\(String(pair[0], radix: 16))]")
            }
            return mismatches
        }

        @Test func vectors() throws {
            let dir = URL(fileURLWithPath: thDir!)
            let files = try FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            #expect(!files.isEmpty, "no .json vectors in \(dir.path)")

            var failures: [String] = []
            var passed = 0, skipped = 0
            for file in files.sorted(by: { $0.path < $1.path }) {
                let cases = try JSONDecoder().decode([THCase].self,
                                                     from: Data(contentsOf: file))
                for c in cases {
                    if knownFailures.contains(c.name) { skipped += 1; continue }
                    let bus = Bus(ramSize: 1 << 24)     // flat 16 MB, setup mode
                    let cpu = M68K(bus: bus)
                    apply(c.initial, to: cpu, bus: bus)
                    _ = cpu.step()
                    // A real 68000's PC is always even once it settles: word
                    // fetches from an odd address always address-error. If a
                    // branch/jump/return (BSR/JSR/JMP/Bcc/DBcc/RTS/RTE/RTR)
                    // targets an odd address, Musashi's cycle-budgeted
                    // m68k_execute(1) exhausts its budget completing that
                    // instruction (which itself didn't fault) before the
                    // do-while loop ever attempts the next fetch -- so the
                    // resulting address error doesn't fire within this
                    // step() call at all. TomHarte's single-vector
                    // convention expects that immediately-following fetch
                    // fault to be chased through as part of "this"
                    // instruction's final state, so detect the odd PC and
                    // step once more to let Musashi actually attempt (and
                    // fault on) that fetch.
                    if cpu[.pc] % 2 != 0 { _ = cpu.step() }
                    let bad = check(c.final, name: c.name, cpu: cpu, bus: bus)
                    if bad.isEmpty { passed += 1 }
                    else { failures.append("\(c.name): \(bad.joined(separator: ", "))") }
                }
            }
            print("TomHarte: \(passed) passed, \(failures.count) failed, \(skipped) known-failures skipped")
            // Triage aid: LISAEMU_TH_DUMP=/path/to/file writes every failure
            // (not just the first 20 in the #expect message below) so a
            // full run's failures can be categorized without re-running.
            if let dumpPath = ProcessInfo.processInfo.environment["LISAEMU_TH_DUMP"] {
                try? failures.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
            }
            #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
        }
    }
}
