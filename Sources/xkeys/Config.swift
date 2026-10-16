import CoreGraphics
import Foundation

/// Which keyboard a rule applies to.
///
/// Matching is a case-insensitive substring of the product name the device
/// reports - `"gk61"` matches `"gk61 pro 48"` - because the laptop keyboard
/// reports a vendor and product number of zero and can only be told apart by
/// name. `nil` means every keyboard, which is what every rule meant before
/// scoping existed.
struct DeviceScope: Equatable {
    /// Lowercased, for matching.
    let needle: String?
    /// As written in the config, for printing back.
    let written: String?

    static let any = DeviceScope(nil)

    init(_ raw: String?) {
        written = raw
        needle = raw?.lowercased()
    }

    func matches(_ product: String) -> Bool {
        guard let needle else { return true }
        return product.lowercased().contains(needle)
    }

    /// "   on gk61" for display, empty when the rule is unscoped.
    var suffix: String { written.map { "   on \($0)" } ?? "" }
}

/// A single one-to-one key swap, as written in the config file.
struct Swap: Equatable {
    let from: UInt32 // HID usage
    let to: UInt32 // HID usage
    let on: DeviceScope

    init(from: UInt32, to: UInt32, on: DeviceScope = .any) {
        self.from = from
        self.to = to
        self.on = on
    }

    var description: String { "\(KeyNames.name(for: from)) -> \(KeyNames.name(for: to))" }

    /// Comparing what the driver reports against what the config declared:
    /// the driver knows nothing about scope, only the two key usages.
    func sameKeys(as other: Swap) -> Bool { from == other.from && to == other.to }
}

/// A trigger key plus the modifiers to paint onto other keys while it is
/// held. `when` names the key your finger presses - the hardware reports the
/// physical key, not what the driver swapped it to.
struct Chord: Equatable {
    let when: UInt32 // HID usage of the physical trigger key
    let hold: CGEventFlags
    /// Swallow the trigger's own keystroke so no app receives it. Normally a
    /// no-op, because the window manager already removes it one stage
    /// earlier; it matters the day the window manager stops doing that.
    let hide: Bool
    let on: DeviceScope

    init(when: UInt32, hold: CGEventFlags, hide: Bool, on: DeviceScope = .any) {
        self.when = when
        self.hold = hold
        self.hide = hide
        self.on = on
    }

    /// "Cmd+Ctrl+Opt+Shift" - derived from the flags rather than echoed back
    /// from the config, so two configs that mean the same thing print the
    /// same way and the order is stable.
    var holdDescription: String { ModifierNames.describe(hold) }

    var description: String {
        "\(KeyNames.name(for: when)) held  ->  \(holdDescription) on the next key"
    }
}

/// Modifier names accepted in a chord's `hold` list.
enum ModifierNames {
    static let byName: [String: CGEventFlags] = [
        "command": .maskCommand,
        "control": .maskControl,
        "option": .maskAlternate,
        "shift": .maskShift,
        "function": .maskSecondaryFn,
    ]

    /// Display order is fixed so output never depends on config order.
    private static let display: [(CGEventFlags, String)] = [
        (.maskCommand, "Cmd"), (.maskControl, "Ctrl"), (.maskAlternate, "Opt"),
        (.maskShift, "Shift"), (.maskSecondaryFn, "Fn"),
    ]

    static func flag(for name: String) -> CGEventFlags? { byName[name.lowercased()] }

    static func describe(_ flags: CGEventFlags) -> String {
        let parts = display.filter { flags.contains($0.0) }.map(\.1)
        return parts.isEmpty ? "nothing" : parts.joined(separator: "+")
    }
}

/// The config file: a flat list of one-to-one key swaps, plus any number of
/// chords.
///
/// JSON rather than TOML because this app has no dependencies and Swift reads
/// JSON natively; a TOML parser would be the only third-party code in the tree.
///
/// ```json
/// { "swaps": [ { "from": "CapsLock",    "to": "Escape" },
///              { "from": "LeftCommand", "to": "F20" } ],
///   "chords": [ { "when": "LeftCommand",
///                 "hold": ["Command", "Control", "Option", "Shift"],
///                 "hide": true } ] }
/// ```
///
/// There are deliberately no rules, layers, conditions or per-app behaviour.
/// Anything beyond flat swaps and chords is Karabiner's job.
struct Config {
    let swaps: [Swap]
    let chords: [Chord]

