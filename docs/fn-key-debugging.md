# Claiming the Fn (Globe) key on macOS — a debugging story

> *How Wave silences macOS's "Press 🌐 key to…" feature live on every launch,
> with no logout, no System Settings detour, no root, and no DriverKit
> extension.*

This is a writeup of the single hardest bug I shipped for Wave. It's the
story of going from "the emoji picker keeps stealing my dictation
hotkey" to a four-line fix in `FnSystemPreference.swift`. The fix looks
obvious in retrospect — most good ones do — but getting there involved
reverse-engineering an Apple XPC service, watching `log stream` like a
hawk, and bisecting an enum of distributed-notification names until the
right one fell out. Total elapsed time: about three days.

The relevant code lives at:

- `Sources/WaveCore/Hotkey/FnSystemPreference.swift` — the four-line fix.
- `Sources/WaveCore/Hotkey/FnKeyMonitor.swift` — the `CGEventTap` that
  consumes the Fn flag for our own hotkey handling.

---

## Symptom

Wave's whole interaction model is "hold Fn (the Globe key) to dictate,
release to paste cleaned text." Holding Fn is the most ergonomic chord
on a modern Apple keyboard — no thumb gymnastics, no chord that
conflicts with editor bindings, no modifier-modifier collision.

The symptom: on a stock Mac, the first time the user pressed and held
Fn, macOS's "Press 🌐 key to…" feature would fire its own action —
typically **Show Emoji & Symbols** (the default on most accounts) or
**Start Dictation** (if the user had ever turned on system dictation).
The emoji picker would slide up over whatever window the user was
typing into, stealing focus. Even though Wave was *also* receiving the
keystroke and starting to record audio, the user-visible state was
"there's an emoji picker covering my code editor."

This was unacceptable. The whole pitch of the app is "hold Fn, talk,
release, get text." If the OS pops a picker on top of the user's
editor every time, the product is dead in the water.

## Suspicion

The obvious first guess: install a `CGEventTap` and consume the Fn
`flagsChanged` events before they reach the system. macOS lets a tap
sit at the HID level (`kCGHIDEventTap`), which is upstream of the
session-level taps that peer apps install. If we sit there and return
`nil` from the callback, the event is supposed to be dropped from the
pipeline entirely.

I built that. It's `FnKeyMonitor.swift` today, more or less unchanged
from the first cut: `kCGHIDEventTap` + `.headInsertEventTap` +
`.defaultTap`, eating `flagsChanged` events whose `.maskSecondaryFn`
bit transitioned. The tap worked: Wave's hold-to-talk fired correctly,
recording started and stopped on Fn down/up, and our callback ran on
every transition.

**The emoji picker still appeared anyway.**

This is where it got weird. The CGEvent stream is supposed to be the
single source of truth for keyboard events in user space. If I'm
upstream of every peer app, and I'm returning `nil`, *nobody* should
see the Fn keystroke. But the emoji picker — which is dispatched by
some Apple process, not by my app — clearly was seeing it.

So macOS must have a second path into the Fn key, one that doesn't go
through the public CGEvent stream. The question was: which process is
dispatching the picker, and how does it know Fn was pressed?

## What I tried (and what didn't work)

### Attempt 1: a more aggressive tap

First instinct: my tap isn't aggressive enough. Maybe `.listenOnly`
vs `.defaultTap` matters, maybe `.tailAppendEventTap` is wrong, maybe
some other mask bit needs to be set. I cycled through every
combination of `CGEventTapPlacement`, `CGEventTapOptions`, and event
mask bits I could think of.

Result: no change. The tap was definitely consuming the event for the
public stream — peer apps installed at the session level couldn't see
the Fn key at all — but the emoji picker still appeared.

This ruled out "I configured the tap wrong" and forced the question:
**which process is dispatching the picker?**

### Attempt 2: `log stream` reconnaissance

Spent an afternoon running:

```bash
log stream --predicate 'eventMessage CONTAINS "Fn" OR eventMessage CONTAINS "Globe" OR eventMessage CONTAINS "AppleFnUsageType"' --info --debug
```

…while pressing the Fn key in various contexts:

1. Press Fn with Wave not running → emoji picker appears.
2. Press Fn with Wave running and the tap consuming → emoji picker
   still appears, but the log stream goes quieter (the public stream
   *is* being suppressed).
3. Flip "Press 🌐 key to" in System Settings → System Preferences pane
   → from "Show Emoji & Symbols" to "Do Nothing" → emoji picker stops
   appearing. Even with Wave not running.

