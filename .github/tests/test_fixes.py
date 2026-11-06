#!/usr/bin/env python3
"""Host-side regression tests for the v11.2.2 reliability fixes.

These tests never touch /data, sysfs, input devices, or Android services. They
extract the small marked shell helper blocks and exercise them with stubs under
both bash and dash. They are not a substitute for on-device FOD/AOD testing.
"""

import os
import pathlib
import re
import subprocess
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SHELLS = ["bash", "dash"]


def read(name):
    return (REPO / name).read_text()


def marked_block(text, start, end):
    match = re.search(re.escape(start) + r"\n(.*?)\n" + re.escape(end), text, re.S)
    if not match:
        raise AssertionError(f"missing marked block: {start}")
    return match.group(1)


def run_shell(shell, script, cwd=None, env=None):
    return subprocess.run(
        [shell, "-c", script],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
    )


class SyntaxTests(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = sorted(REPO.glob("*.sh")) + [REPO / "META-INF/com/google/android/update-binary"]
        for shell in SHELLS:
            for script in scripts:
                with self.subTest(shell=shell, script=script.name):
                    result = subprocess.run(
                        [shell, "-n", str(script)],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=20,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)


class GuardPlacementTests(unittest.TestCase):
    def test_fod_helpers_are_guarded(self):
        fod = read("fod_service.sh")
        sofod = read("sofod_touch.sh")
        self.assertIn("single_instance fod_service", fod)
        self.assertIn("single_instance sofod_touch", sofod)
        self.assertNotIn("pkill -f", sofod)
        self.assertLess(fod.index("single_instance fod_service"), fod.index("sofod_touch.sh"))


class HbmSafetyTests(unittest.TestCase):
    def setUp(self):
        self.block = marked_block(
            read("fod_service.sh"),
            "# --- HBM safety helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end HBM safety helpers ---",
        )

    def test_stale_watchdog_cannot_disable_newer_hbm(self):
        with tempfile.TemporaryDirectory() as td:
            script = f"""
set -eu
D={td!r}
NODE={td!r}/node
MAX_S=3
HOT=0
hot() {{ [ "$HOT" = 1 ]; }}
log() {{ :; }}
{self.block}
# Keep the unit test deterministic; the real watchdog is just sleep + hbm_timeout.
hbm_start_watchdog() {{ :; }}
echo 0 > "$NODE"
hbm_on
[ "$(cat "$NODE")" = 1 ]
old=$HBM_TOKEN
hbm_off
[ "$(cat "$NODE")" = 0 ]
hbm_on
new=$HBM_TOKEN
[ "$old" != "$new" ]
hbm_timeout "$old"
[ "$(cat "$NODE")" = 1 ]
hbm_timeout "$new"
[ "$(cat "$NODE")" = 0 ]
HOT=1
if hbm_on; then exit 1; fi
[ "$(cat "$NODE")" = 0 ]
"""
            for shell in SHELLS:
                with self.subTest(shell=shell):
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_cancel_reaps_watchdog_pid(self):
        with tempfile.TemporaryDirectory() as td:
            script = f"""
set -eu
D={td!r}
NODE={td!r}/node
MAX_S=3
hot() {{ return 1; }}
log() {{ :; }}
{self.block}
sleep 30 & WD=$!
pid=$WD
hbm_cancel
if kill -0 "$pid" 2>/dev/null; then exit 1; fi
[ -z "$WD" ]
"""
            for shell in SHELLS:
                with self.subTest(shell=shell):
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)


class SingleInstanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.state = self.root / "fod"
        self.state.mkdir()
        lib = read("lib.sh").replace("/data/adb/fod", str(self.state))
        (self.root / "lib.sh").write_text(lib)
        self.acquire = f""". {str(self.root / 'lib.sh')!r}
single_instance fod_service
echo acquired >> {str(self.root / 'acquired')!r}
echo $$ > {str(self.root / 'acquired_pid')!r}
"""

    def tearDown(self):
        self.tmp.cleanup()

    def spawn_owner(self, argv0):
        proc = subprocess.Popen(
            ["bash", "-c", f"exec -a {argv0} sleep 10"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise AssertionError(f"owner process exited early: {proc.returncode}")
                try:
                    cmdline = pathlib.Path(f"/proc/{proc.pid}/cmdline").read_bytes()
                except FileNotFoundError:
                    cmdline = b""
                if cmdline.split(b"\0", 1)[0] == argv0.encode():
                    return proc
                time.sleep(0.02)
            raise AssertionError(f"owner process did not become {argv0}")
        except BaseException:
            proc.terminate()
            proc.wait()
            raise

    def test_live_matching_owner_blocks_duplicate(self):
        proc = self.spawn_owner("fod_service")
        try:
            (self.state / ".fod_service.pid").write_text(str(proc.pid))
            for shell in SHELLS:
                with self.subTest(shell=shell):
                    result = run_shell(shell, self.acquire, cwd=self.root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse((self.root / "acquired").exists())
                    self.assertEqual((self.state / ".fod_service.pid").read_text().strip(), str(proc.pid))
        finally:
            proc.terminate()
            proc.wait()

    def test_stale_pid_is_replaced(self):
        proc = self.spawn_owner("fod_service")
        proc.terminate()
        proc.wait()
        (self.state / ".fod_service.pid").write_text(str(proc.pid))
        for shell in SHELLS:
            with self.subTest(shell=shell):
                if (self.root / "acquired").exists():
                    (self.root / "acquired").unlink()
                result = run_shell(shell, self.acquire, cwd=self.root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.root / "acquired").exists())
                self.assertEqual(
                    (self.state / ".fod_service.pid").read_text().strip(),
                    (self.root / "acquired_pid").read_text().strip(),
                )

    def test_live_unrelated_pid_does_not_lock_out_service(self):
        proc = subprocess.Popen(["sleep", "10"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            (self.state / ".fod_service.pid").write_text(str(proc.pid))
            for shell in SHELLS:
                with self.subTest(shell=shell):
                    if (self.root / "acquired").exists():
                        (self.root / "acquired").unlink()
                    result = run_shell(shell, self.acquire, cwd=self.root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((self.root / "acquired").exists())
        finally:
            proc.terminate()
            proc.wait()

    def test_corrupt_pid_file_is_replaced(self):
        (self.state / ".fod_service.pid").write_text("not-a-pid\n")
        for shell in SHELLS:
            with self.subTest(shell=shell):
                if (self.root / "acquired").exists():
                    (self.root / "acquired").unlink()
                result = run_shell(shell, self.acquire, cwd=self.root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.root / "acquired").exists())


class DexoptIdleTests(unittest.TestCase):
    def setUp(self):
        self.block = marked_block(
            read("perf_tweaks.sh"),
            "# --- dexopt idle helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end dexopt idle helpers ---",
        )

    def test_screen_idle_states(self):
        cases = {
            "  mWakefulness=Awake": False,
            "  mWakefulness=Dreaming": False,
            "  mWakefulness=Dozing": True,
            "  mWakefulness=Asleep": True,
            "  mWakefulness=Asleepish": False,
            "": False,
        }
        with tempfile.TemporaryDirectory() as td:
            for shell in SHELLS:
                for power, expected in cases.items():
                    with self.subTest(shell=shell, power=power):
                        script = f"""
set -eu
POWER_OUT={power!r}
dumpsys() {{ [ "$1" = power ] && printf '%s\\n' "$POWER_OUT"; }}
{self.block}
if dexopt_screen_idle; then echo yes; else echo no; fi
"""
                        result = run_shell(shell, script)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), "yes" if expected else "no")

    def test_power_gate(self):
        cases = [
            ("10", "  powered: true", True),
            ("39", "  powered: false", False),
            ("40", "  powered: false", True),
            ("", "  powered: false", False),
            ("bad", "  powered: false", False),
            ("bad", "  powered: true", True),
        ]
        for shell in SHELLS:
            for level, battery, expected in cases:
                with self.subTest(shell=shell, level=level, battery=battery):
                    script = f"""
set -eu
LEVEL={level!r}
BATTERY_OUT={battery!r}
dumpsys() {{ [ "$1" = battery ] && printf '%s\\n' "$BATTERY_OUT"; }}
cat() {{
  if [ "$1" = /sys/class/power_supply/battery/capacity ]; then printf '%s\\n' "$LEVEL";
  else command cat "$@"; fi
}}
{self.block}
if dexopt_power_ok; then echo yes; else echo no; fi
"""
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "yes" if expected else "no")


if __name__ == "__main__":
    unittest.main(verbosity=2)