    static let `default` = Config(swaps: [], chords: [])

    static var path: String {
        if let override = ProcessInfo.processInfo.environment["XKEYS_CONFIG"] {
            return override
        }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("xkeys/config.json")
    }

    private struct Document: Decodable {
        struct Entry: Decodable {
            let from: String
            let to: String
            let on: String?
        }

        struct ChordEntry: Decodable {
            let when: String
            let hold: [String]
            let hide: Bool?
            let on: String?
        }

        let swaps: [Entry]
        let chords: [ChordEntry]?
        /// Only here to catch the retired singular spelling. A config that
        /// still says `"chord"` would otherwise lose its chord in silence,
        /// which is the one failure mode worse than an error message.
        let chord: ChordEntry?
    }

    /// Read and validate the config. Returns the parsed swaps plus any
    /// problems found; problems are surfaced in the menu rather than thrown,
    /// because a typo in one swap must not stop the other swaps from applying.
    static func load(path file: String = Config.path) -> (config: Config, problems: [String]) {
        guard let data = FileManager.default.contents(atPath: file) else {
            return (.default, ["no config at \(file)"])
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            return (.default, ["\(file): \(error.localizedDescription)"])
        }

        return parse(document)
    }

    /// Split from `load` so the parsing rules can be exercised without a file.
    static func parse(_ data: Data) -> (config: Config, problems: [String]) {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return (.default, ["could not parse as JSON"])
        }
        return parse(document)
    }

    private static func parse(_ document: Document) -> (config: Config, problems: [String]) {
        var swaps: [Swap] = []
        var problems: [String] = []
        var seen = Set<String>()

        for entry in document.swaps {
            guard let from = KeyNames.usage(for: entry.from) else {
                problems.append("unknown key name '\(entry.from)'")
                continue
            }
            guard let to = KeyNames.usage(for: entry.to) else {
                problems.append("unknown key name '\(entry.to)'")
                continue
            }
            let scope = DeviceScope(entry.on)
            // The same key may be swapped once per keyboard: it is only a
            // duplicate when the scope is the same too.
            guard seen.insert("\(from)|\(scope.needle ?? "*")").inserted else {
                problems.append("'\(entry.from)' is swapped more than once\(scope.suffix); keeping the first")
                continue
            }
            swaps.append(Swap(from: from, to: to, on: scope))
        }

        if document.chord != nil {
            problems.append(#""chord" is no longer read; rename it to "chords": [ … ]"#)
        }

        var chords: [Chord] = []
        var triggers = Set<String>()
        for entry in document.chords ?? [] {
            guard let chord = parseChord(entry, problems: &problems) else { continue }
            guard triggers.insert("\(chord.when)|\(chord.on.needle ?? "*")").inserted else {
                problems.append(
                    "chord: '\(KeyNames.name(for: chord.when))' triggers more than one chord"
                        + "\(chord.on.suffix); keeping the first"
                )
                continue
            }
            chords.append(chord)
        }

        return (Config(swaps: swaps, chords: chords), problems)
    }

    /// A malformed chord disables that chord and nothing else - the swaps are
    /// what keep your Escape key working, and must not fail with it.
    private static func parseChord(
        _ entry: Document.ChordEntry,
        problems: inout [String]
    ) -> Chord? {
        guard let when = KeyNames.usage(for: entry.when) else {
            problems.append("chord: unknown key name '\(entry.when)'")
            return nil
        }
        guard !entry.hold.isEmpty else {
            problems.append("chord: '\(entry.when)' holds nothing; it would add no modifiers")
            return nil
        }

        var flags: CGEventFlags = []
        for name in entry.hold {
            guard let flag = ModifierNames.flag(for: name) else {
                problems.append("chord: unknown modifier '\(name)'")
                continue
            }
            flags.insert(flag)
        }
        guard !flags.isEmpty else { return nil }

        return Chord(when: when, hold: flags, hide: entry.hide ?? true, on: DeviceScope(entry.on))
    }
}
