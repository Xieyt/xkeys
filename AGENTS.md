# Repository Guidelines

## Project Overview

**xkeys** is a dependency-free macOS menu-bar agent (`LSUIElement`, bundle `com.xieyt.xkeys`) that does three things:

1. **Applies key swaps at the HID driver level** via `/usr/bin/hidutil`, declared in `~/.config/xkeys/config.json`, and keeps them applied (the driver list does not survive reboot or a keyboard reconnect).
2. **Seizes external keyboards** over IOKit and replays their keystrokes as CGEvents, because on macOS 26+ a `CGEventTap` receives *no* events from external keyboards — every tap-based program on the machine is blind to them.
3. **Paints real modifier flags onto keystrokes while a trigger key is held** (the "chord"), so apps that are not the window manager can bind the trigger at all.

**It does not synthesize a Hyper key by intercepting a chord.** Manufacturing modifiers on the key itself puts them downstream of anything that listens earlier; the chord instead paints flags onto the *following* keys, after an earlier listener has had its pick. See Decisions.

macOS 13+. No third-party dependencies.

## Architecture & Data Flow

Everything runs in one process on the **main run loop**. That is why there is no locking anywhere — stated at `Sources/xkeys/Chord.swift:5-7` and `Sources/xkeys/KeyboardMonitor.swift:12`.

### Three input layers, from lowest to highest

| Layer | Owner | What it sees |
|---|---|---|
| **1. hidutil driver swap** | `HIDMapping.swift` | Machine-global `UserKeyMapping` list. Applied below every program; nothing can intercept before it. |
| **2. IOKit HID device** | `KeyboardMonitor.swift` | Raw device usages, **pre-swap**. Used to seize external keyboards and to passively read the chord trigger. |
| **3. CGEvent session tap** | `Chord.swift` | `cgSessionEventTap` + `tailAppendEventTap`. Downstream of any HID-stage tap, such as a tiling window manager's. |

### Why the chord tap sits at the session stage

A window manager that taps the **HID** stage sits one step earlier and **deletes the keystrokes it binds**. By the time the chord tap runs, those are already gone — so its bindings keep matching bare keys and nothing fires twice (`Chord.swift:26-30`).

A session-stage tap is always downstream of an HID-stage tap, **regardless of start order**. Creation order only decides precedence *within* one stage, which is why no restart ordering between the two apps is needed.

### Why trigger state is NOT read from the event stream

An HID-stage listener deletes the trigger's own keypress before any session tap sees it. So `chordTriggerHeld` is set from the **HID device** instead (`KeyboardMonitor.swift:196-198` external, `:233` built-in), which sits below every event tap.

The device reports the **physical** key — `LeftCommand`, usage `0xE3` — not the `F20` it is swapped to, because the driver swap sits above that layer. **Measured**, not assumed (`/tmp/chordprobe/hw.swift` → `out4.txt`). This is why `chord.when` names the key your finger presses.

### Startup order is load-bearing (`XKeysApp.swift:49-128`)

```
1. NSApplication.shared + .accessory    ← BEFORE anything spins the run loop
2. single-instance check                 ← two processes = two writers to one swap list
3. HIDMapping.apply(config.swaps)        ← BEFORE anything that can block
4. Accessibility.ensureAccessibility()   ← nothing above this line depends on it
5. ChordTap.start(chord, swaps:)         ← MUST precede step 6
6. KeyboardMonitor.start(swaps:)
7. signal handlers → HIDMapping.remove(ownedSwaps)
8. delegate install + explicit applicationDidFinishLaunching
```

Each ordering constraint encodes a real past bug — see **Gotchas** below. Do not reorder without reading the comments.

### Data flow and types

```
~/.config/xkeys/config.json
  → Config.load() -> (config: Config, problems: [String])     Config.swift:94   (lenient; never throws)
  → Config { swaps: [Swap], chord: Chord? }                   Config.swift:60
      Swap  { from: UInt32, to: UInt32 }                      HID usages
      Chord { when: UInt32, hold: CGEventFlags,
              holdNames: [String], hide: Bool }               hide defaults true
  → HIDMapping.apply([Swap]) -> Bool                          HIDMapping.swift:27
  → ChordTap.start(Chord, swaps: [Swap])                      Chord.swift:44
  → KeyboardMonitor.start(swaps: [Swap])                      flattens to activeSwaps [UInt32: UInt32]
```

### Two keyboard paths

