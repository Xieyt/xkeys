import AppKit
import ApplicationServices
import Foundation

/// Strong reference to the app delegate.
///
/// `NSApplication.delegate` is a WEAK reference. Holding the delegate only in a
/// local inside `main()` lets ARC deallocate it immediately after the
/// assignment in optimized (`-c release`) builds, since the local is never read
/// again — `app.run()` then runs with a nil delegate and
/// `applicationDidFinishLaunching` is never called, so the menu bar item is
/// never created. A static keeps it alive for the process lifetime.
nonisolated(unsafe) private var appDelegate: AppDelegate?

/// The swaps this process applied, so the quit path knows what is its own to
/// take back out.
nonisolated(unsafe) var ownedSwaps: [Swap] = []

@main
struct XKeysApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "keys":
            Commands.keys()
            return
        case "watch":
            Commands.watch()
        case "--uninstall":
            let (config, _) = Config.load()
            HIDMapping.remove(config.swaps)
            fputs("xkeys: swaps removed.\n", stderr)
            return
        case "--version":
            print("xkeys \(Constants.displayVersion)")
            return
        case "--help", "-h":
            usage()
            return
        case .some(let unknown) where unknown.hasPrefix("-") || !unknown.isEmpty:
            fputs("xkeys: unknown command '\(unknown)'\n\n", stderr)
            usage()
            exit(2)
        default:
            break
        }

        // 1. Bring up NSApplication BEFORE anything spins the run loop.
        //
        // AppKit posts applicationDidFinishLaunching when it receives the
        // kAEOpenApplication Apple Event that LaunchServices sends at launch.
        // Those handlers are installed when NSApplication is first created, so
        // running the run loop before that point (which
        // Accessibility.ensureAccessibility does while waiting for the grant)
        // lets the launch event be dequeued and dropped with nobody listening
        // — after which the notification never arrives, the delegate's setup
        // never runs, and the app has no menu bar item at all.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 2. Refuse to run twice: two processes fighting over one swap list
        // is exactly the bug this app exists to avoid.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Constants.bundleID)
            .filter { $0.processIdentifier != selfPID }
        if !others.isEmpty {
            fputs("xkeys: already running (pid \(others.map(\.processIdentifier))).\n", stderr)
            return
        }

        // 3. Apply the swaps FIRST, before anything that can block.
        //
        // `hidutil` needs no permission at all. Waiting for the Accessibility
        // grant before applying them means a revoked or not-yet-granted
        // permission silently costs you the swaps too — typically your
        // Escape key and your chord trigger, for as long as the dialog sits
        // unanswered.
        let (config, problems) = Config.load()
        for problem in problems { Log.info("xkeys: config: \(problem)") }
        ownedSwaps = config.swaps
        let swapsOK = config.swaps.isEmpty ? true : HIDMapping.apply(config.swaps)
        Log.info("xkeys: applied \(config.swaps.count) swap(s) from \(Config.path)")

        // 4. Accessibility is needed to replay external keyboards and to
        // watch. Nothing above this line depends on it.
        Accessibility.ensureAccessibility()

        // 5. Arm the chord before the keyboard watch: the watch registers the
        // passive trigger reader only when a chord is configured, so the
        // trigger usage has to be set first.
        if let chord = config.chord {
            ChordTap.start(chord, swaps: config.swaps)
        }

        // 6. Watch for keyboards: re-apply swaps on connect, and make external
        // keyboards visible to everything else.
        KeyboardMonitor.start(swaps: config.swaps)

        // 7. Take only our own entries back out on the way down.
        //
        // The previous version replaced the whole swap list with an empty one
        // here, which erased entries it had never created — so quitting wiped
        // swaps belonging to other tools, and killing the app left the
        // keyboard in a different state than it found it.
        signal(SIGINT) { _ in
            HIDMapping.remove(ownedSwaps)
            fputs("\nxkeys: stopped, swaps removed.\n", stderr)
            exit(0)
        }
        signal(SIGTERM) { _ in
            HIDMapping.remove(ownedSwaps)
            exit(0)
        }

        // 8. Install the delegate (NSApplication was created in step 1).
        let delegate = AppDelegate(swapsOK: swapsOK, problems: problems)
        appDelegate = delegate
        app.delegate = delegate

        // Build the menu bar item explicitly instead of relying solely on
        // applicationDidFinishLaunching: the callback is idempotent and the
        // failure mode (runs perfectly, no icon, no menu) is very hard to
        // recognise as a missing notification.
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        app.run()
    }

    private static func usage() {
        print("""
        xkeys \(Constants.displayVersion) — keeps your key swaps applied

        usage:
          xkeys              run as a menu bar agent
          xkeys keys         list swap targets no Apple keyboard has ever had
          xkeys watch        name each key as you press it
          xkeys --uninstall  remove this app's swaps and exit
          xkeys --version

        config: \(Config.path)
        """)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Guards against building the menu twice: main() calls the setup
    /// explicitly, and AppKit calls it again when the launch notification
    /// arrives.
    private var setupComplete = false
    private var statusItem: NSStatusItem!
    private var updateMenuItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    private var warningMenuItem: NSMenuItem!
    private var keyboardsMenuItem: NSMenuItem!
    private var swapsMenuItem: NSMenuItem!
    private var chordMenuItem: NSMenuItem!
    private var updateURL: String?
    private let swapsOK: Bool
    private let problems: [String]

    init(swapsOK: Bool, problems: [String]) {
        self.swapsOK = swapsOK
        self.problems = problems
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !setupComplete else {
            Log.debug("applicationDidFinishLaunching: already set up, ignoring")
            return
        }
        setupComplete = true
        Log.debug("applicationDidFinishLaunching: building menu bar item")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Without an autosaveName, macOS assigns a slot from the shared generic
        // "Item-N" pool in com.apple.controlcenter's prefs. Those carry a
        // persisted per-slot visibility flag, and a stale
        // `NSStatusItem Visible Item-N = 0` (left behind by ⌘-dragging some
        // other app's icon off the menu bar) makes our item silently invisible:
        // created, functional, but never drawn.
        statusItem.autosaveName = "xkeys"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "keyboard",
                accessibilityDescription: "xkeys"
            )
        }

        let menu = NSMenu()
        menu.delegate = self

        let statusMenuItem = NSMenuItem(title: "xkeys v\(Constants.displayVersion)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        updateMenuItem = NSMenuItem(title: "Update available", action: #selector(openUpdate(_:)), keyEquivalent: "")
        updateMenuItem.target = self
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)

        checkForUpdatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        warningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningMenuItem.isHidden = true
        menu.addItem(warningMenuItem)

        if !swapsOK {
            warningMenuItem.title = "Warning: could not apply swaps"
            warningMenuItem.isHidden = false
        } else if !problems.isEmpty {
            warningMenuItem.title = "Config: \(problems[0])"
            warningMenuItem.isHidden = false
        }

        menu.addItem(NSMenuItem.separator())

        swapsMenuItem = NSMenuItem(title: "Swaps", action: nil, keyEquivalent: "")
        swapsMenuItem.submenu = NSMenu()
        menu.addItem(swapsMenuItem)

        chordMenuItem = NSMenuItem(title: "Chord", action: nil, keyEquivalent: "")
        chordMenuItem.submenu = NSMenu()
        menu.addItem(chordMenuItem)

        keyboardsMenuItem = NSMenuItem(title: "Keyboards", action: nil, keyEquivalent: "")
        keyboardsMenuItem.submenu = NSMenu()
        menu.addItem(keyboardsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let reloadItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig(_:)),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit xkeys", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Populate now, and again whenever a keyboard connects/disconnects.
        // Relying on menuWillOpen alone left this permanently empty, because
        // AppKit does not deliver that callback to this app.
        refreshMenuState()
        KeyboardMonitor.onDevicesChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshMenuState() }
        }

        Task { await performUpdateCheck() }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Log.debug("menuWillOpen delivered")
        refreshMenuState()
    }

    /// Rebuild the dynamic parts of the menu.
    ///
    /// Called eagerly at setup and from the HID device callbacks, NOT only from
    /// `menuWillOpen`: AppKit does not reliably deliver delegate callbacks to
    /// this app, so a submenu populated only on menu-open stays permanently
    /// empty.
    func refreshMenuState() {
        if !AXIsProcessTrusted() {
            warningMenuItem.title = "Warning: Accessibility permission revoked"
            warningMenuItem.isHidden = false
        } else if swapsOK, problems.isEmpty {
            warningMenuItem.isHidden = true
        }

        if let submenu = swapsMenuItem.submenu {
            submenu.removeAllItems()
            let live = HIDMapping.current()
            if live.isEmpty {
                let item = NSMenuItem(title: "No swaps active", action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            } else {
                for swap in live {
                    let item = NSMenuItem(title: swap.description, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)
                }
            }
        }

        if let submenu = chordMenuItem.submenu {
            submenu.removeAllItems()
            var lines: [String] = []
            if let chord = ChordTap.active {
                chordMenuItem.title = "Chord  \(KeyNames.name(for: chord.when)) → \(chord.holdNames.joined(separator: "+"))"
                if ChordTap.tapFailed {
                    lines.append("Needs Accessibility permission")
                } else {
                    lines.append(chord.description)
                    if chord.hide {
                        lines.append("\(KeyNames.name(for: chord.when)) itself hidden from apps")
                    }
                    lines.append("applied after the window manager has taken its bindings")
                }
            } else {
                chordMenuItem.title = "Chord"
                lines.append("No chord configured")
            }
            for line in lines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        guard let submenu = keyboardsMenuItem.submenu else { return }
        submenu.removeAllItems()
        let devices = KeyboardMonitor.connectedDevices
        Log.debug("refreshMenuState: connectedDevices=\(devices.count) openFailure="
            + (KeyboardMonitor.openFailure.map { String(format: "0x%08X", $0) } ?? "none"))

        if devices.isEmpty {
            // An empty list is almost never "you have no keyboard" — it means
            // IOHIDManagerOpen was refused for lack of Input Monitoring, a
            // separate grant from Accessibility that macOS does not prompt an
            // LSUIElement agent for.
            let title: String
            if let failure = KeyboardMonitor.openFailure {
                title = "Needs Input Monitoring permission (\(String(format: "0x%08X", failure)))"
            } else {
                title = "No keyboards detected"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)

            if KeyboardMonitor.openFailure != nil {
                let fix = NSMenuItem(
                    title: "Open Input Monitoring settings…",
                    action: #selector(openInputMonitoringSettings(_:)),
                    keyEquivalent: ""
                )
                fix.target = self
                submenu.addItem(fix)
            }
        } else {
            for device in devices {
                let item = NSMenuItem(title: "\(device.name) (\(device.status))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }
    }

    // MARK: - Actions

    @objc private func openInputMonitoringSettings(_ sender: NSMenuItem) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-read the config and move the driver to match it.
    ///
    /// Swaps that were dropped from the file are taken back out, otherwise
    /// they would linger until reboot with nothing declaring them.
    @objc private func reloadConfig(_ sender: NSMenuItem) {
        let previous = ownedSwaps
        let (config, problems) = Config.load()

        let stillWanted = Set(config.swaps.map(\.from))
        let dropped = previous.filter { !stillWanted.contains($0.from) }
        if !dropped.isEmpty { HIDMapping.remove(dropped) }

        ownedSwaps = config.swaps
        KeyboardMonitor.swaps = config.swaps
        activeSwaps = Dictionary(uniqueKeysWithValues: config.swaps.map { ($0.from, $0.to) })
        HIDMapping.apply(config.swaps)

        for problem in problems { Log.info("xkeys: config: \(problem)") }
        warningMenuItem.isHidden = problems.isEmpty
        if let first = problems.first { warningMenuItem.title = "Config: \(first)" }

        Log.info("xkeys: reloaded \(config.swaps.count) swap(s), removed \(dropped.count)")
        refreshMenuState()
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        if let urlString = updateURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        sender.title = "Checking..."
        sender.isEnabled = false
        Task {
            await performUpdateCheck(force: true)
            sender.title = "Check for Updates"
            sender.isEnabled = true
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let plistName = "\(Constants.bundleID).plist"
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent(plistName)
        let uid = getuid()

        if sender.state == .on {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(uid)/\(plistName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: plistPath)
            sender.state = .off
        } else {
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let execPath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(Constants.bundleID)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                    <key>Crashed</key>
                    <true/>
                </dict>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>StandardOutPath</key>
                <string>/tmp/xkeys.out.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/xkeys.err.log</string>
                <key>LimitLoadToSessionType</key>
                <string>Aqua</string>
            </dict>
            </plist>
            """

            do {
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            } catch {
                fputs("xkeys: failed to write LaunchAgent plist: \(error)\n", stderr)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(uid)", plistPath.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    sender.state = .on
                } else {
                    fputs("xkeys: launchctl bootstrap failed (status \(process.terminationStatus))\n", stderr)
                }
            } catch {
                fputs("xkeys: failed to run launchctl: \(error)\n", stderr)
            }
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        HIDMapping.remove(ownedSwaps)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func performUpdateCheck(force: Bool = false) async {
        if let (version, url) = await UpdateChecker.check(force: force) {
            updateMenuItem.title = "Update available: v\(version)"
            updateMenuItem.isHidden = false
            updateURL = url
        } else if force {
            updateMenuItem.title = "Up to date"
            updateMenuItem.isHidden = false
            updateURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.updateURL == nil {
                    self?.updateMenuItem.isHidden = true
                }
            }
        }
    }

    private func isLaunchAgentInstalled() -> Bool {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Constants.bundleID).plist")
        return FileManager.default.fileExists(atPath: plistPath.path)
    }
}
