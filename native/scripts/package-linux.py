#!/usr/bin/env python3
"""Package the tested portable Linux build with native package-manager metadata."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

REPO = Path(__file__).resolve().parents[2]
VERSION = tomllib.loads((REPO / 'native/Cargo.toml').read_text())['package']['version']


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def install(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(mode)


def payload(source, root):
    for name in ['freedigi', 'freedigi-service']:
        install(source / name, root / 'usr/lib/freedigi' / name, 0o755)
    (root / 'usr/bin').mkdir(parents=True)
    (root / 'usr/bin/freedigi').symlink_to('../lib/freedigi/freedigi')
    install(REPO / 'native/assets/freedigi.desktop', root / 'usr/share/applications/freedigi.desktop')
    install(REPO / 'native/assets/freedigi-256.png', root / 'usr/share/icons/hicolor/256x256/apps/freedigi.png')
    install(source / '70-freedigi.rules', root / 'usr/lib/udev/rules.d/70-freedigi.rules')
    for name in ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.txt']:
        install(source / name, root / 'usr/share/licenses/freedigi' / name)
    install(REPO / 'native/packaging/README.md', root / 'usr/share/doc/freedigi/README.md')


def deb(root, work, output, arch):
    metadata = root / 'DEBIAN'
    metadata.mkdir()
    # Resolve the actual ELF ABI requirements on the build distribution. Graphics
    # backends are loaded dynamically and therefore need explicit dependencies.
    (work / 'debian').mkdir()
    (work / 'debian/control').write_text('Source: freedigi\nSection: utils\nPriority: optional\nMaintainer: ruxxzebre <paullaboratory@gmail.com>\n\nPackage: freedigi\nArchitecture: any\nDescription: Flydigi controller configuration\n')
    result = run('dpkg-shlibdeps', '-O', '-e' + str(root / 'usr/lib/freedigi/freedigi'),
                 '-e' + str(root / 'usr/lib/freedigi/freedigi-service'), cwd=work, capture_output=True, text=True)
    deps = result.stdout.strip().removeprefix('shlibs:Depends=')
    if not deps or '\n' in deps:
        raise RuntimeError('Could not determine ELF dependencies: ' + result.stdout)
    deps += ', libgl1, libegl1, libxkbcommon0, libwayland-client0, libx11-6, libxcursor1, libxi6, libxrandr2'
    size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink()) // 1024
    (metadata / 'control').write_text(f'''Package: freedigi
Version: {VERSION}
Section: utils
Priority: optional
Architecture: {arch}
Maintainer: ruxxzebre <paullaboratory@gmail.com>
Depends: {deps}
Installed-Size: {size}
Homepage: https://github.com/ruxxzebre/freedigi
Description: Configure Flydigi controllers
 Native controller mappings, lighting, firmware information and live inputs.
 Supports Vader 5 Pro and experimental Vader 4 Pro in DInput mode.
''')
    for script in ['postinst', 'postrm']:
        path = metadata / script
        path.write_text('#!/bin/sh\nset -e\nif command -v udevadm >/dev/null 2>&1; then\n    udevadm control --reload-rules || true\nfi\n')
        path.chmod(0o755)
    install(REPO / 'LICENSE', root / 'usr/share/doc/freedigi/copyright')
    run('dpkg-deb', '--root-owner-group', '--build', str(root), str(output / f'freedigi_{VERSION}_{arch}.deb'))


def arch_package(root, work, output):
    if platform.machine() != 'x86_64':
        raise RuntimeError('The Arch Linux binary package targets x86_64')
    archive = work / 'payload.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(root / 'usr', arcname='usr')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (work / 'PKGBUILD').write_text(f'''pkgname=freedigi
pkgver={VERSION}
pkgrel=1
pkgdesc='Configure Flydigi controllers'
arch=('x86_64')
url='https://github.com/ruxxzebre/freedigi'
license=('MIT')
depends=('glibc' 'gcc-libs' 'libglvnd' 'libxkbcommon' 'wayland' 'libx11' 'libxcursor' 'libxi' 'libxrandr')
options=('!strip' '!debug')
source=('payload.tar.gz')
sha256sums=('{digest}')
package() {{
    cp -a "$srcdir/usr" "$pkgdir/"
}}
''')
    run('makepkg', '--nodeps', '--cleanbuild', '--noconfirm', cwd=work,
        env={**os.environ, 'PKGDEST': str(output), 'PKGEXT': '.pkg.tar.zst'})


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--format', choices=['deb', 'arch'], required=True)
    parser.add_argument('--output', default=REPO / 'native/dist', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    machine = platform.machine()
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(machine)
    if arch is None or not args.archive.name.endswith(f'linux-{arch}.tar.gz'):
        parser.error('Build and package on the matching Linux architecture')
    with tempfile.TemporaryDirectory(prefix='freedigi-package-') as folder:
        work = Path(folder)
        with tarfile.open(args.archive) as tar:
            tar.extractall(work / 'source', filter='data')
        root = work / 'root'
        payload(work / 'source/FreeDigi', root)
        if args.format == 'deb':
            deb(root, work, output, arch)
        else:
            arch_package(root, work, output)


if __name__ == '__main__':
    main()