- **Built-in** (`kIOHIDBuiltInKey`, or transport `SPI`/`BuiltIn` — `KeyboardMonitor.swift:102-115`): driver swap only. If a chord is configured, a **passive, non-seizing** input callback is registered that reads *only* whether the trigger is down and injects nothing.
- **External**: `IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)`. On success, register the input callback and replay. **On failure, skip the device entirely** — never register a callback on an unseized device, or input doubles. Keyboards commonly expose 2+ HID interfaces; the extras fail with `kIOReturnExclusiveAccess` and are correctly skipped.
- Replayed events are stamped with `CGEventField(43) = 0x584B_4559` (`"XKEY"`) so replay cannot be mistaken for real input (`Constants.swift:22-26`).
- Seizure handles **keyboard page 0x07 only**. Consumer page `0x0C` (volume, brightness, play/pause) is **not** re-injected — media keys on a seized keyboard stop working.

## Key Directories

| Path | Purpose |
|---|---|
| `Sources/xkeys/` | All 12 Swift files. The only source directory. |
| `.github/workflows/` | Tag-triggered release build. Untested — verify before relying on a `v*` tag. |
| `/tmp/chordprobe/` | Throwaway verification harness from the chord work. Not tracked; recipe preserved below. |

## Development Commands

`just` is the only supported runner; there is no Makefile.

```sh
just build          # env-stripped `swift build -c release`
just install        # stage bundle → pkill → copy to /Applications/xkeys.app → sign → open → status
just dev-install    # fast loop: swap the binary into the existing bundle (requires a prior `just install`)
just status         # pid, signing Authority, live swaps, chord config, TCC grants from TCC.db
just restart        # pkill + open
just stop
just uninstall      # `xkeys --uninstall` (removes only OUR swaps) + stop + rm bundle
just reset-permissions   # tccutil reset Accessibility + ListenEvent — only when changing signing identity
just open-permissions    # opens both Privacy panes
just debug-on / debug-off / log / log-dump
just fix-capslock   # LAST RESORT: wipes EVERY swap on the machine, including other tools'
just setup-signing-cert  # once: create the stable self-signed identity in the System keychain
```

### The nix SDK trap

**Never run a bare `swift build` in this repo inside the nix devShell.** The devShell exports `DEVELOPER_DIR`/`SDKROOT` pointing at nixpkgs' `apple-sdk_14`, which the system Swift 6.x compiler rejects (`SDK is built with Apple Swift 5.10 ... select a toolchain which matches the SDK`). Every justfile build goes through (`justfile:16`):

```sh
env -u SDKROOT -u DEVELOPER_DIR -u LIBRARY_PATH /usr/bin/swift build -c release
```

For one-off `swiftc` compiles use `env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx swiftc ...`.

### CLI surface (`XKeysApp.swift:24-46`)

```
xkeys               run as a menu bar agent
xkeys keys          live swaps + chord + safe swap targets
xkeys watch         name each key as you press it (never returns; needs Accessibility)
xkeys --uninstall   remove only this app's swaps and exit
xkeys --version     "xkeys 1.0.0"
xkeys --help | -h
```

Any other non-empty argument → error + usage, `exit 2`.

## Code Conventions & Common Patterns

### C callbacks cannot capture context

`CGEventTap` and `IOHIDManager` callbacks are **C function pointers**. Swift closures that capture — including closures that merely call a static method on an enum — will not compile as one. Two sanctioned patterns:

1. **`nonisolated(unsafe)` file-scope globals** + a top-level `private func` callback. Used by `Chord.swift` (`chordTriggerUsage`, `chordTriggerHeld`, `chordFlags`, `chordHiddenKeyCode`) and `KeyboardMonitor.swift` (`activeSwaps`, `currentModifierFlags`, `connectedDevices`, …).
2. **Box state through `userInfo`** with `Unmanaged.passRetained`. Used only by `Commands.watch` (`WatchContext`, `Commands.swift:87-100`).

Safe without locks **only** because every callback runs on the main run loop. If you ever move one off it, this invariant dies.

### Ownership of global machine state

`UserKeyMapping` is one array shared by every tool on the machine. All access is **read-modify-write, keyed by source usage**: an entry whose source matches one of our declared swaps is ours to replace; everything else is left exactly as found (`HIDMapping.swift:22-52`). **Never write the list wholesale.** hidutil returns an old-style OpenStep plist with string values, not JSON — parse via `PropertyListSerialization`, and accept both `NSNumber` and `String`.

Value packing: page `0x07` in the high 32 bits, so usage `0x39` → `0x700000039` (`KeyNames.swift:81-85`).

### Error handling: degrade, never fail closed

