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
        scripts = (sorted(REPO.glob("*.sh")) + sorted(REPO.glob("gpumod/*.sh"))
                   + [REPO / "META-INF/com/google/android/update-binary"])
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


class GpuModulePackagingTests(unittest.TestCase):
    def test_standalone_module_reuses_the_shared_script(self):
        # gpumod/ is packaged on its own; a divergent copy of gpufix.sh in it would
        # ship different behaviour than the one that is tested here.
        self.assertEqual(read("gpufix.sh"), read("gpumod/gpufix.sh"))
        self.assertTrue((REPO / "gpumod/module.prop").exists())
        self.assertIn("id=gpu_dvfs_x6886", read("gpumod/module.prop"))
        self.assertIn("gpufix.sh", read("gpumod/service.sh"))
        # The main module starts every part with `sh <part>`; gpufix.sh has no
        # shebang-free assumptions, so it must receive the explicit `boot` argument.
        self.assertIn("gpufix.sh\" boot", read("gpumod/service.sh"))


class GuardPlacementTests(unittest.TestCase):
    def test_fod_helpers_are_guarded(self):
        fod = read("fod_service.sh")
        sofod = read("sofod_touch.sh")
        self.assertIn("single_instance fod_service", fod)
        self.assertIn("single_instance sofod_touch", sofod)
        self.assertNotIn("pkill -f", sofod)
        self.assertLess(fod.index("single_instance fod_service"), fod.index("sofod_touch.sh"))


class Dt2wRemovalTests(unittest.TestCase):
    def test_dt2w_is_removed(self):
        self.assertFalse((REPO / "dt2w.sh").exists())
        service = read("service.sh")
        customize = read("customize.sh")
        diag = read("diag.sh")
        self.assertNotIn("dt2w.sh", service)
        self.assertNotIn("dt2w_infinix_x6886", customize)
        self.assertNotIn("cat > \"$DATA/fod/dt2w.conf\"", customize)
        self.assertIn("rm -f \"$DATA/fod/dt2w.conf\"", customize)
        self.assertNotIn("dt2w", diag)
        self.assertIn("proc_gesture_function", read("sepolicy.rule"))


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


class GpuHelperTests(unittest.TestCase):
    """The GPU OPP ladder reader for gpufix.sh.

    The ladder is a table of strings from the kernel; getting the index wrong moves
    the floor to an unrelated frequency, so it is pinned down here.
    """

    TABLE = """[0] freq = 1600000, volt = 106250, vsram = 110000
[1] freq = 1500000, volt = 100000, vsram = 110000
[2] freq = 900000, volt = 70000, vsram = 87500
[44] freq = 390000, volt = 56250, vsram = 75000
"""

    def setUp(self):
        self.block = marked_block(
            read("gpufix.sh"),
            "# --- GPU OPP / node helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end GPU OPP / node helpers ---",
        )

    def run_block(self, td, table, body):
        path = pathlib.Path(td) / "table"
        path.write_text(table)
        script = f"""
set -eu
TABLES={str(path)!r}
STATUS={str(pathlib.Path(td) / 'missing')!r}
{self.block}
{body}
"""
        out = []
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            out.append(result.stdout)
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_ladder_stats(self):
        with tempfile.TemporaryDirectory() as td:
            out = self.run_block(td, self.TABLE, 'ladder_stats\necho "$L_N $L_MIN $L_MAX $L_SLOW"')
            self.assertEqual(out.split(), ["4", "390000", "1600000", "44"])

    def test_resolve_opp(self):
        cases = {"0": ("0", "1600000"), "350000": ("44", "390000"), "900000": ("2", "900000"),
                 "950000": ("1", "1500000"), "1600000": ("0", "1600000"), "2000000": ("0", "1600000")}
        with tempfile.TemporaryDirectory() as td:
            for want, expected in cases.items():
                with self.subTest(want=want):
                    out = self.run_block(
                        td, self.TABLE,
                        f'resolve_opp {want}\necho "$R_IDX $R_FREQ"',
                    )
                    self.assertEqual(out.split(), list(expected))

    def test_no_ladder_means_apply_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            out = self.run_block(td, "", 'if resolve_opp 900000; then echo ok; else echo refused; fi\n'
                                          'if ladder_stats; then echo stats; else echo noladder; fi')
            self.assertEqual(out.split(), ["refused", "noladder"])

    def test_adaptive_block_is_present(self):
        block = marked_block(
            read("gpufix.sh"),
            "# --- adaptive helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end adaptive helpers ---",
        )
        self.assertIn("sticky_step", block)
        self.assertIn("pick_target", block)

    def test_ged_ladder_format_is_accepted(self):
        # The GED status dump is the fallback source when /proc/gpufreqv2 has nothing.
        ged = ("[GPU-OPP]       Index: 0, Freq: 1600000, Volt: 106250, Vsram: 110000\n"
               "[GPU-OPP]       Index: 44, Freq: 390000, Volt: 56250, Vsram: 75000\n")
        with tempfile.TemporaryDirectory() as td:
            out = self.run_block(td, ged, 'resolve_opp 900000\necho "$R_IDX $R_FREQ"')
            self.assertEqual(out.split(), ["0", "1600000"])


