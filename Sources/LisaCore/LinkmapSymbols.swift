import Foundation

/// Address -> symbol overlay for `lisadbg`, parsed from the Lisa Pascal
/// Workshop LINKMAP tool's text output (`LISAEMU_LINKMAP_DIR`, default
/// `~/Development/Lisa_Source/LISA_OS/Linkmaps 3.0/`; M4 Task 2). **Never
/// bundled/committed** -- this repo never ships or checks in any parsed or
/// derived Apple data; every byte of symbol data is read from a
/// user-supplied path at runtime, in memory only (both-docs / global
/// constraints rule).
///
/// ## Format (established by reading real files, 2026-08-06)
///
/// Every `linkmap-*.TEXT.unix.txt` file (`Linkmaps 3.0/` and `Linkmaps and
/// Misc. 3.0/`) is the captured console log of one LINK invocation and has
/// three parts:
///
/// 1. A "Reading file:"/"Input summary"/"Global area:" preamble (ignored).
/// 2. A **module-relative** proc listing, one routine per line, offset from
///    that Pascal UNIT's own segment start (always near-zero per unit --
///    NOT a usable address on its own): `<unit-or-blank>: <proc> at
///    <8-hex offset>`, e.g. `linkmap-btn.TEXT.unix.txt:22`
///    (`        : BTNREAD  at 00000000`, blank unit = the file's main
///    program) and `:80` (`ckUtil  : STUFFHAN at 00000000`). Ignored here --
///    superseded by part 3, which resolves the same routines to final
///    addresses.
/// 3. The **final address table**, introduced by a
///    `  Number of segments in file = N, number of Jump Table entries = M`
///    line (not itself parsed -- every data line below is self-describing)
///    and running to the `Linking segment:` trailer. One line per routine,
///    alphabetically keyed:
///    `<key> - <proc> @ <unit>: <6-hex address> [JT: <6-hex>]`, e.g.
///    `linkmap-btn.TEXT.unix.txt:120` (`BTNREAD  - BTNREAD  @         :
///    020000`, blank unit) and `:132` (`STUFFHAN - STUFFHAN @ ckUtil  :
///    040000 JT: F8030A`). `<key>` is the proc name, or a synthetic
///    `$NNNNNNN` placeholder the linker assigns when the same name is
///    reused by another unit in the file (both alphabetic-key forms carry
///    the correct `<proc>`/`<unit>`/address after the `@`, so `<key>` is
///    ignored). This is the table this parser reads.
/// 4. `Linking segment: <name> file (JT) seg: <N> size: <bytes>` trailer
///    lines (parsed only for the citation below, not consumed): they
///    confirm that a routine's 6-hex address is
///    `segmentNumber * $020000 + offsetWithinSegment` -- e.g.
///    `linkmap-filer.TEXT.unix.txt:1228` says `flrCopy` is segment 9, and
///    every `flrCopy` routine's address has high byte `$12` = 9*2
///    (`:631`, `CALCBBOX @ flrCopy : 121C40`); `linkmap-btn.TEXT.unix.txt:
///    215-217` says the blank/main segment is 1 and `ckUtil` is 2, matching
///    their `$02...`/`$04...` addresses throughout part 3.
///
/// ## Coverage finding (Task 2 step 2, both `Linkmaps 3.0/` and
/// `Linkmaps and Misc. 3.0/` inspected)
///
/// All 22 files are Office System **application/library** linkmaps (Filer,
/// LisaWrite, LisaCalc, LisaDraw, LisaGraph, LisaList, LisaProject,
/// LisaTerminal, Preferences, Shell, Clock, Calculator, TKALERT, and the
/// shared libraries btn/cimap/iosfplib/lcorbglib/prlib/qplib/sys1lib/
/// sys2lib/timer). **There is no linkmap for the OS kernel itself** --
/// the anonymous supervisor code the boot loader installs at `$520000+`
/// (`SOURCE-STARTUP`/`LIBHW-DRIVERS`/`INITSYS`, the M3/M4 trace target)
/// has no corresponding file in either Linkmaps directory; only its
/// *source* lives under `LISA_OS/OS/`, and its *build scripts* (not a
/// linkmap) live under `LISA_OS/OS exec files/`. So symbol resolution in
/// kernel space is expected, honestly, to be EMPTY with these inputs alone
/// -- see `task-2-report.md`'s "symbol coverage" finding.
///
/// ## Base-offset story
///
/// Part 3's addresses are the Lisa linker's LINK-TIME logical addresses
/// (`segment# * $020000 + offset`), assigned independently per file/app --
/// NOT post-relocation runtime addresses. The OS's segment loader remaps
/// each numbered segment into a real MMU domain/segment at load time (the
/// same SMT mechanism traced in M3's `do_an_mmu`; see rom-trace-notes.md
/// "Kernel push"), which this parser does not simulate, and different
/// files' segment-1 tables collide at the same link-time addresses (e.g.
/// both `btn`'s and `filer`'s main segments start at `$020000`) -- they are
/// only meaningful one file at a time. `LinkmapSymbols` therefore exposes a
/// user-settable `baseOffset` (`lisadbg`'s `symbase` command), ADDED to a
/// parsed address to get the address `lookup` matches against; it defaults
/// to 0 (`assume link-time == runtime`, which is exactly right for a
/// freshly-loaded segment 1 sitting at its own `$020000` link address --
/// the same convention the ROM's boot-block load coincidentally also
/// uses, per `ROMFloppyBootTests`).
public struct LinkmapSymbols {
    public struct Symbol: Equatable {
        /// Pascal unit name, or `""` for a file's main program.
        public let unit: String
        public let proc: String
        /// Link-time logical address (`segment# * $020000 + offset`).
        public let address: UInt32

