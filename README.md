# Soundwich

Per-app audio routing for macOS. Send Spotify to your Bluetooth speaker while Slack, Notion, and Mail stay on your MacBook speakers.

> 🥪 _A sandwich of sound — each layer goes where it belongs._

## Status

**v0.1 (pre-alpha)** — menu bar shell + audio device discovery. Per-app routing wiring is the next milestone.

## Requirements

- macOS 14.2 or later (uses the CoreAudio Process Tap API)
- Xcode 15.2+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Install (prebuilt)

Grab the latest `Soundwich.dmg` from [Releases](../../releases) and follow
[INSTALL.md](INSTALL.md). It's an unsigned build, so macOS Gatekeeper needs a
one-time bypass (instructions included).

## Build from source

```sh
brew install xcodegen        # one time
xcodegen generate            # generates Soundwich.xcodeproj
open Soundwich.xcodeproj
```

In Xcode, select the `Soundwich` scheme and hit ⌘R. A 🥪-ish icon will appear in the menu bar.

To produce a distributable universal `.dmg`:

```sh
./scripts/build_dmg.sh       # → Soundwich.dmg (arm64 + x86_64, ad-hoc signed)
```

## Project Layout

```
Soundwich/
├── project.yml                  # XcodeGen spec — edit this, not .xcodeproj
├── Soundwich/
│   ├── SoundwichApp.swift       # @main + AppDelegate
│   ├── Info.plist               # LSUIElement, audio usage strings
│   ├── Soundwich.entitlements   # audio-input, sandbox off
│   ├── MenuBar/
│   │   ├── MenuBarController.swift
│   │   └── MenuBarRootView.swift
│   └── Audio/
│       ├── AudioDevice.swift
│       ├── AudioDeviceManager.swift   # CoreAudio device discovery ✅
│       └── ProcessTapManager.swift    # Process Tap wiring ⏳
```

## Roadmap

- [x] Menu bar shell
- [x] Output device enumeration
- [ ] Running-audio process detection
- [ ] App ↔ device mapping UI
- [ ] Process Tap + aggregate device routing
- [ ] Persistence (UserDefaults)
- [ ] Auto-pause / ducking
- [ ] App icon & branding pass

## Why not just use BackgroundMusic or SoundSource?

- [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) — great, but built on a custom HAL plugin (virtual device). Soundwich uses Apple's modern Process Tap API instead.
- [SoundSource](https://rogueamoeba.com/soundsource/) — the gold standard, but closed source and paid. Soundwich is the free, open take.

## License

[MIT](LICENSE)
