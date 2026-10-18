# Development

[README](../README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [License](../LICENSE)

Ed.Board contains a native SwiftUI/AppKit App, a local Swift package and ESP-IDF firmware. Source versions: **App 0.6.6 (46)** and **firmware 0.6.6** (not yet released). Run the commands below from the repository root.

## Changes since 0.5.3

- Support 16 layers including Codex, with 1–6 ordered Favorites and a searchable Extended sidebar. Moving categories keeps IDs, bindings, appearance and app links.
- Editing a layer never changes the keyboard runtime. Touch cycles Favorites; Extended has no layer indicator lights. An Extended automatic layer can be dismissed by touch until its match changes, lease expires or a new session begins. Favorite automatic layers retain their existing priority.
- Start a fresh live-preview session when reopening Keymap so background key presses are not replayed as highlights.
- Use configuration schema 7 and compact NVS `snapshot8`; read legacy snapshots without changing bindings or order, and migrate their layers to Favorites. The partition layout and runtime/preview/joystick/power versions are unchanged. Mouse Control adds report 3; existing keyboard, media and Codex report IDs are preserved.
- Commit and read back the new snapshot before reclaiming older snapshot keys. A cleanup failure leaves the latest verified configuration readable and disables further writes until cleanup succeeds. Older firmware cannot read settings saved in this format; restore a verified backup for an intentional downgrade.

Disabled keys use the destination layer’s key lighting. Selecting Disabled removes the key’s custom lighting, name and icon (including custom images) from the draft; choosing another action does not restore it. Discard restores the saved configuration. Inherited Disabled actions and legacy Disabled overrides also render with destination-layer lighting.

Codex defaults and Reset use Managed by Codex for all actions in Custom mode; ordinary layers default to Disabled. Switching Native/Custom preserves existing edits, including explicitly disabled keys. Reset still resets lighting and removes layer links and custom appearance.

Known issues: an old pairing-clear message may remain until **Refresh Status** is clicked; intermittent input unavailability after deep-sleep wake remains under investigation. Neither issue is claimed fixed here. Website detection is not implemented; automatic matching uses the active application.

Battery estimates use a bounded voltage curve with a low-end reserve and fixed-memory smoothing at the existing 1 Hz ADC cadence. The charger’s full flag owns 100%; readings without that flag are capped at 99%. No capacity learning or runtime prediction is claimed. The App shares a 15% / 5% warning policy between its main window and menu bar, polls at most once per minute in the background (15 seconds on visible status surfaces), and suspends checks during sleep or firmware updates. The normal menu icon is unchanged. On Bluetooth, only the vertical battery inside its keyboard frame turns orange/red; USB always uses the normal icon. Charging also suppresses this indicator. No notification permission or additional firmware telemetry endpoint is required.

Automatic lights off uses the same physical-input idle timeout on battery and external power. Physical input restores the lights. USB data, charging, or a full-charge indication inhibit deep sleep only; unplugging starts a fresh deep-sleep idle interval. The power settings format and protocol remain unchanged.

New Inherited From selections use the first eligible Favorite, falling back to an eligible Extended layer. Self-inheritance, cycles, and the existing Codex component restrictions remain disallowed. Existing selections are preserved. New key-light Custom overrides start with Solid while retaining the layer color and brightness; existing custom effects are preserved.

Open application includes a left-aligned Finder shortcut below the application chooser. It resolves Finder through macOS and fills the application path without launching it; saving follows the existing action workflow.

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
python3 -B -m unittest discover -s tools/joystick -p 'test_*.py'
```

The media configuration test uses cJSON from the project ESP-IDF dependency (or `CJSON_DIR`) with in-memory NVS; it skips explicitly if that dependency is unavailable.

Media Control requires firmware advertising `mediaVersion: 1`. It adds Consumer Control report 2 alongside the existing keyboard report 1 and Codex report 6. Test all six actions over USB and Bluetooth, including repeated encoder steps, inherited actions, disconnect/reconnect and App-closed operation. After the HID report map changes, a host with cached Bluetooth services may need the keyboard to be forgotten and paired again.

These tests do not replace device testing. Check USB and Bluetooth, save/discard, layer inheritance, app matching, joystick feedback, sleep/wake reconnection and menu-bar/Dock behavior on hardware.

## Mouse Control

Requires firmware advertising `mouseVersion: 1`. Actions `mouse` usage 1/2 send signed relative Wheel +1/-1 in USB/Bluetooth mouse report 3. Its four-byte payload is buttons/X/Y/Wheel; buttons and pointer movement always remain zero. Each physical press or encoder step sends one delta; release sends nothing, and holding does not auto-repeat. Firmware 0.6.5 repeats joystick wheel actions every 80 ms while the selected direction is held, starting immediately; centre stops with no extra pulse. A delayed loop never emits a catch-up burst. Direction changes, Cancel, link loss, input faults and resynchronization stop repetition; other joystick actions retain their return-to-centre behavior. App-closed execution is supported on the keyboard's active layer; app auto-linking still requires the App.

The compact schema 7/snapshot8 layout is retained, with kind 9 appended after the existing kinds. Configurations without mouse actions retain their existing encoding. Older firmware rejects configurations containing kind 9; use a verified pre-upgrade backup for downgrade. Test saving/readback, both directions, inheritance, USB/Bluetooth, App-closed operation, sleep/wake and the existing keyboard/media/Codex reports. Cached Bluetooth HID services may require forgetting the device in macOS and clearing pairing in the App over USB, then pairing again. Pairing is never erased automatically.

Wheel reports follow the [USB-IF HID specifications](https://www.usb.org/hid) and use the existing TinyUSB transport. Scroll direction and distance follow host mouse settings.

## Compact configuration

Schema 7 JSON has exactly two fields: `{"schemaVersion":7,"payload":"<lowercase hex>"}`. The payload is binary version 8, using little-endian integers. Decoders validate the complete graph, field ranges, UTF-8, exact payload length and Codex component protection. Schema 4–6 JSON and persisted snapshots 1–7 remain read-only migration inputs. Synthetic fixtures cover both formats.

| Part | Bytes / encoding |
| --- | --- |
| Header | version `8`, layer count (1–16), favorite count (1–6), then ordered favorite IDs; each value is one byte |
| Layer | ID, UTF-8 name byte count, name (1–48 bytes), native flag, key RGB (3), outer RGB (3), brightness, five effect bytes (`255` represents outer brightness `-1`) |
| Bindings | 25 records; header low nibble is kind (native/shortcut/disabled/inherit/application/open/text/cancel/media/mouse = 0…9), high nibble is ordered chord count (0–14) |
| Binding data | Shortcut: count > 0 means that many usage bytes, otherwise usage + modifiers. Inherit: source ID byte. Application/open/text: 4-byte host ID. Media/Mouse: usage byte. Other kinds: no data |
| Key lighting | 13 records; `0` uses layer lighting, otherwise `128 OR effect`, followed by RGB (3), brightness and active brightness |
| NVS only | Insert the 4-byte revision immediately after version; runtime selection is not persisted in the payload |

The worst allowed 16-layer configuration occupies **8,101 bytes** including the NVS revision, within the unchanged 8,192-byte snapshot limit. Hex transport stays within the existing 32,768-byte frame limit. Real NVS page allocation, repeated large saves and interrupted migration still require hardware testing; host tests use a bounded fake NVS and do not emulate flash wear or page garbage collection. No idle polling or telemetry stream is added.

Validation should cover legacy configuration preservation, 16-layer save/read/restart, Favorites limits/order, cross-category inheritance, application matching, Extended touch return and all-off layer LEDs. Also test USB/Bluetooth save/discard, desktop joystick feedback and sleep/wake behavior. Local action catalogs allow 400 controls plus up to 400 previous IDs while staging a save; the appearance file retains its 12 MB size ceiling.

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
  app/DerivedData/ReleasePackage/Ed.Board-0.6.6-macOS-arm64-candidate.dmg
shasum -a 256 app/DerivedData/ReleasePackage/Ed.Board-0.6.6-macOS-arm64-candidate.dmg
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

Runtime settings use the current user's Application Support directory, not the checkout. The per-device appearance catalog optionally stores `hiddenDesktopOverlayLayers`; missing values enable the overlay for ordinary layers, while Codex always hides it. The saved runtime layer controls visibility independently of action inheritance and editor selection. This is a Mac-local preference and does not change the firmware protocol. Keep real device dumps, logs, private actions, local paths and screenshots containing personal data out of contributions.

```sh
python3 tools/release/check_public.py
```

Maintain `tools/release/public-files.json` when adding or moving public files. This read-only check reports unclassified files and known privacy markers; it does not inspect Git history or certify a binary release.

For bounded local build logs, optionally wrap a command with:

```sh
python3 tools/logging/run.py build -- pio run --project-dir firmware/usb-probe -e edboard_codex_probe
```

Logs stay in ignored `test-results/`. Contributions should be focused, include relevant synthetic tests, and preserve third-party attribution. Discuss protocol, hardware or behavior changes before implementation.

Custom image import accepts SVG through the macOS AppKit renderer; unsupported SVGs fail without replacing the current icon. Images retain their aspect ratio and alpha, with a maximum dimension of 128 pixels and PNG size limit of 128 KiB. Raster imports retain the existing ImageIO thumbnail path. The last successful image directory is a local user preference, separate from appearance/configuration exports; cancellation and failed imports do not update it. Missing or unreadable directories fall back to the system picker. Offline checks: `python3 -B tools/images/test_import.py` (macOS with Xcode command line tools).

New SVG imports set the optional `imageIsTemplate` appearance flag. Keymap, image preview and desktop overlay use template rendering with the PNG alpha; other image imports clear the flag and keep their original colours. Missing flags preserve legacy image rendering. Existing SVG-derived PNGs must be reimported because the original file type is not retained.

## App Switcher

Firmware 0.6.6 advertises `appSwitcherVersion: 1`. `appSwitcher` is compact kind 10 with no payload, valid only for ordinary-layer control 20 (knob Press and hold); inheritance at the same control is supported. Schema 7 / snapshot 8 layout and HID services/report IDs are unchanged. Older firmware rejects this new action, so downgrades require a verified backup.

After the 600 ms hold threshold, keyboard report 1 pulses Command+Tab and retains Command. Each held detent pulses Tab, adding Shift only for reverse selection. Release clears the temporary modifiers without a Click; normal detents and non-switcher holds retain their behavior. The temporary state merges into keyboard reports and is cleared by the existing release/resynchronization path on link, epoch, input fault or configuration changes. Switching neither changes the layer nor overrides existing application matching or locks. Codex knob behavior is unchanged. Offline checks: `python3 -B tools/joystick/test_app_switcher.py`.
