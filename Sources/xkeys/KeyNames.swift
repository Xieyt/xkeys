import Foundation

/// Names for HID Keyboard/Keypad usages (usage page 0x07).
///
/// This is the vocabulary of the config file: a swap is written as
/// `{"from": "CapsLock", "to": "F20"}`, and both sides resolve through here.
/// It is also what `xkeys watch` prints and what `xkeys keys` lists.
enum KeyNames {
    /// Canonical name -> HID usage. Lookup is case-insensitive via `usage(for:)`.
    static let byName: [String: UInt32] = {
        var t: [String: UInt32] = [:]

        // Letters, 0x04-0x1D
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            t[String(c)] = UInt32(0x04 + i)
        }
        // Digits 1-9 then 0, 0x1E-0x27
        for (i, c) in "1234567890".enumerated() {
            t[String(c)] = UInt32(0x1E + i)
        }

        let fixed: [String: UInt32] = [
            "Return": 0x28, "Escape": 0x29, "Delete": 0x2A, "Tab": 0x2B,
            "Space": 0x2C, "Minus": 0x2D, "Equal": 0x2E,
            "LeftBracket": 0x2F, "RightBracket": 0x30, "Backslash": 0x31,
            "Semicolon": 0x33, "Quote": 0x34, "Grave": 0x35,
            "Comma": 0x36, "Period": 0x37, "Slash": 0x38,
            "CapsLock": 0x39,

            "F1": 0x3A, "F2": 0x3B, "F3": 0x3C, "F4": 0x3D, "F5": 0x3E, "F6": 0x3F,
            "F7": 0x40, "F8": 0x41, "F9": 0x42, "F10": 0x43, "F11": 0x44, "F12": 0x45,

            "PrintScreen": 0x46, "ScrollLock": 0x47, "Pause": 0x48,
            "Insert": 0x49, "Home": 0x4A, "PageUp": 0x4B,
            "ForwardDelete": 0x4C, "End": 0x4D, "PageDown": 0x4E,
            "Right": 0x4F, "Left": 0x50, "Down": 0x51, "Up": 0x52,

            "F13": 0x68, "F14": 0x69, "F15": 0x6A, "F16": 0x6B, "F17": 0x6C,
            "F18": 0x6D, "F19": 0x6E, "F20": 0x6F, "F21": 0x70, "F22": 0x71,
            "F23": 0x72, "F24": 0x73,

            "Execute": 0x74, "Help": 0x75, "Menu": 0x76, "Select": 0x77,
            "Stop": 0x78, "Again": 0x79, "Undo": 0x7A, "Cut": 0x7B,
            "Copy": 0x7C, "Paste": 0x7D, "Find": 0x7E,

            "Intl1": 0x87, "Intl2": 0x88, "Intl3": 0x89, "Intl4": 0x8A,
            "Intl5": 0x8B, "Intl6": 0x8C, "Intl7": 0x8D, "Intl8": 0x8E, "Intl9": 0x8F,
            "Lang1": 0x90, "Lang2": 0x91, "Lang3": 0x92, "Lang4": 0x93,
            "Lang5": 0x94, "Lang6": 0x95, "Lang7": 0x96, "Lang8": 0x97, "Lang9": 0x98,

            "LeftControl": 0xE0, "LeftShift": 0xE1, "LeftOption": 0xE2, "LeftCommand": 0xE3,
            "RightControl": 0xE4, "RightShift": 0xE5, "RightOption": 0xE6, "RightCommand": 0xE7,
        ]
        t.merge(fixed) { a, _ in a }
        return t
    }()

    /// HID usage -> canonical name.
    static let byUsage: [UInt32: String] = {
        var t: [UInt32: String] = [:]
        for (name, usage) in byName where t[usage] == nil || t[usage]!.count > name.count {
            t[usage] = name
        }
        return t
    }()

    static func usage(for name: String) -> UInt32? {
        if let exact = byName[name] { return exact }
        let folded = name.lowercased()
        for (candidate, usage) in byName where candidate.lowercased() == folded {
            return usage
        }
        return nil
    }

    static func name(for usage: UInt32) -> String {
        byUsage[usage] ?? String(format: "usage 0x%02X", usage)
    }

    /// Full HID usage value as `hidutil` wants it: usage page 0x07 in the high
    /// 32 bits, usage in the low. 0x39 (CapsLock) becomes 0x700000039.
    static func hidValue(_ usage: UInt32) -> UInt64 {
        0x7_0000_0000 | UInt64(usage)
    }

    /// Recover the usage from a full hidutil value, or nil if it is not on the
    /// keyboard page.
    static func usageFromHIDValue(_ value: UInt64) -> UInt32? {
        guard value & 0xFFFF_FFFF_0000_0000 == 0x7_0000_0000 else { return nil }
        return UInt32(value & 0xFFFF_FFFF)
    }

    /// Keys that no Apple keyboard has ever shipped, grouped for display.
    ///
    /// Asking the hardware does not work: a MacBook's keyboard descriptor
    /// claims all 228 usages including F13-F20 and the Japanese language keys,
    /// so the device cannot tell you what it is physically able to send. This
    /// table is the honest answer instead - if Apple never put the key on a
    /// keyboard, nothing can press it, so nothing can be bound to it.
    ///
    /// F13-F19 are deliberately absent: full-size Apple keyboards have them.
    static let safeTargets: [(group: String, names: [String], note: String)] = [
        ("Function", ["F20", "F21", "F22", "F23", "F24"], "F13-F19 exist on full-size Apple keyboards"),
        ("Editing", ["Again", "Undo", "Cut", "Copy", "Paste", "Find"], "HID editing keys, never on Apple hardware"),
        ("System", ["Execute", "Menu", "Select", "Stop"], ""),
        ("Japanese/Korean", ["Lang3", "Lang4", "Lang5", "Lang6", "Lang7", "Lang8", "Lang9"], "Lang1/Lang2 ship on JIS keyboards"),
        ("International", ["Intl4", "Intl5", "Intl6", "Intl7", "Intl8", "Intl9"], "Intl1-Intl3 ship on JIS/ABNT keyboards"),
    ]
}
