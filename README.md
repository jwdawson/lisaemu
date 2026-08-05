# LisaEmu

A from-scratch Apple Lisa 2/10 emulator in Swift, built to study the released
Lisa OS 3.1 source. Design spec: docs/superpowers/specs/.

No Apple ROMs, disk images, or Lisa source files are included or accepted in
this repository.

The macOS app (`LisaApp/`) is an Xcode project generated from a committed
spec: run `xcodegen generate --spec LisaApp/project.yml` to produce
`LisaApp/LisaApp.xcodeproj` (gitignored, regenerate as needed).
