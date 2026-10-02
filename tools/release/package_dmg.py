"""Create a verified drag-to-install disk image without launching the App."""
from pathlib import Path
import argparse
import hashlib
import os
import plistlib
import subprocess
import tempfile


def run(*args, capture=False):
    return subprocess.run([str(arg) for arg in args], check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def contents(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = ('link', os.readlink(path))
        elif path.is_file():
            result[name] = ('file', path.stat().st_mode & 0o777,
                            hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def package(app, destination):
    app = Path(app).resolve()
    destination = Path(destination).absolute()
    if app.name != 'Ed.Board.app' or not (app / 'Contents/Info.plist').is_file():
        raise ValueError('Expected a built Ed.Board.app bundle')
    if destination.suffix != '.dmg' or destination.exists() or destination.is_symlink():
        raise ValueError('Choose a new .dmg output path; existing files are not overwritten')
    destination.parent.mkdir(parents=True, exist_ok=True)
    run('codesign', '--verify', '--deep', '--strict', app)
    expected = contents(app)
    with tempfile.TemporaryDirectory(prefix='.dmg-stage-', dir=destination.parent) as temp:
        work = Path(temp)
        payload = work / 'payload'
        payload.mkdir()
        run('ditto', '--norsrc', '--noextattr', app, payload / app.name)
        (payload / 'Applications').symlink_to('/Applications', target_is_directory=True)
        image = work / 'Ed.Board.dmg'
        run('hdiutil', 'create', '-volname', 'Ed.Board', '-srcfolder', payload,
            '-format', 'UDZO', '-fs', 'HFS+', image)
        run('hdiutil', 'verify', image)
        # Let Disk Arbitration choose the mount location; custom mountpoints on
        # the build volume can be rejected even when image creation succeeds.
        attached = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse',
                                     '-noautoopen', '-plist', image, capture=True))
        entities = attached.get('system-entities', [])
        devices = [entry['dev-entry'] for entry in entities if entry.get('dev-entry')]
        mounts = [Path(entry['mount-point']) for entry in entities if entry.get('mount-point')]
        if not devices and not mounts:
            raise RuntimeError('Disk image attach returned no device or mount location')
        detach_target = devices[0] if devices else mounts[0]
        try:
            if len(mounts) != 1:
                raise RuntimeError('Expected exactly one mounted disk image volume')
            mount = mounts[0]
            installed = mount / app.name
            if contents(installed) != expected:
                raise RuntimeError('Disk image App content differs from the source bundle')
            if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
                raise RuntimeError('Disk image Applications shortcut is invalid')
            run('codesign', '--verify', '--deep', '--strict', installed)
        finally:
            run('hdiutil', 'detach', detach_target)
        # Atomic, no-clobber publication on the same filesystem, after verification.
        os.link(image, destination)
    print('Verified DMG: ' + str(destination))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    package(args.app, args.destination)
