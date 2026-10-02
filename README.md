[English](README.md) · [简体中文](public/README.zh-CN.md)

<div align="center">

<img src="app/EdBoard/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="104" height="104" alt="Ed.Board app icon">

# Ed.Board

**Your Micro. Your workflow.**

A native macOS companion and firmware for AI Micro.
Keys, layers, lighting and an eight-direction joystick — configured in one place.

`macOS 14+` · `Apple Silicon` · `USB + Bluetooth`

[Get started](#get-started) · [Daily use](#daily-use) · [Firmware](#firmware) · [Help](#help) · [Roadmap](#roadmap)

</div>

---

## Small board. More control.

| Control | Make it yours |
| --- | --- |
| Keys & knob | Assign shortcuts, open apps, URLs or files, and insert text. Add your own names and icons. |
| Layers | Arrange up to six layers, link them to apps, and inherit actions from other layers. |
| Joystick | Map eight directions. A compact desktop wheel shows your choices as you move; return to centre to act or cancel. |
| Lighting | Adjust key and outer lighting, with per-layer colours and input effects. |
| Menu bar | Check the connection and battery, open the editor, or leave Ed.Board running in the background. |

The Codex layer retains native Codex control of its knob and joystick; the desktop wheel stays hidden for those controls.

## Get started

**Requirements:** an Apple Silicon Mac running macOS 14 or later, and an **AI Micro Board3 with ESP32-S3 N16R8** and compatible firmware. Other board revisions are not covered. The App interface is currently English.

### 1. Install

When a release is available, download the App **DMG** from this repository’s **Releases** page. Open it and drag **Ed.Board.app** onto the **Applications** shortcut. Eject the disk image, then open Ed.Board from Applications. To replace an older version, choose **Quit Ed.Board** first.

The current build has no Developer ID signature or Apple notarization. If macOS blocks it, review [Apple’s guidance on opening downloaded apps](https://support.apple.com/en-au/102445). Only approve a copy whose source you trust; installation on other Macs still needs verification.

### 2. Connect

- **USB:** connect with a data-capable cable and open Ed.Board. If needed, go to **Settings → Connection**, choose the USB port and select **Connect USB**.
- **Bluetooth:** on Ed.Board firmware, hold the touch area for **3 seconds** to open a **60-second** pairing window. Pair the keyboard in macOS Bluetooth settings, allow Ed.Board Bluetooth access, then choose **Connect Bluetooth** in the App. A key or knob press cancels the pairing window.

Ed.Board reads the connected keyboard’s configuration. A fresh installation does not include anyone else’s app bindings, text actions or custom images.

### 3. Make it yours

Open **Keymap**, choose a layer, and select a key, knob or joystick direction to edit. Choose **Save changes** to apply your work, or **Discard changes** to return to the saved configuration.

Link a layer to an application to switch automatically while that app is active. Selecting a layer in the editor only changes what you are editing, not the keyboard’s active layer.

## Daily use

- **Close the window:** Ed.Board stays in the menu bar and leaves the Dock. Reopen it from the menu bar or Applications.
- **Start quietly:** enable **System → Launch at Login** to start in the background.
- **Keep host actions available:** app launching, opening files or URLs, text insertion, automatic app matching and the desktop joystick wheel need Ed.Board running.
- **Insert text:** allow Accessibility access when prompted. Text insertion depends on the target app; shortcuts are simultaneous key combinations, not multi-step macros.

## Firmware

The current pair is **App 0.5.0 (22) / firmware 0.5.0**.

Inspired by [AI Micro](https://micro.diyshare.cn/); portions of the firmware are adapted from its code, with the original [MIT license and copyright notice](firmware/usb-probe/src/vendor/LICENSE) retained.

For a recognized, compatible keyboard, connect over **USB**, open **System → Device & Firmware**, and follow **Install required firmware** when offered. Close serial monitors and keep USB connected until verification finishes. The updater backs up settings before writing and does not erase the whole chip.

This is an updater for compatible devices, **not a universal factory installer**. A keyboard running unrecognized firmware may need a separate initial installation procedure; do not flash this package onto a different board or bypass a compatibility check.

## Help

**macOS says connected, but Ed.Board does not?** Keyboard input and App management use separate connections. Check **Settings → Connection** and retry the App connection. A working Bluetooth keyboard alone does not confirm management access.

**Battery says Unknown?** The App may not have received a valid reading yet. Check its connection first. The percentage is a voltage-based estimate, not a precise remaining-runtime prediction.

**Where is my data?** Mac-side settings live in `~/Library/Application Support/Ed.Board/Settings/`; firmware recovery files live in `~/Library/Application Support/Ed.Board/Firmware/`. Logs are stored separately in `~/Library/Logs/Ed.Board/` and rotate automatically. Detailed diagnostics stop automatically after 30 minutes.

**Found a problem or have an idea?** Open an issue with your App and firmware versions, macOS version, USB/Bluetooth connection type, and steps to reproduce. Remove personal paths, device identifiers and action content before sharing logs or screenshots. Small fixes and focused improvements are welcome.

For hardware information and original firmware resources, also visit [AI Micro](https://micro.diyshare.cn/). For Ed.Board-specific issues, please use this repository’s issues.

## Roadmap

Future exploration, guided by community feedback:

- A Chinese App interface.
- Media controls, multi-step macros and other actions based on community feedback.
- Firmware support for remembering Bluetooth pairings with multiple computers.

These are exploratory directions, without a committed release schedule.

## Development & license

See the [development guide](public/DEVELOPMENT.md) to build from source. Original Ed.Board code is licensed under **GNU GPL version 3 only (GPL-3.0-only)**; see [LICENSE](LICENSE). Third-party code and assets retain their own terms, described in [Third-party notices](public/THIRD_PARTY_NOTICES.md).
