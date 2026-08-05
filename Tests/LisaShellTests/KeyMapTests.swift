import Testing
@testable import LisaShell

/// Tests for `KeyMap.lisaKeycap(forMacKeyCode:)` -- host (macOS Carbon
/// virtual keycode) to Lisa 7-bit keycap translation, per
/// docs/hardware-notes.md §8 "Keyboard and Mouse Input" (mined from
/// LIBHW-LEGENDS/KEYBD/DRIVERS, M1c Task 2).
///
/// Numeric literals below spell out the macOS Carbon `kVK_*` name they
/// stand for in a trailing comment, matching `KeyMap.swift`'s own
/// hardcoded-constant convention (this target is Foundation-only, no
/// Carbon import).
@Suite struct KeyMapTests {
    // MARK: - Spot round-trips

    @Test func lettersMapToTheirLisaLegend() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x00) == 0x70, "kVK_ANSI_A -> 'a'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x01) == 0x76, "kVK_ANSI_S -> 's'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x0C) == 0x75, "kVK_ANSI_Q -> 'q'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x06) == 0x79, "kVK_ANSI_Z -> 'z'")
    }

    @Test func digitsMapToTheirLisaLegend() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x12) == 0x74, "kVK_ANSI_1 -> '1!'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x1D) == 0x51, "kVK_ANSI_0 -> '0)'")
    }

    @Test func punctuationMapsToItsLisaLegend() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x1B) == 0x40, "kVK_ANSI_Minus -> '-_'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x18) == 0x41, "kVK_ANSI_Equal -> '=+'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x2A) == 0x42, "kVK_ANSI_Backslash -> '\\|'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x32) == 0x68, "kVK_ANSI_Grave -> '`~'")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x27) == 0x5B, "kVK_ANSI_Quote -> '\\'\"'")
    }

    @Test func editingAndWhitespaceKeysMapCorrectly() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x24) == 0x48, "kVK_Return -> Return")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x30) == 0x78, "kVK_Tab -> Tab")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x33) == 0x45, "kVK_Delete (backspace) -> Backspace")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x31) == 0x5C, "kVK_Space -> Space")
    }

    @Test func keypadDigitsMapPerTheMinedMatrix() {
        // pad 0 = $49, pad 1 = $4D live in the Lisa "main block" range;
        // pad 2-9/./Enter live in the $20-$2F keypad range -- see
        // hardware-notes.md §8 "Keycap Code Matrix".
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x52) == 0x49, "kVK_ANSI_Keypad0 -> pad 0")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x53) == 0x4D, "kVK_ANSI_Keypad1 -> pad 1")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x54) == 0x2D, "kVK_ANSI_Keypad2 -> pad 2")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x55) == 0x2E, "kVK_ANSI_Keypad3 -> pad 3")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x56) == 0x28, "kVK_ANSI_Keypad4 -> pad 4")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x57) == 0x29, "kVK_ANSI_Keypad5 -> pad 5")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x58) == 0x2A, "kVK_ANSI_Keypad6 -> pad 6")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x59) == 0x24, "kVK_ANSI_Keypad7 -> pad 7")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x5B) == 0x25, "kVK_ANSI_Keypad8 -> pad 8")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x5C) == 0x26, "kVK_ANSI_Keypad9 -> pad 9")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x41) == 0x2C, "kVK_ANSI_KeypadDecimal -> pad .")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x4C) == 0x2F, "kVK_ANSI_KeypadEnter -> pad Enter")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x4E) == 0x21, "kVK_ANSI_KeypadMinus -> pad -")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x47) == 0x20, "kVK_ANSI_KeypadClear -> pad Clear")
    }

    @Test func keypadPlusMapsToLeftSlashPlusPerTheNoBarePlusNote() {
        // The Lisa keypad has no bare '+' key -- $22 is Left(,+shift=+) --
        // hardware-notes.md §8. Host Numpad+ is mapped there too.
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x45) == 0x22, "kVK_ANSI_KeypadPlus -> $22 (Left/+)")
    }

    @Test func arrowKeysDoubleAsTheKeypadDirectionKeys() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x7B) == 0x22, "kVK_LeftArrow -> $22 (Left)")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x7C) == 0x23, "kVK_RightArrow -> $23 (Right)")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x7E) == 0x27, "kVK_UpArrow -> $27 (Up)")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x7D) == 0x2B, "kVK_DownArrow -> $2B (Down)")
    }

    @Test func modifiersMapCorrectly() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x38) == 0x7E, "kVK_Shift -> Shift")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x3C) == 0x7E, "kVK_RightShift -> Shift (same keycap)")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x37) == 0x7F, "kVK_Command -> Command")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x3A) == 0x7C, "kVK_Option (left) -> L-Option")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x3D) == 0x4E, "kVK_RightOption -> R-Option")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x39) == 0x7D, "kVK_CapsLock -> CapsLock")
    }

    // MARK: - Unmappable host keys

    @Test func unmappableHostKeysReturnNil() {
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x35) == nil, "kVK_Escape has no Lisa keycap")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x7A) == nil, "kVK_F1 has no Lisa keycap")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0x3B) == nil, "kVK_Control has no Lisa keycap")
        #expect(KeyMap.lisaKeycap(forMacKeyCode: 0xFFFF) == nil, "out-of-range code")
    }

    // MARK: - Completeness

    /// Every event-generating Lisa keycap in hardware-notes.md §8's matrix
    /// that a Mac keyboard can actually produce a key for must be reachable
    /// from some Mac keycode. Excluded (documented, not host-producible):
    /// $01-$08/$0B-$0E (disk/parallel/mouse/power pseudo-keys -- not
    /// keyboard events at all), $43 (marked "unused" on US), $46
    /// (AlphaEnter -- no distinct Mac key produces it), and $47/$4A/$4B/$4F
    /// (gaps in the mined matrix -- hardware-notes.md §8 notes these do
    /// not appear in the source table at all).
    @Test func everyReachableLisaKeycapInTheMatrixIsReachable() {
        let matrixGaps: Set<UInt8> = [0x43, 0x46, 0x47, 0x4A, 0x4B, 0x4F]
        var expectedReachable: Set<UInt8> = []
        // Main block $40-$7F minus the documented gaps above.
        for code in UInt8(0x40)...UInt8(0x7F) where !matrixGaps.contains(code) {
            expectedReachable.insert(code)
        }
        // Keypad block $20-$2F, all 16 codes.
        for code in UInt8(0x20)...UInt8(0x2F) {
            expectedReachable.insert(code)
        }

        var actuallyReachable: Set<UInt8> = []
        for macCode: UInt16 in 0...0xFF {
            if let cap = KeyMap.lisaKeycap(forMacKeyCode: macCode) {
                actuallyReachable.insert(cap)
            }
        }

        let missing = expectedReachable.subtracting(actuallyReachable)
        #expect(missing.isEmpty, "Lisa keycaps with no reachable Mac key: \(missing.map { String(format: "$%02X", $0) })")
    }

    /// No Mac keycode is ambiguous: the switch's cases must not clash on
    /// the same host code (would be a compile-time-unreachable-case bug),
    /// and every Lisa keycap has exactly one source Mac keycode EXCEPT the
    /// intentional arrow/keypad-direction and Numpad+/Left overlaps
    /// documented above.
    @Test func noUnintendedManyToOneCollisionsAmongMacKeycodes() {
        let intentionalDoubleMappedCaps: Set<UInt8> = [
            0x22, // Left/+: kVK_LeftArrow AND kVK_ANSI_KeypadPlus
            0x7E, // Shift: kVK_Shift AND kVK_RightShift (OS ORs L/R into one bit)
        ]

        var sources: [UInt8: [UInt16]] = [:]
        for macCode: UInt16 in 0...0xFF {
            if let cap = KeyMap.lisaKeycap(forMacKeyCode: macCode) {
                sources[cap, default: []].append(macCode)
            }
        }

        for (cap, macCodes) in sources {
            if intentionalDoubleMappedCaps.contains(cap) { continue }
            #expect(macCodes.count == 1,
                    "Lisa keycap $\(String(format: "%02X", cap)) has multiple unexpected Mac sources: \(macCodes)")
        }

        // Determinism: calling twice for the same input always agrees.
        for macCode: UInt16 in 0...0xFF {
            #expect(KeyMap.lisaKeycap(forMacKeyCode: macCode) == KeyMap.lisaKeycap(forMacKeyCode: macCode))
        }
    }
}
