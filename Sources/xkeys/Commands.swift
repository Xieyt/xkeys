import AppKit
import CoreGraphics
import Foundation

/// The terminal side of xkeys: `keys`, `watch`, `check` and `doctor`.
enum Commands {
    // MARK: - keys

    /// List swap targets that no Apple keyboard has ever shipped.
    ///
    /// This is a fixed table, not a hardware query, and that is deliberate.
    /// A MacBook's keyboard descriptor reports all 228 HID usages — it claims
    /// it can send F13 through F20 and the Japanese language keys, none of
    /// which exist on the hardware. The device cannot tell you what it is
    /// physically able to press, so asking it would give a confidently wrong
    /// answer. "Apple never shipped this key" is the honest test.
    static func keys() {
        let (config, problems) = Config.load()
        let keyboards = HIDMapping.attachedKeyboards()

        // Scoped swaps live on their own device, so the live list is the
        // machine-wide one plus a read per keyboard any rule names.
        var live = HIDMapping.current()
        for product in keyboards where config.swaps.contains(where: { $0.on.needle != nil && $0.on.matches(product) }) {
            for swap in HIDMapping.current(product: product) where !live.contains(where: { $0.sameKeys(as: swap) }) {
                live.append(swap)
            }
        }
        let inUse = Set(live.map(\.to))

        print("Swaps in effect")
        if live.isEmpty {
            print("  (none)")
        } else {
            for swap in live {
                let declared = config.swaps.first { $0.sameKeys(as: swap) }
                let note = declared.map(\.on.suffix) ?? "   (not in your config)"
                print("  \(swap.description)\(note)")
            }
        }

        print("")
        if keyboards.isEmpty {
            print("Keyboards attached")
            print("  (none visible)")
        } else {
            print("Keyboards attached")
            for product in keyboards { print("  \(product)") }
        }

        print("")
        print("Chords for other apps")
        if config.chords.isEmpty {
            print("  (none - other apps cannot see the trigger key)")
        } else {
            for chord in config.chords {
                let hidden = chord.hide ? "   (trigger hidden)" : ""
                print("  \(chord.description)\(chord.on.suffix)\(hidden)")
            }
            print("  applied after the window manager has taken its bindings")
        }

        print("")
        print("Safe swap targets — no Apple keyboard has ever had these keys")
        var free = 0
        for group in KeyNames.safeTargets {
            let rendered = group.names.map { name -> String in
                guard let usage = KeyNames.usage(for: name) else { return name }
                if inUse.contains(usage) { return "\(name)*" }
                free += 1
                return name
            }
            let note = group.note.isEmpty ? "" : "   \(group.note)"
            print("  \(group.group.padding(toLength: 16, withPad: " ", startingAt: 0))\(rendered.joined(separator: " "))\(note)")
        }

        print("")
        print("  \(free) free, * = already a target of one of your swaps")
        print("  config: \(Config.path)")

        if !problems.isEmpty {
            print("")
            print("Config problems")
            for problem in problems { print("  \(problem)") }
        }
    }

    // MARK: - watch

    /// Print every key as it is pressed, with what the system actually
    /// received after swapping. This is the thing that tells you a key's name
    /// without going and looking it up.
    static func watch() -> Never {
        Accessibility.ensureAccessibility()

        let live = HIDMapping.current()
        var swapTargets: [UInt32: UInt32] = [:] // destination usage -> source usage
        for swap in live { swapTargets[swap.to] = swap.from }

        // macOS gives three pairs of keys the same virtual keycode — F13 and
        // PrintScreen share 105, F14 and ScrollLock 107, F15 and Pause 113.
        // Walking the name table in dictionary order therefore named those
        // keys differently from run to run. Sorting ascending and letting the
        // larger usage win settles it on the Apple name (F13-F15), which is
        // the key that physically exists on this hardware.
        var keyCodeToUsage: [UInt16: UInt32] = [:]
        for usage in KeyNames.byName.values.sorted() {
            if let code = HIDKeyTable.virtualKeyCode(forUsage: usage) {
                keyCodeToUsage[code] = usage
            }
        }

        let (config, _) = Config.load()
        let context = WatchContext(
            swapTargets: swapTargets,
            keyCodeToUsage: keyCodeToUsage,
            chordHolds: config.chords.map(\.hold)
        )
        let boxed = Unmanaged.passRetained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: Constants.eventMask,
            callback: watchCallback,
            userInfo: boxed
        ) else {
            fputs("xkeys: could not watch the keyboard. Grant Accessibility and try again.\n", stderr)
            exit(1)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("watching the keyboard — press keys, ctrl-c to stop")
        if live.isEmpty {
            print("no swaps are live")
        } else {
            for swap in live { print("swap: \(swap.description)") }
        }
        print("")

        CFRunLoopRun()
        exit(0)
    }