The third observation was the breakthrough. There's a *setting* that
controls this. It's not just "what does the OS do when it sees Fn"; it
reads a preference and dispatches the corresponding action. If we can
write that preference to "Do Nothing" on Wave's behalf, the picker
goes away even without any tap at all.

Skimming the log stream during that third toggle revealed an avalanche
of Apple processes — WindowServer, ControlCenter, TextInputMenuAgent,
CharacterPalette, TISwitcher — all re-reading the same key:
**`AppleFnUsageType`** in the **`com.apple.HIToolbox`** preference
domain.

So: there's a preference, it lives in HIToolbox, and a bunch of system
processes care about it. The picker is dispatched from HIToolbox's
internal HID listener — which is a *separate* path from the public
CGEvent stream. That's why no tap, no matter how aggressive, could
suppress it: HIToolbox isn't listening to my tap; it's listening to
its own private pipeline, and dispatching based on what
`AppleFnUsageType` says.

### Attempt 3: just write the preference

Easy, right? `CFPreferencesSetAppValue`, sync, done.

```swift
CFPreferencesSetAppValue(
    "AppleFnUsageType" as CFString,
    NSNumber(value: 0),
    "com.apple.HIToolbox" as CFString
)
CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
```

Equivalent shell incantation, to verify:

```bash
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Both wrote the value (I could `defaults read` it back immediately).
And both did **nothing** to the live system. The picker still appeared
on the next Fn press.

Logging out and back in *did* fix it. So the value was being written
to disk correctly, but HIToolbox's in-memory cache was stale, and only
a fresh login re-read it.

This was the worst possible failure mode: a fix that works after
logout, but not in the running session. Shipping an app that requires
"please log out and back in after first launch" is a non-starter for a
hold-to-talk dictation tool.

### Attempt 4: invalidate the cache manually

I went looking for "what does System Settings do that I'm not doing?"
The Keyboard pane flips the same value, and it takes effect live.
There has to be a mechanism.

The interesting thing about `log stream` output when you flip the
setting in System Settings is the *cascade*. Within milliseconds,
every Apple process that has any interest in keyboard preferences
re-reads `AppleFnUsageType`. Something is fanning out a notification,
and they're all subscribed.

The candidates for "what fans out the notification":

- Darwin notification (`notify_post`) — unlikely, those are usually
  for low-level signals, not preference changes.
- Distributed notification (`CFNotificationCenter`'s distributed
  center) — Apple's classic way to broadcast cross-process events.
- Mach port — too low-level; would show up differently in the log.

Distributed notification was the best fit. But which notification
name? There's no public API for "tell HIToolbox to reload its
preferences."

### Attempt 5: reverse-engineering the XPC service

Found that the Keyboard pane in System Settings doesn't actually write
the preference itself — it asks an XPC service to do it on its behalf.
The service is `com.apple.hiservices-xpcservice`, living in
`/System/Library/Frameworks/HIServices.framework`. Pulled the binary
into Hopper and skimmed the symbols.

The relevant symbol was a list of allowed notification names — a
fixed array of `CFString`s that the XPC service is permitted to post
on the distributed center. Maybe ten names total, all with names like
`com.apple.*ChangedNotification` or `com.apple.*DidChange`.

Most of them looked plausible:

- `AppleSelectedInputSourcesChangedNotification`
- `AppleEnabledInputSourcesChangedNotification`
- `com.apple.HIToolbox.keyboardLayoutsDidChange`
- `com.apple.KeyboardUIModeDidChange`
- *…and several more.*

### Attempt 6: bisect the notifications

Wrote a tiny test harness that did this in a loop:

1. Set `AppleFnUsageType = 2` (emoji picker).
2. Confirm picker fires on next Fn press.
3. Set `AppleFnUsageType = 0` (do nothing) via `CFPreferencesSetAppValue`.
4. Post a candidate distributed notification.
5. Press Fn. Did the picker fire?
   - **Yes** → the notification didn't move HIToolbox's cache; try the
     next candidate.
   - **No** → we found it.

The first few I tried (`AppleSelectedInputSourcesChangedNotification`,
`AppleEnabledInputSourcesChangedNotification`,
`com.apple.HIToolbox.keyboardLayoutsDidChange`) didn't move the cache.
Picker kept appearing.

`com.apple.KeyboardUIModeDidChange` moved it.

The picker stopped appearing immediately on the very next Fn press.
No logout. No System Settings detour. The fix was live.

I verified by going the other way: after the notification posted, I
flipped the preference back to `2` and posted again. Picker reappeared
within milliseconds. The notification was load-bearing in both
directions — HIToolbox really does re-read on this signal.

## Why CFPreferences + distributed notification is the right answer

The final fix is four lines, and it's the entire body of
`FnSystemPreference.setFnUsageType`:

```swift
CFPreferencesSetAppValue("AppleFnUsageType" as CFString,
                         NSNumber(value: type.rawValue),
                         "com.apple.HIToolbox" as CFString)
CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
CFNotificationCenterPostNotification(
    CFNotificationCenterGetDistributedCenter(),
    CFNotificationName("com.apple.KeyboardUIModeDidChange" as CFString),
    nil, nil, true
)
```

Why this is the right answer, vs. the alternatives I considered:

- **vs. "just use a CGEventTap"** — doesn't work alone. HIToolbox
  dispatches the emoji/dictation overlay from its own internal HID
  listener, not from the public CGEvent stream. The tap is still
  necessary (for *our* hold-to-talk handling) but it's not sufficient
  for suppressing the picker.
- **vs. "writing the preference and waiting"** — doesn't work without
  a logout. HIToolbox caches the value in-memory at login and won't
  re-read on disk changes.
- **vs. "shelling out to `defaults write` + something"** — same
  problem. `defaults` does exactly what `CFPreferencesSetAppValue`
  does; the in-memory cache stays stale.
- **vs. "ask the user to flip the dropdown in System Settings"** —
  works, but it's a terrible first-run experience and the user can
  reset it accidentally at any time, breaking Wave silently. The
  ergonomics are unacceptable for the product.
- **vs. "seize the keyboard via `IOHIDManager` with
  `kIOHIDOptionsTypeSeizeDevice`"** — requires either root or a
  DriverKit extension. Massive overkill. Wispr Flow doesn't do it
  either (checked their bundle).
- **vs. "use a private API to flush HIToolbox's cache directly"** —
  there isn't one. The distributed notification *is* the public API,
  it's just undocumented.

The four-line fix is the smallest possible change that takes effect
live, requires no special permissions, and uses only public APIs (the
notification name is the only undocumented piece, and it's just a
string constant Apple's own pane posts millions of times a day).

## Guardrails baked into the code

The comments in `FnSystemPreference.swift` are deliberately long and
include a "DO NOT" section. The reason: every part of the fix looks
load-bearing-in-a-non-obvious-way, and any of them is easy to
"refactor away" if you don't know the history. Specifically:

- Don't drop the `CFNotificationCenterPostNotification` call thinking
  `CFPreferencesSetAppValue` is enough. It isn't.
- Don't switch the notification name to something that "looks more
  related" (e.g., `AppleSelectedInputSourcesChangedNotification`).
  Only `com.apple.KeyboardUIModeDidChange` moves HIToolbox's cache.
- Don't re-add a "please log out" prompt or a "please flip the
  dropdown" onboarding step. The recipe works live.
- Don't try to seize the keyboard via DriverKit / `IOHIDManager`. It's
  unnecessary and a massive yak-shave.

Three days of debugging compressed into four lines of code and a
comment block. If you change `FnSystemPreference.swift`, read the
comments first — they're the receipt.

## What I'd do differently

- **`log stream` earlier.** I spent the first day fiddling with tap
  configurations. Once I started `log stream`-ing the system while
  reproducing the bug, the answer surfaced in an hour.
- **Test on a "stock" account earlier.** I'd been developing on my own
  account, which had `AppleFnUsageType` set to `0` already from years
  of System Settings tweaking. Discovered the bug only when a friend
  tried Wave on a fresh account. The release pipeline now spins up a
  clean macOS VM for smoke tests so this can't slip again.
- **Build the bisection harness up-front.** Once I had a list of
  candidate notification names, the bisection took ten minutes. I
  should have built that harness on day one — instead I spent a day
  staring at Hopper trying to *prove* which notification was the right
  one before testing.

## References

- `Sources/WaveCore/Hotkey/FnSystemPreference.swift` — the fix.
- `Sources/WaveCore/Hotkey/FnKeyMonitor.swift` — the `CGEventTap` that
  consumes Fn for our own hotkey handling. Necessary but not
  sufficient; this file's header comment cross-references the
  preference story.
- `/System/Library/Frameworks/HIServices.framework` — contains
  `com.apple.hiservices-xpcservice`, the XPC service whose allowed
  notification list was the source of the candidate names.