class GpuPresetTests(unittest.TestCase):
    """Presets and config rewriting: `preset max` must mean "top OPP, always"."""

    def setUp(self):
        self.block = marked_block(
            read("gpufix.sh"),
            "# --- preset helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end preset helpers ---",
        )

    def run_block(self, body):
        script = f"""
set -eu
{self.block}
{body}
"""
        out = []
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            out.append(result.stdout)
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_preset_values(self):
        self.assertEqual(self.run_block('preset_values max').split(), ["floor", "0", "60", "20", "1"])
        self.assertEqual(self.run_block('preset_values boost').split(), ["adaptive", "1200000", "60", "20", "1"])
        self.assertEqual(self.run_block('preset_values stock').split(), ["off", "390000", "60", "0", "2"])
        self.assertEqual(self.run_block('if preset_values nope; then echo bad; else echo refused; fi').strip(), "refused")

    def test_setkey_replaces_and_appends_without_losing_comments(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = pathlib.Path(td) / "gpu.conf"
            cfg.write_text("# keep me\nENABLED=0\nMODE=adaptive\n")
            body = f"""
setkey {str(cfg)!r} MODE floor
setkey {str(cfg)!r} TOP_HZ 0
setkey {str(cfg)!r} ENABLED 1
"""
            self.run_block(body)
            text = cfg.read_text()
            self.assertIn("# keep me", text)
            self.assertEqual(text.count("MODE="), 1)
            self.assertIn("MODE=floor", text)
            self.assertIn("TOP_HZ=0", text)
            self.assertIn("ENABLED=1", text)
            self.assertFalse(list(cfg.parent.glob("*.tmp")))


class GpuPlanTests(unittest.TestCase):
    """plan_now() decides what the governor asks for right now."""

    def plan(self, mode, top, hot=1, hot_hz=0, load=0, min_hz=390000, load_on=60):
        block = marked_block(
            read("gpufix.sh"),
            "# --- plan helper (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end plan helper ---",
        )
        script = f"""
set -eu
MODE={mode}; TOP_HZ={top}; MIN_HZ={min_hz}; HOT_HZ={hot_hz}; LOAD_ON={load_on}
N_UTIL=/nonexistent
num_or() {{ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }}
{block}
hot() {{ [ {hot} = 1 ]; }}
node_val() {{ echo {load}; }}
plan_now
"""
        out = []
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            out.append(result.stdout.strip())
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_floor_mode_asks_for_the_fastest_opp(self):
        # TOP_HZ=0 is "fastest OPP"; plan_now must pass the 0 through untouched.
        self.assertEqual(self.plan("floor", 0, hot=0), "0 floor")
        self.assertEqual(self.plan("floor", 1200000, hot=0), "1200000 floor")

    def test_off_and_adaptive(self):
        self.assertEqual(self.plan("off", 1200000, hot=0), "390000 released")
        self.assertEqual(self.plan("adaptive", 1200000, hot=0, load=85), "1200000 busy")
        self.assertEqual(self.plan("adaptive", 1200000, hot=0, load=10), "390000 idle")

    def test_hot_battery_releases(self):
        self.assertEqual(self.plan("floor", 0, hot=1), "390000 hot")
        # an explicit HOT_HZ keeps a warm-but-fast floor instead of the stock one
        self.assertEqual(self.plan("floor", 0, hot=1, hot_hz=900000), "900000 hot")


class GpuGovernorTests(unittest.TestCase):
    """sticky_step / pick_target decide when the GPU floor is raised.

    All time values are seconds of uptime passed in as plain integers, so the
    helper is deterministic under both shells.
    """

    def setUp(self):
        self.block = marked_block(
            read("gpufix.sh"),
            "# --- adaptive helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end adaptive helpers ---",
        )

    DEFAULT_ENV = "LOAD_ON=60\nHOLD_S=20\nTOP_HZ=1200000\nMIN_HZ=390000"

    def run_block(self, body, env=None):
        env = self.DEFAULT_ENV if env is None else env
        script = f"""
set -eu
{env}
{self.block}
{body}
"""
        out = []
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            out.append(result.stdout)
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_load_at_threshold_sticks(self):
        self.assertEqual(self.run_block('sticky_step 0 60 100 0 20').split(), ["1", "100"])
        self.assertEqual(self.run_block('sticky_step 0 59 100 0 20').split(), ["0", "0"])

    def test_hold_window(self):
        # busy at t=100, still inside the 20 s hold at t=115
        self.assertEqual(self.run_block('sticky_step 1 0 115 100 20').split(), ["1", "100"])
        # and released once the hold is over at t=121
        self.assertEqual(self.run_block('sticky_step 1 0 121 100 20').split(), ["0", "100"])

    def test_load_refreshes_last_busy(self):
        self.assertEqual(self.run_block('sticky_step 1 90 130 100 20').split(), ["1", "130"])

    def test_non_numeric_input_is_survivable(self):
        # A broken node read must not crash the loop or raise the floor.
        self.assertEqual(self.run_block('sticky_step 0 "" 100 0 20').split(), ["0", "0"])
        self.assertEqual(self.run_block('sticky_step x 99 100 0 20').split()[0], "x")

    def test_target_selection(self):
        self.assertEqual(self.run_block('pick_target 1').strip(), "1200000")
        self.assertEqual(self.run_block('pick_target 0').strip(), "390000")


if __name__ == "__main__":
    unittest.main(verbosity=2)