    // MARK: - check

    /// Validate a config without applying any of it. Exit 1 on problems, so
    /// whatever generates the file can refuse to write a config that would
    /// cost you your Escape key.
    static func check(path: String) -> Never {
        let (config, problems) = Config.load(path: path)

        if problems.isEmpty {
            print("ok — \(count(config.swaps.count, "swap")), \(count(config.chords.count, "chord"))")
            exit(0)
        }

        print("\(count(problems.count, "problem"))")
        for problem in problems { print("  \(problem)") }
        exit(1)
    }

    // MARK: - doctor

    /// Everything that decides whether this app is actually working, with
    /// each failure naming what it costs you and how to fix it.
    ///
    /// Permission state is read out of the TCC database rather than asked
    /// for directly: this runs as a short-lived command-line process, so
    /// asking the system about *this* process would report the terminal's
    /// permissions, not the menu bar app's.
    static func doctor() {
        var faults: [(String, [String])] = []
        print("xkeys doctor")
        print("")

        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: Constants.bundleID)
            .first
        row("process", running.map { "running (pid \($0.processIdentifier))" } ?? "not running")
        if running == nil {
            faults.append(("process", [
                "your swaps and chords are not being maintained",
                "fix: open /Applications/xkeys.app, or `just restart`",
            ]))
        }

        row("signature", signature() ?? "unsigned or not installed")

        let grants = tccGrants()
        switch grants["kTCCServiceAccessibility"] {
        case 2: row("Accessibility", "granted")
        case .some:
            row("Accessibility", "DENIED")
            faults.append(("Accessibility", [
                "chords cannot paint modifiers, and `xkeys watch` will not run",
                "fix: just open-permissions, then enable xkeys",
            ]))
        case nil:
            row("Accessibility", grants.isEmpty ? "unknown (cannot read TCC.db)" : "not granted")
        }

        // Not read from TCC: on this macOS the keyboard watch opens fine with
        // no ListenEvent row anywhere, so a missing row proves nothing. What
        // settles it is whether the app's own attempt to open the keyboard
        // manager succeeded, which it writes to its log at every launch.
        switch lastManagerOpenSucceeded() {
        case true?: row("Input Monitoring", "granted (keyboard manager opened)")
        case false?:
            row("Input Monitoring", "DENIED (keyboard manager refused)")
            faults.append(("Input Monitoring", [
                "external keyboards are invisible to every app on this Mac",
                "fix: just open-permissions, then enable xkeys",
            ]))
        case nil:
            row("Input Monitoring", "unknown (no launch recorded in \(Log.path))")
        }

        let (config, problems) = Config.load()
        row("config", "\(Config.path) — \(count(config.swaps.count, "swap")), \(count(config.chords.count, "chord"))")
        if !problems.isEmpty {
            faults.append(("config", problems + ["fix: xkeys check \(Config.path)"]))
        }

        let keyboards = HIDMapping.attachedKeyboards()
        if keyboards.isEmpty {
            row("keyboards", "none visible")
        } else {
            for (i, product) in keyboards.enumerated() {
                row(i == 0 ? "keyboards" : "", product)
            }
        }

