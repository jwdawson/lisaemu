# M1b demo — POST to the boot menu

Milestone M1b's exit criterion: the real Apple Lisa Rev H boot ROM runs
under the emulator, completes power-on self-test, and draws its startup
menu. This page shows how to reproduce it.

## Reproduce

Point `lisadbg` at a directory holding the interleaved Rev H ROM halves
(`341-0175-H.BIN` / `341-0176-H.BIN`):

```sh
cd LisaEmu
printf 'g 25000000\nsc ~/Development/LisaEmu-artifacts/m1b-boot-screen.png\nq\n' \
  | swift run -c release lisadbg --rom $HOME/Development/LisaROMs
```

- `g 25000000` runs 25 M CPU cycles (the menu is fully drawn and the ROM has
  entered its input-idle loop by ~18 M; 25 M is comfortably inside the
  bit-stable window — see docs/rom-trace-notes.md "POST completion (Task 7)").
- `sc <path>.png` writes the 720×364 1bpp framebuffer as a PNG (set bit =
  black). Use `sca` instead for a quick in-terminal ASCII preview.

The screenshot is written OUTSIDE the repo — it renders Apple's ROM-drawn UI,
which is not committed.

Screenshot path: `~/Development/LisaEmu-artifacts/m1b-boot-screen.png`

## Expected output

The `g` command's final status line:

```
      setup=OFF domain=0 mmuPortWrites=4384 busErrorPulses=0 halted=false
FE2DCA: btst    #$1, D0
```

- `setup=OFF` — the ROM dropped MMU setup mode; translated execution works.
- `busErrorPulses=0`, `halted=false` — clean run, no fault.
- PC in `$FE2DBE-$FE2DD6` (`$FE2DCA` here) — the boot menu's "await next COPS
  input event" (mouse/keypress) idle loop.

The rendered screen (`m1b-boot-screen.png`) is the classic Lisa startup menu:

- Three buttons in a bordered box: **`⌘1 RESTART`**, **`⌘2 CONTINUE`**,
  **`⌘3 STARTUP FROM…`**.
- A mouse-cursor arrow, and an **`H`** ROM-revision marker (top-right).
- A crossed-out **ProFile** hard-disk icon labelled **`42`** — the
  no-boot-device / device-error indicator, expected since M1b models no
  floppy or hard-disk hardware.

This is both accepted M1b success states at once: the startup/boot-device UI
*and* a no-boot-device error indicator. With no user input, the ROM waits
here indefinitely — the correct terminal behavior for a menu.

## Regression test

`Tests/LisaCoreTests/ROMBootTests.romCompletesPOSTAndReachesBootMenu`
(env-gated on `LISAEMU_ROM_DIR`) asserts the same end state: POST-complete
markers, the input-loop PC range, a non-blank framebuffer with the exact set-
pixel count (78,100 / 262,080 = 29.8%), a robust `>1%`-black weaker
invariant, and the exact 64-bit FNV-1a framebuffer fingerprint
`0xd09234d25516d0b8`.

```sh
LISAEMU_ROM_DIR=$HOME/Development/LisaROMs swift test --filter ROMBootTests
```

## Correction (M1c Task 5)

The `m1b-boot-screen.png` and `live-boot-demo.png` screenshots have been
**regenerated** — earlier versions were photographic negatives of the real
screen (black/white swapped). M1c Task 3's review discovered the
discrepancy: the app's live-window blit pipeline was verified bit-exact
against `ROMBootTests`' 78,100-set-pixel invariant, but `lisadbg`'s `sc`
PNG writer produced 183,980 black pixels instead (the framebuffer's
minority-set "ink" bits rendering white, and the majority-clear
background rendering black). Root cause: `CGImageDestinationFinalize`
does not honor a custom CGImage `decode` array when encoding to PNG — the
`decode: [1, 0]` `sc` used to express "set bit = black" was silently
ignored, and the raw bits were written under PNG's default polarity
instead. Fixed in `Sources/lisadbg/main.swift`'s `writeScreenshotPNG` by
inverting the bits before encoding (matching `LisaShell/FrameExpansion
.swift`'s `expand1bppRow`, which bakes polarity into the sample data
rather than relying on a decode array) rather than by changing the
`decode` array again. The `sca` ASCII preview was checked as part of the
same investigation and found *not* to be affected — it counts raw bits
directly (like `expand1bppRow`) rather than going through `CGImage`/PNG,
so it was already correct. Both screenshots above were regenerated with
the fixed `sc` and re-verified against the same 78,100-black-pixel count
(`magick <file>.png -format %c histogram:info:-`).
