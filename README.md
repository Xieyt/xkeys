# xkeys

Three jobs, all about keys arriving where you want them:

1. **Keeps your key swaps applied** — at the HID driver level, across reboots and keyboard reconnects.
2. **Makes external keyboards visible** to programs that watch the keyboard, which macOS 26+ broke.
3. **Turns one held key into a real modifier chord**, so a launcher or a shortcut recorder can bind it.

A flat config file, no kernel extension, no virtual keyboard driver, no daemon you have to babysit.

## 1. Keeps your swaps applied

A key swap lives in the HID driver, applied with Apple's own `hidutil`. The key is changed before anything on the machine can see it — no interception, no latency, nothing to race with. The catch is that the driver forgets every swap at reboot and resets when a keyboard connects. Something has to re-ask. That is this app's main job.

Swaps are declared in `~/.config/xkeys/config.json`:

```json
{
  "swaps": [
    { "from": "CapsLock",    "to": "Escape" },
    { "from": "LeftCommand", "to": "F20" }
  ]
}
```

A flat list of one-to-one swaps. No layers, no per-app rules, no tap-versus-hold. If you need those, you need Karabiner, not this.

xkeys owns only the entries it declared. The driver's swap list is a single machine-global setting shared by every tool, so xkeys reads it, changes its own rows, and writes it back — it never replaces the list wholesale, and `xkeys --uninstall` removes only its own rows.

## 2. Makes external keyboards visible

On macOS 26+ a `CGEventTap` receives nothing at all from external keyboards. Every program that watches the keyboard — window managers, launchers, anything with a global shortcut — is blind to them.

xkeys seizes external keyboards directly over IOKit and replays their keystrokes as ordinary events, applying your swaps on the way through, so those programs work again. Built-in keyboards need none of this; the driver swap is enough.

Media keys keep working. The consumer HID page is not replayed, but on the keyboards measured so far it lives on an interface seizure fails on and xkeys skips, so it keeps delivering on its own.

## 3. Turns a held key into a modifier chord

Swapping a key to `F20` gives a window manager a modifier nothing can steal. But **no other app can use it**, and the reason is structural: a shortcut recorder stores a set of modifier flags plus one key. `F20` is an ordinary key, not a modifier flag. There is no slot for "and F20 is also held".

So xkeys manufactures the flags:

```json
{
  "swaps": [
    { "from": "LeftCommand", "to": "F20" }
  ],
  "chords": [
    {
      "when": "LeftCommand",
      "hold": ["Command", "Control", "Option", "Shift"],
      "hide": true
    }
  ]
}
```

Hold Left Command, press `U`, and the app you are in receives `Cmd+Ctrl+Opt+Shift+U` — a chord any shortcut recorder can capture. Tap Left Command on its own and nothing is typed anywhere.

Four details that matter:

- **`when` names the key your finger presses**, not what the swap turns it into. The trigger is read off the keyboard device, which reports the physical key.
- **The chord runs late**, after a window manager has taken the keystrokes it binds. So a window manager keeps first pick, and nothing fires twice.
- **Add as many chords as you like.** Each needs its own trigger; two held at once combine their modifiers.
- **No `chords` block means no event tap is created at all.** Swaps alone need no permissions and intercept nothing.

## Why swap to a key that does not exist

If you want a modifier nothing else can steal, swap a key to one no keyboard physically has. Nothing in macOS and no app binds `F20`, because no hardware can send it.

`xkeys keys` lists the safe targets:

```
Safe swap targets — no Apple keyboard has ever had these keys
  Function        F20 F21 F22 F23 F24   F13-F19 exist on full-size Apple keyboards
  Editing         Again Undo Cut Copy Paste Find
  ...
```

This is a fixed table, not a hardware query, and deliberately so: a MacBook's keyboard descriptor reports all 228 HID usages, claiming it can send F13–F20 and the Japanese language keys when it physically has none of them. The device cannot tell you what it is able to press. "Apple never shipped this key" is the only honest test.

## Commands

```
xkeys                run as a menu bar agent
xkeys keys           your live swaps, your chords, and the safe swap targets
xkeys watch          name each key as you press it, and what the system received
xkeys doctor         check everything that decides whether this is working
xkeys check <file>   validate a config without applying it
xkeys --uninstall    remove this app's swaps (leaving other tools' alone) and exit
xkeys --version
```

`xkeys doctor` is the first thing to run when something is off. It names what each failure costs you and how to fix it:

```
  process           running (pid 72273)
  signature         fern-codesign
  Accessibility     granted
  Input Monitoring  granted (keyboard manager opened)
  config            ~/.config/xkeys/config.json — 2 swaps, 1 chord
  swaps live        2 of 2 declared
  chords            LeftCommand held  ->  Cmd+Ctrl+Opt+Shift on the next key

  no problems found
```

`xkeys check` exits non-zero with the problem list, so whatever generates your config can refuse to write a broken one.

`xkeys watch` is the one that saves you looking things up:

```
watching the keyboard — press keys, ctrl-c to stop
swap: CapsLock -> Escape
swap: LeftCommand -> F20

  CapsLock      arrives as Escape      usage 0x29
  LeftCommand   arrives as F20         usage 0x6F
  a                                    usage 0x04
```

## Install

```
just setup-signing-cert   once: create a stable local signing identity
just install              build, sign, install to /Applications, launch
just status               what is running, what is signed, which swaps are live
just restart
just uninstall
```

The signing identity matters more than it looks. macOS ties the Accessibility and Input Monitoring grants to the signature, and an ad-hoc signature (`-s -`) changes every build — so every rebuild looks like a brand new app and re-prompts. `just setup-signing-cert` creates a stable self-signed identity once; after that, grants survive rebuilds. Override the name with `just signing_cert=my-identity install`.

## Permissions

| grant | needed for | without it |
|---|---|---|
| none | applying swaps | swaps still work |
| Accessibility | the chord, and `xkeys watch` | swaps unaffected; chord silently inactive |
| Input Monitoring | seeing external keyboards at all | external keyboards invisible to other apps |

Swaps are applied before either permission is checked, so a revoked grant or an unanswered dialog never costs you your Escape key.

`just open-permissions` opens both panes. `just reset-permissions` clears the grants, which you only need after changing the signing identity.

## Troubleshooting

```
just debug-on && just restart && just log    # verbose log at /tmp/xkeys.log
just status                                  # pid, signature, live swaps, chords, grants
just test                                    # pure-logic checks: config, key tables, hidutil parsing
```

| symptom | cause |
|---|---|
| No menu bar icon, process running | Launch from Finder rather than a terminal; a terminal-spawned launch has been seen to stall before the icon is created. |
| Chord stopped working mid-session | The tap re-enables itself after a system timeout; if not, `just restart`. |
| A chord fires in no app | Accessibility is missing; `xkeys doctor` says so. |
| Keys doubled on an external keyboard | Two tools are replaying the same device. |
| A swap is live that you never declared | Another tool writes the same driver list. `xkeys keys` marks those `(not in your config)`. |

## Requirements

macOS 13+. Swift 6 toolchain to build. No third-party dependencies.

## Credits

Inspired by [hyperkey](https://github.com/feedthejim/hyperkey) by Jimmy Lai, whose IOKit seizure approach to the macOS 26 external-keyboard problem is carried forward here. xkeys has since gone a different way — config-driven driver swaps instead of a hardcoded CapsLock remap, and a late-stage chord instead of an intercepted Hyper key.

MIT licensed. See [LICENSE](LICENSE).
