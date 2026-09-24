#!/usr/bin/env python3
"""Offline release guard checks using a real ad hoc signature and isolated files."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parent.parent
env = {key: value for key, value in os.environ.items() if not key.startswith("EINK_")}


def run(*args, **kwargs):
    return subprocess.run(args, cwd=repo, env=kwargs.pop("env", env),
                          text=True, capture_output=True, timeout=30, **kwargs)


for script in ("build.sh", "release.sh"):
    result = run("/bin/bash", str(repo / "scripts" / script),
                 env=dict(env, EINK_DISTRIBUTION="1"))
    assert result.returncode != 0 and "requires" in result.stderr.lower(), result

with tempfile.TemporaryDirectory(prefix="eink-release-qa-") as directory:
    root = pathlib.Path(directory)
    destination = root / "installed"
    installed = destination / "E-Ink Mode.app"
    installed.mkdir(parents=True)
    marker = installed / "existing-copy"
    marker.write_text("keep this installed app")
    installer_env = dict(env, EINK_NO_LAUNCH="1", EINK_INSTALL_DIR=str(destination))

    # The source installer has no trust anchor; even an environment variable cannot supply one.
    result = run("/bin/bash", str(repo / "scripts/install.sh"),
                 env=dict(installer_env, EINK_TEAM_ID="TESTTEAM01"))
    assert result.returncode != 0 and "no pinned publisher identity" in result.stderr, result

    candidate = root / "candidate/E-Ink Mode.app"
    executable = candidate / "Contents/MacOS/EinkBar"
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    info = {"CFBundleIdentifier": "local.eink.mode", "CFBundleExecutable": "EinkBar",
            "CFBundleName": "E-Ink Mode", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "999", "CFBundleShortVersionString": "99.0.0"}
    (candidate / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    result = run("/usr/bin/codesign", "--force", "--sign", "-", str(candidate))
    assert result.returncode == 0, result
    result = run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(candidate))
    assert result.returncode == 0, result  # Signature validity alone must not be enough.
    archive = root / "candidate.zip"
    result = run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(candidate), str(archive))
    assert result.returncode == 0, result
    stamped = root / "install.sh"
    stamped.write_text((repo / "scripts/install.sh").read_text().replace("__EINK_TEAM_ID__", "TESTTEAM01"))
    result = run("/bin/bash", str(stamped), str(archive), env=installer_env)
    assert result.returncode != 0 and "expected publisher" in result.stderr, result
    assert marker.read_text() == "keep this installed app"
    assert list(destination.iterdir()) == [installed]

print("Release guards passed: missing credentials, unconfigured trust anchor, and valid ad hoc signature rejected without replacing installed app")
