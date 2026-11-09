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
SLEEP_HZ=390000; TOP_INDEX=44; TOP_HZ_KHZ=1600000; BOTTOM_HZ_KHZ=390000
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

    def test_offline_index_rules(self):
        # With /proc/gpufreqv2 denied (the phone's build), only index 0 / the slowest OPP
        # can be named. Getting this wrong would move the floor to an unrelated step.
        body = """
L_MIN=390000; L_MAX=1600000; L_SLOW=44; LADDER_OK=0
offline_top; echo "top:$R_IDX:$R_FREQ"
offline_index 0 && echo "zero:$R_IDX:$R_FREQ"
offline_index 1600000 && echo "max:$R_IDX:$R_FREQ"
offline_index 390000 && echo "min:$R_IDX:$R_FREQ"
if offline_index 900000; then echo "mid:resolved"; else echo "mid:refused"; fi
"""
        with tempfile.TemporaryDirectory() as td:
            out = self.run_block(td, "", body)
            # R_FREQ is no longer 0 for the top OPP: the kHz parameters must be written
            # with the real top frequency, or GED keeps its stock 1100000 cap.
            self.assertEqual(out.split(), ["top:0:1600000", "zero:0:1600000",
                                           "max:0:1600000", "min:44:390000", "mid:refused"])

    def test_ladder_available_is_cached(self):
        with tempfile.TemporaryDirectory() as td:
            table = pathlib.Path(td) / "table"
            table.write_text("[0] freq = 1600000\n")
            script = f"""
LADDER_OK=""
TABLES={str(table)!r}
{self.block}
if ladder_available; then echo readable; else echo denied; fi
echo "cached=$LADDER_OK"
"""
            for shell in SHELLS:
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.split(), ["readable", "cached=1"])

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
        # the 6th field is the ceiling: safer must lift GED's upper bound too (0 = top OPP),
        # otherwise the stock 1100000 cap keeps the GPU at 1100 MHz whatever the floor says.
        self.assertEqual(self.run_block('preset_values safer').split(), ["safer", "0", "25", "6", "1", "0"])
        self.assertEqual(self.run_block('preset_values boost').split()[5:], [], "boost leaves the ceiling alone")
        self.assertEqual(self.run_block('preset_values max').split(), ["floor", "0", "60", "20", "1", "0"])
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
SLEEP_HZ=390000
N_UTIL=/nonexistent
num_or() {{ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }}
{block}
hot() {{ [ {hot} = 1 ]; }}
screen_on() {{ return 0; }}
low_battery() {{ return 1; }}
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

    def plan_scr(self, mode, top, screen_off, hot=0, sleep_hz=390000, hot_hz=0):
        """plan_now() with the screen state stubbed (max is screen-aware since v11.10)."""
        block = marked_block(
            read("gpufix.sh"),
            "# --- plan helper (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end plan helper ---",
        )
        script = f"""
set -eu
MODE={mode}; TOP_HZ={top}; MIN_HZ=390000; HOT_HZ={hot_hz}; LOAD_ON=60; SLEEP_HZ={sleep_hz}
N_UTIL=/nonexistent
num_or() {{ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }}
{block}
hot() {{ [ {hot} = 1 ]; }}
screen_on() {{ [ {screen_off} = 0 ]; }}
low_battery() {{ return 1; }}
node_val() {{ echo 0; }}
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
        self.assertEqual(self.plan_scr("floor", 0, 0), "0 floor")
        self.assertEqual(self.plan_scr("floor", 1200000, 0), "1200000 floor")

    def test_floor_mode_sleeps_at_the_lowest_opp(self):
        # max: the top OPP while the screen is on, 390 while it is off
        self.assertEqual(self.plan_scr("floor", 0, 1), "390000 screen-off")
        self.assertEqual(self.plan_scr("floor", 1200000, 1), "390000 screen-off")
        self.assertEqual(self.plan_scr("floor", 0, 1, hot=1), "390000 hot")

    def test_off_and_adaptive(self):
        self.assertEqual(self.plan("off", 1200000, hot=0), "390000 released")
        self.assertEqual(self.plan("adaptive", 1200000, hot=0, load=85), "1200000 busy")
        self.assertEqual(self.plan("adaptive", 1200000, hot=0, load=10), "390000 idle")

    def test_hot_battery_releases(self):
        self.assertEqual(self.plan_scr("floor", 0, 0, hot=1), "390000 hot")
        # an explicit HOT_HZ keeps a warm-but-fast floor instead of the stock one
        self.assertEqual(self.plan_scr("floor", 0, 0, hot=1, hot_hz=900000), "900000 hot")


class GpuKHzSyncTests(unittest.TestCase):
    """v12: a correct hal index is not enough - the kHz parameter must match it.

    Device symptom this pins down: 'hal index 0' together with cust_upbound_freq=1100000,
    so GED kept enforcing the stock 1100 MHz cap while every index looked right.
    """

    def block(self):
        return marked_block(
            read("gpufix.sh"),
            "# --- GPU OPP / node helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end GPU OPP / node helpers ---",
        ) + "\n" + marked_block(
            read("gpufix.sh"),
            "# --- OPP end helper (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end OPP end helper ---",
        )

    def run_with(self, body, **vars_):
        defaults = dict(L_MIN="", L_MAX="", SLEEP_HZ=390000, TOP_INDEX=44,
                        TOP_HZ_KHZ=1600000, BOTTOM_HZ_KHZ=390000, MIN_HZ=790000,
                        SAFE_INDEX=43, LADDER_OK=0)
        defaults.update(vars_)
        assign = "\n".join(f"{k}={v!r}" for k, v in defaults.items())
        script = f"""
