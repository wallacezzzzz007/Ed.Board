# Development

[README](../README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [License](../LICENSE)

Ed.Board contains a native SwiftUI/AppKit App, a local Swift package and ESP-IDF firmware. Current versions: **App 0.5.0 (22)** and **firmware 0.5.0**. Run the commands below from the repository root.

## Requirements

- An Apple Silicon Mac; deployment target: macOS 14 or later.
- Xcode with macOS SDK and Swift 5.9 or later. Release builds have been made with Xcode 27.0; other toolchain versions need verification.
- Python 3 with `venv` support, and PlatformIO Core (`pio` available on PATH).
- Internet access for the pinned firmware toolchain and Python dependencies.

The firmware targets **AI Micro Board3 / ESP32-S3 N16R8**. Keep the supplied board definition, partition layout and dependency lock file. The directory name `usb-probe` is the existing production firmware entry point.

## Build in order

### 1. Firmware

```sh
pio run --project-dir firmware/usb-probe -e edboard_codex_probe
```

This builds firmware without uploading it. Do not use an erase-all or generic board upload procedure as an installation shortcut; the App updater protects the existing device identity and settings.

### 2. App resources

```sh
python3 tools/firmware/package.py
python3 tools/firmware/check_resources.py
```

The packager requires the matching firmware build, creates a project-local virtual environment under `tools/firmware/.build/`, builds the updater and generates `app/EdBoard/Resources/Firmware/`. Do not install these Python dependencies globally. Generated resources are excluded from Git and must be regenerated in a clean checkout before building the App.

### 3. Tests and App

```sh
swift test --package-path app/Packages/BoardCore
xcodebuild -project app/EdBoard.xcodeproj -scheme EdBoard \
  -configuration Release -derivedDataPath app/DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

Alternatively, open `app/EdBoard.xcodeproj` in Xcode after preparing the resources. The command above writes the App to `app/DerivedData/Build/Products/Release/Ed.Board.app`.

Offline Python checks:

```sh
python3 -B -m unittest discover -s tools/firmware -p 'test_*.py'
python3 -B -m unittest discover -s tools/release -p 'test_*.py'
python3 -B -m unittest discover -s tools/logging -p 'test_*.py'
```

These tests do not replace device testing. Check USB and Bluetooth, save/discard, layer inheritance, app matching, joystick feedback, sleep/wake reconnection and menu-bar/Dock behavior on hardware.

## Prepare a DMG

Use a clean checkout and fresh build products for distribution. The following prepares a locally signed candidate; it does **not** provide Developer ID signing or notarization.

```sh
mkdir -p app/DerivedData/ReleasePackage
ditto --norsrc --noextattr \
  app/DerivedData/Build/Products/Release/Ed.Board.app \
  app/DerivedData/ReleasePackage/Ed.Board.app
xcrun strip -S app/DerivedData/ReleasePackage/Ed.Board.app/Contents/MacOS/Ed.Board
python3 tools/release/check_macos.py app/DerivedData/ReleasePackage/Ed.Board.app
codesign --force --deep --sign - --timestamp=none app/DerivedData/ReleasePackage/Ed.Board.app
codesign --verify --deep --strict app/DerivedData/ReleasePackage/Ed.Board.app
python3 tools/release/package_dmg.py \
  app/DerivedData/ReleasePackage/Ed.Board.app \
  app/DerivedData/ReleasePackage/Ed.Board-0.5.0-macOS-arm64-candidate.dmg
shasum -a 256 app/DerivedData/ReleasePackage/Ed.Board-0.5.0-macOS-arm64-candidate.dmg
```

Use a fresh `ReleasePackage` directory each time; do not merge an old App bundle into a new one. The DMG tool refuses to overwrite an existing output. It verifies image checksums, mounts the image read-only at a system-selected location, compares App contents and signatures, and then detaches it. It neither launches nor installs the App.

Before publishing, inspect the final binaries and licenses, supply matching source, and test installation on another Mac. The [third-party notice](THIRD_PARTY_NOTICES.md) records asset sources and dependency requirements. A local signature passing verification is not Apple notarization.

## Source and data boundaries

| Location | Purpose |
| --- | --- |
| `app/EdBoard/` | App UI and services |
| `app/Packages/BoardCore/` | Shared models and synthetic unit tests |
| `firmware/usb-probe/` | Production firmware |
| `firmware/boards/` | Board definition |
| `protocol/` | Synthetic protocol fixture and configuration schema |
| `tools/` | Build, packaging and verification tools |
| `public/` | Public documentation |

Runtime settings use the current user's Application Support directory, not the checkout. Keep real device dumps, logs, private actions, local paths and screenshots containing personal data out of contributions.

```sh
python3 tools/release/check_public.py
```

Maintain `tools/release/public-files.json` when adding or moving public files. This read-only check reports unclassified files and known privacy markers; it does not inspect Git history or certify a binary release.

For bounded local build logs, optionally wrap a command with:

```sh
python3 tools/logging/run.py build -- pio run --project-dir firmware/usb-probe -e edboard_codex_probe
```

Logs stay in ignored `test-results/`. Contributions should be focused, include relevant synthetic tests, and preserve third-party attribution. Discuss protocol, hardware or behavior changes before implementation.
