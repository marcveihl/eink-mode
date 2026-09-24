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
    version = subprocess.run([binary, "version"], text=True, capture_output=True, timeout=15)
    assert version.returncode == 0 and version.stdout.startswith("E-Ink Mode "), version
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
    # Temporary color lifts grayscale only, keeps the saved profile, and can be cancelled.
    run("off"); run("set", "dock", "on"); run("set", "grayscale", "on")
    before_color = run("config")
    run("on")
    colored = run("color", "5")
    assert colored["system"]["values"]["grayscale"] == {"flag": {"_0": False}}
    assert colored["system"]["values"]["dock"] == {"flag": {"_0": True}}
    assert "colorUntil" in colored["state"]
    assert run("config") == before_color
    run("color", "0", good=False)
    back = run("grayscale")
    assert back["system"]["values"]["grayscale"] == {"flag": {"_0": True}} and "colorUntil" not in back["state"]
    run("off")
    run("color", good=False)  # requires an active session
    assert run("off")["system"]["values"] == original
    evening = run("set", "schedule", "evening")["configuration"]["schedule"]
    assert evening == {"enabled": True, "on": 1260, "off": 420}
    run("set", "schedule", "off")
    # Pomodoro: focus is grayscale, settings validate, stop restores, stats report.
    run("off"); run("set", "focus-minutes", "1"); run("set", "break-minutes", "1"); run("set", "focus-sessions", "2")
    run("set", "focus-sessions", "0", good=False)
    focus = run("focus")
    assert focus["state"]["focus"]["phase"] == "focus" and focus["state"]["focus"]["rounds"] == 2
    assert focus["system"]["values"]["grayscale"] == {"flag": {"_0": True}}
    run("focus", good=False)          # one round at a time
    peek = run("color", "2")          # color peek mid-focus; the round keeps going
    assert peek["system"]["values"]["grayscale"] == {"flag": {"_0": False}} and "focus" in peek["state"]
    assert run("grayscale")["system"]["values"]["grayscale"] == {"flag": {"_0": True}}
    assert run("set", "daily-goal", "6")["configuration"]["focus"]["dailyGoal"] == 6
    run("set", "daily-goal", "4")
    run("focus", "skip", good=False)  # no break yet
    paused = run("focus", "pause")
    assert "pausedAt" in paused["state"]["focus"]
    frozen_end = paused["state"]["focus"]["phaseEnds"]
    assert run("focus", "pause")["state"]["focus"]["phaseEnds"] == frozen_end
    assert run("tick")["state"]["focus"]["pausedAt"] == paused["state"]["focus"]["pausedAt"]
    resumed = run("focus", "resume")
    assert "pausedAt" not in resumed["state"]["focus"]
    assert run("focus", "resume")["state"]["focus"]["phaseEnds"] == resumed["state"]["focus"]["phaseEnds"]
    stopped = run("focus", "stop")
    assert "focus" not in stopped["state"] and stopped["system"]["values"] == original
    stats = subprocess.run([binary, "stats"], env=env, text=True, capture_output=True, timeout=15)
    assert stats.returncode == 0 and "Today: 0 of 4 focus sessions" in stats.stdout, stats
    # A resumed process restores the durable journal left by a previous process.
    run("on")
    run("resume")
    assert run("off")["system"]["values"] == original
    assert run("off")["system"]["values"] == original
    pathlib.Path(directory, "state.json").write_text("corrupt")
    assert "Cannot read state.json" in run("on", good=False)
print("CLI integration passed: settings, validation, restart recovery, concurrent mode commands and configuration edits, temporary color, evening preset, focus rounds, color peeks and stats, restoration")
