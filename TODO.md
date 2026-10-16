# xkeys TODO

## Open

- [ ] **Chord emits no modifier-state change while the trigger is held.** *(blocked - needs one measurement)*

  The chord tap paints its flags onto each key-down and key-up, so the modifiers exist attached to every keystroke but never as a standalone "modifiers are now held" event. Apps that read flags off each keystroke work - Raycast's shortcut field is proven, 8 presses, 8 fires. Apps that track held modifiers may not.

  **Unmeasured.** The test is one press: hold the trigger about two seconds, press `U` while still holding, release, with a monitor logging modifier-change events and key-down flags. Real modifiers emit a modifier-change event when held - measured - so if the chord emits none, the asymmetry is confirmed rather than assumed. If so, post a synthetic modifier event when the trigger goes down and clear it on release. If the painted flags turn out to be enough, close this with no code.

- [ ] **First release.** The tag workflow is written for this project's paths but has never run - no `v*` tag exists. It also ad-hoc signs, so every downloaded update re-prompts for permissions. Deliberately deferred.

## Done

- [x] **Per-device modifier state.** Each seized keyboard keeps its own held modifiers; unplugging one no longer clears another's.
- [x] **Reload re-arms the chords.** The tap is torn down and rebuilt, so a trigger removed from the file stops being a trigger without a restart.
- [x] **The update check throttles on failure.** The last-check time is stamped before the result is inspected, so a repository with no releases is no longer re-asked on every launch.
- [x] **`xkeys watch` shows the chord.** Each key-down line ends with the modifiers the event carries, labelled `chord:` when they match a configured chord exactly and `mods:` otherwise - the two are indistinguishable at that point, so the label is a reading, not a proof.
- [x] **Multiple chords**, as a `chords` array. The singular `chord` key is no longer read and says so rather than losing your chord in silence.
- [x] **`xkeys doctor`** - process, signature, both permissions, config, live-versus-declared swaps, chords, each failure naming its cost and fix.
- [x] **`xkeys check <file>`** - validate without applying; exit 1 with the problem list.
- [x] **Pure-logic checks**, ~90 of them, run by `just test`.

## Closed without code

- **Media keys are not killed by seizure.** Previously documented as a limitation with no measurement behind it. Two findings disagree: the keyboard interface carrying the media collection is the one seizure *fails* on and xkeys skips, so xkeys never holds it exclusively; and across 291 recorded presses from an internal keyboard and an external GK61, no media event appeared at all. Revisit only with a keyboard that actually loses its media keys.

- **`Fn` can never be a trigger.** Measured on a GK61: `Fn` is resolved inside the keyboard's firmware and never transmitted - not on the key page, not on a vendor page, not at all. No tool on the Mac can see it.

- **Keycode collisions are Apple's, not ours.** F13/PrintScreen, F14/ScrollLock and F15/Pause share one virtual keycode each. A check that forbade all collisions was wrong and was replaced by one allowing exactly those three. It did expose a real defect next door: `xkeys watch` named those keys from an unordered table, so the same key could print differently run to run. Now resolved deterministically to the key Apple ships.

## Decisions

- **2026-10-17 - Multiple chords use a `chords` array with a clean cutover.** The singular `chord` key is not kept as an alias; it reports an error naming the replacement. Two spellings for one thing is the shim pattern the rewrite removed.

- **2026-10-17 - Checks are a compiled program, not a test target.** Originally agreed as swift-testing. Reversed on a new fact: this machine has Command Line Tools and no Xcode, which ships neither `XCTest` nor `Testing`, so `swift test` cannot run here with either framework. `Checks/main.swift` compiles together with the sources it covers and runs with nothing installed. Converting it to a real target is mechanical if Xcode ever appears.

- **2026-10-17 - Checks cover pure logic only.** Driver state, device seizure and event taps are not observable from a separate process.

- **2026-10-17 - Media-key re-injection is not built.** Named fact: the interface carrying the media collection fails to seize and is skipped, so xkeys cannot be suppressing it; and 291 recorded presses produced no media event.

- **2026-10-17 - Input Monitoring is reported from the app's own result, not from TCC.** Named fact: on this macOS the keyboard manager opens and seizes successfully while no `kTCCServiceListenEvent` row exists in either the system or the user database. A missing row therefore proves nothing, and `xkeys doctor` reads the app's recorded launch result instead.

- **2026-10-17 - The first release is deferred**, so the unverified tag workflow stays unverified for now.