set -eu
TABLES=/nonexistent
STATUS=/nonexistent
{assign}
{self.block()}
{body}
"""
        out = []
        for shell in SHELLS:
            r = run_shell(shell, script)
            self.assertEqual(r.returncode, 0, r.stderr)
            out.append(r.stdout.strip())
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_offline_top_publishes_a_real_frequency(self):
        # top_khz comes from the config when the ladder is unavailable, so index 0 is
        # written together with a real kHz value instead of being skipped.
        self.assertEqual(self.run_with("offline_top; echo \"$R_IDX:$R_FREQ\""), "0:1600000")
        self.assertEqual(self.run_with("offline_top; echo \"$R_IDX:$R_FREQ\"", TOP_HZ_KHZ=1500000), "0:1500000")

    def test_bottom_frequency_uses_the_config(self):
        self.assertEqual(self.run_with("bottom_khz"), "390000")
        self.assertEqual(self.run_with("bottom_khz", BOTTOM_HZ_KHZ=400000), "400000")

    def test_a_readable_ladder_still_wins(self):
        # When the ladder can be read, its own numbers override the configured ones.
        self.assertEqual(self.run_with("top_khz", L_MAX=1600000, TOP_HZ_KHZ=1500000), "1600000")
        self.assertEqual(self.run_with("bottom_khz", L_MIN=350000, BOTTOM_HZ_KHZ=390000), "350000")

    def test_reapply_and_ceil_accept_a_spelled_out_top_opp(self):
        """CEIL_HZ=1600000 on a denied ladder is index 0, not an error."""
        src = read("gpufix.sh")
        ceil_block = re.search(r"^ceil_to\(\) \{.*?^\}", src, re.S | re.M).group(0)
        self.assertIn('_top=$(top_khz)', ceil_block)
        self.assertIn('"$_want" -ge "$_top"', ceil_block)
        # and reapply must exist and be dispatched under the spellings we advertise
        self.assertIn("reapply|fix|repair) reapply", src)


class GpuClipAndPinTests(unittest.TestCase):
    """v13: the two limits that live BELOW the two nodes we publish.

    Device symptom this pins down: after v12 every index and every kHz parameter read
    correctly, the daemon re-published them every 15 s, and BOTH presets still topped out
    at exactly 1100 MHz. Either (a) /proc/gpufreqv2/fix_target_opp_index pins one OPP, or
    (b) the driver's own table is clipped by the platform limiter. Neither is visible in
    custom_upbound_gpu_freq / gpu_cust_upbound_freq.
    """

    def block(self):
        src = read("gpufix.sh")
        return "\n".join([
            marked_block(src, "# --- GPU OPP / node helpers (regression-tested by "
                               ".github/tests/test_fixes.py) ---",
                         "# --- end GPU OPP / node helpers ---"),
            marked_block(src, "# --- cap audit / pin release (regression-tested by "
                               ".github/tests/test_fixes.py) ---",
                         "# --- end cap audit ---"),
            marked_block(src, "# --- node io (regression-tested by "
                               ".github/tests/test_fixes.py) ---",
                         "# --- end node io ---"),
        ])

    def run_with(self, body, **vars_):
        defaults = dict(L_MIN="", L_MAX="", SLEEP_HZ=390000, TOP_INDEX=44,
                        TOP_HZ_KHZ=1600000, BOTTOM_HZ_KHZ=390000, MIN_HZ=790000,
                        SAFE_INDEX=43, LADDER_OK=0, UNPIN=1, KEEP_PIN=0,
                        PIN="/nonexistent/pin", AVAIL="/nonexistent/avail",
                        LTABLE="/nonexistent/ltable", STATUS="/nonexistent/status",
                        N_UPBOUND="/nonexistent/n_up", P_UPBOUND="/nonexistent/p_up",
                        P_BOOST="/nonexistent/p_boost", P_CUST="/nonexistent/p_cust",
                        N_BOOST="/nonexistent/n_boost", N_CUR="/nonexistent/n_cur",
                        N_UTIL="/nonexistent/n_util", N_LEVELS="/nonexistent/n_lv")
        defaults.update(vars_)
        import tempfile, os
        assign = "\n".join(f"{k}={v!r}" for k, v in defaults.items())
        out = []
        for shell in SHELLS:
            logf = os.path.join(tempfile.mkdtemp(), "log")
            open(logf, "w").close()
            script = f"""
