import Foundation
import Testing
@testable import LisaCore

// MARK: - Synthetic fixtures (CPU-free; no MusashiSuites needed)
//
// Every fixture below is HAND-BUILT to mimic the real LINKMAP tool's output
// *structure* (see LinkmapSymbols.swift's doc comment for the real-file
// citations) with entirely fake identifiers -- never real Apple Linkmap
// content, per the M4 global constraints ("never commit Apple-derived
// data").

/// A synthetic linkmap "part 3" final-address-table line, matching the
/// real `NAME - NAME @ UNIT: ADDR [JT: xxx]` shape.
private func finalLine(_ proc: String, unit: String = "", address: String, jt: String? = nil) -> String {
    // Real files always separate the unit field from its trailing colon
    // with padding whitespace (e.g. "ckUtil  : STUFFHAN...") -- keep a
    // literal space before the colon here too, even for the blank-unit
    // case, so this matches the real tokenization the parser relies on.
    var line = "\(proc) - \(proc) @ \(unit) : \(address)"
    if let jt { line += " JT: \(jt)" }
    return line
}

@Test func parseReadsABlankUnitFinalTableLine() {
    let symbols = LinkmapSymbols.parse(finalLine("FAKEPROC", address: "020000"))
    #expect(symbols == [.init(unit: "", proc: "FAKEPROC", address: 0x02_0000)])
}

@Test func parseReadsANamedUnitFinalTableLineWithJumpTableSuffix() {
    let symbols = LinkmapSymbols.parse(finalLine("FAKEROUT", unit: "fakeUnit", address: "040096", jt: "F80100"))
    #expect(symbols == [.init(unit: "fakeUnit", proc: "FAKEROUT", address: 0x04_0096)])
}

@Test func parseIgnoresThePreambleModuleRelativeAndTrailerNoise() {
    // A full synthetic "file", structurally identical to a real linkmap
    // (preamble -> module-relative offsets -> final table -> segment
    // trailer -> footer), but every identifier is fake.
    let fakeFile = """
    Reading file: fakeapp/fakemod.OBJ
    Input summary:
           1 Files     , max =   100
    Global area: FAKEGLOB at $00000100
    Active: 1 of 1 read.
            : FAKEPROC at 00000000
    fakeUnit: FAKEROUT at 00000096
      Number of segments in file = 2, number of Jump Table entries = 2
    FAKEPROC - FAKEPROC @         : 020000
    FAKEROUT - FAKEROUT @ fakeUnit : 040096 JT: F80100
    Linking segment:          file (JT) seg:   1 size:      512
    Linking segment: fakeUnit file (JT) seg:   2 size:      256
       0 Errors detected.

    The output is an executable program file.

    Elapsed time: 1.000 seconds.
    """
    let symbols = LinkmapSymbols.parse(fakeFile)
    #expect(symbols == [
        .init(unit: "", proc: "FAKEPROC", address: 0x02_0000),
        .init(unit: "fakeUnit", proc: "FAKEROUT", address: 0x04_0096),
    ])
}

@Test func parseIgnoresADuplicateNameSyntheticDollarKeyLine() {
    // Real files disambiguate a name reused by two units with a synthetic
    // "$NNNNNNN" left-hand key (see LinkmapSymbols.swift doc comment) --
    // the parser must still read the real proc/unit/address after "@".
    let symbols = LinkmapSymbols.parse("$0100000 - FAKEPROC @ fakeUnit : 040420")
    #expect(symbols == [.init(unit: "fakeUnit", proc: "FAKEPROC", address: 0x04_0420)])
}

@Test func parseSkipsMalformedOrIncompleteLines() {
    let malformed = """
    just some noise
    FAKEPROC @ : 020000
    FAKEPROC - FAKEPROC @
    FAKEPROC - FAKEPROC @ fakeUnit: 02000
    FAKEPROC - FAKEPROC @ fakeUnit: ZZZZZZ
    """
    #expect(LinkmapSymbols.parse(malformed).isEmpty)
}

// MARK: - Lookup

private func makeSymbols(_ entries: [(unit: String, proc: String, address: UInt32)]) -> LinkmapSymbols {
    LinkmapSymbols(symbols: entries.map { .init(unit: $0.unit, proc: $0.proc, address: $0.address) })
}

@Test func lookupReturnsBareProcNameForAnExactBlankUnitMatch() {
    let symbols = makeSymbols([(unit: "", proc: "FAKEPROC", address: 0x02_0000)])
    #expect(symbols.lookup(0x02_0000) == "FAKEPROC")
}

@Test func lookupReturnsDottedNameForAnExactNamedUnitMatch() {
    let symbols = makeSymbols([(unit: "fakeUnit", proc: "FAKEROUT", address: 0x04_0096)])
    #expect(symbols.lookup(0x04_0096) == "fakeUnit.FAKEROUT")
}

