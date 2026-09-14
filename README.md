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

## Build

Requirements: macOS 14+, Xcode command-line tools, a signed-in ChatGPT desktop app, and a wired duckyPad Pro.

```sh
./scripts/build-app.sh
ditto build/DuckyAccess.app /Applications/DuckyAccess.app
open /Applications/DuckyAccess.app
```

Grant Accessibility and Input Monitoring to `DuckyAccess` in System Settings; the app requests Microphone access, installs itself as a login item, and starts the global key listener. FluidAudio downloads the Parakeet model into its normal application-support cache. The app does not ship model weights.

For a quick local verification after the first build:

```sh
./scripts/verify-profile.sh
swift run -c release ParakeetProbe /path/to/english-recording.wav
./scripts/verify-app-server.sh
```

## Pad profile

Import `profile/DuckyAccess` with the official duckyPad Configurator, then save it to the pad. On macOS the vendor tool must be launched through its `run.sh` with administrator authentication before Connect can access the device; Ducky Access itself does not need root. The intended physical orientation has the two knobs and OLED above four rows of five switches. `IS_LANDSCAPE 1` rotates the vendor OLED guide and native 4-column × 5-row index order so the legend reads upright in that 5-column × 4-row orientation. Keep the stock +/− profile buttons. Back up the pad first. The bridge is not a replacement for the vendor configurator; see the [vendor macOS notes](https://dekunukem.github.io/duckyPad-Pro/doc/linux_macos_notes.html).

| A | B | C | D | E |
|---|---|---|---|---|
| F | G | H | I | J |
| K | L | M | N | O |
| NAV | DICT | CMD | BKSP | ESC |

The profile emits reserved modifier/function-key chords. The bridge consumes those chords and does not type the visible letters into the focused app.

## Demo

The [demo video](demo/ducky-access-demo.mp4) is a clean, synthetic product walkthrough. Its narration is English-only and contains no personal data. The storyboard and renderer are in `demo/`; rerun `demo/render-demo.sh` after replacing the narration WAV if you want to make another version.

## Privacy and safety

Audio, raw transcripts, cleaned transcripts, and recordings remain local until deleted. Parakeet runs locally. Luna receives only the finished text required for formatting or command classification. Command classification is limited to focus app, open URL, switch tab, and scroll; it is not a shell or general computer-use agent.

## License

This project is MIT-licensed. It builds on the [official duckyPad Configurator](https://github.com/duckyPad/duckyPad-Configurator), [DuckyScript reference](https://github.com/dekuNukem/duckyPad-Pro/blob/master/doc/duckyscript_info.md), [FluidAudio](https://github.com/FluidInference/FluidAudio), and the [Parakeet EOU 120M model card](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml). Those projects and model weights retain their own licenses.
