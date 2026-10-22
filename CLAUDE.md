# Setting up HoldToType

You are setting up HoldToType, a hold-to-talk dictation app for macOS, on the user's Mac. Work through the steps in
order. Tell the user in one line what each step is doing. Don't change the source code unless the build fails, and then
change as little as possible and say what you changed.

## 1. Check the Mac

- `uname -m` must print `arm64` (Apple Silicon) and `sw_vers -productVersion` must be 13 or higher. If not, stop and tell
  the user the app needs an Apple Silicon Mac on macOS 13 or later.
- `xcode-select -p` must print a path. If it fails, run `xcode-select --install`, ask the user to click **Install** in
  the dialog, and wait until they say it has finished.
- `brew --version` must work. If Homebrew is missing, ask the user to paste this into Terminal themselves (it asks for
  their Mac password, which you can't type for them), then carry on once it finishes:
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

## 2. Install whisper.cpp

```sh
brew install whisper-cpp
```

## 3. Download the speech model

Skip this if `~/.cache/whisper-models/ggml-large-v3-turbo.bin` or `~/.cache/whisper/ggml-large-v3-turbo.bin` already
exists and is about 1.6 GB. Otherwise tell the user it is a 1.6 GB download, then:

```sh
mkdir -p ~/.cache/whisper-models
curl -L --fail -o ~/.cache/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

Check the file is about 1.6 GB (`ls -lh`). A file of a few KB means the download failed.

## 4. Build

```sh
./build.sh
```

It prints `Built …/build/HoldToType.app`.

## 5. Check the speech-to-text works

This needs no permissions:

```sh
say -o /tmp/holdtotype-test.wav --file-format=WAVE --data-format=LEI16@16000 "Hold to type is working"
build/HoldToType.app/Contents/MacOS/HoldToType --transcribe /tmp/holdtotype-test.wav
```

It should print *Hold to type is working* (punctuation can differ). If it prints nothing or an error, fix that before
going on.

## 6. Install and open

Ask the user whether to copy the app into Applications. If yes:

```sh
cp -R build/HoldToType.app /Applications/
open /Applications/HoldToType.app
```

Otherwise `open build/HoldToType.app`.

## 7. Permissions, then hand over

Walk the user through these, one at a time:

1. **Accessibility:** System Settings → Privacy & Security → Accessibility, turn on HoldToType. The menu-bar mic icon
   loses its slash within about 2 seconds.
2. **Microphone:** allow it when macOS asks, on the first dictation.

Then tell them how to use it: click into any text box, hold **Right Option ⌥**, speak, let go. The hotkey, how text is
inserted and the language are in the menu-bar icon. The README has the rest, including start at login.
