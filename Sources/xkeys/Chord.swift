import CoreGraphics
import Foundation

/// Trigger state, shared between the keyboard watch that sets it and the
/// event tap that reads it. Both run on the main run loop, so no locking is
/// needed. Global because the tap callback is a C function pointer that
/// cannot capture context.
nonisolated(unsafe) var chordTriggerUsage: UInt32?
nonisolated(unsafe) var chordTriggerHeld = false

/// Flags painted onto every other key while the trigger is held.
nonisolated(unsafe) private var chordFlags: CGEventFlags = []
/// Virtual keycode of the trigger as it appears in the event stream, when the
/// chord is configured to hide it. Nil when `hide` is off.
nonisolated(unsafe) private var chordHiddenKeyCode: UInt16?

/// Paints real modifier flags onto keystrokes while the trigger key is held,
/// so apps that are not the window manager can bind the trigger at all.
///
/// Why this exists: an app's shortcut recorder stores a set of modifier flags
/// plus one key. A trigger like F20 is an ordinary key, not a modifier, so
/// there is no way to express "F20 held plus U" to Raycast, Alfred, or the
/// system shortcut list. Painting the four modifiers on is the only form such
/// an app can recognise.
///
/// Why the tap sits at the session stage: the window manager listens one
/// stage earlier and removes the keystrokes it binds. Anything it took is
/// already gone by the time this runs, so its bindings keep matching bare
/// keys and nothing fires twice.
///
/// Why the trigger state is NOT read from the event stream: the window
/// manager deletes the trigger's own press, so it never reaches this stage.
/// `KeyboardMonitor` reads it off the keyboard device instead, which is below
/// every event tap. That watch reports the key as the hardware sends it —
/// `LeftCommand`, not the `F20` it is swapped to — which is why the config
/// names the key your finger presses.
enum ChordTap {
    nonisolated(unsafe) static var active: Chord?
    /// True when tap creation failed, which in practice means the
    /// Accessibility grant is missing. Surfaced in the menu.
    nonisolated(unsafe) static var tapFailed = false
    private nonisolated(unsafe) static var tap: CFMachPort?

    static func start(_ chord: Chord, swaps: [Swap]) {
        active = chord
        chordTriggerUsage = chord.when
        chordTriggerHeld = false
        chordFlags = chord.hold

        // The trigger reaches the event stream as whatever the driver swapped
        // it to, so hiding it means hiding that key, not the one pressed.
        let arrivesAs = swaps.first { $0.from == chord.when }?.to ?? chord.when
        chordHiddenKeyCode = chord.hide ? HIDKeyTable.virtualKeyCode(forUsage: arrivesAs) : nil

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
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapFailed = false
        Log.info("ChordTap.start: \(chord.description)")
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

    // The trigger itself must never reach an app: a bare tap of it would
    // otherwise type a key nobody asked for. Usually the window manager has
    // already removed it before this point, in which case this never fires.
    if let hidden = chordHiddenKeyCode, keyCode == hidden {
        return nil
    }

    guard chordTriggerHeld else { return Unmanaged.passUnretained(event) }

    event.flags = event.flags.union(chordFlags)
    return Unmanaged.passUnretained(event)
}
