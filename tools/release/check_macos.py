"""Read-only release bundle checks; does not launch the App or change signatures."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

MAGIC = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf')


def version(value):
    parts = tuple(int(p) for p in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def minimum_versions(text):
    values = re.findall(r'\bminos\s+([\d.]+)', text)
    return values or re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', text)


def check(app):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    minimum = version(info['LSMinimumSystemVersion'])
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    errors, seen = [], set()
    count = 0
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if app not in resolved.parents:
            errors.append('External bundle link: ' + str(path.relative_to(app)))
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        data = path.read_bytes()
        if any(p in data for p in (b'/Users/', b'/Volumes/', b'/var/folders/', b'edboard-release-', b'/DerivedData/')):
            errors.append('Build-machine path: ' + str(path.relative_to(app)))
        if data[:4] not in MAGIC:
            continue
        count += 1
        subprocess.run(['lipo', '-verify_arch', 'arm64', str(path)], check=True, capture_output=True)
        loads = subprocess.check_output(['otool', '-arch', 'arm64', '-l', str(path)], text=True)
        versions = minimum_versions(loads)
        if not versions or any(version(v) > minimum for v in versions):
            errors.append('Minimum macOS exceeds App declaration: ' + str(path.relative_to(app)))
        if path == binary and any(version(v) != minimum for v in versions):
            errors.append('Main executable minimum macOS differs from Info.plist')
    symbols = subprocess.check_output(['nm', '-ap', str(binary)], text=True)
    if re.search(r'\b(?:OSO|SO)\b', symbols):
        errors.append('Main executable still contains debug mappings')
    if errors:
        raise ValueError('\n'.join(errors))
    print(f'PASS: {count} Mach-O components support arm64 and macOS {info["LSMinimumSystemVersion"]}; no flagged raw build paths or main debug mappings.')


if __name__ == '__main__':
    try:
        check(sys.argv[1])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
