# QmouseFix

A lightweight, single-process menu-bar mouse utility for macOS 15+ (Sequoia and later).
It gives a plain USB/Bluetooth mouse the things macOS leaves out: smooth scrolling, button
remapping, and a drag-to-switch-Spaces gesture — without a background helper, a license server,
or any system configuration changes.

## Features

### Scroll
- **Three styles** — *Standard* (instant wheel, no animation), *Smooth* (trackpad-style eased
  momentum), and *Smooth-step* (Windows-browser feel: each notch eases a fixed number of lines
  with no coast).
- **Adjustable speed** and **lines-per-notch** (Smooth-step).
- **Reverse direction** independent of the system setting.
- **Smooth high-res mice** — opt-in smoothing for high-resolution mice that have no hardware
  flywheel (e.g. Keychron M6) and otherwise scroll choppily. Leave it off for free-spin mice
  like the MX Master 3, whose flywheel is already smooth.
- Trackpad gestures are never touched — only a physical mouse wheel is affected.

### Buttons
- Remap any mouse button to a **preset action** (Move Left/Right a Space, Mission Control,
  App Exposé, Launchpad, media keys) or **record a custom keyboard shortcut** (e.g. ⌘[ / ⌘]
  for browser back/forward, ⌘W, ⌘⇧4).

### Gestures
- **Drag to switch Spaces** — hold a chosen button and drag left/right; one Space jump per
  configurable drag distance.

### Reliability
- Recovers automatically from **sleep/wake** and **display changes** (plugging/unplugging a
  monitor or changing resolution) — scroll and gestures never silently die.
- Correctly handles **high-resolution / free-spin mice** (honors speed and reverse without
  fighting the hardware flywheel).
- Runs as one Swift process with negligible idle CPU and a small, stable memory footprint.

## Requirements

- macOS 15.0 (Sequoia) or later.
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) so it can
  read mouse input.

## Install

### Homebrew (tap)

```sh
brew install --cask minhquang28/tap/qmousefix
```

The build is signed with a local (non-notarized) certificate, so Gatekeeper quarantines it on
first launch. Clear the flag once after install:

```sh
xattr -dr com.apple.quarantine /Applications/QmouseFix.app
```

### Build from source

Requires the Xcode (beta) Swift toolchain.

```sh
# Optional but recommended: a stable signing identity so Accessibility is granted once and
# survives every rebuild (otherwise the app re-prompts after each build).
tools/setup-signing-cert.sh

# Build the menu-bar .app into build/QmouseFix.app
./build-app.sh

# Run it
open build/QmouseFix.app
```

## Usage

Launch the app — it lives in the menu bar (no Dock icon). Open **Settings** (⌘,) for four tabs:
**General** (enable, launch-at-login, Accessibility status), **Buttons**, **Scroll**, and
**Gestures**.

## Development

```sh
# Run the test suite (config codec, button actions, scroll math)
swift test

# Package a release: build + zip + sha256 + patch the Homebrew cask (local only)
tools/package-release.sh

# Same, and publish the GitHub release + upload the zip
tools/package-release.sh --publish
```

### Project layout

| Path | Purpose |
|------|---------|
| `Sources/QmouseFix/` | App source (event tap, scroll animator, settings UI, config) |
| `Tests/QmouseFixTests/` | Unit tests |
| `Casks/qmousefix.rb` | Homebrew cask |
| `build-app.sh` | Assemble & sign the `.app` bundle |
| `tools/setup-signing-cert.sh` | Create the stable local signing certificate |
| `tools/package-release.sh` | Build, zip, hash, and (optionally) publish a release |

## License

No formal license has been added yet. Mac Mouse Fix was used only as a behavioral reference;
no source was copied from it.
