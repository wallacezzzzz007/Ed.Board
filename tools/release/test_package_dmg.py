"""Offline packaging failure tests; no disk images are built or mounted."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import package_dmg


class PackageTests(unittest.TestCase):
    def exercise(self, corrupt=False, attach_failure=False, missing_mount=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / 'Ed.Board.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(b'synthetic app')
            output = root / 'release.dmg'
            calls = []

            def fake_run(*args, capture=False):
                calls.append(args)
                if args[0] == 'ditto':
                    shutil.copytree(args[-2], args[-1], symlinks=True)
                elif args[:2] == ('hdiutil', 'create'):
                    Path(args[-1]).write_bytes(b'synthetic disk image')
                elif args[:2] == ('hdiutil', 'attach'):
                    self.assertNotIn('-mountpoint', args)
                    self.assertIn('-plist', args)
                    self.assertTrue(capture)
                    if attach_failure:
                        raise subprocess.CalledProcessError(1, args)
                    mount = root / 'system-assigned-volume'
                    shutil.copytree(Path(args[-1]).parent / 'payload', mount, symlinks=True)
                    if corrupt:
                        (mount / 'Ed.Board.app/Contents/Info.plist').write_bytes(b'changed')
                    entities = [{'dev-entry': '/dev/disk99'}]
                    if not missing_mount:
                        entities.append({'dev-entry': '/dev/disk99s1', 'mount-point': str(mount)})
                    return plistlib.dumps({'system-entities': entities})

            with patch.object(package_dmg, 'run', side_effect=fake_run):
                if attach_failure:
                    with self.assertRaises(subprocess.CalledProcessError):
                        package_dmg.package(app, output)
                    self.assertFalse(output.exists())
                elif missing_mount:
                    with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                        package_dmg.package(app, output)
                    self.assertFalse(output.exists())
                elif corrupt:
                    with self.assertRaisesRegex(RuntimeError, 'differs'):
                        package_dmg.package(app, output)
                    self.assertFalse(output.exists())
                else:
                    package_dmg.package(app, output)
                    self.assertEqual(output.read_bytes(), b'synthetic disk image')
                    with self.assertRaises(ValueError):
                        package_dmg.package(app, output)
                    self.assertEqual(output.read_bytes(), b'synthetic disk image')
            detaches = [args for args in calls if args[:2] == ('hdiutil', 'detach')]
            self.assertEqual(detaches, [] if attach_failure else [('hdiutil', 'detach', '/dev/disk99')])

    def test_verified_image_is_published_without_overwriting(self):
        self.exercise()

    def test_changed_bundle_is_rejected_and_detached(self):
        self.exercise(corrupt=True)

    def test_attach_failure_does_not_publish_or_detach_unrelated_disks(self):
        self.exercise(attach_failure=True)

    def test_missing_mount_still_detaches_attached_device(self):
        self.exercise(missing_mount=True)


if __name__ == '__main__':
    unittest.main()