`Config.load()` returns `(config, problems)` and never throws. An unknown key name, a duplicate source, or a malformed chord becomes a string in `problems`, surfaced in the menu and in `xkeys keys`. **A malformed chord disables the chord alone** — the swaps that keep your Escape key working still load (`Config.swift:128-130`). Duplicate `from` keeps the first.

### Menu state is pushed, not pulled

AppKit does **not** reliably deliver delegate callbacks to this app. `menuWillOpen` alone left submenus permanently empty. Dynamic content is pushed via `KeyboardMonitor.onDevicesChanged` and an explicit `refreshMenuState()` at setup (`XKeysApp.swift:267-269`, `:440-445`).

### Logging

stderr goes nowhere for an `open`-launched `LSUIElement`. Logs are written to `/tmp/xkeys.log`. `Log.info` always writes; `Log.debug` is gated by `XKEYS_DEBUG=1` or `defaults write com.xieyt.xkeys debugLogging -bool true`, resolved **once** at startup to avoid a `UserDefaults` syscall per keystroke (`Log.swift:19-24`). Restart the app after toggling.

### Deliberate non-features

Flat one-to-one swaps and one chord. **No layers, no per-app rules, no tap-versus-hold, no conditions.** "Anything beyond a flat swap and one chord is Karabiner's job" (`Config.swift:56-58`). Zero third-party dependencies — JSON over TOML for exactly this reason.

## Important Files

| File | Purpose |
|---|---|
| `Sources/xkeys/XKeysApp.swift` | `@main`, CLI switch, 8-step startup, AppDelegate, menu bar, LaunchAgent, quit path |
| `Sources/xkeys/Chord.swift` | Session-stage tap painting modifier flags while the trigger is held |
| `Sources/xkeys/KeyboardMonitor.swift` | IOHIDManager: seize external, passively watch built-in, inject marked CGEvents |
| `Sources/xkeys/HIDMapping.swift` | hidutil `UserKeyMapping` owner; read-modify-write apply/remove |
| `Sources/xkeys/Config.swift` | `Swap` / `Chord` / `Config` types, lenient JSON loader |
| `Sources/xkeys/KeyNames.swift` | Config vocabulary (name ↔ HID usage), hidutil packing, `safeTargets` |
| `Sources/xkeys/HIDKeyTable.swift` | HID usage → macOS virtual keycode, and modifier usage → `CGEventFlags` |
| `Sources/xkeys/Commands.swift` | `xkeys keys` and `xkeys watch` |
| `Sources/xkeys/Accessibility.swift` | Permission prompt + `CFRunLoopRunInMode` poll + 20 s nag alert |
| `Sources/xkeys/Constants.swift` | Version, bundle id, injected-event marker, update repo |
| `Sources/xkeys/Log.swift` | `/tmp/xkeys.log` writer |
| `Sources/xkeys/UpdateChecker.swift` | GitHub releases check, 24 h cache |
| `justfile` | **Authoritative** build/install/diagnose tooling |
| `~/.config/xkeys/config.json` | **Not in this repo.** The user's swap + chord declarations |

### Config format

```json
{ "swaps": [ { "from": "CapsLock",    "to": "Escape" },
             { "from": "LeftCommand", "to": "F20" } ],
  "chord": { "when": "LeftCommand",
             "hold": ["Command", "Control", "Option", "Shift"],
             "hide": true } }
```

- Key names come from `KeyNames.byName` (~110 names: letters, digits, F1–F24, arrows, punctuation, all 8 modifiers L/R, HID editing keys, Lang/Intl). `xkeys keys` prints the vocabulary.
- `hold` vocabulary: `command`, `control`, `option`, `shift`, `function` (case-insensitive).
- `when` names the **physical** key, never the swapped-to key. See the Decisions log.
- Overrides: `XKEYS_CONFIG=<path>`, `XDG_CONFIG_HOME`.

### Output contracts (parsed by `just status`)

`xkeys keys` emits these headings in order — changing them breaks `just status`:

```
Swaps in effect
Chord for other apps
Safe swap targets — no Apple keyboard has ever had these keys
Config problems           (only when problems exist)
```

## Runtime/Tooling Preferences

- **Build**: SwiftPM, swift-tools 6.0, `.macOS(.v13)`, single `executableTarget` named `xkeys` at `Sources/xkeys`, `unsafeFlags(["-parse-as-library"])` for `@main`.
- **Runner**: `just` (not `make`). Always the env-stripped swift.
- **Signing**: a stable local identity named by the justfile's `signing_cert` variable, held in `/Library/Keychains/System.keychain` and created by `just setup-signing-cert`.
  - A stable identity is what lets the TCC grants survive a rebuild. Ad-hoc (`-s -`) changes identity every build → re-prompt every time, **and worse**: ad-hoc has produced grants that TCC.db showed as present while `AXIsProcessTrustedWithOptions` still failed at runtime.
