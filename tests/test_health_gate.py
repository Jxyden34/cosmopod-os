"""Exercise the real OTA shell gate with isolated data and a controllable clock."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HEALTH_SCRIPT = Path(os.environ.get(
    "COSMOPOD_HEALTH_SCRIPT",
    ROOT / "meta-cosmopod/recipes-core/cosmopod-config/files/ArtifactCommit_Enter_50_cosmopod-health",
))

STUB = """#!/bin/sh
read -r now ignored < "$TEST_HEALTH_CLOCK"
now=${now%%.*}
case "${0##*/}" in
    sleep) printf '%s.00 0.00\\n' "$((now + $1))" > "$TEST_HEALTH_CLOCK" ;;
    systemctl)
        case "$TEST_HEALTH_FAULT" in
            stall) /bin/sleep 30 ;;
            slow) printf '%s.00 0.00\\n' "$((now + 50))" > "$TEST_HEALTH_CLOCK" ;;
            always) exit 1 ;;
            transient) if [ "$now" -ge 60 ] && [ "$now" -lt 90 ]; then exit 1; fi ;;
        esac ;;
    find) printf '/isolated/wayland-0\\n' ;;
esac
"""


@unittest.skipUnless(os.name == "posix" and shutil.which("timeout"),
                     "requires POSIX shell and GNU/BusyBox timeout")
class HealthGateTests(unittest.TestCase):
    def run_gate(self, fault="", deadline=None):
        with tempfile.TemporaryDirectory(prefix="cosmopod-health-test-") as directory:
            base = Path(directory)
            data = base / "data"
            (data / "cosmopod").mkdir(parents=True)
            clock = base / "uptime"
            clock.write_text("0.00 0.00\n", encoding="utf-8")
            binaries = base / "bin"
            binaries.mkdir()
            for name in ("systemctl", "sshd", "find", "logger", "sleep"):
                stub = binaries / name
                stub.write_text(STUB, encoding="utf-8")
                stub.chmod(0o755)
            # Replace only external paths; the production health logic runs intact.
            script = HEALTH_SCRIPT.read_text(encoding="utf-8")
            script = script.replace("/data", str(data))
            script = script.replace("/proc/uptime", str(clock))
            script = script.replace("/usr/share/cosmopod/pi-hardware", str(base / "no-pi"))
            if deadline is not None:
                script = script.replace("deadline=300", f"deadline={deadline}")
            runner = base / "health.sh"
            runner.write_text(script, encoding="utf-8")
            runner.chmod(0o755)
            env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                       TEST_HEALTH_CLOCK=str(clock), TEST_HEALTH_FAULT=fault)
            started = time.monotonic()
            result = subprocess.run(["timeout", "--kill-after=1", "8", str(runner)],
                                    env=env, capture_output=True,
                                    text=True, timeout=10)
            duration = time.monotonic() - started
            return result, int(float(clock.read_text().split()[0])), duration

    def test_requires_full_120_second_window(self):
        result, elapsed, _ = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 120)

    def test_failure_restarts_stable_window(self):
        result, elapsed, _ = self.run_gate("transient")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 210)

    def test_unhealthy_device_never_commits(self):
        result, elapsed, _ = self.run_gate("always")
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 300)

    def test_stalled_check_is_bounded(self):
        result, _, duration = self.run_gate("stall", deadline=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(duration, 4)

    def test_slow_checks_count_toward_deadline(self):
        result, elapsed, _ = self.run_gate("slow")
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 300)


if __name__ == "__main__":
    unittest.main()
