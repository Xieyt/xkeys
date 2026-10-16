import CoreGraphics
import Foundation

// Regression checks for the parts of xkeys that are pure functions: the
// config parser, the hidutil property-list parser, and the key tables.
//
// Not a test target, and not by preference. This machine has Command Line
// Tools and no Xcode, which ships neither XCTest nor swift-testing, so
// `swift test` cannot run here at all. These are compiled together with the
// sources they check — see `just test` — so they run with nothing installed.
//
// Nothing here touches the driver, device seizure, event taps or
// permissions. None of that is observable from a separate process, and a
// check that cannot observe its subject is worse than no check.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL  \(what)   (line \(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    checks += 1
    if a != b {
        failures += 1
        print("  FAIL  \(what)\n          got      \(a)\n          expected \(b)   (line \(line))")
    }
}

func section(_ name: String) { print(name) }

func parse(_ json: String) -> (config: Config, problems: [String]) {
    Config.parse(Data(json.utf8))
}

// MARK: - swaps

section("config: swaps")

do {
    let (config, problems) = parse(#"{ "swaps": [ { "from": "CapsLock", "to": "Escape" } ] }"#)
    expect(problems.isEmpty, "a clean config reports no problems")
    expectEqual(config.swaps, [Swap(from: 0x39, to: 0x29)], "both key names resolve to HID usages")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [ { "from": "CapsLok", "to": "Escape" }, { "from": "CapsLock", "to": "Escape" } ] }
    """#)
    expectEqual(config.swaps.count, 1, "an unknown key name drops only that swap")
    expect(problems.contains { $0.contains("CapsLok") }, "the unknown name is reported")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [ { "from": "CapsLock", "to": "Escape" }, { "from": "CapsLock", "to": "F20" } ] }
    """#)
    expectEqual(config.swaps, [Swap(from: 0x39, to: 0x29)], "a key swapped twice keeps the first")
    expect(problems.contains { $0.contains("more than once") }, "the duplicate is reported")
}

