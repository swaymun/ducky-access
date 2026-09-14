# Ducky Access

Ducky Access is a small, local-first macOS menu-bar bridge for a wired duckyPad Pro. It turns the pad into an accessibility controller with on-screen hints, local English dictation, bounded voice commands, a native app switcher, volume, and a local dictation history.

## Features

- Four-row, five-column rotated duckyPad layout with an OLED legend.
- A–O accessibility hints backed by macOS Accessibility APIs.
- Parakeet EOU 120M running locally through FluidAudio.
- Dictate and Command modes with a notch-style waveform/transcript panel.
- Codex App Server formatting through the bundled ChatGPT runtime, defaulting to Luna / Low / Fast.
- Native `⌘Tab` app switching and focused-pane scrolling.
- Menu-bar model, reasoning, speed, usage, recent-history, help, and playback controls.
- Local HTML history viewer with raw text, cleaned text, and recordings.

The black dictation preview extends below the built-in notch at its measured
width (or 200 points on a display without a notch). It stays visible while
listening and formatting, then dismisses 2.5 seconds after insertion, copying,
or command completion. Click to dismiss it sooner; this does not cancel
recording or insertion in DICT mode. During a CMD recording or command run,
clicking the notch cancels that command instead.

## Build

Requirements: macOS 14+, Xcode command-line tools, a signed-in ChatGPT desktop app, and a wired duckyPad Pro. A local Apple Development signing identity is used when available so macOS privacy permissions remain stable across rebuilds.

```sh
./scripts/build-app.sh
ditto build/DuckyAccess.app /Applications/DuckyAccess.app
open /Applications/DuckyAccess.app
```

Grant Accessibility to `DuckyAccess` in System Settings; the app requests Microphone access, installs itself as a login item, and listens directly to the matched wired DuckyPad HID interface. FluidAudio downloads the Parakeet model into its normal application-support cache. The app does not ship model weights.

For a quick local verification after the first build:

```sh
./scripts/verify-profile.sh
swift run -c release ParakeetProbe /path/to/english-recording.wav
./scripts/verify-app-server.sh
swift test
```

An opt-in command smoke test uses the signed-in Codex account and model quota,
but only a synthetic app (no desktop control or personal screen content):

```sh
DUCKY_TEST_APP_SERVER=1 swift test --filter CommandSessionTests/testLiveAppServerDynamicToolRoundTrip
```

This verifies model/tool round trips, not physical pad or real-app behavior.
Live acceptance additionally requires CMD → “In Calculator, calculate twelve
times seven” → CMD, checking 84, then cancelling a second run by clicking the
notch and checking that no subsequent action is sent.

If the menu says the pad is connected but a press does nothing, confirm that
`DuckyAccess` is enabled under System Settings → Privacy & Security → Input
Monitoring, then relaunch the app. A healthy launch logs
`matchedInterfaces=1` and `Attached ... openResult=0`; `TCC deny IOHIDDeviceOpen`
means the app must be removed and re-added after signing. Accessibility is also
needed for on-screen hint activation, and Microphone is needed for dictation.

After upgrading from an earlier unsigned build, the Accessibility switch can
remain on while macOS rejects the new app. Remove the stale `DuckyAccess` entry
with the minus button, add `/Applications/DuckyAccess.app` again with the plus
button, enable it, and relaunch. The menu checks the running app's Accessibility
and keyboard-output permissions and shows whether they are allowed. Keep using
the same signing identity for subsequent builds.

Dictation reports **Inserted** only after the destination field confirms the
text changed. It inserts into the editable field focused when formatting
finishes. If permission is missing or no editable field is focused, the result
stays on the clipboard for manual paste. Editors whose text cannot
be inspected show **Paste sent — text also copied**. Recent dictations also have
an **Insert formatted** action to retry in the focused field.

## Pad profile

Import the packaged profile with the official duckyPad Configurator, then save it to the pad. Generate it with `./scripts/package-profile.sh`; the single-profile importer expects a ZIP with a top-level directory named `profile_DuckyAccess`. Do not select the repository's `profile/DuckyAccess` source folder directly. On macOS the vendor tool must be launched through its `run.sh` with administrator authentication before Connect can access the device; Ducky Access itself does not need root. The intended physical orientation has the two knobs and OLED above four rows of five switches. `IS_LANDSCAPE 1` rotates the vendor OLED guide and native 4-column × 5-row index order so the legend reads upright in that 5-column × 4-row orientation. Keep the stock +/− profile buttons. Back up the pad first. The bridge is not a replacement for the vendor configurator; see the [vendor macOS notes](https://dekunukem.github.io/duckyPad-Pro/doc/linux_macos_notes.html).