- **Two TCC grants are required, and they are separate**:
  - `Accessibility` — the chord's session tap, and `xkeys watch`.
  - `ListenEvent` (Input Monitoring) — `IOHIDManagerOpen`, i.e. the Keyboards menu and all external-keyboard support. Opening the manager cold is denied **without prompting**, which is why `IOHIDRequestAccess` is called first.
- **The driver swap list has exactly one writer.** `UserKeyMapping` is machine-global. If anything else on the system writes it — a Nix `system.keyboard.*` option, another remapper — the two fight and the loser is silent. Keep xkeys the only writer. On a config-managed machine a generated `~/.config/xkeys/config.json` is overwritten on rebuild, so hand edits do not survive.

## Testing & QA

### There are no automated tests

No `Tests/` directory, no test target in `Package.swift`, zero `XCTest`/`swift-testing` references, no test recipe in `just` or `make`. CI (`.github/workflows/release.yml`) builds on tag push only and runs nothing. **Do not claim test coverage. Do not add a test target without being asked** — this app's behaviour lives in driver state, IOKit seizure, and event taps, none of which a unit test can observe.

### How this project is actually verified

1. `just status` — the fast check: pid, signing Authority, live swaps read back from hidutil, chord config, TCC grants read directly out of `TCC.db`.
2. `xkeys watch` — name keys as you press them, with what the system actually received after swapping.
3. **A signed throwaway probe bundle** — the only way to observe tap/hotkey/HID behaviour. Recipe below.

### The probe recipe (and its two traps)

**Trap 1: a bare executable never inherits the TCC grant.** Compiling a probe and running it from a shell fails with `TAP CREATE FAILED - no Accessibility grant`, even signed correctly. It must be a **bundle**, signed with the project's stable identity under the **already-granted bundle id `com.xieyt.xkeys`**, launched with `open -n`.

**Trap 2: synthetic keypresses do not fire registered hotkeys.** `CGEvent(...).post(...)` events never trigger `RegisterEventHotKey`, even when the flags are set at creation. This produced two false negatives before a control run exposed it. **Any verification of modifier behaviour requires a real human keypress inside a timed window.**

```sh
# 1. Scaffold the bundle
mkdir -p /tmp/probe/P.app/Contents/MacOS
cat > /tmp/probe/P.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>com.xieyt.xkeys</string>
<key>CFBundleName</key><string>xkeys</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF

# 2. The probe must append to a pre-existing file — FileHandle(forWritingAtPath:)
#    silently drops everything if the file does not exist.
touch /tmp/probe/out.txt

# 3. Compile with the system toolchain, dodging the nix SDK env
env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx \
  swiftc -O /tmp/probe/probe.swift -o /tmp/probe/P.app/Contents/MacOS/probe

# 4. Sign under the granted identity + bundle id
codesign -f -s xkeys-codesign --identifier com.xieyt.xkeys /tmp/probe/P.app

# 5. Launch as a bundle, with a generous timed window (NSApp.run + a timer exit)
open -n /tmp/probe/P.app

# 6. Press the real keys yourself, then read the log
cat /tmp/probe/out.txt
```

Three probe shapes proved useful:

- **Hardware watch** — passive `IOHIDManager` (GenericDesktop/Keyboard match, **no seize**) logging raw usages. Answers "what does the device actually report?". Proved the passive read sees `0xE3` (pre-swap `LeftCommand`), not `0x6F` (`F20`).
- **Observer** — `NSEvent.addGlobalMonitorForEvents(matching: [.keyDown])` logging modifier flags per key. Answers "what does an ordinary app receive after every tap?". Filter to 1–2 keycodes and timestamp each line, or normal typing drowns the signal.
- **Hotkey probe** — `RegisterEventHotKey` + a session tap stamping flags. Answers "does an app's shortcut actually fire?". Requires real keypresses.

### The verification that shipped the chord

Press-by-press, with an observer watching only keycodes `9` and `H`:

```
9                ->  bare                  plain key untouched
LeftCommand + 9  ->  Cmd+Ctrl+Opt+Shift    chord fires while trigger held
9                ->  bare                  trigger released cleanly, not stuck
LeftCommand + H  ->  (nothing, x2)         the window manager took it first
H                ->  bare                  plain key still plain
```

Plus: `xkeys keys` and `just status` output checked against the agreed mock; a config with `"when": "NotAKey"` confirmed to disable **only** the chord while the swaps still loaded; and a config with no `chord` block confirmed to create no tap.