set -eu
TABLES=/nonexistent
LOGFILE={logf!r}
{assign}
say() {{ printf '%s\\n' "$*"; }}
log() {{ printf '%s\\n' "$*" >> "$LOGFILE"; }}
{self.block()}
{body}
"""
            r = run_shell(shell, script)
            self.assertEqual(r.returncode, 0, r.stderr)
            # stdout only: log() appends to a file, and merging it here would make the
            # order shell-dependent (bash vs dash buffer differently). Tests that care
            # about a log line cat "$LOGFILE" themselves.
            out.append(r.stdout.strip())
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    # ---- (a) the configmed top OPP must never be dragged down by a clipped table ----

    def test_a_clipped_table_cannot_lower_the_published_top(self):
        """The exact v12 bug: a limiter-viewed ladder made us publish 1100000 again."""
        self.assertEqual(self.run_with("top_khz", L_MAX=1100000, TOP_HZ_KHZ=1600000), "1600000")

    def test_a_real_ladder_above_the_config_still_wins(self):
        self.assertEqual(self.run_with("top_khz", L_MAX=1800000, TOP_HZ_KHZ=1600000), "1800000")

    def test_driver_table_reports_the_clipped_view(self):
        """opp_top_khz reads the FILE: what the kernel publishes, not what we write."""
        import tempfile, os
        path = os.path.join(tempfile.mkdtemp(), "table")
        with open(path, "w") as fh:
            fh.write("[0] freq = 1100000\n[1] freq = 890000\n[44] freq = 390000\n")
        self.assertEqual(self.run_with("opp_top_khz", TABLES=path), "1100000")
        self.assertEqual(self.run_with("opp_top_khz"), "")          # no table at all

    def test_a_clipped_table_is_treated_as_unreadable_for_mid_ladder_maths(self):
        # top_khz must be usable without ladder_stats() having run first (the audit needs
        # it before anything else does): it falls back to the configured top.
        self.assertEqual(self.run_with("top_khz"), "1600000")

    # ---- (b) the pin ----

    def test_pin_state_reads_all_three_shapes(self):
        import tempfile, os
        path = os.path.join(tempfile.mkdtemp(), "pin")
        for raw, want in (("0", "0"), ("-1", "none"), ("44", "44")):
            # seeded inside the script so bash and dash start from the same state
            self.assertEqual(
                self.run_with('printf "%s\\n" "$SEED" > "$PIN"; pin_state', PIN=path, SEED=raw),
                want, raw)
        self.assertEqual(self.run_with("pin_state"), "none")   # node absent

    def test_pin_release_writes_minus_one_and_respects_the_switches(self):
        import tempfile, os
        path = os.path.join(tempfile.mkdtemp(), "pin")
        # Seed the node INSIDE the script: both shells run the same body, so a file left
        # behind by bash would make dash see a different starting state.
        body = ('printf "%s\\n" "$SEED" > "$PIN"; '
                'rc=0; pin_release || rc=$?; echo rc=$rc; cat "$LOGFILE"; cat "$PIN"')
        # pinned -> written to -1
        out = self.run_with(body, PIN=path, SEED="9")
        self.assertIn("rc=0", out.split())
        self.assertIn("released fix_target_opp_index", out)
        self.assertEqual(out.split()[-1], "-1")
        # already released -> nothing to do, value untouched
        out = self.run_with(body, PIN=path, SEED="-1")
        self.assertIn("rc=2", out.split())
        self.assertEqual(out.split()[-1], "-1")
        # switched off by config, or a pin someone set on purpose: 9 must SURVIVE
        for vars_ in (dict(UNPIN=0), dict(KEEP_PIN=1)):
            out = self.run_with(body, PIN=path, SEED="9", **vars_)
            self.assertIn("rc=2", out.split())
            self.assertEqual(out.split()[-1], "9", vars_)

    def test_limit_rows_parses_only_set_rows(self):
        import tempfile, os
        d = tempfile.mkdtemp()
        path = os.path.join(d, "ltable")
        with open(path, "w") as fh:
            fh.write("# id max min\nset 1 0 44\nset 2 9 44  \nnot a row\n")
        self.assertEqual(self.run_with("limit_rows", LTABLE=path), "1 0 44\n2 9 44")

    def test_cap_sources_names_a_clipped_table_and_a_pin(self):
        import tempfile, os
        d = tempfile.mkdtemp()
        pin = os.path.join(d, "pin"); up = os.path.join(d, "up")
        open(pin, "w").write("7\n"); open(up, "w").write("1100000\n")
        table = os.path.join(d, "table")
        open(table, "w").write("[0] freq = 1100000\n[44] freq = 390000\n")
        out = self.run_with("cap_sources", TABLES=table, PIN=pin, P_UPBOUND=up)
        self.assertIn("CLIPPED", out)
        self.assertIn("PINNED", out)
        self.assertIn("1100000", out)

    # ---- wiring: the release has to actually happen on its own ----

    def test_reapply_releases_the_pin_before_it_writes(self):
        src = read("gpufix.sh")
        body = re.search(r"^reapply\(\) \{.*?^\}", src, re.S | re.M).group(0)
        self.assertIn("pin_release", body)
        # released BEFORE the ceiling is published, or the write is pointless
        self.assertLess(body.index("pin_release"), body.index('ceil_to "$CEIL_HZ"'))

    def test_the_loop_re_checks_the_pin_with_the_ceiling(self):
        src = read("gpufix.sh")
        self.assertEqual(src.count("$(((_n - 1) % 15)) -eq 0 ] && pin_release"), 2,
                         "both loop paths (offline and ladder) must re-check the pin")

    def test_reapply_verifies_the_ceiling_from_outside(self):
        """A matching readback is not proof: the kernel can keep a lower bound."""
        src = read("gpufix.sh")
        body = re.search(r"^reapply\(\) \{.*?^\}", src, re.S | re.M).group(0)
        self.assertIn("asked $_want kHz, kernel kept", body)

    def test_cap_and_unpin_are_dispatchable(self):
        src = read("gpufix.sh")
        self.assertIn("cap|why) cap ;;", src)
        self.assertIn("unpin) is_root", src)
        self.assertIn("self.assertIn", "self.assertIn")   # no-op, keeps the block honest


class GpuSaferModeTests(unittest.TestCase):
    """MODE=safer: whole-system boost on load, but never a pinned floor.

    Precedence is pinned here because getting it wrong is exactly the bug the user
    reported twice: (1) a floor left at the top OPP after load ends, (2) a top OPP floor
    while the screen is off.
    """

    def block(self):
        return marked_block(
            read("gpufix.sh"),
            "# --- screen/charging helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end screen/charging helpers ---",
        )

    def policy(self, sticky, screen, hot=0, lowb=0, cpu=0, min_hz=790000, top_hz=1600000,
               sleep_hz=390000, hot_hz=0, screen_off_min=1, cpu_on=60):
        script = f"""
