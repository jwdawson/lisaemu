import Foundation

/// Host (macOS) keyboard event -> Lisa COPS keycap translation.
///
/// Source: docs/hardware-notes.md §8 "Keyboard and Mouse Input" (mined
/// from LIBHW-LEGENDS/KEYBD/DRIVERS -- M1c Task 2), which is the
/// authoritative reference for every numeric Lisa keycap below; see that
/// section for citations.
///
/// The Mac-side keycodes are macOS's Carbon/HIToolbox `kVK_*` virtual
/// keycode constants. This target is deliberately Foundation-only (no
/// AppKit/Carbon import -- see the `LisaShell` target's doc comment in
/// `Package.swift`), so the numeric values are hardcoded here with the
/// `kVK_*` name they correspond to noted in a trailing comment on each
/// case, rather than importing Carbon for the symbols.
///
/// Only ordinary keyboard events live here. The mouse button (Lisa keycap
/// `$06`, hardware-notes.md §8 "Mouse") is delivered via mouse events, not
/// a keyboard virtual keycode, and is out of scope for this type -- see
/// M1c Task 4 ("Input wiring").
public enum KeyMap {
    /// Translates a macOS Carbon virtual keycode (`kVK_*`) to the Lisa
    /// 7-bit keycap it corresponds to, or `nil` if the Lisa keyboard has
    /// no equivalent key (function keys, Escape, Control, etc. -- the Lisa
    /// keyboard predates all of these).
    ///
    /// The returned value is the bare 7-bit keycap (bits 6-0). Down/up
    /// framing (bit 7: `$80` down / `$00` up) is the caller's
    /// responsibility -- this function only answers "which key", not
    /// "pressed or released".
    ///
    /// CapsLock (`$7D`) is a **latching** key on real Lisa hardware
    /// (hardware-notes.md §8 "Modifiers") -- the OS/app layer tracks lock
    /// state itself from the down/up edges this returns; this function
    /// does no latching of its own (that's M1c Task 4's job, at the app
    /// layer).
    public static func lisaKeycap(forMacKeyCode macKeyCode: UInt16) -> UInt8? {
        switch macKeyCode {
        // MARK: Letters (main block, mapped by legend, not physical position)
        case 0x00: return 0x70 // kVK_ANSI_A -> 'a'
        case 0x0B: return 0x6E // kVK_ANSI_B -> 'b'
        case 0x08: return 0x6D // kVK_ANSI_C -> 'c'
        case 0x02: return 0x7B // kVK_ANSI_D -> 'd'
        case 0x0E: return 0x60 // kVK_ANSI_E -> 'e'
        case 0x03: return 0x69 // kVK_ANSI_F -> 'f'
        case 0x05: return 0x6A // kVK_ANSI_G -> 'g'
        case 0x04: return 0x6B // kVK_ANSI_H -> 'h'
        case 0x22: return 0x53 // kVK_ANSI_I -> 'i'
        case 0x26: return 0x54 // kVK_ANSI_J -> 'j'
        case 0x28: return 0x55 // kVK_ANSI_K -> 'k'
        case 0x25: return 0x59 // kVK_ANSI_L -> 'l'
        case 0x2E: return 0x58 // kVK_ANSI_M -> 'm'
        case 0x2D: return 0x6F // kVK_ANSI_N -> 'n'
        case 0x1F: return 0x5F // kVK_ANSI_O -> 'o'
        case 0x23: return 0x44 // kVK_ANSI_P -> 'p'
        case 0x0C: return 0x75 // kVK_ANSI_Q -> 'q'
        case 0x0F: return 0x65 // kVK_ANSI_R -> 'r'
        case 0x01: return 0x76 // kVK_ANSI_S -> 's'
        case 0x11: return 0x66 // kVK_ANSI_T -> 't'
        case 0x20: return 0x52 // kVK_ANSI_U -> 'u'
        case 0x09: return 0x6C // kVK_ANSI_V -> 'v'
        case 0x0D: return 0x77 // kVK_ANSI_W -> 'w'
        case 0x07: return 0x7A // kVK_ANSI_X -> 'x'
        case 0x10: return 0x67 // kVK_ANSI_Y -> 'y'
        case 0x06: return 0x79 // kVK_ANSI_Z -> 'z'

        // MARK: Digits + their shifted-row punctuation (main block)
        case 0x12: return 0x74 // kVK_ANSI_1 -> '1!'
        case 0x13: return 0x71 // kVK_ANSI_2 -> '2@'
        case 0x14: return 0x72 // kVK_ANSI_3 -> '3#'
        case 0x15: return 0x73 // kVK_ANSI_4 -> '4$'
        case 0x17: return 0x64 // kVK_ANSI_5 -> '5%'
        case 0x16: return 0x61 // kVK_ANSI_6 -> '6^'
        case 0x1A: return 0x62 // kVK_ANSI_7 -> '7&'
        case 0x1C: return 0x63 // kVK_ANSI_8 -> '8*'
        case 0x19: return 0x50 // kVK_ANSI_9 -> '9('
        case 0x1D: return 0x51 // kVK_ANSI_0 -> '0)'

        // MARK: Other punctuation (main block)
        case 0x1B: return 0x40 // kVK_ANSI_Minus -> '-_'
        case 0x18: return 0x41 // kVK_ANSI_Equal -> '=+'
        case 0x2A: return 0x42 // kVK_ANSI_Backslash -> '\|'
        case 0x21: return 0x56 // kVK_ANSI_LeftBracket -> '[{'
        case 0x1E: return 0x57 // kVK_ANSI_RightBracket -> ']}'
        case 0x29: return 0x5A // kVK_ANSI_Semicolon -> ';:'
        case 0x27: return 0x5B // kVK_ANSI_Quote -> '\'"'
        case 0x2B: return 0x5D // kVK_ANSI_Comma -> ',<'
        case 0x2F: return 0x5E // kVK_ANSI_Period -> '.>'
        case 0x2C: return 0x4C // kVK_ANSI_Slash -> '/?'
        case 0x32: return 0x68 // kVK_ANSI_Grave -> '`~'

        // MARK: Editing / whitespace (main block)
        case 0x24: return 0x48 // kVK_Return -> Return ($0D)
        case 0x30: return 0x78 // kVK_Tab -> Tab ($09)
        case 0x33: return 0x45 // kVK_Delete (backspace) -> Backspace ($08)
        case 0x31: return 0x5C // kVK_Space -> Space

        // MARK: Modifiers (main block)
        case 0x38: return 0x7E // kVK_Shift -> Shift
        case 0x3C: return 0x7E // kVK_RightShift -> Shift (same Lisa keycap; OS ORs L/R)
        case 0x37: return 0x7F // kVK_Command -> Command/Apple
        case 0x3A: return 0x7C // kVK_Option -> L-Option
        case 0x3D: return 0x4E // kVK_RightOption -> R-Option
        case 0x39: return 0x7D // kVK_CapsLock -> CapsLock (latching -- see doc comment)

        // MARK: Keypad digits 0/1 (these live in the Lisa MAIN block range,
        // not $20-$2F -- hardware-notes.md §8's matrix is explicit about
        // this asymmetry).
        case 0x52: return 0x49 // kVK_ANSI_Keypad0 -> pad 0
        case 0x53: return 0x4D // kVK_ANSI_Keypad1 -> pad 1

        // MARK: Keypad block ($20-$2F)
        case 0x47: return 0x20 // kVK_ANSI_KeypadClear -> pad Clear
        case 0x4E: return 0x21 // kVK_ANSI_KeypadMinus -> pad -
        case 0x7B: return 0x22 // kVK_LeftArrow -> pad Left ($22) -- also doubles as an arrow key
        case 0x45: return 0x22 // kVK_ANSI_KeypadPlus -> pad Left/+ ($22): the Lisa keypad has
                                // no bare '+' key, $22 is Left(,+shift=+) -- hardware-notes.md §8.
        case 0x7C: return 0x23 // kVK_RightArrow -> pad Right ($23) -- also doubles as an arrow key
        case 0x59: return 0x24 // kVK_ANSI_Keypad7 -> pad 7
        case 0x5B: return 0x25 // kVK_ANSI_Keypad8 -> pad 8
        case 0x5C: return 0x26 // kVK_ANSI_Keypad9 -> pad 9
        case 0x7E: return 0x27 // kVK_UpArrow -> pad Up ($27) -- also doubles as an arrow key
        case 0x56: return 0x28 // kVK_ANSI_Keypad4 -> pad 4
        case 0x57: return 0x29 // kVK_ANSI_Keypad5 -> pad 5
        case 0x58: return 0x2A // kVK_ANSI_Keypad6 -> pad 6
        case 0x7D: return 0x2B // kVK_DownArrow -> pad Down ($2B) -- also doubles as an arrow key
        case 0x41: return 0x2C // kVK_ANSI_KeypadDecimal -> pad .
        case 0x54: return 0x2D // kVK_ANSI_Keypad2 -> pad 2
        case 0x55: return 0x2E // kVK_ANSI_Keypad3 -> pad 3
        case 0x4C: return 0x2F // kVK_ANSI_KeypadEnter -> pad Enter (numeric)

        // Unmappable: F-keys, Escape, Control, Function, forward-delete,
        // Home/End/PageUp/PageDown, and anything else the Lisa keyboard
        // (a mid-1980s 76-key layout) has no equivalent for.
        default: return nil
        }
    }
}
