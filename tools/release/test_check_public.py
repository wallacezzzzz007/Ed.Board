from pathlib import Path
import tempfile
import unittest
import check_public

class PublicTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
    def test_unknown_files_remain_visible(self):
        (self.root/'unlisted.txt').write_text('example')
        self.assertIn('unlisted.txt',check_public.inventory(self.root))
    def test_private_and_cache_excluded(self):
        for name in ('private','docs','test-results','.git','DerivedData'):
            (self.root/name).mkdir();(self.root/name/'secret').write_text('example')
        self.assertEqual(check_public.inventory(self.root),set())
    def test_personal_path_and_identity(self):
        p=self.root/'example.swift';p.write_text('/'+'Users'+'/example/name')
        self.assertTrue(check_public.inspect_file(p))
        p.write_text('Example Identity');self.assertTrue(check_public.inspect_file(p,['Example Identity']))
    def test_metadata_rejected(self):
        p=self.root/'icon.png';p.write_bytes(b'\x89PNG\r\n\x1a\n'+(0).to_bytes(4,'big')+b'tEXt'+bytes(4))
        self.assertIn('PNG metadata requires review',check_public.inspect_file(p))
    def test_symlink_rejected(self):
        p=self.root/'link';p.symlink_to(self.root/'missing')
        self.assertTrue(check_public.inspect_file(p))
if __name__=='__main__':unittest.main()
