# Third-party notices

[README](../README.md) · [Development](DEVELOPMENT.md) · [Project license](../LICENSE)

Original Ed.Board code is licensed under GPL-3.0-only. The third-party code, assets and tools below retain their own copyright notices and license terms. Their inclusion does not imply endorsement of Ed.Board.

## Firmware

| Component | Source | License / scope |
| --- | --- | --- |
| AI Micro code | [AI Micro](https://micro.diyshare.cn/) | MIT. Portions of protocol support, lighting animation logic and battery conversion are used or adapted. Copyright (c) 2026 虾米实验室 (AI Micro contributors). The full [original notice](../firmware/usb-probe/src/vendor/LICENSE) is retained. |
| ESP-IDF 5.5.3 | [Espressif ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.3) | Primarily Apache-2.0, with separately licensed components and binary libraries. See the notices supplied with the framework and the components actually linked into a release. |
| esp_tinyusb 1.7.6 | [Espressif component registry](https://components.espressif.com/components/espressif/esp_tinyusb/versions/1.7.6) | Apache-2.0. |
| TinyUSB 0.17.0~2 | [Espressif component registry](https://components.espressif.com/components/espressif/tinyusb/versions/0.17.0~2) | MIT; copyright (c) 2018, hathach (tinyusb.org). |

The firmware dependency versions are specified in [platformio.ini](../firmware/usb-probe/platformio.ini) and [dependencies.lock](../firmware/usb-probe/dependencies.lock). The packager collects framework/component notices and compiler runtime licenses into `Contents/Resources/Firmware/licenses/firmware/`; the standalone firmware ZIP includes the same firmware notices. The framework also brings components such as FreeRTOS, NimBLE, mbedTLS and C libraries; the framework's top-level license does not replace their individual notices. Compiler runtime exceptions and vendor binary-library terms must be preserved where applicable.

## App icons and artwork

- **Font Awesome Free**, by Fonticons, Inc.: the bundled SVG icons use the **CC BY 4.0** icon license. See the [upstream licensing page](https://fontawesome.com/license/free) and [CC BY 4.0 terms](https://creativecommons.org/licenses/by/4.0/). The assets carry upstream notices for versions 6.7.2 and 7.3.1, copyright 2024 and 2026 respectively. Icons used: `link`, `highlighter`, `language`, `spell-check`, `folder-open`, `paste` and `window-restore`. They are rendered for App actions; some SVG view boxes are adjusted for framing. These icons are not relicensed under GPL.
- **OpenAI mark**: `CodexMark.imageset/openai.svg` identifies the Codex integration. OpenAI names and marks belong to OpenAI and are subject to its [brand guidelines](https://openai.com/brand/), not the project GPL license. Its path geometry matches [LobeHub lobe-icons at revision 79b551cf](https://github.com/lobehub/lobe-icons/blob/79b551cf26aab9ea4ac701fb807160950a5b860f/packages/static-svg/icons/openai.svg). The SVG carries the full upstream MIT notice, copyright (c) 2023 LobeHub. Local adaptations set a fixed 24px size and black fill and omit CSS sizing. This source attribution does not grant trademark rights or imply OpenAI endorsement.
- **System symbols and installed application icons** are obtained through macOS. They remain subject to their owners' terms; the project does not grant rights to third-party brands or to images imported by users.

## Firmware updater and Python runtime

The App packages an updater built from [updater.py](../tools/firmware/updater.py), CPython and Python dependencies. The main tools are:

| Component | Upstream | License |
| --- | --- | --- |
| esptool 4.11.0 | [espressif/esptool](https://github.com/espressif/esptool/tree/v4.11.0) | GPL-2.0-or-later. |
| pySerial | [pyserial/pyserial](https://github.com/pyserial/pyserial) | BSD-3-Clause. |
| PyInstaller 6.16.0 | [pyinstaller/pyinstaller](https://github.com/pyinstaller/pyinstaller/tree/v6.16.0) | GPL-2.0-or-later with its bootloader exception; preserve the upstream text. |
| CPython | [python/cpython](https://github.com/python/cpython) | PSF license agreement and included historical/component licenses. |

The exact resolved dependency versions are recorded in `Contents/Resources/Firmware/dependencies.txt` inside the built App. License texts collected from installed dependency metadata and the Python runtime are stored in `Contents/Resources/Firmware/licenses/`; upstream esptool and pySerial source archives are stored in `Contents/Resources/Firmware/sources/`. The updater's source is also included as `updater-source.py`.

Dependency resolution can change between builds. Review the actual packaged modules and notices for every release; the generated collection is supporting evidence, not a guarantee that all required notices or corresponding sources have been captured.

## Redistribution checklist

- Preserve this document, the project LICENSE, and all applicable upstream notices.
- Provide the matching Ed.Board source, build scripts and required corresponding source with binary releases, in accordance with the applicable licenses. A binary-only DMG is not the complete source distribution.
- Check linked firmware components, Python runtime modules, compiler runtimes and bundled binary libraries against the actual release, including any separately licensed dependencies.
- Preserve the icon source notices and comply with the linked brand guidelines; do not use third-party marks as Ed.Board branding.

This file records third-party attribution and release requirements; it does not grant additional rights over third-party material.
