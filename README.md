<img width="438" height="509" alt="appvolumescreenshot" src="https://github.com/user-attachments/assets/0ce112c6-ebf4-46ab-8146-8f15872a7ebe" />

# AppVolume

A lightweight macOS utility for controlling the volume of individual apps.

AppVolume uses Apple's Core Audio process-tap APIs to detect apps producing audio
and apply per-app gain controls without requiring a third-party audio driver.

## Features

- Per-app volume sliders
- Automatically detects newly active audio apps
- Automatically removes apps that stop producing audio or quit
- Remembers each app's selected volume while AppVolume is running
- Restores the previous volume when an app restarts
- Native macOS app
- No kernel extension
- No third-party audio driver

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode Command Line Tools

Install the command line tools if needed:

```bash
xcode-select --install
```

## Build

Clone the repository and run:

```bash
chmod +x build.sh
./build.sh
open AppVolume.app
```

The build script compiles `AppVolume.swift`, creates the `.app` bundle, adds the
required audio-capture usage description, and ad-hoc signs the application for
local use.

## Usage

1. Launch AppVolume.
2. Start playing audio in Music, Spotify, Chrome, or another app.
3. The app should automatically appear in AppVolume.
4. Adjust its slider to control its individual volume.
5. When the app stops producing audio or quits, it is automatically removed.

A **Rescan** button is also included as a fallback.

## Permissions

macOS may request permission for AppVolume to capture system audio.

If you previously denied access, check:

**System Settings → Privacy & Security → Screen & System Audio Recording**

## Current status

AppVolume is an early experimental macOS utility. It currently targets the
default output device and common stereo output paths.

Known limitations may include:

- Output-device switching while a tap is active
- Unusual multichannel audio interfaces
- Bluetooth profile transitions
- Multiple audio processes belonging to the same app bundle
- Volume preferences are not yet persisted across AppVolume launches

## Distribution

The included build script uses ad-hoc signing for local development. Public
binary releases should be signed with an Apple Developer ID and notarized to
avoid Gatekeeper warnings.

## License

MIT
