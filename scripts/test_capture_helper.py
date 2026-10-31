"""Local integration test: requires previously authorized sudo and Apple PacketLogger.
Does not save raw captures. Restores trace settings after every case.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

helper, tool, peripheral = sys.argv[1:4]
domain = "/Library/Preferences/com.apple.MobileBluetooth.debug"

def trace_settings():
    result = subprocess.run(["sudo", "-n", "/usr/bin/defaults", "export", domain, "-"], capture_output=True)
    return plistlib.loads(result.stdout).get("HCITraces") if result.returncode == 0 else None

if subprocess.run(["sudo", "-n", "/usr/bin/true"], capture_output=True).returncode:
    raise SystemExit("Administrator authorization required before this integration test")

def run_case(name, invalid=False, lose_parent=False):
    before = trace_settings()
    directory = Path(tempfile.mkdtemp(prefix="MiRemote-test-"))
    directory.chmod(0o700)
    output = directory / "events.jsonl"
    output.touch(mode=0o600)
    sleeper = subprocess.Popen(["/bin/sleep", "30"]) if lose_parent else None
    executable = tool
    if invalid:
        executable = str(directory / "packetlogger")
        Path(executable).write_text("#!/bin/sh\nexit 99\n")
        Path(executable).chmod(0o700)
    parent = sleeper.pid if sleeper else os.getpid()
    process = subprocess.Popen(["sudo", "-n", helper, executable, str(output), str(parent), peripheral, "46"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def records():
        rows = output.read_text().splitlines()
        return [json.loads(row) for row in rows if row.endswith("}")]
    try:
        if not invalid:
            deadline = time.monotonic() + 14
            while time.monotonic() < deadline and process.poll() is None:
                if any(row["kind"] == "ready" for row in records()):
                    break
                time.sleep(0.05)
            assert any(row["kind"] == "ready" for row in records()), records()
            if sleeper:
                sleeper.terminate()
                sleeper.wait(timeout=2)
            else:
                (directory / "stop").touch()
        _, error = process.communicate(timeout=8)
        rows = records()
        assert trace_settings() == before, "trace preferences were not restored"
        if invalid:
            assert process.returncode != 0 and any(row["kind"] == "error" for row in rows), rows
        else:
            assert process.returncode == 0 and any(row["kind"] == "stopped" for row in rows), (rows, error)
        print("PASS", name, "events", [row["kind"] for row in rows], "settings restored")
    finally:
        (directory / "stop").touch(exist_ok=True)
        if sleeper and sleeper.poll() is None:
            sleeper.terminate()
            sleeper.wait(timeout=2)
        if process.poll() is None:
            process.communicate(timeout=8)

run_case("stop restores settings")
run_case("unsigned tool rejected", invalid=True)
run_case("parent exit restores settings", lose_parent=True)
