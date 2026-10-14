#!/usr/bin/env python3
"""Repair older ControlLab Xcode projects while preserving local signing choices."""
import copy
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def decode(path):
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def repair(path, read_project=decode):
    path = Path(path)
    if path.is_dir():
        path = path / "project.pbxproj"
    original = read_project(path)
    expected = copy.deepcopy(original)
    text = path.read_text()
    count = 0
    for key, obj in expected["objects"].items():
        if obj.get("isa") != "XCBuildConfiguration" or obj.get("name") not in ("Debug", "NativeGamepad"):
            continue
        if obj.get("buildSettings", {}).get("ONLY_ACTIVE_ARCH") == "YES":
            continue
        # Xcode may rewrite our quoted keys and add object-name comments.
        # Restrict the edit to this configuration's buildSettings dictionary.
        pattern = (r'(?m)(^[ \t]*"?' + re.escape(key)
                   + r'"?(?:[ \t]*/\*[^\n]*?\*/)?[ \t]*=[ \t]*\{'
                   + r'.*?\b"?buildSettings"?[ \t]*=[ \t]*\{)(.*?)(\n[ \t]*\};)')
        matches = list(re.finditer(pattern, text, re.S))
        if len(matches) != 1:
            raise ValueError(f"Cannot safely locate settings for {obj['name']}; project was not changed.")
        match = matches[0]
        settings = match.group(2)
        assignment = r'(?m)^[ \t]*"?ONLY_ACTIVE_ARCH"?[ \t]*=[^;\n]*;'
        if re.search(assignment, settings):
            settings, replacements = re.subn(assignment, '\t\t\t\t"ONLY_ACTIVE_ARCH" = "YES";', settings)
            if replacements != 1:
                raise ValueError("Ambiguous architecture settings; project was not changed.")
        else:
            settings += '\n\t\t\t\t"ONLY_ACTIVE_ARCH" = "YES";'
        text = text[:match.start(2)] + settings + text[match.end(2):]
        obj.setdefault("buildSettings", {})["ONLY_ACTIVE_ARCH"] = "YES"
        count += 1
    if count == 0:
        print("Active-architecture settings are already correct. No files changed.")
        return
    # Parse the entire result and ensure no other setting (especially signing)
    # changed. Only replace the original once this check passes.
    with tempfile.TemporaryDirectory(prefix="controllab-xcode-fix-") as temporary:
        candidate = Path(temporary) / "project.pbxproj"
        candidate.write_text(text)
        if read_project(candidate) != expected:
            raise ValueError("Patched project failed validation; original was not changed.")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = path.with_name(path.name + f".before-architecture-fix-{stamp}")
    shutil.copy2(path, backup)
    fd, stage_name = tempfile.mkstemp(prefix=".controllab-", dir=path.parent)
    stage = Path(stage_name)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        shutil.copymode(path, stage)
        os.replace(stage, path)
    finally:
        stage.unlink(missing_ok=True)
    print(f"Fixed {count} Debug/NativeGamepad configurations. Signing settings preserved.")
    print(f"Backup: {backup}")
    print("Reopen the project in Xcode, choose Product > Clean Build Folder once, then press Command-R.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 fix-xcode-architectures.py /path/to/ControlLab.xcodeproj")
    try:
        repair(sys.argv[1])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Could not repair project: {error}")
