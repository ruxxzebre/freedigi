#!/usr/bin/env python3
"""Collect installed Rust dependency license texts and the Swift runtime notice."""
import json
from pathlib import Path
import subprocess

native = Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(native / "Cargo.toml")
]))
print("FreeDigi bundles Rust dependencies and the Swift runtime.\n")
print("Chaiky native theme, palette and gull: Chaiky project / Core shared theme.\n")
print("\n=== Nunito font · SIL Open Font License 1.1 ===\n")
print((native / "assets/fonts/OFL.txt").read_text())
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["source"] is None:
        continue
    print(f'\n=== {package["name"]} {package["version"]} · {package.get("license") or "see package license"} ===\n')
    root = Path(package["manifest_path"]).parent
    files = sorted(p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")))
    if not files:
        print(f'Source and license: https://crates.io/crates/{package["name"]}/{package["version"]}')
    for path in files:
        print(f"--- {path.name} ---\n{path.read_text(errors='replace')}")
print("\n=== Swift runtime ===\n")
print((native / "assets/swift-runtime-license.txt").read_text())