        // A scoped swap is only expected on the keyboards it names, so it is
        // looked for there rather than in the machine-wide list.
        let global = HIDMapping.current()
        var perDevice: [String: [Swap]] = [:]
        for product in keyboards where config.swaps.contains(where: { $0.on.needle != nil && $0.on.matches(product) }) {
            perDevice[product] = HIDMapping.current(product: product)
        }
        let missing = config.swaps.filter { swap in
            if swap.on.needle == nil {
                return !global.contains { $0.sameKeys(as: swap) }
            }
            let targets = keyboards.filter { swap.on.matches($0) }
            if targets.isEmpty { return false } // that keyboard is unplugged
            return !targets.allSatisfy { product in
                (perDevice[product] ?? []).contains { $0.sameKeys(as: swap) }
            }
        }
        let unplugged = config.swaps.filter { swap in
            swap.on.needle != nil && !keyboards.contains { swap.on.matches($0) }
        }
        let expected = config.swaps.count - unplugged.count
        row("swaps live", "\(expected - missing.count) of \(expected) declared"
            + (unplugged.isEmpty ? "" : ", \(unplugged.count) waiting on a keyboard"))
        if !missing.isEmpty {
            faults.append(("swaps live", missing.map { "\($0.description)\($0.on.suffix) is missing" }
                + ["another tool may be writing the same driver list", "fix: just restart"]))
        }

        for swap in unplugged {
            row("", "\(swap.description)\(swap.on.suffix) — that keyboard is not attached")
        }

        if config.chords.isEmpty {
            row("chords", "none configured")
        } else {
            for (i, chord) in config.chords.enumerated() {
                row(i == 0 ? "chords" : "", chord.description + chord.on.suffix)
            }
        }

        print("")
        if faults.isEmpty {
            print("  no problems found")
        } else {
            for (what, lines) in faults {
                print("  \(what)")
                for line in lines { print("     \(line)") }
            }
        }
    }

    private static func row(_ label: String, _ value: String) {
        print("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(value)")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// What happened the last time the app tried to open the keyboard
    /// manager: true opened, false refused, nil never recorded.
    private static func lastManagerOpenSucceeded() -> Bool? {
        guard let text = try? String(contentsOfFile: Log.path, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").last(where: { $0.contains("IOHIDManagerOpen ->") })
        else { return nil }
        return line.contains("(success)")
    }

    /// The signing authority of the installed bundle, which is what the
    /// permission grants are actually attached to.
    private static func signature() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dvvv", "/Applications/xkeys.app"]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    /// Empty when the database cannot be read, which is a different answer
    /// from "nothing is granted" and is reported as such.
    private static func tccGrants() -> [String: Int] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "select service || ' ' || auth_value from access where client='\(Constants.bundleID)';",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [:] }

        var grants: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let value = Int(parts[1]) { grants[String(parts[0])] = value }
        }
        return grants
    }
}

/// State for the watch callback, which is a C function pointer and cannot
/// capture anything.
final class WatchContext {
    let swapTargets: [UInt32: UInt32]
    let keyCodeToUsage: [UInt16: UInt32]
    /// The flag sets your chords paint on. Used only to label a line as
    /// coming from a chord rather than from fingers on real modifier keys.
    let chordHolds: [CGEventFlags]

    init(swapTargets: [UInt32: UInt32], keyCodeToUsage: [UInt16: UInt32], chordHolds: [CGEventFlags]) {
        self.swapTargets = swapTargets
        self.keyCodeToUsage = keyCodeToUsage
        self.chordHolds = chordHolds
    }
}

private func watchCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<WatchContext>.fromOpaque(userInfo).takeUnretainedValue()

    // Auto-repeat would flood the terminal; one line per press is the point.
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let usage = context.keyCodeToUsage[keyCode]
    let arrived = usage.map { KeyNames.name(for: $0) } ?? String(format: "keycode 0x%02X", keyCode)

    var line: String
    if let usage, let origin = context.swapTargets[usage] {
        line = "  \(KeyNames.name(for: origin).padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "arrives as \(arrived)"
    } else {
        line = "  \(arrived.padding(toLength: 14, withPad: " ", startingAt: 0))"
    }
    if let usage {
        line += String(format: "   usage 0x%02X", usage)
    }
    if type == .flagsChanged {
        line += "   (modifier)"
    } else {
        // Everything the event carries, labelled as a chord when it matches
        // a configured chord's flags exactly. A chord and four fingers on
        // the real modifier keys are indistinguishable at this point, so the
        // label is a reading of the flags, not proof of where they came from.
        let flags = event.flags.intersection([
            .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
        ])
        if !flags.isEmpty {
            let label = context.chordHolds.contains(flags) ? "chord" : "mods"
            line += "   \(label): \(ModifierNames.describe(flags))"
        }
    }
    print(line)
    fflush(stdout)

    return Unmanaged.passUnretained(event)
}
