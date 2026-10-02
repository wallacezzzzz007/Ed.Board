from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import package

class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.staged=self.root/'staged';self.dest=self.root/'Firmware'
        self.staged.mkdir();(self.staged/'new').write_text('new')
        self.dest.mkdir();(self.dest/'stale').write_text('old')
    def test_installation_paths_removed_without_losing_runtime_metadata_or_licenses(self):
        helper = self.root / 'helper'
        metadata = helper / '_internal/example-1.0.dist-info'
        licenses = metadata / 'licenses'
        licenses.mkdir(parents=True)
        for name in ('RECORD', 'direct_url.json', 'METADATA', 'entry_points.txt'):
            (metadata / name).write_text('synthetic fixture')
        (licenses / 'LICENSE').write_text('license fixture')
        (helper / 'RECORD').write_text('unrelated resource')
        package.remove_installation_records(helper)
        self.assertFalse((metadata / 'RECORD').exists())
        self.assertFalse((metadata / 'direct_url.json').exists())
        self.assertEqual((metadata / 'METADATA').read_text(), 'synthetic fixture')
        self.assertTrue((metadata / 'entry_points.txt').exists())
        self.assertEqual((licenses / 'LICENSE').read_text(), 'license fixture')
        self.assertTrue((helper / 'RECORD').exists())
        package.remove_installation_records(helper)

    def test_clean_replace_not_merge(self):
        with patch.object(package,'validate_package'):
            package.publish(self.staged,self.dest)
        self.assertEqual([p.name for p in self.dest.iterdir()],['new'])
    def test_invalid_preserves_previous(self):
        with patch.object(package,'validate_package',side_effect=ValueError):
            with self.assertRaises(ValueError):package.publish(self.staged,self.dest)
        self.assertTrue((self.dest/'stale').exists())
    def test_failed_swap_restores_previous(self):
        original=Path.rename
        def fail(p,target):
            if p==self.staged:raise PermissionError()
            return original(p,target)
        with patch.object(package,'validate_package'),patch.object(Path,'rename',fail):
            with self.assertRaises(PermissionError):package.publish(self.staged,self.dest)
        self.assertTrue((self.dest/'stale').exists())
if __name__=='__main__':unittest.main()