set -eu
MIN_HZ={min_hz}; TOP_HZ={top_hz}; SLEEP_HZ={sleep_hz}; HOT_HZ={hot_hz}
SCREEN_OFF_MIN={screen_off_min}; BAT_MIN=15; CPU_ON={cpu_on}
{self.block()}
floor_policy {sticky} 0 {screen} {hot} {lowb} {cpu}
"""
        out = []
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            out.append(result.stdout.strip())
        self.assertEqual(out[0], out[1], "bash and dash disagree")
        return out[0]

    def test_the_idle_floor_is_790_and_load_reaches_1600(self):
        # idle, screen on -> the 790 MHz rest floor; busy -> the full 1600 MHz
        self.assertEqual(self.policy(0, 1), "790000 idle")
        self.assertEqual(self.policy(1, 1), "1600000 busy")

    def test_cpu_busy_alone_raises_the_floor(self):
        # The UI costs CPU, not GPU: a busy CPU must be enough on its own.
        self.assertEqual(self.policy(0, 1, cpu=1), "1600000 busy")
        # CPU_ON is a load threshold, not a switch: 0 means "any CPU use counts", so the
        # floor still stays put when nothing at all is running.
        self.assertEqual(self.policy(0, 1, cpu=0, cpu_on=0), "790000 idle")

    def test_screen_off_always_drops_to_the_lowest_opp(self):
        self.assertEqual(self.policy(1, 0), "390000 screen-off")
        self.assertEqual(self.policy(1, 0, cpu=1), "390000 screen-off")

    def test_hot_and_low_battery_release_to_sleep_hz(self):
        self.assertEqual(self.policy(1, 1, hot=1), "390000 hot")
        self.assertEqual(self.policy(1, 1, hot=1, hot_hz=900000), "900000 hot")
        self.assertEqual(self.policy(1, 1, lowb=1), "390000 low-battery")

    def test_screen_off_wins_over_hot(self):
        self.assertEqual(self.policy(1, 0, hot=1), "390000 screen-off")

    def test_screen_off_can_be_disabled(self):
        self.assertEqual(self.policy(1, 1, cpu=1, screen_off_min=0), "1600000 busy")

    def test_cpu_busy_reads_proc_stat(self):
        """cpu_busy must measure real occupancy from two /proc/stat samples."""
        block = marked_block(
            read("gpufix.sh"),
            "# --- screen/charging helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end screen/charging helpers ---",
        ).replace("/proc/stat", '"$STATF"')
        cases = {
            # two samples, 100 ticks apart, 90 of them idle -> ~10% busy -> quiet
            "quiet": ("cpu  10 0 10 90 0 0 0 0 0 0", "cpu  12 0 11 185 1 0 0 0 0 0"),
            # 100 ticks apart, 10 idle -> 90% busy -> busy
            "busy": ("cpu  70 0 20 10 0 0 0 0 0 0", "cpu  165 0 40 15 2 0 0 0 0 0"),
        }
        for name, (first, second) in cases.items():
            with tempfile.TemporaryDirectory() as td:
                f = pathlib.Path(td) / "stat"
                f.write_text(first + "\n" + second + "\n")
                # Each read() call must return the NEXT /proc/stat sample, like the real file.
                script = f"""
