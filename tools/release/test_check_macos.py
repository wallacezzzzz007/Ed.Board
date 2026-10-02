from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import check_macos


class BundleChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / 'Example.app'
        self.binary = self.app / 'Contents/MacOS/Example'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(check_macos.MAGIC[0] + b'fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Example', 'LSMinimumSystemVersion': '14.0'}))

    def verify(self, minos='14.0', symbols=''):
        def output(args, **kwargs):
            return 'cmd LC_BUILD_VERSION\n minos ' + minos if args[0] == 'otool' else symbols
        with patch.object(check_macos.subprocess, 'run'), patch.object(check_macos.subprocess, 'check_output', side_effect=output):
            check_macos.check(self.app)

    def test_matching_minimum(self):
        self.verify()

    def test_newer_dependency_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Minimum macOS exceeds'):
            self.verify('15.0')

    def test_temporary_build_path_is_rejected(self):
        self.binary.write_bytes(self.binary.read_bytes() + b'/tmp/edboard-release-fixture/Board/app/DerivedData/a.o')
        with self.assertRaisesRegex(ValueError, 'Build-machine path'):
            self.verify()

    def test_debug_mapping_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'debug mappings'):
            self.verify(symbols='000 OSO build/object.o')

    def test_legacy_load_command(self):
        self.assertEqual(check_macos.minimum_versions('cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 11.0\n sdk 14.0'), ['11.0'])


if __name__ == '__main__':
    unittest.main()
