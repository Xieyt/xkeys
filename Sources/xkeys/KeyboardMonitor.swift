import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// The swaps to apply when replaying a seized keyboard, as source usage ->
/// destination usage. A seized device is read below the layer that performs
/// the driver swap, so the swap has to be redone here or external keyboards
/// would behave differently from the built-in one.
///
/// Global because the IOKit callback is a C function pointer that cannot
/// capture context. It runs on the main run loop, so no locking is needed.
nonisolated(unsafe) var activeSwaps: [UInt32: UInt32] = [:]

/// Held modifiers, per seized keyboard.
///
/// Per device, not global: two external keyboards each track their own
/// Shift. A single shared value let a modifier held on one keyboard colour
/// keys typed on another, and let unplugging either keyboard clear a
/// modifier the other one was still holding.
nonisolated(unsafe) private var modifierFlagsByDevice: [UnsafeMutableRawPointer: UInt64] = [:]

private func deviceKey(_ device: IOHIDDevice) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(device).toOpaque()
}

/// Connected keyboard info for menu display.
struct KeyboardInfo {
    let name: String
    let status: String // "Built-in", "Seized", "Skipped"
}

/// Watches for keyboards and makes external ones visible to the rest of the
/// system.
///
/// On macOS 26+, a CGEventTap no longer receives events from external
/// keyboards at all. Every program that watches the keyboard — including the
/// window manager — is blind to them. This module seizes external keyboards
/// directly and replays their keystrokes as ordinary events, which is the only
/// reason those programs see them. Built-in keyboards need none of this.
enum KeyboardMonitor {
    private nonisolated(unsafe) static var manager: IOHIDManager?
    /// Connected keyboards for menu display. Updated on connect/disconnect.
    nonisolated(unsafe) static var connectedDevices: [KeyboardInfo] = []
    /// Non-nil when IOHIDManagerOpen failed — almost always a missing Input
    /// Monitoring grant. Surfaced in the Keyboards menu.
    nonisolated(unsafe) static var openFailure: IOReturn?
    /// Invoked after `connectedDevices` changes so the menu can rebuild. The
    /// menu cannot refresh itself on open: AppKit does not deliver
    /// `menuWillOpen` to this app (same reason `applicationDidFinishLaunching`
    /// never arrives), so the submenu must be pushed, not pulled.
    nonisolated(unsafe) static var onDevicesChanged: (() -> Void)?
    /// Swaps to re-apply whenever a keyboard appears.
    nonisolated(unsafe) static var swaps: [Swap] = []

    static func start(swaps: [Swap]) {
        self.swaps = swaps
        activeSwaps = Dictionary(uniqueKeysWithValues: swaps.map { ($0.from, $0.to) })

        // Ask for Input Monitoring before opening the manager. Calling
        // IOHIDManagerOpen cold is denied WITHOUT prompting when the grant is
        // missing — no dialog, no error, just an empty Keyboards menu and no
        // external-keyboard support. IOHIDRequestAccess is the Input
        // Monitoring equivalent of AXIsProcessTrustedWithOptions.
        let accessBefore = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.info("KeyboardMonitor.start: IOHIDCheckAccess(ListenEvent)=\(accessBefore.rawValue) (0=granted,1=denied,2=unknown)")
        if accessBefore != kIOHIDAccessTypeGranted {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Log.info("KeyboardMonitor.start: IOHIDRequestAccess -> \(granted)")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceConnectedCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, nil)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // IOHIDManagerOpen fails with kIOReturnNotPermitted (0xE00002E2)
        // unless the app has Input Monitoring — a SEPARATE grant from
        // Accessibility. When it fails no device callbacks ever fire, so the
        // Keyboards menu silently shows nothing. Record it so the menu can say
        // so.
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        openFailure = openResult == kIOReturnSuccess ? nil : openResult
        Log.info("KeyboardMonitor.start: IOHIDManagerOpen -> \(String(format: "0x%08X", openResult))"
            + (openResult == kIOReturnSuccess ? " (success)" : " (FAILED - needs Input Monitoring)"))

        // Enumerate synchronously too: the matching callback only fires once
        // the run loop is servicing the manager.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            Log.info("KeyboardMonitor.start: IOHIDManagerCopyDevices -> \(devices.count) device(s)")
        }

        self.manager = manager
    }
}

// MARK: - Device Classification

private func isBuiltIn(_ device: IOHIDDevice) -> Bool {
    if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber,
       builtIn.boolValue
    {
        return true
    }
    if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
       transport == "SPI" || transport == "BuiltIn"
    {
        return true
    }
    return false
}

private func productName(_ device: IOHIDDevice) -> String {
    IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
}

// MARK: - Device Connect/Disconnect Callbacks

