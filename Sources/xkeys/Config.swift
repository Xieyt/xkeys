import CoreGraphics
import Foundation

/// A single one-to-one key swap, as written in the config file.
struct Swap: Equatable {
    let from: UInt32 // HID usage
    let to: UInt32 // HID usage

    var description: String { "\(KeyNames.name(for: from)) -> \(KeyNames.name(for: to))" }
}

/// A trigger key plus the modifiers to paint onto other keys while it is
/// held. `when` names the key your finger presses — the hardware reports the
/// physical key, not what the driver swapped it to.
struct Chord: Equatable {
    let when: UInt32 // HID usage of the physical trigger key
    let hold: CGEventFlags
    let holdNames: [String]
    /// Swallow the trigger's own keystroke so no app receives it. Normally a
    /// no-op, because the window manager already removes it one stage
    /// earlier; it matters the day the window manager stops doing that.
    let hide: Bool

    var description: String {
        "\(KeyNames.name(for: when)) held -> \(holdNames.joined(separator: "+")) on the next key"
    }
}

/// Modifier names accepted in `chord.hold`.
enum ModifierNames {
    static let byName: [String: CGEventFlags] = [
        "command": .maskCommand,
        "control": .maskControl,
        "option": .maskAlternate,
        "shift": .maskShift,
        "function": .maskSecondaryFn,
    ]

    static func flag(for name: String) -> CGEventFlags? { byName[name.lowercased()] }
}

/// The config file: a flat list of one-to-one key swaps, plus an optional
/// chord.
///
/// JSON rather than TOML because this app has no dependencies and Swift reads
/// JSON natively; a TOML parser would be the only third-party code in the tree.
///
/// ```json
/// { "swaps": [ { "from": "CapsLock",    "to": "Escape" },
///              { "from": "LeftCommand", "to": "F20" } ],
///   "chord": { "when": "LeftCommand",
///              "hold": ["Command", "Control", "Option", "Shift"],
///              "hide": true } }
/// ```
///
/// There are deliberately no rules, layers, conditions or per-app behaviour.
/// Anything beyond a flat swap and one chord is Karabiner's job.
struct Config {
    let swaps: [Swap]
    let chord: Chord?

    static let `default` = Config(swaps: [], chord: nil)

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
        }

        struct ChordEntry: Decodable {
            let when: String
            let hold: [String]
            let hide: Bool?
        }

        let swaps: [Entry]
        let chord: ChordEntry?
    }

    /// Read and validate the config. Returns the parsed swaps plus any
    /// problems found; problems are surfaced in the menu rather than thrown,
    /// because a typo in one swap must not stop the other swaps from applying.
    static func load() -> (config: Config, problems: [String]) {
        let file = path
        guard let data = FileManager.default.contents(atPath: file) else {
            return (.default, ["no config at \(file)"])
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            return (.default, ["\(file): \(error.localizedDescription)"])
        }

        var swaps: [Swap] = []
        var problems: [String] = []
        var seen = Set<UInt32>()

        for entry in document.swaps {
            guard let from = KeyNames.usage(for: entry.from) else {
                problems.append("unknown key name '\(entry.from)'")
                continue
            }
            guard let to = KeyNames.usage(for: entry.to) else {
                problems.append("unknown key name '\(entry.to)'")
                continue
            }
            guard seen.insert(from).inserted else {
                problems.append("'\(entry.from)' is swapped more than once; keeping the first")
                continue
            }
            swaps.append(Swap(from: from, to: to))
        }

        return (Config(swaps: swaps, chord: parseChord(document.chord, problems: &problems)), problems)
    }

    /// A malformed chord disables the chord and nothing else — the swaps are
    /// what keep your Escape key working, and must not fail with it.
    private static func parseChord(
        _ entry: Document.ChordEntry?,
        problems: inout [String]
    ) -> Chord? {
        guard let entry else { return nil }
        guard let when = KeyNames.usage(for: entry.when) else {
            problems.append("chord: unknown key name '\(entry.when)'")
            return nil
        }
        guard !entry.hold.isEmpty else {
            problems.append("chord: 'hold' is empty; nothing would be added to a key")
            return nil
        }

        var flags: CGEventFlags = []
        var names: [String] = []
        for name in entry.hold {
            guard let flag = ModifierNames.flag(for: name) else {
                problems.append("chord: unknown modifier '\(name)'")
                continue
            }
            flags.insert(flag)
            names.append(name)
        }
        guard !flags.isEmpty else { return nil }

        return Chord(when: when, hold: flags, holdNames: names, hide: entry.hide ?? true)
    }
}
