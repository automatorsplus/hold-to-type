# HoldToType

Hold a key, speak, let go, and the words are typed wherever your cursor is. Speech-to-text runs entirely on your Mac with whisper.cpp and the `large-v3-turbo` model. No audio or text leaves the machine.

## Set it up with Claude Code

Open Claude Code in the folder where you keep your projects and paste:

```
Clone https://github.com/automatorsplus/hold-to-type and set it up on my Mac by following its CLAUDE.md.
```

Claude Code installs what it needs, downloads the speech model (1.6 GB), builds the app, checks it works and then walks you through the two permissions. The app is built on your own Mac, so macOS doesn't block it as a download from an unknown developer.

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Homebrew, and `brew install whisper-cpp` (provides `libwhisper` and the Metal backend)
- A ggml Whisper model. The app looks in `~/.cache/whisper-models/ggml-large-v3-turbo.bin`, then `~/.cache/whisper/ggml-large-v3-turbo.bin`.

## Build and run by hand

```sh
./build.sh
open build/HoldToType.app
```

The first launch needs two permissions:

1. **Accessibility.** macOS shows a prompt. Turn on HoldToType under System Settings → Privacy & Security → Accessibility. The app needs it to see the hotkey and to paste or type into other apps. The menu-bar mic icon has a slash until this is granted, and it activates within about 2 seconds of being granted, with no restart.
2. **Microphone.** Allow it when asked.

A mic icon appears in the menu bar. It shows an hourglass for about 2 seconds while the model loads.

## Use

Hold **Right Option ⌥**, speak, and release. A pill at the bottom of the screen shows *Listening…* and then *Transcribing…*. The text is inserted at the cursor about a second after you let go.

- If you tap the key for less than 0.3 s, nothing happens.
- If you press another key while holding the hotkey (for example ⌥E for an accent), the recording is cancelled. Normal Option shortcuts keep working.
- Each dictation adds a leading space when the character before the cursor is a letter or punctuation, so consecutive dictations don't run together. This works in apps that expose their text through Accessibility.

From the menu-bar icon you can choose:

- **Hotkey:** Right Option, Right Command, Right Control, or fn/Globe. For fn, set System Settings → Keyboard → Press 🌐 key to → *Do Nothing*, or macOS will also open the emoji picker or its own dictation.
  - **Set Mouse Button…** uses a mouse button instead. Choose it, then press the button you want (any mouse button except left and right click). Pressing a key cancels. That button then stops doing its usual job, such as Back in a browser, while it's the hotkey. If the mouse's own software (for example Logi Options+) has remapped the button to a keystroke, macOS doesn't see it as a mouse button, so set it back to its default there first.
- **Insert Text By:**
  - *Pasting* (default) puts the text on the clipboard, sends ⌘V, and restores your previous clipboard 0.5 s later. The temporary entry is marked transient so clipboard managers ignore it.
  - *Typing* sends the text as keystrokes and never touches the clipboard. It's slower for long text.
- **Language:** English, or automatic detection.

These settings have no menu item:

```sh
defaults write local.holdtotype vocabulary "Kubernetes, PostgreSQL, whisper.cpp"   # spelling hints
defaults write local.holdtotype modelPath ~/models/ggml-small.en.bin               # other model
```

Restart the app after changing them.

## Checking the speech-to-text without permissions

```sh
build/HoldToType.app/Contents/MacOS/HoldToType --transcribe some-recording.wav
```

This runs the same pipeline the live mic uses: mixdown, resampling to 16 kHz, the silence gate, then Whisper. It prints the text and the timings.

## How it works

| Stage | Implementation |
|---|---|
| Hotkey | A `CGEventTap` at session level sees `flagsChanged`. It matches the key code and the device-specific flag bit, so Left Option doesn't trigger it. Keyboard events pass through unchanged. A mouse-button hotkey is matched on `otherMouseDown`/`otherMouseUp` by button number, and those events are swallowed. |
| Recording | A fresh `AVAudioEngine` input tap on each press, so a newly connected headset is picked up. Audio is mixed to mono and kept 150 ms past release so the last word isn't cut off. |
| Speech-to-text | `libwhisper` is linked directly. The model loads once at launch, runs a warm-up pass on Metal, and stays in memory. Audio is resampled to 16 kHz with `AVAudioConverter`. An RMS gate skips silent clips. Bracketed non-speech markers are dropped. |
| Insertion | Clipboard plus synthesized ⌘V with the clipboard restored, or `CGEventKeyboardSetUnicodeString` keystrokes. The ⌘V key code is looked up for the current keyboard layout. Accessibility (`kAXSelectedTextRange` and `kAXStringForRange`) supplies the character before the cursor for smart spacing. |

## Known limitations

- **Rebuilds and permissions.** The app is ad-hoc signed, because it's built on your Mac without an Apple developer certificate. `build.sh` pins the signature's designated requirement to the bundle ID so the Accessibility and Microphone grants should survive rebuilds. If they don't, remove HoldToType from both lists in System Settings and grant them again.
- **Secure input.** While a password field or Terminal's *Secure Keyboard Entry* is active, macOS hides keystrokes from every app, so the hotkey may not respond.
- **Formatting.** There's no LLM clean-up step. The text is what Whisper produces, with Whisper's own punctuation and capitalisation.
- **Bluetooth headsets.** Recording from a Bluetooth headset mic switches it to its lower-quality call profile while you hold the key. That's macOS behaviour.
- **Start at login.** To start HoldToType at login, add it under System Settings → General → Login Items.

## Credits

Speech-to-text by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT licence) and OpenAI's Whisper `large-v3-turbo` model.
