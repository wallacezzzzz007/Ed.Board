"""Collect dependency license texts without copying installer records or local paths."""
from importlib.metadata import distributions
from pathlib import Path
import json
import re
import shutil
import sys
import sysconfig

ROOT = Path(__file__).resolve().parents[2]


def collect_firmware(destination, description):
    """Read build locations locally, but emit only relative upstream filenames."""
    info = json.loads(Path(description).read_text())
    idf = Path(info['idf_path'])
    compiler = Path(info['c_compiler']).parent.parent / 'share/licenses'
    destination = Path(destination)
    sources = [(idf, 'esp-idf-' + info['git_revision'])]
    for component in info['build_component_paths']:
        path = Path(component)
        if path.parent.name == 'managed_components':
            sources.append((path, path.name))
    copied = []
    for source, label in sources:
        if not source.is_dir():
            raise RuntimeError('Firmware dependency directory missing: ' + label)
        count = 0
        for original in sorted(source.rglob('*')):
            if original.is_file() and original.name.lower().startswith(('license', 'copying', 'notice')):
                relative = Path(label) / original.relative_to(source)
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, target)
                copied.append(relative.as_posix())
                count += 1
        if not count:
            raise RuntimeError('No firmware dependency notices found: ' + label)
    # GCC's runtime exception and newlib terms are required with the linked runtime.
    for name in ('gcc/COPYING3', 'gcc/COPYING.RUNTIME', 'newlib/COPYING.NEWLIB'):
        original = compiler / name
        if not original.is_file():
            raise RuntimeError('Compiler runtime notice missing: ' + name)
        relative = Path('compiler-runtime') / name
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
        copied.append(relative.as_posix())
    (destination / 'INDEX.txt').write_text('\n'.join(sorted(copied)) + '\n')


def collect(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for dist in distributions():
        name = re.sub(r'[^a-zA-Z0-9_.-]', '_', dist.metadata['Name'])
        for entry in dist.files or []:
            parts = entry.parts
            if not parts or not parts[0].endswith('.dist-info'):
                continue
            relative = Path(*parts[1:])
            if not relative.parts or '..' in relative.parts:
                continue
            if not any(word in str(relative).lower() for word in ('license', 'copying', 'notice', 'authors')):
                continue
            original = Path(dist.locate_file(entry))
            if original.is_file():
                target = destination / (name + '-' + dist.version) / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, target)
    python_license = Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt'
    if not python_license.is_file():
        raise RuntimeError('Python runtime LICENSE.txt missing; supply its license before packaging')
    shutil.copyfile(python_license, destination / 'Python-LICENSE.txt')
    shutil.copyfile(ROOT / 'firmware/usb-probe/src/vendor/LICENSE', destination / 'AI-Micro-MIT-LICENSE.txt')
    shutil.copyfile(ROOT / 'LICENSE', destination / 'Ed.Board-GPL-3.0.txt')
    shutil.copyfile(ROOT / 'public/THIRD_PARTY_NOTICES.md', destination / 'THIRD_PARTY_NOTICES.md')
    notices = []
    for svg in sorted((ROOT / 'app/EdBoard/Resources/Assets.xcassets').rglob('*.svg')):
        for comment in re.findall(r'<!--(.*?)-->', svg.read_text(), re.DOTALL):
            if 'Font Awesome' in comment:
                notices.append(svg.name + '\n' + comment.strip('! ') + '\n')
    (destination / 'Font-Awesome-NOTICES.txt').write_text('\n'.join(notices))
    mark = ROOT / 'app/EdBoard/Resources/Assets.xcassets/CodexMark.imageset/openai.svg'
    if mark.is_file():
        comments = re.findall(r'<!--(.*?)-->', mark.read_text(), re.DOTALL)
        (destination / 'LobeHub-OpenAI-SVG-NOTICE.txt').write_text('\n'.join(comments))


if __name__ == '__main__':
    collect(sys.argv[1])
    collect_firmware(Path(sys.argv[1]) / 'firmware', sys.argv[2])