private func deviceConnectedCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    let name = productName(device)

    // A new keyboard resets the driver's swap list, so re-apply on every
    // connect regardless of which kind of keyboard it is.
    HIDMapping.apply(KeyboardMonitor.swaps)

    if isBuiltIn(device) {
        // Watch, do not seize. A seized device stops delivering to the normal
        // input pipeline, which is why only external keyboards are seized;
        // this callback only reads, and injects nothing, so it cannot double
        // input. It exists so the chord can tell when the trigger key is
        // down: the window manager deletes that keystroke before any event
        // tap sees it, and the device is the one place still holding it.
        if !chordTriggerUsages.isEmpty {
            IOHIDDeviceRegisterInputValueCallback(device, passiveInputCallback, nil)
        }
        Log.info("deviceConnected: built-in keyboard (\(name)) - driver swap only")
        KeyboardMonitor.connectedDevices.append(KeyboardInfo(name: name, status: "Built-in"))
        KeyboardMonitor.onDevicesChanged?()
        return
    }

    // External keyboard: seize for exclusive access, then replay its input.
    // Only replay devices we successfully seize — if seizure fails (e.g. a
    // duplicate HID interface for the same physical keyboard), skip it to
    // avoid doubled input.
    let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    if seizeResult == kIOReturnSuccess {
        IOHIDDeviceRegisterInputValueCallback(device, hidInputCallback, nil)
        Log.info("deviceConnected: seized external keyboard (\(name))")
        KeyboardMonitor.connectedDevices.append(KeyboardInfo(name: name, status: "Seized"))
        KeyboardMonitor.onDevicesChanged?()
    } else {
        Log.info("deviceConnected: skipping \(name) - could not seize (error \(seizeResult))")
    }
}

private func deviceRemovedCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    let name = productName(device)
    Log.info("deviceRemoved: \(name)")
    KeyboardMonitor.connectedDevices.removeAll { $0.name == name }
    KeyboardMonitor.onDevicesChanged?()
    // Only this keyboard's modifiers are gone. Clearing every device's would
    // drop a modifier still held on a keyboard that never left.
    modifierFlagsByDevice.removeValue(forKey: deviceKey(device))
}

// MARK: - HID Input Callback

private func hidInputCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ value: IOHIDValue
) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    var usage = IOHIDElementGetUsage(element)
    let pressed = IOHIDValueGetIntegerValue(value) != 0
    let key = deviceKey(IOHIDElementGetDevice(element))

    // Only handle Keyboard/Keypad page (0x07)
    guard usagePage == 0x07 else { return }
    // Skip reserved/invalid usages and the rollover sentinel
    guard usage >= 0x04, usage <= 0xE7 else { return }

    // Trigger state is read before the swap, from the key the hardware
    // actually reports, so an external keyboard drives a chord the same way
    // the built-in one does.
    if chordTriggerUsages.contains(usage) {
        if pressed {
            chordHeldTriggers.insert(usage)
        } else {
            chordHeldTriggers.remove(usage)
        }
    }

    // Seizure reads the device below the layer that performs the driver swap,
    // so apply the swap here to keep external keyboards identical to the
    // built-in one.
    if let swapped = activeSwaps[usage] {
        usage = swapped
    }

    // Modifier keys (0xE0-0xE7)
    if let flag = HIDKeyTable.modifierFlag(forUsage: usage) {
        var flags = modifierFlagsByDevice[key] ?? 0
        if pressed {
            flags |= flag.rawValue
        } else {
            flags &= ~flag.rawValue
        }
        modifierFlagsByDevice[key] = flags
        if let keyCode = HIDKeyTable.virtualKeyCode(forUsage: usage) {
            injectFlagsChanged(keyCode: keyCode, flags: flags)
        }
        return
    }

    if let keyCode = HIDKeyTable.virtualKeyCode(forUsage: usage) {
        injectKey(keyCode: keyCode, keyDown: pressed, flags: modifierFlagsByDevice[key] ?? 0)
    }
}

/// Reads an un-seized keyboard for one thing only: whether a chord trigger
/// is down. Injects nothing.
private func passiveInputCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ value: IOHIDValue
) {
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == 0x07 else { return }
    let usage = IOHIDElementGetUsage(element)
    guard chordTriggerUsages.contains(usage) else { return }
    if IOHIDValueGetIntegerValue(value) != 0 {
        chordHeldTriggers.insert(usage)
    } else {
        chordHeldTriggers.remove(usage)
    }
}

// MARK: - CGEvent Injection

private func injectKey(keyCode: UInt16, keyDown: Bool, flags: UInt64) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown) else { return }

    event.flags = CGEventFlags(rawValue: flags)
    event.setIntegerValueField(Constants.injectedEventField, value: Constants.injectedEventMarker)
    event.post(tap: .cghidEventTap)
}

private func injectFlagsChanged(keyCode: UInt16, flags: UInt64) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) else { return }
    event.type = .flagsChanged

    event.flags = CGEventFlags(rawValue: flags)
    event.setIntegerValueField(Constants.injectedEventField, value: Constants.injectedEventMarker)
    event.post(tap: .cghidEventTap)
}
