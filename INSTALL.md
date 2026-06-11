# Installing Soundwich

Soundwich is distributed as an unsigned `.dmg` (no paid Apple Developer
certificate). macOS Gatekeeper will block it on first launch — this is expected
for free, unsigned apps. Follow the steps below once; afterwards it launches
normally.

## Install

1. Open **Soundwich.dmg** and drag **Soundwich** into the **Applications** folder.
2. Eject the disk image.

## First launch (bypass Gatekeeper)

Because the app isn't notarized, macOS won't open it by double-click the first
time. Pick **one** of the two methods:

### Method A — Terminal (fastest)

Open Terminal and run:

```sh
xattr -dr com.apple.quarantine /Applications/Soundwich.app
```

Then open Soundwich normally from Applications.

### Method B — System Settings

1. Double-click Soundwich. macOS shows a warning and refuses to open it.
2. Open **System Settings → Privacy & Security**.
3. Scroll down — you'll see *"Soundwich was blocked…"* with an **Open Anyway** button. Click it.
4. Confirm. Soundwich opens.

> On macOS 15 (Sequoia) and later, right-click → Open no longer works for
> unsigned apps — use Method A or B above.

## Grant audio permission

On first use, macOS asks for **system audio recording** permission — this is how
Soundwich captures an app's audio to re-route it. Click **Allow**. You can manage
it later under **System Settings → Privacy & Security → Microphone / Audio Recording**.

## Requirements

- macOS 14.2 or later
- Apple Silicon or Intel (the build is universal)

## Why the warnings?

Soundwich is open source and not code-signed with a paid Apple Developer ID, so
macOS can't verify the publisher automatically. You can review the full source in
this repository and build it yourself if you prefer. The app needs audio-capture
permission and runs outside the App Sandbox because per-app audio routing requires
system-wide audio access — the same approach used by tools like BackgroundMusic.
