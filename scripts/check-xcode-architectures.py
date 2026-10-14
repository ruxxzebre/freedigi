#!/usr/bin/env python3
"""Mac check for development architecture alignment and in-place repair safety."""
import copy
import importlib.util
from pathlib import Path
import re
import tempfile

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("repair", root / "scripts/fix-xcode-architectures.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)
project = root / "ControlLab.xcodeproj/project.pbxproj"
parsed = repair.decode(project)
configurations = [obj for obj in parsed["objects"].values() if obj.get("isa") == "XCBuildConfiguration"]
assert len(configurations) == 9
for configuration in configurations:
    expected = "NO" if configuration["name"] == "Release" else "YES"
    assert configuration["buildSettings"]["ONLY_ACTIVE_ARCH"] == expected, configuration["name"]

with tempfile.TemporaryDirectory(prefix="controllab-architecture-check-") as temporary:
    for style in ("generated", "xcode-reformatted"):
        path = Path(temporary) / style / "project.pbxproj"
        path.parent.mkdir()
        # Reproduce the old project with personal signing choices, then check
        # the real migration leaves every other setting and Release untouched.
        text = re.sub(r'(?m)^[ \t]*"ONLY_ACTIVE_ARCH" = "[^"]*";\n', "", project.read_text())
        text = text.replace('"DEVELOPMENT_TEAM" = "";', '"DEVELOPMENT_TEAM" = "MYTEAM1234";')
        text = text.replace('"io.github.dracinn.controllab"', '"dev.example.personal"')
        if style == "xcode-reformatted":
            text = re.sub(r'"([A-Za-z_][A-Za-z0-9_]*)"', r'\1', text)
            text = re.sub(r'(?m)^(\s*)"?([A-F0-9]{24})"? = \{', r'\1\2 /* User configuration */ = {', text)
        path.write_text(text)
        expected = copy.deepcopy(repair.decode(path))
        for obj in expected["objects"].values():
            if obj.get("isa") == "XCBuildConfiguration" and obj["name"] in ("Debug", "NativeGamepad"):
                obj["buildSettings"]["ONLY_ACTIVE_ARCH"] = "YES"
        repair.repair(path)
        assert repair.decode(path) == expected
        backups = list(path.parent.glob("*.before-architecture-fix-*"))
        assert len(backups) == 1 and backups[0].read_text() == text
        fixed = path.read_text()
        repair.repair(path)
        assert path.read_text() == fixed
        assert len(list(path.parent.glob("*.before-architecture-fix-*"))) == 1
print("PASS: development architecture alignment, unchanged signing/Release settings, backup and idempotent repair.")
