#!/usr/bin/env python3
"""Process-level tests: real CLI parsing, persistence, locks, and a simulated OS."""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="eink-cli-") as directory:
    env = dict(os.environ, EINK_HOME=directory, EINK_SIMULATED="1")
    def run(*args, good=True):
        result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) == good, (args, result.stdout, result.stderr)
        return json.loads(result.stdout) if good else result.stderr
    original = run("status")["system"]["values"]
    assert run("on")["state"]["session"]["phase"] == "active"
    first = run("status")["state"]["session"]["started"]
    assert run("on")["state"]["session"]["started"] == first
    state = run("set", "grayscale", "off")
    assert state["system"]["values"]["grayscale"] == {"flag": {"_0": False}}
    assert state["state"]["session"] is not None
    assert run("set", "brightness", "42")["system"]["values"]["brightness:simulated"] == {"level": {"_0": 0.42}}
    run("set", "motion", "on")
    run("set", "transparency", "on")
    run("set", "dock", "off")
    config = run("config")
    assert config["brightness"] == 0.42 and config["reduceMotion"] and config["reduceTransparency"]
    run("set", "brightness", "nan", good=False)
    run("set", "schedule-on", "24:00", good=False)
    assert run("config") == config
    assert run("off")["system"]["values"] == original
    # Separate processes must serialize activation: never capture another command's modified state.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: run("on"), range(16)))
    assert run("off")["system"]["values"] == original
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: run("toggle"), range(16)))
    status = run("status")
    assert "session" not in status["state"]
    assert status["system"]["values"] == original
    # Concurrent edits to unrelated fields must both survive read/modify/write.
    for _ in range(10):
        run("set", "dock", "on")
        run("set", "motion", "off")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(run, "set", "dock", "off"), pool.submit(run, "set", "motion", "on")]
            for future in futures: future.result()
        edited = run("config")
        assert edited["hideDock"] is False and edited["reduceMotion"] is True
    # A resumed process restores the durable journal left by a previous process.
    run("on")
    run("resume")
    assert run("off")["system"]["values"] == original
    assert run("off")["system"]["values"] == original
    pathlib.Path(directory, "state.json").write_text("corrupt")
    assert "Cannot read state.json" in run("on", good=False)
print("CLI integration passed: settings, validation, restart recovery, concurrent mode commands and configuration edits, restoration")
