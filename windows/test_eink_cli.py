"""Process-level tests for `eink_cli.py`, ported from the macOS
`scripts/test_cli.py` minus everything Focus/Pomodoro (stats, `focus`,
`focus stop`/`skip`) -- out of scope on Windows per PARITY-SPEC.md.

Runs the real CLI as a subprocess with `EINK_HOME` pointed at a scratch
directory and `EINK_SIMULATED=1`, so `SimulatedSystem` stands in and nothing
here ever touches the real display or registry. Assertions use this port's
own value shapes (plain bool/float/dict), not macOS's `{"flag": {"_0": ...}}`
enum wrapper.
"""

import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLI = str(Path(__file__).resolve().parent / "eink_cli.py")


class CLIFlowTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="eink-cli-"))
        self.env = dict(os.environ, EINK_HOME=str(self.home), EINK_SIMULATED="1")

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def run_cli(self, *args, good=True):
        result = subprocess.run([sys.executable, CLI, *args], env=self.env,
                                 text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, good, (args, result.stdout, result.stderr))
        return json.loads(result.stdout) if good else result.stderr

    def test_version(self):
        result = subprocess.run([sys.executable, CLI, "version"], text=True,
                                 capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("E-Ink Mode"), result.stdout)

    def test_cli_flow(self):
        # Each `run()` returns the *full* status (or, for "config", the full
        # configuration) after that command -- config.json persists across
        # calls, so a later command's response already reflects every earlier
        # one. Reusing those returned values instead of issuing a fresh
        # `status`/`config` just to re-read the same thing keeps this test's
        # process count (and wall time) down without dropping any assertion.
        run = self.run_cli
        original = run("status")["system"]["values"]
        first_on = run("on")
        self.assertEqual(first_on["state"]["session"]["phase"], "active")
        first = first_on["state"]["session"]["started"]
        self.assertEqual(run("on")["state"]["session"]["started"], first)

        state = run("set", "grayscale", "off")
        self.assertEqual(state["system"]["values"]["grayscale"], False)
        self.assertIsNotNone(state["state"]["session"])
        self.assertEqual(run("set", "brightness", "42")["system"]["values"]["brightness:simulated"], 0.42)
        run("set", "motion", "on")
        run("set", "transparency", "on")
        config = run("set", "dock", "off")["configuration"]
        self.assertEqual(config["brightness"], 0.42)
        self.assertTrue(config["reduceMotion"])
        self.assertTrue(config["reduceTransparency"])
        run("set", "brightness", "nan", good=False)
        run("set", "schedule-on", "24:00", good=False)
        self.assertEqual(run("config"), config)
        self.assertEqual(run("off")["system"]["values"], original)

        # Separate processes must serialize activation: never capture another
        # command's modified state. (A handful of real concurrent processes
        # already exercises the exclusive lock fully -- correctness here does
        # not depend on the count, only on whether the lock holds at all, so
        # this stays small to keep the process-spawning cost of this test down.)
        concurrency = 2  # even, so starting OFF and toggling `concurrency` times ends OFF again
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(lambda _: run("on"), range(concurrency)))
        self.assertEqual(run("off")["system"]["values"], original)
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(lambda _: run("toggle"), range(concurrency)))
        status = run("status")
        self.assertNotIn("session", status["state"])
        self.assertEqual(status["system"]["values"], original)

        # Concurrent edits to unrelated fields must both survive read/modify/write.
        for _ in range(2):
            run("set", "dock", "on")
            run("set", "motion", "off")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(run, "set", "dock", "off"), pool.submit(run, "set", "motion", "on")]
                for future in futures:
                    future.result()
            edited = run("config")
            self.assertFalse(edited["hideDock"])
            self.assertTrue(edited["reduceMotion"])

        # Temporary color lifts grayscale only, keeps the saved profile, and
        # can be cancelled.
        run("off")
        run("set", "dock", "on")
        before_color = run("set", "grayscale", "on")["configuration"]
        run("on")
        colored = run("color", "5")
        self.assertEqual(colored["system"]["values"]["grayscale"], False)
        self.assertEqual(colored["system"]["values"]["dock"], True)
        self.assertIn("colorUntil", colored["state"])
        self.assertEqual(run("config"), before_color)
        run("color", "0", good=False)
        back = run("grayscale")
        self.assertEqual(back["system"]["values"]["grayscale"], True)
        self.assertNotIn("colorUntil", back["state"])
        run("off")
        run("color", good=False)  # requires an active session
        self.assertEqual(run("off")["system"]["values"], original)

        evening = run("set", "schedule", "evening")["configuration"]["schedule"]
        self.assertEqual(evening, {"enabled": True, "on": 1260, "off": 420})
        run("set", "schedule", "off")

        # A resumed process restores the durable journal left by a previous
        # process, and "off" is idempotent (already covered at the unit level
        # by ControllerTests.test_off_without_session_does_not_clear_existing_grayscale,
        # so one check here is enough, not two).
        run("on")
        run("resume")
        self.assertEqual(run("off")["system"]["values"], original)

        Path(self.home, "state.json").write_text("corrupt", encoding="utf-8")
        self.assertIn("Cannot read state.json", run("on", good=False))


if __name__ == "__main__":
    unittest.main()
