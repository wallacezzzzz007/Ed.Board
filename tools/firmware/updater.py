"""Ed.Board application-only USB installer. No erase-all or arbitrary offsets."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import time

OFFSET = 0x20000
LIMIT = 0x200000
NVS_OFFSET = 0x220000
NVS_SIZE = 0x16000
ROM_PIDS = (0x1001, 0x0009)  # S3 USB Serial/JTAG and USB OTG ROM CDC


def validate_package(root):
    root = Path(root)
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('format') != 1 or manifest.get('chip') != 'esp32s3' or manifest.get('offset') != OFFSET:
        raise ValueError('Unsupported firmware package')
    image = (root / 'firmware.bin').read_bytes()
    table = (root / 'partitions.bin').read_bytes()
    if not 256 < len(image) <= LIMIT or image[0] != 0xE9:
        raise ValueError('Invalid application image or size')
    # ESP image header followed by first segment header and esp_app_desc.
    if struct.unpack_from('<I', image, 32)[0] != 0xABCD5432:
        raise ValueError('Missing application descriptor')
    version = image[48:80].split(b'\0')[0].decode('ascii')
    if version != manifest.get('version') or struct.unpack_from('<H', image, 12)[0] != 9:
        raise ValueError('Image version or chip does not match package')
    for name, data in [('firmware', image), ('partitions', table)]:
        if hashlib.sha256(data).hexdigest() != manifest.get(name + 'SHA256'):
            raise ValueError('Package checksum failed: ' + name)
    validate_table(table)
    return manifest, image, table


def validate_table(data):
    entries = []
    for pos in range(0, len(data) - 31, 32):
        magic, kind, sub, offset, size, label, flags = struct.unpack_from('<HBBII16sI', data, pos)
        if magic != 0x50AA:
            break
        entries.append((kind, sub, offset, size, label.rstrip(b'\0'), flags))
    expected = [(0, 0, OFFSET, LIMIT, b'factory', 0),
                (1, 2, NVS_OFFSET, 0x6000, b'edboard', 0),
                (1, 2, 0x226000, 0x10000, b'edboard_ble', 0)]
    if entries != expected:
        raise ValueError('Unknown partition layout; no flash was written')


def emit(stage, **fields):
    print(json.dumps(dict(stage=stage, **fields)), flush=True, file=sys.__stdout__)


class ToolLog:
    def __init__(self):
        self.buffer = ''
    def write(self, text):
        sys.stderr.write(text)
        sys.stderr.flush()
        self.buffer += text
        while '\r' in self.buffer or '\n' in self.buffer:
            pieces = re.split(r'[\r\n]', self.buffer, maxsplit=1)
            line = pieces[0]
            self.buffer = pieces[1]
            match = re.search(r'Writing at .*?\((\d+)\s*%\)', line)
            if match:
                emit('writing', progress=int(match.group(1)) / 100)
        return len(text)
    def isatty(self):
        return False
    @property
    def encoding(self):
        return "utf-8"
    def flush(self):
        sys.stderr.flush()


def run(args):
    import esptool
    import serial
    from serial.tools import list_ports
    manifest, image, table = validate_package(args.package)
    expected_mac = args.serial.removeprefix('CM3-').lower()
    if not re.fullmatch(r'[0-9a-f]{12}', expected_mac):
        raise ValueError('A previously identified Ed.Board is required for recovery')
    backup = Path(args.backup)
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    emit('entering')
    # Restrict reset to the known runtime identity, or the explicitly selected ROM port.
    ports = {p.device: p for p in list_ports.comports()}
    selected = ports.get(args.port)
    if selected is None or selected.vid != 0x303A or selected.pid not in (0x8360, *ROM_PIDS):
        raise ValueError('Selected USB keyboard is unavailable')
    if selected.pid == 0x8360:
        if selected.serial_number != args.serial:
            raise ValueError('USB identity changed; reconnect the selected keyboard')
        # TinyUSB CDC standard 1200-baud touch. Older firmware may require B/R.
        with serial.Serial(args.port, 1200, timeout=1, exclusive=True) as port:
            port.dtr = False
        time.sleep(1)
    esp = None
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        candidates = [p for p in list_ports.comports() if p.vid == 0x303A and p.pid in ROM_PIDS]
        if len(candidates) > 1:
            raise ValueError('Multiple download-mode devices found. Disconnect other ESP devices and retry.')
        if candidates:
            candidate = candidates[0]
            # OTG is already in ROM: do not apply Serial/JTAG reset signalling.
            mode = 'no_reset' if candidate.pid == 0x0009 else 'usb_reset'
            emit('entering', message=f'Download interface {candidate.vid:04x}:{candidate.pid:04x}; connecting')
            esp = esptool.detect_chip(candidate.device, connect_mode=mode, connect_attempts=3)
            break
        time.sleep(0.3)
    if esp is None:
        raise ValueError('Could not enter download mode. Use B/R recovery, then retry installation.')
    try:
        if esp.CHIP_NAME != 'ESP32-S3' or ''.join(f'{x:02x}' for x in esp.read_mac()) != expected_mac:
            raise ValueError('Chip identity does not match the selected keyboard; no flash was written')
        if esp.secure_download_mode or esp.get_secure_boot_enabled() or esp.get_flash_encryption_enabled():
            raise ValueError('Protected chips are not supported; no flash was written')
        esp = esp.run_stub()
        actual_table = esp.read_flash(0x8000, 0x1000)
        validate_table(actual_table)
        if actual_table[:len(table)] != table:
            raise ValueError('Partition table differs from this package; no flash was written')
        emit('backup')
        saved = esp.read_flash(NVS_OFFSET, NVS_SIZE)
        if len(saved) != NVS_SIZE:
            raise ValueError('Configuration backup incomplete')
        path = backup / 'device-nvs.bin'
        with open(path, 'xb') as f:
            os.chmod(path, 0o600)
            f.write(saved)
            f.flush()
            os.fsync(f.fileno())
        emit('writing', progress=0)
        esptool.main(['--chip', 'esp32s3', '--no-stub', '--after', 'no_reset_stub', 'write_flash',
                      '--flash_mode', 'keep', '--flash_freq', 'keep', '--flash_size', 'keep',
                      hex(OFFSET), str(Path(args.package) / 'firmware.bin')], esp=esp)
        emit('verifying')
        if esp.flash_md5sum(OFFSET, len(image)).lower() != hashlib.md5(image).hexdigest():
            raise ValueError('Firmware readback checksum failed')
        if esp.read_flash(NVS_OFFSET, NVS_SIZE) != saved:
            raise ValueError('Configuration verification failed; backup retained')
        emit('verified')
        emit('restarting')
        # USB Serial/JTAG RTS does not reliably leave manually entered ROM mode.
        # Clear the software download latch, then reset the complete S3 via RTC WDT.
        esp.write_reg(esp.RTC_CNTL_OPTION1_REG, 0, esp.RTC_CNTL_FORCE_DOWNLOAD_BOOT_MASK)
        if esp.read_reg(esp.RTC_CNTL_OPTION1_REG) & esp.RTC_CNTL_FORCE_DOWNLOAD_BOOT_MASK:
            raise ValueError('Firmware verified, but download mode could not be cleared')
        esp.watchdog_reset()
        emit('written', version=manifest['version'])
    finally:
        esp._port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for key in ['package', 'port', 'serial', 'backup']:
        parser.add_argument('--' + key, required=True)
    try:
        with contextlib.redirect_stdout(ToolLog()):
            run(parser.parse_args())
    except Exception as error:
        emit('failed', message=str(error))
        sys.exit(1)