do {
    let (config, problems) = parse(#"{ "swaps": [ { "from": "capslock", "to": "escape" } ] }"#)
    expect(problems.isEmpty && config.swaps.count == 1, "key names are case-insensitive")
}

// MARK: - chords

section("config: chords")

do {
    let (config, problems) = parse(#"""
    { "swaps": [], "chords": [ { "when": "LeftCommand",
                                 "hold": ["Command", "Control", "Option", "Shift"] } ] }
    """#)
    expect(problems.isEmpty, "a clean chord reports no problems")
    expectEqual(config.chords.first?.when, 0xE3, "the trigger resolves to its HID usage")
    expectEqual(
        config.chords.first?.hold,
        [.maskCommand, .maskControl, .maskAlternate, .maskShift],
        "every named modifier is held"
    )
}

do {
    let on = parse(#"{ "swaps": [], "chords": [ { "when": "F20", "hold": ["Shift"] } ] }"#)
    let off = parse(#"""
    { "swaps": [], "chords": [ { "when": "F20", "hold": ["Shift"], "hide": false } ] }
    """#)
    expectEqual(on.config.chords.first?.hide, true, "hiding the trigger is on by default")
    expectEqual(off.config.chords.first?.hide, false, "hide: false is honoured")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [ { "from": "CapsLock", "to": "Escape" } ],
      "chords": [ { "when": "NotAKey", "hold": ["Command"] } ] }
    """#)
    expectEqual(config.swaps.count, 1, "a chord typo must not cost you your Escape key")
    expect(config.chords.isEmpty, "the broken chord is dropped")
    expect(problems.contains { $0.contains("NotAKey") }, "the bad trigger is named")
}

do {
    let (config, problems) = parse(#"{ "swaps": [], "chords": [ { "when": "F20", "hold": [] } ] }"#)
    expect(config.chords.isEmpty, "a chord holding nothing is rejected")
    expect(problems.contains { $0.contains("holds nothing") }, "and says why")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [], "chords": [ { "when": "F20", "hold": ["Command", "Hyper"] } ] }
    """#)
    expectEqual(config.chords.first?.hold, .maskCommand, "an unknown modifier is dropped, the rest survives")
    expect(problems.contains { $0.contains("Hyper") }, "the unknown modifier is named")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [], "chords": [ { "when": "F20", "hold": ["Command"] },
                               { "when": "F20", "hold": ["Shift"] } ] }
    """#)
    expectEqual(config.chords.count, 1, "two chords on one trigger keep the first")
    expectEqual(config.chords.first?.hold, .maskCommand, "and it is the first one")
    expect(problems.contains { $0.contains("more than one chord") }, "the clash is reported")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [], "chords": [ { "when": "LeftCommand", "hold": ["Command"] },
                               { "when": "RightOption", "hold": ["Control", "Option"] } ] }
    """#)
    expect(problems.isEmpty, "two different triggers are fine")
    expectEqual(config.chords.count, 2, "both chords load")
}

do {
    let (config, problems) = parse(#"""
    { "swaps": [], "chord": { "when": "LeftCommand", "hold": ["Command"] } }
    """#)
    expect(config.chords.isEmpty, "the retired singular key arms nothing")
    expect(
        problems.contains { $0.contains("no longer read") },
        "and is reported rather than silently ignored"
    )
}

do {
    let (config, problems) = parse("{ not json")
    expect(config.swaps.isEmpty && !problems.isEmpty, "unparseable JSON yields nothing and says so")
}

// MARK: - hidutil property list

section("hidutil output")

do {
    let entries = HIDMapping.entries(fromPropertyList: """
    (
        {
            HIDKeyboardModifierMappingDst = 30064771113;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """)
    expectEqual(
        entries,
        [HIDMapping.Entry(src: 30_064_771_129, dst: 30_064_771_113)],
        "an old-style property list is read"
    )
}

expect(HIDMapping.entries(fromPropertyList: "(\n)").isEmpty, "an empty list is no entries, not a failure")
expect(
    HIDMapping.entries(fromPropertyList: "hidutil: no such property").isEmpty,
    "output that is not a property list yields nothing"
)

do {
    let entries = HIDMapping.entries(fromPropertyList: """
    (
        { HIDKeyboardModifierMappingSrc = 30064771129; },
        {
            HIDKeyboardModifierMappingDst = 30064771183;
            HIDKeyboardModifierMappingSrc = 30064771299;
        }
    )
    """)
    expectEqual(entries.count, 1, "an entry missing one side is skipped")
    expectEqual(entries.first?.src, 30_064_771_299, "and its sibling survives")
}

// MARK: - key tables

section("key names and codes")

expectEqual(KeyNames.hidValue(0x39), 0x7_0000_0039, "a usage packs with the keyboard page in the high bits")

for usage: UInt32 in [0x04, 0x39, 0x6F, 0xE3] {
    expectEqual(KeyNames.usageFromHIDValue(KeyNames.hidValue(usage)), usage, "packing round-trips for 0x\(String(usage, radix: 16))")
}

expect(KeyNames.usageFromHIDValue(0xC_0000_00E9) == nil, "a consumer-page value is not read as a keyboard key")

for name in ["CapsLock", "LeftCommand", "F20", "Escape", "A", "9"] {
    guard let usage = KeyNames.usage(for: name.lowercased()) else {
        expect(false, "\(name) resolves case-insensitively")
        continue
    }
    expectEqual(KeyNames.name(for: usage), name, "\(name) round-trips back to its name")
}

expect(KeyNames.usage(for: "NotAKey") == nil, "an unknown name resolves to nothing")
expect(KeyNames.name(for: 0xFE).contains("0xFE"), "an unnamed usage prints its number, not a wrong name")

for group in KeyNames.safeTargets {
    for name in group.names {
        expect(KeyNames.usage(for: name) != nil, "safe target \(name) is a real key name")
    }
}

do {
    let offered = Set(KeyNames.safeTargets.flatMap(\.names))
    for n in 13...19 {
        expect(!offered.contains("F\(n)"), "F\(n) is not offered: full-size Apple keyboards have it")
    }
}

expectEqual(HIDKeyTable.modifierFlag(forUsage: 0xE3), .maskCommand, "LeftCommand maps to the Command flag")
expectEqual(HIDKeyTable.modifierFlag(forUsage: 0xE1), .maskShift, "LeftShift maps to the Shift flag")
expect(HIDKeyTable.modifierFlag(forUsage: 0x04) == nil, "A is not a modifier")

do {
    // macOS itself aliases three pairs onto one keycode. Those are expected;
    // a fourth collision would mean a typo in the keycode table, which would
    // make replay send the wrong key.
    let known: Set<Set<UInt32>> = [[0x68, 0x46], [0x69, 0x47], [0x6A, 0x48]]
    var byCode: [UInt16: Set<UInt32>] = [:]
    for usage in KeyNames.byName.values {
        guard let code = HIDKeyTable.virtualKeyCode(forUsage: usage) else { continue }
        byCode[code, default: []].insert(usage)
    }
    let unexpected = byCode.values.filter { $0.count > 1 && !known.contains($0) }
    expect(unexpected.isEmpty, "the only keycode collisions are Apple's own F13/F14/F15 aliases")

    // What `xkeys watch` does: same rule, so a collided keycode always prints
    // the same name instead of varying with dictionary order.
    var resolved: [UInt16: UInt32] = [:]
    for usage in KeyNames.byName.values.sorted() {
        if let code = HIDKeyTable.virtualKeyCode(forUsage: usage) { resolved[code] = usage }
    }
    expectEqual(resolved[105].map { KeyNames.name(for: $0) }, "F13", "keycode 105 names the key Apple ships")
    expectEqual(resolved[113].map { KeyNames.name(for: $0) }, "F15", "keycode 113 names the key Apple ships")
}

section("modifier names")

expectEqual(ModifierNames.flag(for: "COMMAND"), .maskCommand, "modifier names are case-insensitive")
expectEqual(ModifierNames.flag(for: "option"), .maskAlternate, "option maps to the Alternate flag")
expect(ModifierNames.flag(for: "hyper") == nil, "an unknown modifier resolves to nothing")
expectEqual(
    ModifierNames.describe([.maskShift, .maskCommand, .maskControl, .maskAlternate]),
    "Cmd+Ctrl+Opt+Shift",
    "display order is fixed, not the order the config listed"
)

// MARK: -

print("")
if failures == 0 {
    print("\(checks) checks passed")
    exit(0)
}
print("\(failures) of \(checks) checks FAILED")
exit(1)
