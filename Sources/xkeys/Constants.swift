import CoreGraphics

enum Constants {
    /// Event mask for `xkeys watch`. Listen-only; nothing here modifies input.
    static let eventMask: CGEventMask = (
        (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
    )

    static let version = "1.0.0"

    /// What the menu displays.
    static var displayVersion: String { version }

    /// Update-check repo.
    static let githubRepo = "Xieyt/xkeys"

    /// CGEvent user data field tagging events this app injected, so the
    /// external-keyboard replay cannot be mistaken for real input.
    static let injectedEventField = CGEventField(rawValue: 43)!
    /// Marker value identifying our injected events (prevents feedback loops).
    static let injectedEventMarker: Int64 = 0x584B_4559 // "XKEY"

    /// Bundle identifier and LaunchAgent label.
    static let bundleID = "com.xieyt.xkeys"
}
