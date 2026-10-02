"""Read-only build preflight; never downloads, flashes or repairs resources."""
from pathlib import Path
import os
import plistlib
import re
import sys
from package import VERSION
from updater import validate_package


def check_versions(source):
    app = plistlib.loads((source/'app/EdBoard/Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    updater = re.search(r'static let required = "([^"]+)"', (source/'app/EdBoard/Services/FirmwareUpdater.swift').read_text())
    firmware = re.search(r'set\(PROJECT_VER "([^"]+)"\)', (source/'firmware/usb-probe/CMakeLists.txt').read_text())
    if not updater or not firmware or len({app, updater[1], firmware[1], VERSION}) != 1:
        raise ValueError('App, updater requirement, firmware and package versions must match')

def check(root):
    manifest, *_ = validate_package(root)
    if manifest['version'] != VERSION:
        raise ValueError('Firmware version does not match the App')
    helper = root/'helper/edboard-flasher'
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ValueError('Updater helper missing or not executable')

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]/'app/EdBoard/Resources/Firmware'
    try:
        check_versions(Path(__file__).resolve().parents[2])
        check(root)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error) + '\nerror: Firmware resources are missing or invalid. Build the matching firmware, then run python3 tools/firmware/package.py from the repository root before building the App.')
    print('Firmware resources validated.')