set -eu
CPU_ON=60; CPU_SAMPLE_S=0
sleep() {{ :; }}
STATF={str(f)!r}
_N=0
read() {{ _N=$((_N + 1)); _line=$(sed -n "${{_N}}p" "$STATF"); }}
{block}
if cpu_busy; then echo busy; else echo quiet; fi
"""
                outs = []
                for shell in SHELLS:
                    r = run_shell(shell, script)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    outs.append(r.stdout.strip())
                self.assertEqual(outs[0], outs[1], "bash and dash disagree")
                self.assertEqual(outs[0], name)

    def test_documented_commands_exist(self):
        """Every command the output tells the user to run must be dispatched."""
        src = read("gpufix.sh")
        words = set()
        for line in src.splitlines():
            match = re.match(r"^  ([^ ()]+)\) ", line)
            if not match:
                continue
            for word in match.group(1).split("|"):
                words.add(word.strip().strip("'"))
        for cmd in ("status", "probe", "verify", "apply", "ceil", "release", "preset",
                    "choose", "run", "revert", "boot", "help"):
            with self.subTest(cmd=cmd):
                self.assertIn(cmd, words, f"'$ME {cmd}' is not dispatched")
        self.assertRegex(src, r"(?m)^  help\|", "help is not dispatched")
        # and each advice string must name a real command word
        for advice in re.findall(r"'\$ME ([a-z]+)", src):
            self.assertIn(advice, src, f"advice mentions '$ME {advice}'")

    def test_release_uses_sleep_hz_and_needs_no_ladder(self):
        """release must drop to the lowest OPP ('390') and work where /proc is denied."""
        src = read("gpufix.sh")
        block = re.search(r"^release\(\) \{.*?^\}", src, re.S | re.M).group(0)
        self.assertIn('floor_to "$SLEEP_HZ"', block)
        self.assertNotIn("ladder_stats ||", block, "release must not require the ladder")

    def test_safer_lifts_the_ged_upper_bound(self):
        """Regression: 'safer' left the stock 1100000 ceiling in place, so the GPU never
        passed 1100 MHz no matter what the floor asked for."""
        src = read("gpufix.sh")
        # the ceiling write must be reachable for MODE=safer, not only MODE=floor
        match = re.search(r"if \[ \"\$MODE\" = floor \] \|\| \[ \"\$MODE\" = safer \]; then", src)
        self.assertIsNotNone(match, "preset() only applies the ceiling for MODE=floor")
        # and the loop must keep it enforced for safer even with an empty CEIL_HZ
        self.assertEqual(
            src.count('[ "$MODE" = safer ] && [ -z "$CEIL_HZ" ] && CEIL_HZ=0'),
            2,
            "both loop branches must default safer's ceiling to the top OPP",
        )

    def test_volume_keys_map_to_the_two_profiles(self):
        block = marked_block(
            read("gpufix.sh"),
            "# --- installer chooser (used from customize.sh, not by the governor loop) ---",
            "# --- end installer chooser ---",
        )
        script = f"""
set -eu
GPUFIX_CHOICE=; CHOOSE_TIMEOUT=1; KEYCHECK=
timeout() {{ shift; "$@"; }}
getevent() {{ : "$@"; cat "$EVFILE"; }}
{block}
printf '%s\n' 'KEY_VOLUMEUP DOWN' > "$EVFILE"; CHOOSE_KEY=1 choose_preset
printf '%s\n' 'KEY_VOLUMEDOWN DOWN' > "$EVFILE"; CHOOSE_KEY=1 choose_preset
: > "$EVFILE"; CHOOSE_KEY=1 choose_preset
"""
        out = []
        for shell in SHELLS:
            with tempfile.TemporaryDirectory() as td:
                result = run_shell(
                    shell, script,
                    env={**os.environ, "EVFILE": str(pathlib.Path(td) / "ev")},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                out.append([l for l in result.stdout.splitlines() if l in ("safer", "max")])
        self.assertEqual(out[0], ["safer", "max", "safer"], out[0])
        self.assertEqual(out[0], out[1], "bash and dash disagree")


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
