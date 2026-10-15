#!/usr/bin/env python3
"""Package upstream notices with the app, using the installed dependency sources."""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
parts = ['FreeDigi third-party notices\n\nSee also LICENSE and NOTICE for ControlLab attribution.']

def include(label, folder):
    files = sorted(p for p in pathlib.Path(folder).iterdir()
                   if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')))
    for file in files:
        parts.append('\n' + '=' * 72 + '\n' + label + ' / ' + file.name + '\n\n' + file.read_text(errors='replace'))

raw = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd=root, text=True)
decoder = json.JSONDecoder()
while raw.strip():
    module, end = decoder.raw_decode(raw.lstrip())
    raw = raw.lstrip()[end:]
    if module.get('Dir') and not module.get('Main'):
        include(module['Path'] + ' ' + module.get('Version', ''), module['Dir'])
include('Go standard library', subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip())
for name in ['react', 'react-dom', 'scheduler', 'lucide-react']:
    include(name, root / 'frontend/node_modules' / name)
parts.append('\n' + '=' * 72 + '\nSwift runtime (statically linked on Linux)\n\n' + (root / 'assets/swift-runtime-license.txt').read_text())
pathlib.Path(sys.argv[1]).write_text('\n'.join(parts))
