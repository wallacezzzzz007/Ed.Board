"""Synthetic notice packaging check; no dependencies are installed or built."""
from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch
import collect_licenses


class NoticeTests(unittest.TestCase):
    def test_firmware_notices_use_relative_paths_and_require_runtime_terms(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            idf = root / 'sdk'
            managed = root / 'managed_components/example'
            compiler = root / 'toolchain'
            fixtures = {
                idf / 'LICENSE': 'SDK license',
                idf / 'components/example/NOTICE': 'component notice',
                managed / 'LICENSE': 'managed license',
                compiler / 'share/licenses/gcc/COPYING3': 'GPL',
                compiler / 'share/licenses/gcc/COPYING.RUNTIME': 'exception',
                compiler / 'share/licenses/newlib/COPYING.NEWLIB': 'C runtime',
            }
            for p, value in fixtures.items():
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(value)
            description = root / 'description.json'
            description.write_text(json.dumps(dict(idf_path=str(idf), git_revision='1.0',
                c_compiler=str(compiler / 'bin/cc'), build_component_paths=[str(managed)])))
            output = root / 'licenses'
            collect_licenses.collect_firmware(output, description)
            index = (output / 'INDEX.txt').read_text()
            self.assertNotIn(str(root), index)
            self.assertIn('compiler-runtime/gcc/COPYING.RUNTIME', index)
            self.assertEqual((output / 'example/LICENSE').read_text(), 'managed license')
            (compiler / 'share/licenses/gcc/COPYING.RUNTIME').unlink()
            with self.assertRaisesRegex(RuntimeError, 'runtime notice missing'):
                collect_licenses.collect_firmware(root / 'missing', description)

    def test_project_and_vendor_notices_are_both_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            files = {
                'LICENSE': 'project license fixture',
                'public/THIRD_PARTY_NOTICES.md': 'third-party notice fixture',
                'firmware/usb-probe/src/vendor/LICENSE': 'vendor license fixture',
                'runtime/LICENSE.txt': 'runtime license fixture',
            }
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            output = root / 'output'
            with patch.object(collect_licenses, 'ROOT', root), \
                 patch.object(collect_licenses, 'distributions', return_value=[]), \
                 patch.object(collect_licenses.sysconfig, 'get_path', return_value=str(root / 'runtime')):
                collect_licenses.collect(output)
            self.assertEqual((output / 'Ed.Board-GPL-3.0.txt').read_text(), files['LICENSE'])
            self.assertEqual((output / 'THIRD_PARTY_NOTICES.md').read_text(), files['public/THIRD_PARTY_NOTICES.md'])
            self.assertEqual((output / 'AI-Micro-MIT-LICENSE.txt').read_text(), files['firmware/usb-probe/src/vendor/LICENSE'])


if __name__ == '__main__':
    unittest.main()
