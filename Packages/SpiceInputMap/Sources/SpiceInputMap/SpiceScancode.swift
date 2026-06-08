import Foundation

/// Translates macOS virtual key codes (`NSEvent.keyCode`) to IBM PC **set-1**
/// scancodes, which is what SPICE's `INPUTS` channel transmits (and what
/// CocoaSpice's `-[CSInput sendKey:code:]` expects).
///
/// Encoding: a plain key is its one-byte make code (e.g. `Esc = 0x01`). An
/// "extended" key (arrows, navigation cluster, right-hand modifiers, keypad
/// Enter/Divide, GUI/Menu) is sent on the wire as the prefix byte `0xE0` followed
/// by the make code; we encode that as a single value `0xE0_00 | makeCode`, which
/// matches spice-gtk's convention of carrying the `0xe0` prefix in the high byte.
public enum SpiceScancode {
    /// High-byte marker for an extended (`0xE0`-prefixed) set-1 scancode.
    public static let extendedPrefix = 0xE000

    /// Whether `code` is an extended scancode (its make code is preceded by `0xE0`).
    public static func isExtended(_ code: Int) -> Bool {
        (code & 0xFF00) == extendedPrefix
    }

    /// The raw on-the-wire byte sequence for a scancode on key press (make).
    /// Extended keys expand to `[0xE0, makeByte]`; plain keys to `[makeByte]`.
    public static func makeBytes(_ code: Int) -> [UInt8] {
        if isExtended(code) {
            return [0xE0, UInt8(code & 0xFF)]
        }
        return [UInt8(code & 0xFF)]
    }

    /// The on-the-wire byte sequence on key release (break). Set-1 break codes set
    /// bit 7 of the make code: plain `make | 0x80`; extended `[0xE0, make | 0x80]`.
    public static func breakBytes(_ code: Int) -> [UInt8] {
        if isExtended(code) {
            return [0xE0, UInt8((code & 0xFF) | 0x80)]
        }
        return [UInt8((code & 0xFF) | 0x80)]
    }

    /// Map a macOS virtual key code to a set-1 scancode, or `nil` if unmapped.
    public static func setOne(forMacVirtualKey keyCode: UInt16) -> Int? {
        table[keyCode]
    }

    private static let E = extendedPrefix

    /// macOS virtual key code → set-1 scancode. US/ANSI layout.
    public static let table: [UInt16: Int] = [
        // Letters
        MacVirtualKey.a: 0x1E, MacVirtualKey.b: 0x30, MacVirtualKey.c: 0x2E,
        MacVirtualKey.d: 0x20, MacVirtualKey.e: 0x12, MacVirtualKey.f: 0x21,
        MacVirtualKey.g: 0x22, MacVirtualKey.h: 0x23, MacVirtualKey.i: 0x17,
        MacVirtualKey.j: 0x24, MacVirtualKey.k: 0x25, MacVirtualKey.l: 0x26,
        MacVirtualKey.m: 0x32, MacVirtualKey.n: 0x31, MacVirtualKey.o: 0x18,
        MacVirtualKey.p: 0x19, MacVirtualKey.q: 0x10, MacVirtualKey.r: 0x13,
        MacVirtualKey.s: 0x1F, MacVirtualKey.t: 0x14, MacVirtualKey.u: 0x16,
        MacVirtualKey.v: 0x2F, MacVirtualKey.w: 0x11, MacVirtualKey.x: 0x2D,
        MacVirtualKey.y: 0x15, MacVirtualKey.z: 0x2C,

        // Digits row
        MacVirtualKey.one: 0x02, MacVirtualKey.two: 0x03, MacVirtualKey.three: 0x04,
        MacVirtualKey.four: 0x05, MacVirtualKey.five: 0x06, MacVirtualKey.six: 0x07,
        MacVirtualKey.seven: 0x08, MacVirtualKey.eight: 0x09, MacVirtualKey.nine: 0x0A,
        MacVirtualKey.zero: 0x0B,

        // Punctuation
        MacVirtualKey.minus: 0x0C, MacVirtualKey.equal: 0x0D,
        MacVirtualKey.leftBracket: 0x1A, MacVirtualKey.rightBracket: 0x1B,
        MacVirtualKey.semicolon: 0x27, MacVirtualKey.quote: 0x28,
        MacVirtualKey.grave: 0x29, MacVirtualKey.backslash: 0x2B,
        MacVirtualKey.comma: 0x33, MacVirtualKey.period: 0x34, MacVirtualKey.slash: 0x35,

        // Control / whitespace
        MacVirtualKey.escape: 0x01, MacVirtualKey.delete: 0x0E, MacVirtualKey.tab: 0x0F,
        MacVirtualKey.returnKey: 0x1C, MacVirtualKey.space: 0x39,
        MacVirtualKey.capsLock: 0x3A,

        // Modifiers
        MacVirtualKey.control: 0x1D, MacVirtualKey.shift: 0x2A,
        MacVirtualKey.option: 0x38, MacVirtualKey.command: E | 0x5B,   // left GUI
        MacVirtualKey.rightShift: 0x36, MacVirtualKey.rightControl: E | 0x1D,
        MacVirtualKey.rightOption: E | 0x38, MacVirtualKey.rightCommand: E | 0x5C,

        // Function keys
        MacVirtualKey.f1: 0x3B, MacVirtualKey.f2: 0x3C, MacVirtualKey.f3: 0x3D,
        MacVirtualKey.f4: 0x3E, MacVirtualKey.f5: 0x3F, MacVirtualKey.f6: 0x40,
        MacVirtualKey.f7: 0x41, MacVirtualKey.f8: 0x42, MacVirtualKey.f9: 0x43,
        MacVirtualKey.f10: 0x44, MacVirtualKey.f11: 0x57, MacVirtualKey.f12: 0x58,

        // Keypad
        MacVirtualKey.keypadClear: 0x45,        // NumLock
        MacVirtualKey.keypadDivide: E | 0x35,
        MacVirtualKey.keypadMultiply: 0x37,
        MacVirtualKey.keypadMinus: 0x4A,
        MacVirtualKey.keypadPlus: 0x4E,
        MacVirtualKey.keypadEnter: E | 0x1C,
        MacVirtualKey.keypadDecimal: 0x53,
        MacVirtualKey.keypad0: 0x52, MacVirtualKey.keypad1: 0x4F,
        MacVirtualKey.keypad2: 0x50, MacVirtualKey.keypad3: 0x51,
        MacVirtualKey.keypad4: 0x4B, MacVirtualKey.keypad5: 0x4C,
        MacVirtualKey.keypad6: 0x4D, MacVirtualKey.keypad7: 0x47,
        MacVirtualKey.keypad8: 0x48, MacVirtualKey.keypad9: 0x49,

        // Navigation cluster (extended)
        MacVirtualKey.help: E | 0x52,           // Insert
        MacVirtualKey.forwardDelete: E | 0x53,  // Delete
        MacVirtualKey.home: E | 0x47, MacVirtualKey.end: E | 0x4F,
        MacVirtualKey.pageUp: E | 0x49, MacVirtualKey.pageDown: E | 0x51,
        MacVirtualKey.leftArrow: E | 0x4B, MacVirtualKey.rightArrow: E | 0x4D,
        MacVirtualKey.upArrow: E | 0x48, MacVirtualKey.downArrow: E | 0x50,
    ]
}