@Test func lookupReturnsNearestBelowWithAHexOffsetSuffix() {
    let symbols = makeSymbols([(unit: "fakeUnit", proc: "FAKEROUT", address: 0x04_0096)])
    #expect(symbols.lookup(0x04_00A6) == "fakeUnit.FAKEROUT+0x10")
}

@Test func lookupReturnsNilOutsideTheKnownSegmentSlot() {
    // $020000-aligned slots (part 3's addressing convention): a query in a
    // DIFFERENT 128KB slot than every known symbol must not silently
    // attribute it to the wrong routine's tail.
    let symbols = makeSymbols([(unit: "", proc: "FAKEPROC", address: 0x02_0000)])
    #expect(symbols.lookup(0x04_0010) == nil)
}

@Test func lookupReturnsNilBelowEveryKnownSymbol() {
    let symbols = makeSymbols([(unit: "", proc: "FAKEPROC", address: 0x02_0100)])
    #expect(symbols.lookup(0x02_0000) == nil)
}

@Test func lookupReturnsNilOnAnEmptyTable() {
    #expect(LinkmapSymbols().lookup(0x52_0824) == nil)
}

@Test func lookupPicksTheNearestOfSeveralSymbolsInTheSameSlot() {
    let symbols = makeSymbols([
        (unit: "", proc: "FIRST", address: 0x02_0000),
        (unit: "", proc: "SECOND", address: 0x02_0100),
        (unit: "", proc: "THIRD", address: 0x02_0200),
    ])
    #expect(symbols.lookup(0x02_0150) == "SECOND+0x50")
}

@Test func lookupAppliesBaseOffsetBeforeMatching() {
    // The base-offset story (LinkmapSymbols.swift doc comment): a
    // link-time address of $020000 relocated to run at $520000+baseOffset
    // resolves once the runtime query has baseOffset undone.
    var symbols = makeSymbols([(unit: "", proc: "FAKEPROC", address: 0x02_0000)])
    symbols.baseOffset = 0x50_0000
    #expect(symbols.lookup(0x52_0005) == "FAKEPROC+0x5")
    #expect(symbols.lookup(0x02_0005) == nil, "without the offset undone this must not spuriously match")
}

// MARK: - Directory loading (synthetic files on a throwaway temp dir)

@Test func loadThrowsForAMissingDirectory() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("lisaemu-linkmap-\(UUID())")
    #expect(throws: LinkmapSymbols.LoadError.self) {
        _ = try LinkmapSymbols.load(directory: missing)
    }
}

@Test func loadMergesSymbolsFromEveryFileInADirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lisaemu-linkmap-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try finalLine("FAKEALPHA", address: "020000")
        .write(to: dir.appendingPathComponent("linkmap-alpha.TEXT.unix.txt"), atomically: true, encoding: .utf8)
    try finalLine("FAKEBETA", unit: "betaUnit", address: "040000")
        .write(to: dir.appendingPathComponent("linkmap-beta.TEXT.unix.txt"), atomically: true, encoding: .utf8)

    let symbols = try LinkmapSymbols.load(directory: dir)
    #expect(symbols.lookup(0x02_0000) == "FAKEALPHA")
    #expect(symbols.lookup(0x04_0000) == "betaUnit.FAKEBETA")
}

// MARK: - Real Linkmaps 3.0 smoke (env-gated; never asserts on bundled data)

private let realLinkmapDir: String? = {
    if let env = ProcessInfo.processInfo.environment["LISAEMU_LINKMAP_DIR"] { return env }
    let path = LinkmapSymbols.defaultDirectory.path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}()

@Suite(.enabled(if: realLinkmapDir != nil, "Set LISAEMU_LINKMAP_DIR (or check out Lisa_Source at the default path) to run real-linkmap tests"))
struct RealLinkmapSmokeTests {
    /// `linkmap-btn.TEXT.unix.txt:120` (part 3): `BTNREAD  - BTNREAD  @
    /// : 020000` -- the blank-unit (main-program) entry point of the
    /// `btn` file's segment 1, verified by reading the real file during
    /// Task 2's format investigation.
    @Test func loadedRealBtnLinkmapResolvesTheKnownBTNREADSymbol() throws {
        let fileURL = URL(fileURLWithPath: realLinkmapDir!).appendingPathComponent("linkmap-btn.TEXT.unix.txt")
        let text = try String(contentsOf: fileURL, encoding: .isoLatin1)
        let symbols = LinkmapSymbols(symbols: LinkmapSymbols.parse(text))
        #expect(symbols.lookup(0x02_0000) == "BTNREAD")
    }

    /// The whole directory loads without throwing and yields a
    /// substantial symbol table -- a coarse sanity check on the
    /// multi-file merge path against real data (M4 Task 2 coverage
    /// finding: these are all Office System application/library linkmaps,
    /// never the OS kernel -- see LinkmapSymbols.swift's doc comment).
    @Test func loadedRealDirectoryYieldsManySymbols() throws {
        let symbols = try LinkmapSymbols.load(directory: URL(fileURLWithPath: realLinkmapDir!))
        #expect(symbols.symbols.count > 500)
    }
}
