import CoreGraphics
import Foundation

/// Which physical keys are triggers, and which of them are down right now.
/// Written by the keyboard watch, read by the event tap. Both run on the main
/// run loop, so no locking is needed. Global because the tap callback is a C
/// function pointer that cannot capture context.
nonisolated(unsafe) var chordTriggerUsages: Set<UInt32> = []
nonisolated(unsafe) var chordHeldTriggers: Set<UInt32> = []

/// Flags contributed by each trigger, and the keycodes to swallow.
nonisolated(unsafe) private var chordFlagsByTrigger: [UInt32: CGEventFlags] = [:]
nonisolated(unsafe) private var chordHiddenKeyCodes: Set<UInt16> = []

/// Everything the held triggers add up to. Two triggers held at once union
/// their flags, which is the only sane reading of "both are held".
func chordActiveFlags() -> CGEventFlags {
    var flags: CGEventFlags = []
    for usage in chordHeldTriggers {
        if let f = chordFlagsByTrigger[usage] { flags.insert(f) }
    }
    return flags
}

/// Paints real modifier flags onto keystrokes while a trigger key is held, so
/// apps that are not the window manager can bind the trigger at all.
///
/// Why this exists: an app's shortcut recorder stores a set of modifier flags
/// plus one key. A trigger like F20 is an ordinary key, not a modifier, so
/// there is no way to express "F20 held plus U" to Raycast, Alfred, or the
/// system shortcut list. Painting the modifiers on is the only form such an
/// app can recognise.
///
/// Why the tap sits at the session stage: a window manager listening one
/// stage earlier removes the keystrokes it binds. Anything it took is already
/// gone by the time this runs, so its bindings keep matching bare keys and
/// nothing fires twice.
///
/// Why trigger state is NOT read from the event stream: that earlier listener
/// deletes the trigger's own press, so it never reaches this stage.
/// `KeyboardMonitor` reads it off the keyboard device instead, which is below
/// every event tap. That watch reports the key as the hardware sends it —
/// `LeftCommand`, not the `F20` it is swapped to — which is why the config
/// names the key your finger presses.
enum ChordTap {
    nonisolated(unsafe) static var active: [Chord] = []
    /// True when tap creation failed, which in practice means the
    /// Accessibility grant is missing. Surfaced in the menu.
    nonisolated(unsafe) static var tapFailed = false
    private nonisolated(unsafe) static var tap: CFMachPort?
    private nonisolated(unsafe) static var source: CFRunLoopSource?

    /// Arm the given chords, replacing whatever was armed before. Safe to
    /// call again after a config reload: the previous tap is torn down first,
    /// so a changed trigger does not leave a stale one behind.
    static func start(_ chords: [Chord], swaps: [Swap]) {
        stop()
        guard !chords.isEmpty else { return }

        active = chords
        chordTriggerUsages = Set(chords.map(\.when))
        chordHeldTriggers = []
        chordFlagsByTrigger = Dictionary(chords.map { ($0.when, $0.hold) }) { a, _ in a }

        // A trigger reaches the event stream as whatever the driver swapped
        // it to, so hiding it means hiding that key, not the one pressed.
        chordHiddenKeyCodes = Set(chords.compactMap { chord -> UInt16? in
            guard chord.hide else { return nil }
            let arrivesAs = swaps.first { $0.from == chord.when }?.to ?? chord.when
            return HIDKeyTable.virtualKeyCode(forUsage: arrivesAs)
        })

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: chordTapCallback,
            userInfo: nil
        ) else {
            tapFailed = true
            Log.info("ChordTap.start: tap creation FAILED - needs Accessibility")
            return
        }

        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapFailed = false
        for chord in chords { Log.info("ChordTap.start: \(chord.description)") }
    }

    /// Tear the tap down and forget every trigger. Without the teardown, a
    /// reload that drops or renames a trigger would leave the old tap running
    /// with the old flags.
    static func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        active = []
        tapFailed = false
        chordTriggerUsages = []
        chordHeldTriggers = []
        chordFlagsByTrigger = [:]
        chordHiddenKeyCodes = []
    }

    /// Re-enable after the system disables the tap for being slow. Without
    /// this the chord dies silently mid-session and only a restart brings it
    /// back.
    fileprivate static func reenable() {
        guard let tap else { return }
        Log.info("ChordTap: re-enabling tap after timeout")
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func chordTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ChordTap.reenable()
        return nil
    }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

    // A trigger must never reach an app: a bare tap of it would otherwise
    // type a key nobody asked for. Usually an earlier listener has already
    // removed it, in which case this never fires.
    if chordHiddenKeyCodes.contains(keyCode) {
        return nil
    }

    let flags = chordActiveFlags()
    guard !flags.isEmpty else { return Unmanaged.passUnretained(event) }

    event.flags = event.flags.union(flags)
    return Unmanaged.passUnretained(event)
}
