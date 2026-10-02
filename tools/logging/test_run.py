"""Offline logger tests; no build, upload, device access or project-log mutation."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('devlog', Path(__file__).with_name('run.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LoggingTests(unittest.TestCase):
    def test_new_session_and_oversized_legacy_tail(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'build.log').write_bytes(b'old-output')
            log = module.Log(p, 'build', 8)
            log.write(b'new')
            log.close()
            self.assertEqual((p / 'build.previous.log').read_bytes(), b'd-output')
            self.assertEqual((p / 'build.log').read_bytes(), b'new')

    def test_large_chunk_rolls_without_stopping(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            log = module.Log(p, 'monitor', 8)
            log.write(b'0123456789abcdefghijkl')
            log.close()
            self.assertEqual((p / 'monitor.previous.log').read_bytes(), b'89abcdef')
            self.assertEqual((p / 'monitor.log').read_bytes(), b'ghijkl')
            self.assertEqual(len(list(p.iterdir())), 2)

    def test_symlink_does_not_touch_target(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'target').write_bytes(b'protected')
            (p / 'upload.log').symlink_to(p / 'target')
            with self.assertRaises(ValueError):
                module.Log(p, 'upload')
            self.assertEqual((p / 'target').read_bytes(), b'protected')

    def test_pty_and_exit_status(self):
        with tempfile.TemporaryDirectory() as d:
            script = f"""import sys
sys.path.insert(0, {str(Path(__file__).parent)!r})
from run import Log, run
from pathlib import Path
log=Log(Path({d!r}), 'build')
code=run([sys.executable,'-c','import os,sys; print(os.isatty(0), os.isatty(1)); sys.exit(7)'],log)
log.close()
sys.exit(code)
"""
            result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn(b'True True', (Path(d) / 'build.log').read_bytes())

    def test_concurrent_session_is_rejected_and_termination_forwarded(self):
        with tempfile.TemporaryDirectory() as d:
            script = f"""import sys
sys.path.insert(0, {str(Path(__file__).parent)!r})
import run
from pathlib import Path
run.ROOT=Path({d!r})
sys.argv=['run.py','monitor','--',sys.executable,'-c','import time; print("ready",flush=True); time.sleep(30)']
sys.exit(run.main())
"""
            first = subprocess.Popen([sys.executable, '-c', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                import select
                self.assertTrue(select.select([first.stdout], [], [], 5)[0])
                self.assertIn(b'ready', first.stdout.readline())
                second = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
                self.assertNotEqual(second.returncode, 0)
                self.assertIn(b'another monitor logging session', second.stderr)
                self.assertFalse((Path(d) / 'test-results/monitor.previous.log').exists())
            finally:
                first.terminate()
                first.communicate(timeout=5)
            self.assertEqual(first.returncode, 143)


if __name__ == '__main__':
    unittest.main()