Reproduce this shape for any future keyboard-behaviour change.

## Gotchas / Invariants

Each of these is a bug that already happened. The source comments carry the detail.

### Startup and lifecycle

- **`NSApplication.delegate` is weak.** A delegate held only in a `main()` local is freed by ARC in release builds → nil delegate → no menu bar item. Keep the file-scope static (`XKeysApp.swift:5-12`).
- **Create `NSApplication` before anything spins the run loop.** `Accessibility.ensureAccessibility()` runs the run loop; if it runs first, the launch Apple Event is dequeued with nobody listening and `applicationDidFinishLaunching` never fires (`:49-60`).
- **`applicationDidFinishLaunching` is called explicitly** and guarded by `setupComplete`. Failure mode — "runs perfectly, no icon, no menu" — is very hard to recognise.
- **`statusItem.autosaveName = "xkeys"` is required.** Without it macOS assigns a slot from the shared `Item-N` pool, and a stale `NSStatusItem Visible Item-N = 0` in Control Center's prefs makes the icon silently invisible.
- **Apply swaps before the Accessibility wait.** `hidutil` needs no permission; an unanswered dialog otherwise costs you your Escape key for as long as it sits there.
- **`ChordTap.start` must precede `KeyboardMonitor.start`.** The passive trigger reader is registered only when `chordTriggerUsage != nil`.
- **Poll with `CFRunLoopRunInMode`, never `Thread.sleep`** — sleeping the main thread makes macOS show "application not responding".
- **Launch path matters.** `open` from a terminal or an automated session has been observed to leave the app running but stuck before creating its `NSStatusItem` — no crash, no error, no icon. A genuine Finder double-click works.

### Keyboard and driver

- **Never replace `UserKeyMapping` wholesale.** The previous version did it on quit and erased swaps belonging to other tools.
- **Re-apply swaps on every keyboard connect** — a new keyboard resets the driver's swap list.
- **Seize-failure ⇒ skip the device.** Registering an input callback on an unseized device doubles every keystroke.
- **Read trigger state before applying the software swap**, from the usage the hardware reports, so external and built-in keyboards behave identically.
- **Injected events must carry the `XKEY` marker** or replay is indistinguishable from real input.
- **`IOHIDManagerOpen` cold is denied without prompting.** Call `IOHIDRequestAccess` first.
- **Media keys on seized keyboards are dead** — consumer page `0x0C` is not re-injected.

### Chord

- **Re-enable the tap on `tapDisabledByTimeout`/`ByUserInput`.** Without it the chord dies silently mid-session and only a restart brings it back.
- **`hide` targets the key the trigger *arrives as*** after the driver swap, not the key pressed.
- **Known limitation**: `reloadConfig` re-applies swaps but does **not** re-arm the chord. Changing the chord requires an app restart.

### Repo hygiene

- **`.github/workflows/release.yml` is unverified.** It stamps the version from the tag, builds universal, ad-hoc signs, and publishes a zip. No `v*` tag has been pushed since it was rewritten — check it before trusting a release.
- **Docs drift fast here.** `README.md` and this file both describe behaviour that only exists in code; re-read `Chord.swift` and `justfile` before trusting either.
- **`just fix-capslock` nukes every swap on the machine**, including other tools'. `xkeys --uninstall` is the surgical version.
- `just dev-install` requires a prior `just install`.

## Decisions (binding — do not re-litigate)

From the chord design work, 2026-10-16.

1. **The four modifiers stay.** Dropping them and binding the swapped-to key (`F20`) directly was proposed and rejected. A shortcut recorder calls `RegisterEventHotKey`, which takes a modifier bitmask plus one keycode and nothing else — no app can express "F20 held plus U". Without manufactured flags the feature is unachievable.
2. **xkeys hides the trigger, not the window manager.** "Only swallow the trigger when a binding uses it" was rejected: at the moment the trigger goes down, the second key does not exist yet, so there is nothing to test.
3. **The chord is config-driven.** Any key may be the trigger. Hardcoding Left Command is the pattern the previous rewrite removed.
4. **`chord.when` names the key your finger presses.** The hardware watch reports `LeftCommand` (`0xE3`); `"when": "F20"` would name a key xkeys never observes and would break silently if the swap were removed.
5. **Late-stage stamping is proven, not assumed** — 8 real keypresses, 8 hotkey fires. Synthetic events gave two false negatives and were discarded.
6. **The window manager is out of scope from this repo.** xkeys must assume an earlier listener may delete the trigger press entirely, which is why trigger state comes from the HID device, not the event stream.
