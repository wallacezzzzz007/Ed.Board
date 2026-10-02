"""Read-only source inventory/privacy gate. Does not approve Git history or binaries."""
from pathlib import Path
import getpass
import json
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PRIVATE_ROOTS = {'docs', 'private', 'test-results', '.git'}
CACHE_NAMES = {'.pio', '.build', 'DerivedData', 'managed_components', '__pycache__', 'xcuserdata'}
LOCAL_FILES = {'AGENTS.md', 'Ed.Board.code-workspace'}
TEXT_SUFFIXES = {'.swift', '.py', '.md', '.json', '.svg', '.plist', '.pbxproj', '.xcscheme', '.cpp', '.hpp', '.h', '.c', '.txt', '.ini', '.csv', '.lock', '.yml'}


def excluded(path):
    parts = path.parts
    return (parts[0] in PRIVATE_ROOTS or any(p in CACHE_NAMES for p in parts)
            or path.as_posix() in LOCAL_FILES or path.name == '.DS_Store' or path.suffix == '.pyc'
            or parts[:2] == ('app', 'LocalSettings')
            or parts[:4] == ('app', 'EdBoard', 'Resources', 'Firmware')
            or (len(parts) > 3 and parts[:3] == ('app','EdBoard','Resources') and (parts[3] == 'Firmware.previous' or parts[3].startswith('.firmware-stage-')))
            or (parts[:2] == ('firmware','usb-probe') and path.name.startswith('sdkconfig') and path.name != 'sdkconfig.defaults'))


def inventory(root):
    def walk(directory):
        for p in sorted(directory.iterdir()):
            rel = p.relative_to(root)
            if excluded(rel):
                continue
            if p.is_symlink() or p.is_file():
                yield rel.as_posix()
            elif p.is_dir():
                yield from walk(p)
    return set(walk(root))


def inspect_file(path, private_tokens=()):
    if path.is_symlink():
        return ['symbolic link is not approved']
    data = path.read_bytes()
    if path.suffix == '.png':
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):
            return ['invalid PNG']
        offset = 8
        while offset < len(data):
            if offset + 12 > len(data): return ['truncated PNG']
            size = struct.unpack('>I', data[offset:offset+4])[0]
            kind = data[offset+4:offset+8]
            if kind in (b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'tIME'):
                return ['PNG metadata requires review']
            offset += size + 12
        return [] if offset == len(data) else ['invalid PNG chunk length']
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return ['unreviewed binary asset']
    issues = []
    if re.search(r'/(?:Users|Volumes)/[^\s"\'<>]+', text):
        issues.append('machine-specific absolute path')
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
        issues.append('private-key material')
    if any(token and len(token) > 3 and token.casefold() in text.casefold() for token in private_tokens):
        issues.append('local identity or checkout path')
    if any(value != 'CM3-001122334455' for value in re.findall(r'CM3-[0-9A-Fa-f]{12}', text)):
        issues.append('device identifier requires review')
    return issues


def main():
    manifest = json.loads((ROOT/'tools/release/public-files.json').read_text())
    listed = manifest['files']
    allowed = set(listed)
    errors = []
    if len(allowed) != len(listed):errors.append('Duplicate manifest entries')
    for name in sorted(allowed):
        p = Path(name)
        if p.is_absolute() or '..' in p.parts or excluded(p):
            errors.append('Invalid public entry: ' + name)
    actual = inventory(ROOT)
    for name in sorted(actual - allowed):errors.append('Unclassified file: ' + name)
    for name in sorted(allowed - actual):errors.append('Missing public file: ' + name)
    tokens = [getpass.getuser(), str(Path.home()), str(ROOT)]
    for key in ('user.name', 'user.email'):
        result = subprocess.run(['git', 'config', '--get', key], cwd=ROOT, capture_output=True, text=True)
        if result.returncode == 0: tokens.append(result.stdout.strip())
    for name in sorted(allowed & actual):
        for issue in inspect_file(ROOT/name, tokens):errors.append(name + ': ' + issue)
    if errors:
        print('\n'.join(errors)); return 1
    print(f'PASS: {len(allowed)} source files classified; no flagged paths or asset metadata.')
    print('Not a release approval: Git metadata (if present), release binaries, licenses and clean-machine installation require separate review.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
