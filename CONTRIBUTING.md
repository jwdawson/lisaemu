# Contributing to LisaEmu

Thanks for your interest! LisaEmu is a from-scratch Apple Lisa 2/10 emulator
built primarily as a learning project, and contributions are welcome — with a
few rules that exist to keep the project legally clean and its engineering
record trustworthy.

## The one rule that is never bent: no Apple-derived data

**Never commit, or attach to a PR or issue:**

- ROM images (boot ROM, I/O ROM, COPS ROM) or any fragment of one
- Disk images — install floppies, `.dc42` files, **and any Widget/ProFile
  image an installer has written to** (a blank all-zero image our tooling
  created is fine; one the OS has touched is Apple-derived data)
- Apple's Lisa OS source code beyond short, line-cited excerpts used as
  engineering evidence (the style used throughout `docs/hardware-notes.md`)
- Symbol tables or other data derived from Apple's shipped Linkmaps
  (the emulator parses those at runtime from a user-supplied path — never
  from the repo)
- Screenshots are fine — they're this project's evidence currency — but they
  live outside the repo for the maintainer's records; in PRs/issues, attach
  them to the GitHub conversation rather than committing them.

PRs containing any of the above will be closed. If your fix needs one of
these to reproduce, describe where to obtain it (bitsavers, etc.) and the
exact path layout instead — see "External assets" in the README.

## How changes land

- The `main` branch is protected: all changes go through a pull request and
  require the maintainer's approving review (CODEOWNERS). Nothing merges
  without that approval, so expect review dialogue rather than instant merges.
- Fork the repo, branch from `main`, open a PR against `main`.
- Keep PRs focused — one concern per PR reviews faster and lands sooner.

## Engineering conventions (read before writing code)

This project has an unusual discipline that reviews enforce:

1. **Evidence-gated changes.** Any change to device or CPU-adjacent behavior
   must cite its justification — a file:line reference into the Lisa OS
   source, the boot ROM disassembly, or a live trace. "It makes the OS
   happier" is not a justification; the project's history shows plausible
   guesses are usually wrong.
2. **Both-docs rule.** Hardware facts (registers, bit meanings, constants)
   live in `docs/hardware-notes.md`; trace narratives and boot-journey
   findings live in `docs/rom-trace-notes.md`. A change that alters either
   updates both where relevant.
3. **Strike, never erase.** When new evidence refutes something the docs
   claim, strike the old text (`~~like this~~`) and add a dated supersession
   note. The record of being wrong is part of the record.
4. **TDD for device/core work.** Failing test first, then the implementation.
   Protocol tests use synthetic data (temp-dir images, in-test fixtures) and
   must not require real Apple assets.
5. **Never weaken a pinned anchor.** Framebuffer hashes, block counts, and
   POST markers in the test suite pin real machine states. If your change
   legitimately moves one, the PR must explain *why* with the same evidence
   bar — a moved pin without a story is a red flag, not a re-baseline.

## Building and testing

```sh
swift build -c release          # LisaCore + lisadbg
swift test                      # 242 tests; asset-gated suites skip cleanly
```

The full matrix (real ROM/disk/Widget/Linkmap suites, the LisaApp Xcode
tests, and the ~1M-vector TomHarte CPU conformance run) is described in the
README. PRs are expected to keep `swift test` green with **no** environment
variables set; run the asset-gated suites you can. The TomHarte totals
(807147 passing / 0 failing / 192913 categorized known-failures) are exact —
any movement needs a stop-the-line explanation, not a re-baseline.

## Vendored Musashi

`Sources/CMusashi/` is vendored from Musashi with local patches applied by
`Scripts/vendor-musashi.sh` (anchored and fail-loud, pinned to
`MUSASHI_COMMIT.txt`). Never hand-edit vendored files in a PR — change the
vendor script's patch stages so the modification is reproducible, and include
the citation for why the 68000 behavior change is correct.

## Good first contributions

The current frontier and deferred items are listed at the end of
`docs/m5-demo.md` (M6 candidates: COPS RTC/clock, soft-power, exercising the
desktop applications, and several smaller items). Issues and questions are
welcome even without code.

## License

By contributing, you agree your contributions are licensed under the
project's [MIT License](LICENSE). Don't contribute code you don't have the
right to license — and remember that Apple's ROMs, disk images, and OS
source are not yours (or ours) to license at all.
