"""Offline installer guard tests; never opens a real serial device."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import updater


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = bytearray(512)
        self.image[0] = 0xE9
        struct.pack_into('<H', self.image, 12, 9)
        struct.pack_into('<I', self.image, 32, 0xABCD5432)
        self.image[48:48 + len(b'0.4.9-usb.3')] = b'0.4.9-usb.3'
        self.table = b''.join(struct.pack('<HBBII16sI', 0x50AA, *entry) for entry in [
            (0, 0, 0x20000, 0x200000, b'factory', 0),
            (1, 2, 0x220000, 0x6000, b'edboard', 0),
            (1, 2, 0x226000, 0x10000, b'edboard_ble', 0)]) + b'\xff' * 32
        self.manifest = dict(format=1, chip='esp32s3', offset=0x20000, version='0.4.9-usb.3')
        self.save()

    def save(self):
        for name, data in [('firmware', self.image), ('partitions', self.table)]:
            (self.root / (name + '.bin')).write_bytes(data)
            self.manifest[name + 'SHA256'] = hashlib.sha256(data).hexdigest()
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_package(self):
        self.assertEqual(updater.validate_package(self.root)[0]['version'], '0.4.9-usb.3')

    def test_corruption_rejected(self):
        (self.root / 'firmware.bin').write_bytes(bytes(self.image) + b'x')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            updater.validate_package(self.root)

    def test_wrong_chip_rejected(self):
        struct.pack_into('<H', self.image, 12, 0)
        self.save()
        with self.assertRaisesRegex(ValueError, 'chip'):
            updater.validate_package(self.root)

    def test_wrong_version_rejected(self):
        self.manifest['version'] = 'other'
        self.save()
        with self.assertRaisesRegex(ValueError, 'version'):
            updater.validate_package(self.root)

    def test_config_overlap_rejected(self):
        self.table = self.table[:8] + struct.pack('<I', 0x210000) + self.table[12:]
        self.save()
        with self.assertRaisesRegex(ValueError, 'partition'):
            updater.validate_package(self.root)

    def execute_fake(self, mac='001122334455', wrong_table=False, backup_fails=False, verify_fails=False, pid=0x1001, multiple=False):
        calls = []
        test = self
        class Chip:
            CHIP_NAME = 'ESP32-S3'
            secure_download_mode = False
            _port = SimpleNamespace(close=lambda: None)
            def read_mac(self): return bytes.fromhex(mac)
            def get_secure_boot_enabled(self): return False
            def get_flash_encryption_enabled(self): return False
            def run_stub(self): return self
            def read_flash(self, offset, size):
                calls.append(('read', offset))
                if offset == 0x8000: return b'bad' if wrong_table else test.table
                if backup_fails: raise IOError('backup failed')
                return bytes(size)
            def flash_md5sum(self, offset, size):
                return 'bad' if verify_fails else hashlib.md5(test.image).hexdigest()
            RTC_CNTL_OPTION1_REG = 1
            RTC_CNTL_FORCE_DOWNLOAD_BOOT_MASK = 1
            def write_reg(self, register, value, mask): calls.append(('clear-download', register, value, mask))
            def read_reg(self, register): return 0
            def watchdog_reset(self): calls.append(('reset',))
        chip = Chip()
        def detect(*args, **kwargs):
            calls.append(('connect', kwargs['connect_mode']))
            return chip
        tool = SimpleNamespace(detect_chip=detect,
                               main=lambda argv, esp: calls.append(('write', argv)))
        port = SimpleNamespace(device='/dev/cu.test', vid=0x303A, pid=pid)
        extra = SimpleNamespace(device='/dev/cu.other', vid=0x303A, pid=0x1001)
        lists = SimpleNamespace(comports=lambda: [port, extra] if multiple else [port])
        modules = {'esptool': tool, 'serial': SimpleNamespace(),
                   'serial.tools': SimpleNamespace(list_ports=lists), 'serial.tools.list_ports': lists}
        args = SimpleNamespace(package=self.root, serial='CM3-001122334455', port=port.device, backup=self.root / 'backup')
        with patch.dict('sys.modules', modules), patch.object(updater, 'emit'):
            try: updater.run(args)
            except (ValueError, IOError): pass
        return calls

    def test_otg_rom_connects_without_serial_jtag_reset(self):
        calls = self.execute_fake(pid=0x0009)
        self.assertIn(('connect', 'no_reset'), calls)
        self.assertTrue(any(c[0] == 'write' for c in calls))

    def test_serial_jtag_keeps_usb_reset(self):
        self.assertIn(('connect', 'usb_reset'), self.execute_fake())

    def test_otg_wrong_identity_never_written(self):
        self.assertFalse(any(c[0] == 'write' for c in self.execute_fake(pid=0x0009, mac='112233445566')))

    def test_multiple_rom_interfaces_never_connected(self):
        self.assertFalse(self.execute_fake(pid=0x0009, multiple=True))

    def test_wrong_device_never_written(self):
        self.assertFalse(any(c[0] == 'write' for c in self.execute_fake(mac='112233445566')))

    def test_unknown_partition_never_written(self):
        self.assertFalse(any(c[0] == 'write' for c in self.execute_fake(wrong_table=True)))

    def test_backup_failure_never_written(self):
        self.assertFalse(any(c[0] == 'write' for c in self.execute_fake(backup_fails=True)))

    def test_success_only_writes_app_and_checks_nvs(self):
        calls = self.execute_fake()
        writes = [c for c in calls if c[0] == 'write']
        self.assertEqual(len(writes), 1)
        self.assertIn('0x20000', writes[0][1])
        self.assertNotIn('erase_flash', writes[0][1])
        self.assertEqual(calls.count(('read', 0x220000)), 2)
        self.assertEqual(calls[-2], ('clear-download', 1, 0, 1))
        self.assertEqual(calls[-1], ('reset',))

    def test_verify_failure_does_not_report_reset_success(self):
        self.assertNotIn(('reset',), self.execute_fake(verify_fails=True))


if __name__ == '__main__':
    unittest.main()
