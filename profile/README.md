# DuckyAccess profile

Import a ZIP containing this profile as a top-level folder named `profile_DuckyAccess` with the official duckyPad Configurator, then save it to the pad. The Configurator's single-profile importer requires the `profile_` prefix. The intended physical orientation has the two knobs and OLED above four rows of five switches. The profile uses `IS_LANDSCAPE 1`, which rotates the OLED guide and renders the native 4-column × 5-row matrix as a 5-column × 4-row legend on the OLED.

The twenty switch scripts emit `Ctrl+Alt+Shift+Gui+F1…F20`; the bridge reads the matched DuckyPad HID interface directly. Encoder scripts omit `Gui` so they cannot collide with the accessibility keys:

- Encoder 1 clockwise/counter-clockwise/press: volume up/down/mute.
- Encoder 2 clockwise/counter-clockwise/press: scroll up/down/open the native app switcher.

The physical plus/minus buttons remain vendor profile navigation buttons.
