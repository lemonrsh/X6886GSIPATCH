#!/usr/bin/env python3
"""Host-side regression tests for X6886GSIPATCH.

These tests never touch /data, sysfs, input devices, or Android services. They
extract the small marked shell helper blocks and exercise them with stubs under
bash/dash and optional mksh/ash. They are not a substitute for on-device FOD/AOD testing.
"""

import os
import pathlib
import re
import signal
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SHELLS = ["bash", "dash"]
# Include Android/Magisk-style shells when installed by CI or a local developer.
for candidate in ("mksh", "ash"):
    executable = shutil.which(candidate)
    if executable:
        SHELLS.append(executable)


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


class GpufixRemovalTests(unittest.TestCase):
    def test_gpufix_and_gpumod_are_removed(self):
        self.assertFalse((REPO / "gpufix.sh").exists())
        self.assertFalse((REPO / "gpumod").exists())
        service = read("service.sh")
        customize = read("customize.sh")
        diag = read("diag.sh")
        module_prop = read("module.prop")
        release_yml = read(".github/workflows/release.yml")
        self.assertNotIn("gpufix", service)
        self.assertNotIn("gpufix.sh", customize)
        self.assertNotIn('cat > "$DATA/fod/gpu.conf"', customize)
        self.assertNotIn("GPUFIX_CHOICE", customize)
        self.assertIn('rm -f "$DATA/fod/gpu.conf"', customize)
        self.assertIn('"$DATA/fod/.gpufix.pid"', customize)
        self.assertNotIn("/data/adb/gpufix", customize)
        self.assertNotIn("gpufix", diag)
        self.assertNotIn("gpu.log", diag)
        self.assertNotIn("gpufix", module_prop.lower())
        self.assertNotIn("gpumod", release_yml)
        self.assertNotIn("gpufix", release_yml)
        self.assertNotIn("GPU-DVFS-X6886", release_yml)


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
        self.block = (
            'REFRESH_FOD_TOKEN=""\n'
            'refresh_fod_begin() { :; }\n'
            'refresh_fod_end() { :; }\n'
            + marked_block(
                read("fod_service.sh"),
                "# --- HBM safety helpers (regression-tested by .github/tests/test_fixes.py) ---",
                "# --- end HBM safety helpers ---",
            )
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


AVAIL = "800000000 1200000000 1600000000 1866000000 2400000000 3200000000 4266000000"


def fake_node(td, governor="mtk-dvfsrc-net", min_f="800000000", max_f="4266000000"):
    node = pathlib.Path(td) / "devfreq"
    (node / "userspace").mkdir(parents=True)
    (node / "available_frequencies").write_text(AVAIL + "\n")
    (node / "available_governors").write_text("mtk-dvfsrc-net userspace\n")
    (node / "governor").write_text(governor + "\n")
    (node / "min_freq").write_text(min_f + "\n")
    (node / "max_freq").write_text(max_f + "\n")
    (node / "cur_freq").write_text("800000000\n")
    (node / "userspace" / "set_freq").write_text("\n")
    return node


class DramLockTests(unittest.TestCase):
    def setUp(self):
        self.block = marked_block(
            read("dramlock.sh"),
            "# --- dram helpers (regression-tested by .github/tests/test_fixes.py) ---",
            "# --- end dram helpers ---",
        )

    def run_block(self, shell, node, body, power=""):
        script = f"""
set -eu
NODE={str(node)!r}
POWER_OUT={power!r}
dumpsys() {{ [ "$1" = power ] && printf '%s\\n' "$POWER_OUT"; }}
{self.block}
{body}
"""
        result = run_shell(shell, script)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_resolve_on_and_half(self):
        cases = [
            ('dram_resolve max ""', "4266000000"),
            ('dram_resolve "" ""', "4266000000"),
            ('dram_resolve min ""', "800000000"),
            ('dram_resolve half 4266000000', "1866000000"),   # 2133 MHz is not a step -> 1866
            ('dram_resolve half ""', "1866000000"),
            ('dram_resolve half 3200000000', "1600000000"),
            ('dram_resolve 3000000000 ""', "2400000000"),     # snaps down to a real step
            ('dram_resolve 2400000000 ""', "2400000000"),
            ('dram_resolve 100 ""', "800000000"),             # below every step -> lowest
            ('dram_resolve bogus ""', ""),
        ]
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            for shell in SHELLS:
                for expr, expected in cases:
                    with self.subTest(shell=shell, expr=expr):
                        self.assertEqual(self.run_block(shell, node, f'echo "$({expr})"'), expected)

    def test_set_locks_up_and_down(self):
        for shell in SHELLS:
            for start, target in [("4266000000", "1866000000"), ("1866000000", "4266000000")]:
                with self.subTest(shell=shell, start=start, target=target):
                    with tempfile.TemporaryDirectory() as td:
                        node = fake_node(td, governor="userspace", min_f=start, max_f=start)
                        out = self.run_block(
                            shell, node,
                            f'dram_set {target}; if dram_locked_at {target}; then echo locked; fi',
                        )
                        self.assertEqual(out, "locked")
                        for f in ("min_freq", "max_freq", "userspace/set_freq"):
                            self.assertEqual((node / f).read_text().strip(), target)
                        self.assertEqual((node / "governor").read_text().strip(), "userspace")

    def test_set_order_is_seamless(self):
        start = self.block.index("dram_set() {")
        body = self.block[start:self.block.index("\n}", start)]
        up, down = body.split("  else\n", 1)
        up = up[up.index("then\n"):]
        # going up: max first, target on the 2nd write, never via the lowest step
        self.assertLess(up.index('> "$NODE/max_freq"'), up.index('> "$NODE/userspace/set_freq"'))
        self.assertLess(up.index('> "$NODE/userspace/set_freq"'), up.index('> "$NODE/min_freq"'))
        self.assertNotIn("_low", up)
        # going down: min must drop before max can go below it
        self.assertLess(down.index('> "$NODE/min_freq"'), down.index('> "$NODE/max_freq"'))
        self.assertLess(down.index('> "$NODE/max_freq"'), down.index('> "$NODE/userspace/set_freq"'))

    def test_screen_sig(self):
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            dpms = pathlib.Path(td) / "dpms"
            bl = pathlib.Path(td) / "brightness"
            cases = [("On", "0", "10", "on"), ("Off", "0", "00", "off"), ("Off", "512", "01", "on"),
                     ("Standby", "0", "00", "off")]
            for shell in SHELLS:
                for d, b, sig, state in cases:
                    with self.subTest(shell=shell, dpms=d, bl=b):
                        dpms.write_text(d + "\n")
                        bl.write_text(b + "\n")
                        out = self.run_block(
                            shell, node,
                            f'SCREEN_NODES="{dpms} {bl} {td}/missing/*"; dram_screen_sig; echo "$SIG $(dram_sig_state "$SIG")"',
                        )
                        self.assertEqual(out, f"{sig} {state}")

    def test_switches_governor_to_userspace(self):
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            for shell in SHELLS:
                with self.subTest(shell=shell):
                    self.assertEqual(self.run_block(shell, node, "dram_set 4266000000; dram_gov"), "userspace")

    def test_event_state(self):
        cases = {
            "I/screen_toggled( 1580): 1": "on",
            "I/screen_toggled( 1580): 0": "off",
            "11-11 10:00:00.000  1580  1601 I screen_toggled: 1": "on",
            "1": "on",
            "0": "off",
            "[1]": "on",
            "--------- beginning of events": "",
            "I/screen_toggled( 1580): 5": "",
            "": "",
            # v14.3: PowerManagerService system-log lines (primary source on the X6886 GSI)
            "I/PowerManagerService( 1580): Waking up from Asleep (uid=1000, reason=WAKE_REASON_POWER_BUTTON, details=android.policy:POWER)...": "on",
            "I/PowerManagerService( 1580): Waking up from Dozing (uid=1000, reason=WAKE_REASON_GESTURE, details=null)...": "on",
            "I/PowerManagerService( 1580): Going to sleep due to power_button (uid 1000, screenOffTimeout=30000, activityTimeoutWM=-1, maxDimRatio=0.2, maxDimDur=7000)...": "off",
            "I/PowerManagerService( 1580): Going to sleep now due to long user inactivity": "off",
            "I/PowerManagerService( 1580): Sleeping (uid 1000)...": "off",
            "I/PowerManagerService( 1580): Dozing...": "off",
            "I/PowerGroup( 1580): Waking up power group from Asleep (groupId=0, uid=1000, reason=WAKE_REASON_POWER_BUTTON, details=x)...": "on",
            "I/PowerManagerService( 1580): Brightness boost activated (uid 1000)...": "",
            "I/PowerManagerService( 1580): Something else 1": "",
        }
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            for shell in SHELLS:
                for line, expected in cases.items():
                    with self.subTest(shell=shell, line=line):
                        self.assertEqual(self.run_block(shell, node, f'dram_event_state {line!r}'), expected)

    def test_wake_state(self):
        cases = {
            "  mWakefulness=Awake": "on",
            "  mWakefulness=Dreaming": "on",
            "  mWakefulness=Dozing": "off",
            "  mWakefulness=Asleep": "off",
            "": "",
        }
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            for shell in SHELLS:
                for power, expected in cases.items():
                    with self.subTest(shell=shell, power=power):
                        self.assertEqual(self.run_block(shell, node, "dram_wake_state", power), expected)

    def test_khz_fits_32bit(self):
        with tempfile.TemporaryDirectory() as td:
            node = fake_node(td)
            out = self.run_block("dash", node, 'echo "$(dram_khz 4266000000)|$(dram_khz 12)|$(dram_khz x)|"')
            self.assertEqual(out, "4266000|0||")

    def test_daemon_follows_screen_events(self):
        """End to end: fake logcat emits off/on/off, the lock follows within the event loop."""
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                tdp = pathlib.Path(td)
                node = fake_node(td)
                data = tdp / "fod"
                data.mkdir()
                mod = tdp / "mod"
                mod.mkdir()
                (mod / "dramlock.sh").write_text(read("dramlock.sh"))
                bindir = tdp / "bin"
                bindir.mkdir()
                stubs = {
                    "getprop": "#!/bin/sh\necho 1\n",
                    "dumpsys": "#!/bin/sh\necho '  mWakefulness=Awake'\n",
                    "logcat": (
                        "#!/bin/sh\n"
                        "echo '--------- beginning of events'\n"
                        "sleep 0.8; echo 'I/PowerManagerService( 1580): Going to sleep due to power_button (uid 1000)...'\n"
                        "sleep 0.8; echo 'I/PowerManagerService( 1580): Waking up from Asleep (uid=1000, reason=x)...'\n"
                        "sleep 0.8; echo 'I/screen_toggled( 1580): 0'\n"
                        "exec sleep 60\n"
                    ),
                }
                for name, body in stubs.items():
                    (bindir / name).write_text(body)
                    (bindir / name).chmod(0o755)
                env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                           DRAMLOCK_D=str(data), DRAMLOCK_NODE=str(node), DRAMLOCK_BOOT_DELAY="0",
                           DRAMLOCK_SCREEN_NODES=str(tdp / "no-panel-node"))
                proc = subprocess.Popen([shell, str(mod / "dramlock.sh")], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        start_new_session=True)
                seen = []
                try:
                    deadline = time.time() + 4.5
                    while time.time() < deadline:
                        v = (node / "max_freq").read_text().strip()
                        if v and (not seen or seen[-1] != v):
                            seen.append(v)
                        time.sleep(0.05)
                finally:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate(timeout=5)
                log = (data / "dram.log").read_text()
                self.assertEqual(
                    seen,
                    ["4266000000", "1866000000", "4266000000", "1866000000"],
                    log,
                )
                self.assertEqual((node / "governor").read_text().strip(), "userspace")
                self.assertEqual((data / "dram.orig").read_text().split()[0], "mtk-dvfsrc-net")
                self.assertIn("screen off (event)", log)
                self.assertIn("screen on (event)", log)

    def test_daemon_follows_panel_without_events(self):
        """logcat delivers nothing (the v14.1 failure): the panel check alone must switch both ways."""
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                tdp = pathlib.Path(td)
                node = fake_node(td)
                data = tdp / "fod"
                data.mkdir()
                mod = tdp / "mod"
                mod.mkdir()
                (mod / "dramlock.sh").write_text(read("dramlock.sh"))
                bindir = tdp / "bin"
                bindir.mkdir()
                wake = tdp / "wake"
                panel = tdp / "dpms"
                wake.write_text("Asleep\n")
                panel.write_text("Off\n")
                stubs = {
                    "getprop": "#!/bin/sh\necho 1\n",
                    "dumpsys": f"#!/bin/sh\necho \"  mWakefulness=$(cat {wake})\"\n",
                    "logcat": "#!/bin/sh\nexit 1\n",
                }
                for name, body in stubs.items():
                    (bindir / name).write_text(body)
                    (bindir / name).chmod(0o755)
                env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                           DRAMLOCK_D=str(data), DRAMLOCK_NODE=str(node), DRAMLOCK_BOOT_DELAY="0",
                           DRAMLOCK_SCREEN_NODES=str(panel))
                proc = subprocess.Popen([shell, str(mod / "dramlock.sh")], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        start_new_session=True)

                def wait_for(value, limit=3.0):
                    deadline = time.time() + limit
                    while time.time() < deadline:
                        if (node / "max_freq").read_text().strip() == value:
                            return time.time()
                        time.sleep(0.05)
                    self.fail(f"max_freq never became {value}: " + (data / "dram.log").read_text())

                try:
                    wait_for("1866000000")                 # boot: asleep -> half
                    t0 = time.time()
                    wake.write_text("Awake\n"); panel.write_text("On\n")
                    self.assertLess(wait_for("4266000000") - t0, 1.5)
                    self.assertEqual((node / "min_freq").read_text().strip(), "4266000000")
                    self.assertEqual((node / "userspace" / "set_freq").read_text().strip(), "4266000000")
                    t0 = time.time()
                    wake.write_text("Asleep\n"); panel.write_text("Off\n")
                    self.assertLess(wait_for("1866000000") - t0, 1.5)
                    # AOD: panel lit but framework Dozing -> confirmed back to half
                    wake.write_text("Dozing\n"); panel.write_text("On\n")
                    time.sleep(1.5)
                    self.assertEqual((node / "max_freq").read_text().strip(), "1866000000")
                finally:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate(timeout=5)
                log = (data / "dram.log").read_text()
                self.assertIn("screen on (panel)", log)
                self.assertIn("screen off (confirm)", log)

    def test_wiring(self):
        self.assertIn("dramlock.sh", read("service.sh"))
        customize = read("customize.sh")
        self.assertIn('cat > "$DATA/fod/dram.conf"', customize)
        self.assertIn("OFF_FREQ=half", customize)
        self.assertIn('"$DATA/service.d/lock_dram.sh"', customize)
        self.assertIn('"$f.disabled_by_x6886"', customize)
        self.assertIn("single_instance dramlock", read("dramlock.sh"))
        self.assertIn("dramlock.sh status", read("diag.sh"))
        self.assertIn("SCREEN_POLL=1", customize)
        self.assertNotIn("mkfifo", read("dramlock.sh"))
        self.assertIn("PowerManagerService:I", read("dramlock.sh"))
        self.assertIn('touch "$FASTF"', read("dramlock.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
