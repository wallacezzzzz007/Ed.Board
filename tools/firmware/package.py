"""Build the isolated updater and stage a fresh, validated firmware resource bundle."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import venv
from updater import validate_package

ROOT = Path(__file__).resolve().parents[2]
VERSION = '0.5.3'



def remove_installation_records(helper):
    """Discard installer bookkeeping; retain runtime metadata and license notices."""
    for metadata in helper.rglob('*.dist-info'):
        if not metadata.is_dir():
            continue
        for name in ('RECORD', 'direct_url.json'):
            path = metadata / name
            if path.is_file():
                path.unlink()


def publish(staged, destination):
    """Replace the complete bundle only after validation, never merge old resources."""
    validate_package(staged)
    previous = destination.with_name(destination.name + '.previous')
    if previous.exists():
        raise RuntimeError('Previous resource swap remains; inspect it before retrying')
    existed = destination.exists()
    if existed:
        destination.rename(previous)
    try:
        staged.rename(destination)
    except Exception:
        if existed:
            previous.rename(destination)
        raise
    if existed:
        shutil.rmtree(previous)


def main():
    build = ROOT / 'firmware/usb-probe/.pio/build/edboard_codex_probe'
    required = ['project_description.json', 'firmware.bin', 'partitions.bin']
    if any(not (build / name).is_file() for name in required):
        raise SystemExit('Build firmware first: pio run --project-dir firmware/usb-probe -e edboard_codex_probe')
    version = json.loads((build / 'project_description.json').read_text())['project_version']
    if version != VERSION:
        raise SystemExit('Build the matching firmware version ' + VERSION + ' first. Upload is not required.')
    work = ROOT / 'tools/firmware/.build'
    env = work / 'venv'
    venv.EnvBuilder(with_pip=True).create(env)
    python = env / 'bin/python3'
    subprocess.run([str(python), '-m', 'pip', 'install', 'esptool==4.11.0', 'pyinstaller==6.16.0'], check=True)
    subprocess.run([str(python), '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
                    '--name', 'edboard-flasher', '--collect-all', 'esptool',
                    '--distpath', str(work / 'dist'), '--workpath', str(work / 'work'),
                    '--specpath', str(work), str(ROOT / 'tools/firmware/updater.py')], check=True)
    destination = ROOT / 'app/EdBoard/Resources/Firmware'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.firmware-stage-', dir=destination.parent) as temp:
        staged = Path(temp) / 'Firmware'; staged.mkdir()
        shutil.copytree(work / 'dist/edboard-flasher', staged / 'helper')
        remove_installation_records(staged / 'helper')
        manifest = dict(format=1, chip='esp32s3', version=version, offset=0x20000)
        for name in ['firmware', 'partitions']:
            data = (build / (name + '.bin')).read_bytes()
            (staged / (name + '.bin')).write_bytes(data)
            manifest[name + 'SHA256'] = hashlib.sha256(data).hexdigest()
        (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        with (staged / 'dependencies.txt').open('w') as output:
            subprocess.run([str(python), '-m', 'pip', 'freeze'], stdout=output, check=True)
        shutil.copy2(ROOT / 'tools/firmware/updater.py', staged / 'updater-source.py')
        subprocess.run([str(python), str(ROOT / 'tools/firmware/collect_licenses.py'),
                        str(staged / 'licenses'), str(build / 'project_description.json')], check=True)
        serial_version = subprocess.check_output([str(python), '-c',
            'from importlib.metadata import version; print(version("pyserial"))'], text=True).strip()
        subprocess.run([str(python), '-m', 'pip', 'download', '--no-deps', '--no-binary', ':all:',
                        '--dest', str(staged / 'sources'), 'esptool==4.11.0', 'pyserial==' + serial_version], check=True)
        publish(staged, destination)
    print('Prepared validated firmware resources. Build the App next.')

if __name__ == '__main__':
    main()
