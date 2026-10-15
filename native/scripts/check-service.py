#!/usr/bin/env python3
"""Exercise the actual Swift executable's dry-run contract without HID hardware."""
import base64
import json
import os
import tempfile
import pathlib
import subprocess
import sys

helper = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(__file__).resolve().parents[2]
identity = {"deviceID": 130, "address": [1, 2, 3, 4], "connection": 0}
fixture = repo / "Tests/ControllerProtocolTests/Fixtures/vader5-default-sdk.bin"
profile = {"identity": identity, "slot": 0, "data": base64.b64encode(fixture.read_bytes()).decode()}
setting = {"identity": identity, "supported": True, "enabled": False}
led = [0] * 40
led[1], led[7] = 3, 4
requests = [
    {"action": "profileApply", "snapshot": profile, "mappings": {"18": 4}, "persist": True},
    {"action": "turboApply", "turbo": setting, "enabled": True},
    {"action": "calibrationApply", "calibration": setting, "enabled": True},
    {"action": "lightingApply", "lighting": {"identity": identity, "bytes": led}, "color": "#123456", "brightness": 70},
]
classic_identity = {"deviceID": 85, "address": [1, 2, 3, 4], "connection": 1}
classic_led = [0] * 500
classic_led[1], classic_led[6], classic_led[7], classic_led[8] = 2, 50, 2, 5
for minor, length in [(0, 790), (1, 840)]:
    classic_bytes = bytearray(length)
    classic_bytes[0:3] = bytes([minor, 3, 77])
    classic_bytes[225:227] = bytes([0x34, 0x12])
    classic_profile = {"identity": classic_identity, "slot": 2, "data": base64.b64encode(classic_bytes).decode()}
    requests.append({"action": "profileApply", "snapshot": classic_profile, "mappings": {"18": 4}, "persist": True})
requests.append({"action": "lightingApply", "lighting": {"identity": classic_identity, "slot": 2, "bytes": classic_led}, "color": "#ff8000", "brightness": 70})
state_dir = tempfile.TemporaryDirectory(prefix="freedigi-service-test-")
env = {**os.environ, "XDG_STATE_HOME": state_dir.name}
for request in requests:
    # Deliberately omit both dryRun and path: default mode must preview, and no HID
    # transport may be opened. This tests the shipped process, not a mocked client.
    result = subprocess.run([str(helper)], input=json.dumps(request) + "\n", capture_output=True, text=True, timeout=10, env=env)
    reply = json.loads(result.stdout)
    assert result.returncode == 0 and reply["ok"] and reply["result"]["preview"], reply
    print(request["action"] + ": preview succeeded without a device path")
    live = subprocess.run([str(helper)], input=json.dumps({**request, "dryRun": False}) + "\n", capture_output=True, text=True, timeout=10, env=env)
    assert live.returncode != 0 and not json.loads(live.stdout)["ok"], "Live operation unexpectedly succeeded without hardware"

# Forged support flags and shared-VID foreign models must fail before opening HID,
# including dry run. A classic snapshot cannot authorize a Vader 5 setting write.
rejected = [
    {"action": "turboApply", "turbo": {"identity": classic_identity, "supported": True, "enabled": False}, "enabled": True},
    {"action": "calibrationApply", "calibration": {"identity": classic_identity, "supported": True, "enabled": False}, "enabled": True},
    {"action": "profileApply", "snapshot": {**classic_profile, "identity": {**classic_identity, "deviceID": 54}}, "mappings": {"18": 4}},
    {"action": "lightingApply", "lighting": {"identity": {**classic_identity, "deviceID": 54}, "slot": 2, "bytes": classic_led}, "color": "#ff8000", "brightness": 70},
    {"action": "lightingApply", "lighting": {"identity": classic_identity, "bytes": classic_led}, "color": "#ff8000", "brightness": 70},
]
for request in rejected:
    result = subprocess.run([str(helper)], input=json.dumps(request) + "\n", capture_output=True, text=True, timeout=10, env=env)
    reply = json.loads(result.stdout)
    assert result.returncode != 0 and not reply["ok"], reply
    assert "no longer present" not in reply["error"].lower(), "Rejected request opened HID"
    print(request["action"] + ": unsupported/foreign snapshot rejected")