        public init(unit: String, proc: String, address: UInt32) {
            self.unit = unit
            self.proc = proc
            self.address = address
        }

        /// `"UNIT.PROC"`, or just `"PROC"` for a blank (main-program) unit.
        public var name: String {
            unit.isEmpty ? proc : "\(unit).\(proc)"
        }
    }

    public enum LoadError: Error, CustomStringConvertible {
        case directoryNotFound(URL)
        public var description: String {
            switch self {
            case .directoryNotFound(let url): return "no such directory: \(url.path)"
            }
        }
    }

    /// Default search location per the global constraints (never bundled).
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/Lisa_Source/LISA_OS/Linkmaps 3.0")
    }

    /// Sorted ascending by `address` -- `lookup` relies on this for its
    /// nearest-at-or-below binary search.
    public private(set) var symbols: [Symbol]

    /// Added to a parsed symbol's link-time address before comparing
    /// against a `lookup(_:)` query -- see the type doc's "base-offset
    /// story". 0 by default.
    public var baseOffset: UInt32 = 0

    public init(symbols: [Symbol] = []) {
        self.symbols = symbols.sorted { $0.address < $1.address }
    }

    /// Parses one linkmap file's text (part 3 of the format, see the type
    /// doc comment) into symbols. Pure and file-independent -- this is what
    /// the synthetic-fixture unit tests exercise directly.
    ///
    /// Recognizes a data line by tokenizing on whitespace and locating a
    /// standalone `"@"` token preceded by `"-"` two tokens earlier (the
    /// `NAME - NAME @ UNIT: ADDR [JT: ...]` shape); every other line in the
    /// file (headers, the module-relative part-2 listing, `Linking
    /// segment:` trailers, ...) has no such token and is skipped.
    public static func parse(_ text: String) -> [Symbol] {
        var results: [Symbol] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = rawLine.split(separator: " ").map(String.init)
            guard let atIndex = tokens.firstIndex(of: "@"),
                  atIndex >= 2, tokens[atIndex - 2] == "-",
                  atIndex + 1 < tokens.count
            else { continue }
            let proc = tokens[atIndex - 1]

            var idx = atIndex + 1
            var unit = ""
            if tokens[idx] != ":" {
                unit = tokens[idx]
                idx += 1
            }
            guard idx < tokens.count, tokens[idx] == ":", idx + 1 < tokens.count else { continue }
            idx += 1

            let hexToken = tokens[idx]
            guard hexToken.count == 6, let address = UInt32(hexToken, radix: 16) else { continue }

            results.append(Symbol(unit: unit, proc: proc, address: address))
        }
        return results
    }

    /// Parses every regular file in `directory` (non-recursive -- matches
    /// both real Linkmaps directories, which are flat) and merges the
    /// results. Throws if `directory` does not exist; a directory that
    /// exists but contains no linkmap-shaped lines yields an empty (but
    /// valid, lookups just always return nil) `LinkmapSymbols`.
    public static func load(directory: URL) throws -> LinkmapSymbols {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.directoryNotFound(directory)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var all: [Symbol] = []
        for fileURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // The real files are LINK's captured console output, `.isoLatin1`
            // per `file`(1) (e.g. `linkmap-btn.TEXT.unix.txt` ends in a
            // stray `$FF` byte that trips a strict UTF-8 decode) -- every
            // byte we actually need is plain ASCII, and Latin-1 never fails
            // to decode, so it's used here regardless of a given file's
            // exact byte content.
            guard let text = try? String(contentsOf: fileURL, encoding: .isoLatin1) else { continue }
            all.append(contentsOf: parse(text))
        }
        return LinkmapSymbols(symbols: all)
    }

    /// Nearest-at-or-below match for `address` (after undoing `baseOffset`),
    /// constrained to the same `$020000`-aligned link-time segment slot as
    /// the query (see the type doc's "base-offset story" -- part 3's
    /// addressing convention reserves one 128 KB slot per segment number,
    /// so a match from a different slot is certainly a different segment,
    /// not this one merely lacking a closer symbol). Returns `"UNIT.PROC"`
    /// on an exact hit, `"UNIT.PROC+0xNN"` otherwise, or `nil` if nothing
    /// in range resolves.
    public func lookup(_ address: UInt32) -> String? {
        guard !symbols.isEmpty else { return nil }
        let raw = address &- baseOffset
        let slot = raw & 0xFFFE_0000

        var lo = 0, hi = symbols.count - 1
        var candidate: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if symbols[mid].address <= raw {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let idx = candidate else { return nil }
        let symbol = symbols[idx]
        guard symbol.address & 0xFFFE_0000 == slot else { return nil }

        let offset = raw - symbol.address
        return offset == 0 ? symbol.name : "\(symbol.name)+0x\(String(offset, radix: 16, uppercase: true))"
    }
}
