import Foundation
import LisaCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: lisadbg <binary> [hex-load-address]"); exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let loadAddr = args.count > 2 ? UInt32(args[2], radix: 16) ?? 0 : 0

let machine = Machine()
machine.bus.load([UInt8](data), at: loadAddr)
machine.reset()
let monitor = Monitor(machine: machine)

print("lisadbg — \(data.count) bytes @ \(String(format: "%06X", loadAddr)). ? for help.")
print(monitor.registerDump())
while let line = readLine(strippingNewline: true) {
    switch Monitor.parse(line) {
    case .regs:
        print(monitor.registerDump())
    case .step(let n):
        for _ in 0..<n { _ = machine.cpu.step() }
        print(monitor.disassembly(from: machine.cpu[.pc], count: 1))
        print(monitor.registerDump())
    case .disasm(let addr, let n):
        print(monitor.disassembly(from: addr ?? machine.cpu[.pc], count: n))
    case .mem(let addr, let n):
        print(monitor.hexDump(at: addr, count: n))
    case .quit:
        exit(0)
    case .help:
        print("r | s [n] | d [hexaddr] [n] | m <hexaddr> [n] | q")
    case nil:
        print("? — unknown command")
    }
}
