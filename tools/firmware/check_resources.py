"""Read-only build preflight; never downloads, flashes or repairs resources."""
from pathlib import Path
import os
import sys
from package import VERSION
from updater import validate_package


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
        check(root)
    except (OSError, ValueError, KeyError):
        sys.exit('error: Firmware resources are missing or invalid. Build the matching firmware, then run python3 tools/firmware/package.py from the repository root before building the App.')
    print('Firmware resources validated.')
