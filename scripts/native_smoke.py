#!/usr/bin/env python3
"""Explicit real-display round trip. Always restore in finally; run only for native QA."""
import json
import os
import pathlib
import subprocess
import sys

binary = str(pathlib.Path(sys.argv[1]).resolve())
directory = str(pathlib.Path(sys.argv[2]).resolve())
env = dict(os.environ, EINK_HOME=directory)
env.pop("EINK_SIMULATED", None)
def run(*args):
    result = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)
before = run("status")
assert "session" not in before["state"], "Restore this QA directory's previous session first"
pathlib.Path(directory, "before.json").write_text(json.dumps(before, indent=2))
try:
    run("set", "brightness", "42")
    active = run("on")
    assert active["state"]["session"]["phase"] == "active"
    assert active["system"]["values"]["grayscale"] == {"flag": {"_0": True}}
    assert active["system"]["values"]["dock"] == {"flag": {"_0": True}}
    for key, value in active["system"]["values"].items():
        if key.startswith("brightness:"):
            assert abs(value["level"]["_0"] - 0.42) < 0.001
    color = run("set", "grayscale", "off")
    assert color["system"]["values"]["grayscale"] == {"flag": {"_0": False}}
    assert color["state"]["session"]["phase"] == "active"
    if "transparency" in before["system"]["values"]:
        reduced = run("set", "transparency", "on")
        assert reduced["system"]["values"]["transparency"] == {"flag": {"_0": True}}
finally:
    after = run("off")
    pathlib.Path(directory, "after.json").write_text(json.dumps(after, indent=2))
assert "session" not in after["state"]
assert after["system"]["values"] == before["system"]["values"], (before, after)
print("Native smoke passed: grayscale, independent color toggle, Dock, brightness, transparency, exact restoration")
