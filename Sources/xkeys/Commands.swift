import CoreGraphics
import Foundation

/// The terminal side of xkeys: `xkeys keys` and `xkeys watch`.
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
        let live = HIDMapping.current()
        let inUse = Set(live.map(\.to))

        print("Swaps in effect")
        if live.isEmpty {
            print("  (none)")
        } else {
            for swap in live {
                let declared = config.swaps.contains(swap) ? "" : "   (not in your config)"
                print("  \(swap.description)\(declared)")
            }
        }

        print("")
        print("Chord for other apps")
        if let chord = config.chord {
            print("  \(chord.description)")
            if chord.hide {
                print("  \(KeyNames.name(for: chord.when)) itself hidden from apps")
            }
            print("  applied after the window manager has taken its bindings")
        } else {
            print("  (none - other apps cannot see the trigger key)")
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

        // A keycode table in the direction we need here: macOS virtual keycode
        // back to the HID usage it came from.
        var keyCodeToUsage: [UInt16: UInt32] = [:]
        for (name, usage) in KeyNames.byName {
            _ = name
            if let code = HIDKeyTable.virtualKeyCode(forUsage: usage) {
                keyCodeToUsage[code] = usage
            }
        }

        let context = WatchContext(swapTargets: swapTargets, keyCodeToUsage: keyCodeToUsage)
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
}

/// State for the watch callback, which is a C function pointer and cannot
/// capture anything.
final class WatchContext {
    let swapTargets: [UInt32: UInt32]
    let keyCodeToUsage: [UInt16: UInt32]

    init(swapTargets: [UInt32: UInt32], keyCodeToUsage: [UInt16: UInt32]) {
        self.swapTargets = swapTargets
        self.keyCodeToUsage = keyCodeToUsage
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
    }
    print(line)
    fflush(stdout)

    return Unmanaged.passUnretained(event)
}