| A | B | C | D | E |
|---|---|---|---|---|
| F | G | H | I | J |
| K | L | M | N | O |
| NAV | DICT | CMD | ENTER | ESC |

**ENTER** sends a normal Return to the focused app (which may submit a message).
It replaces BKSP in the same physical position. Press the app knob to open the
native macOS app switcher, turn to select, and press again or ENTER to activate.
ESC cancels. An unattended switcher cancels after 30 seconds; it also cancels
on disconnect or app exit. When closed, that knob scrolls as before.

### Spoken shortcuts

Use **CMD**, say one shortcut, then press **CMD** again:

- “Command T” → ⌘T
- “Control Option Command T” → ⌃⌥⌘T
- “Command Shift Tab” → ⇧⌘Tab
- “Press Enter” → Return

Literal shortcuts run locally without waiting for Luna. Command/cmd,
Control/ctrl, Option/alt, and Shift are supported, along with letters, digits,
F1–F12, arrows, and common named keys. They use macOS English/ANSI key positions.
“Control Command Option” alone still needs a key.
Shortcuts act on the focused app just like the keyboard, including shortcuts
that submit or delete. **DICT** remains text-only; it never executes shortcuts.

### Multi-step commands (experimental)

Other CMD requests use Luna through ChatGPT's bundled Codex App Server.
Ducky Access executes a small set of native Accessibility and keyboard/mouse
actions under its own macOS permissions, with no Computer Use helper or Wonder
installation required. The model receives only fixed tools, not arbitrary code.
The loop is inspect, act, then inspect again. “Run command…” in the
menu or Help uses this same path without recording audio.

The controller reads the requested app's focused window, uses fresh element
indices for each action, and refuses input after focus/window changes. Optional
window-only screenshots require **Ducky Access's own Screen Recording permission**;
ChatGPT's permission does not carry over. Without it, accessibility-based actions
still work. Coordinate clicks require a fresh screenshot. Protected fields are
not readable/typable; screenshots are withheld when protected fields are found.

The notch shows the current step. **Click the notch, press ESC, or press CMD
again to stop**. Cancellation blocks further tool calls immediately, interrupts
the agent, and closes this command's App Server process. An action already dispatched may
finish; completed actions cannot be undone. Runs are limited to 40 tool calls
and three minutes. Sensitive steps request native confirmation; Cancel is the
default. In this experimental version, actions outside Calculator and TextEdit
also require confirmation on each step, and TextEdit text insertion requires
confirmation. These native checks cannot be disabled by the model. This is an
intentional safety limit while real-app coverage is expanded. A tool timeout stops the run instead of blindly retrying an action
that might already have completed.

The Codex executable is reused from `/Applications/ChatGPT.app`, not
bundled or redistributed with this MIT project. Native controls use Apple's APIs.
The bridge isolates commands from unrelated configured MCP servers and plugins;
it does not grant a general-purpose shell to the voice agent.

The profile emits reserved modifier/function-key chords. The bridge uses its
keyboard event tap when permitted and the matched DuckyPad HID interface as a
fallback. Only one path routes actions at a time, so a physical press cannot
toggle navigation or dictation twice. The visible A–O labels are not typed
into the focused app.

## Demo

The [demo video](demo/ducky-access-demo.mp4) is a clean, synthetic product walkthrough. Its narration is English-only and contains no personal data. The storyboard and renderer are in `demo/`; rerun `demo/render-demo.sh` after replacing the narration WAV if you want to make another version.

## Privacy and safety

Audio and dictation history are stored locally until deleted. Parakeet and
literal shortcut parsing run locally. DICT sends its finished transcript to
Luna for formatting. Multi-step CMD runs additionally send the relevant app's
accessibility text and requested window screenshots to the selected
Codex model. On-screen content can contain private information; only use CMD
with apps you intend the agent to inspect. Command sessions are ephemeral;
the local history keeps the spoken request and outcome, not the tool screenshots.
No shell or unrelated connectors are enabled for these command sessions.

## License

This project is MIT-licensed. It builds on the [official duckyPad Configurator](https://github.com/duckyPad/duckyPad-Configurator), [DuckyScript reference](https://github.com/dekuNukem/duckyPad-Pro/blob/master/doc/duckyscript_info.md), [FluidAudio](https://github.com/FluidInference/FluidAudio), and the [Parakeet EOU 120M model card](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml). Those projects and model weights retain their own licenses.
