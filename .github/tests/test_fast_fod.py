#!/usr/bin/env python3
"""Fast 144 <-> 120 Hz switching and one-touch screen-off FOD (fake Android only).

These prove ordering, bounded waits and that slow helpers are off the FOD path.
Millisecond budgets are host test limits, not measured phone/panel latencies.
"""

import os
import signal
import subprocess
import tempfile
import time
import unittest

from test_display import FakeAndroid
from test_fixes import SHELLS, marked_block, read, run_shell

HANDSHAKE = read("refresh_fod.sh")
LIB = read("lib.sh")
REPLAY = marked_block(
    read("sofod_touch.sh"),
    "# --- fast replay helpers (host-tested in test_fast_fod.py) ---",
    "# --- end fast replay helpers ---",
)
SWITCH = marked_block(
    read("refresh.sh"),
    "# --- fast switch helpers (host-tested in test_fast_fod.py) ---",
    "# --- end fast switch helpers ---",
)


def boot_prelude(td):
    """refresh_fod.sh with boot_id redirected to a temp file."""
    boot = os.path.join(td, "boot_id")
    with open(boot, "w") as f:
        f.write("boot-one\n")
    return HANDSHAKE.replace("/proc/sys/kernel/random/boot_id", boot) + f"\nD={td!r}\nrefresh_boot\n"


class HandshakeTests(unittest.TestCase):
    def test_hbm_reuses_a_live_post_wake_sofod_ack_without_waiting(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = boot_prelude(td) + """
printf '%s %s\\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
refresh_now
printf '%s %s so-token\\n' "$REFRESH_BOOT" "$((REFRESH_NOW + 800))" > "$D/.refresh_hold.sofod"
printf '%s 120 - so-token\\n' "$REFRESH_BOOT" > "$D/.refresh_applied"
refresh_fod_begin hbm
echo ok
"""
                start = time.monotonic()
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertLess(time.monotonic() - start, 0.2)

    def test_released_expired_or_other_sofod_tokens_are_not_reused(self):
        cases = {
            "released": "",
            "expired": "printf '%s %s so-token\\n' \"$REFRESH_BOOT\" \"$((REFRESH_NOW - 1))\" > \"$D/.refresh_hold.sofod\"",
            "newer": "printf '%s %s new-token\\n' \"$REFRESH_BOOT\" \"$((REFRESH_NOW + 800))\" > \"$D/.refresh_hold.sofod\"",
            "other boot": "printf 'boot-zero %s so-token\\n' \"$((REFRESH_NOW + 800))\" > \"$D/.refresh_hold.sofod\"",
        }
        for shell in SHELLS:
            for name, hold in cases.items():
                with self.subTest(shell=shell, case=name), tempfile.TemporaryDirectory() as td:
                    script = boot_prelude(td) + f"""
printf '%s %s\\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
refresh_now
{hold}
printf '%s 120 - so-token\\n' "$REFRESH_BOOT" > "$D/.refresh_applied"
refresh_fod_begin hbm
echo ok
"""
                    start = time.monotonic()
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertGreater(time.monotonic() - start, 0.25)  # waited, then failed open

    def test_sofod_and_144_acks_are_never_reused(self):
        for shell in SHELLS:
            for ack in ["{boot} 144 - so-token", "{boot} 120 so-token -"]:
                with self.subTest(shell=shell, ack=ack), tempfile.TemporaryDirectory() as td:
                    line = ack.format(boot="$REFRESH_BOOT")
                    script = boot_prelude(td) + f"""
printf '%s %s\\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
refresh_now
printf '%s %s so-token\\n' "$REFRESH_BOOT" "$((REFRESH_NOW + 800))" > "$D/.refresh_hold.sofod"
echo "{line}" > "$D/.refresh_applied"
refresh_fod_begin hbm
echo ok
"""
                    start = time.monotonic()
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertGreater(time.monotonic() - start, 0.25)

    def test_wait_budget_starts_at_request_so_it_overlaps_other_work(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = boot_prelude(td) + """
printf '%s %s\\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
refresh_fod_request sofod
[ -n "$REFRESH_FOD_TOKEN" ]
sleep 0.2
refresh_fod_wait sofod
echo ok
"""
                start = time.monotonic()
                result = run_shell(shell, script)
                elapsed = time.monotonic() - start
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertGreater(elapsed, 0.25)
                self.assertLess(elapsed, 0.45)  # max(0.2, 0.3), not 0.2 + 0.3

    def test_poke_only_signals_the_exact_controller_identity(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                victim = subprocess.Popen(["sleep", "30"])
                try:
                    # Unrelated live PID, wrong/missing start-time stamp: never signalled.
                    for stamp in ["1", "", "-"]:
                        script = LIB + "\n" + boot_prelude(td) + f"""
printf '%s %s %s\\n' "$REFRESH_BOOT" {victim.pid} {stamp!r} > "$D/.refresh_ready"
refresh_fod_request hbm
echo ok
"""
                        result = run_shell(shell, script)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        time.sleep(0.05)
                        self.assertIsNone(victim.poll(), stamp)
                finally:
                    victim.kill(); victim.wait()
                # The matching identity (a process with a USR1 trap) is poked.
                mark = os.path.join(td, "poked")
                target = subprocess.Popen([shell, "-c", f"trap 'echo > {mark!s}' USR1; i=0; while [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done"])
                try:
                    time.sleep(0.2)
                    script = LIB + "\n" + boot_prelude(td) + f"""
process_stamp {target.pid}
printf '%s %s %s\\n' "$REFRESH_BOOT" {target.pid} "$PROC_STAMP" > "$D/.refresh_ready"
refresh_fod_request hbm
"""
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    deadline = time.monotonic() + 2
                    while not os.path.exists(mark) and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(os.path.exists(mark))
                    self.assertIsNone(target.poll())
                finally:
                    target.kill(); target.wait()


class ReplayHelperTests(unittest.TestCase):
    def test_held_coordinates_are_parsed_without_forks(self):
        cases = {
            "display on, finger still held at (540, 2100)": "540 2100",
            "display on, finger still held at (540,2100) extra": "540 2100",
            "display on, finger still held at (540,   7)": "540 7",
            "display on, finger still held at (-5, 2100)": "",
            "display on, finger still held at (540)": "",
            "display on, finger still held at (, 2100)": "",
            "display on, finger still held at (5a, 2100)": "",
            "something else": "",
        }
        for shell in SHELLS:
            for line, expected in cases.items():
                with self.subTest(shell=shell, line=line):
                    script = REPLAY + f"\nPATH=/no-tools\nif held_xy {line!r}; then echo \"$HX $HY\"; else echo; fi\n"
                    result = run_shell(shell, script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)

    def test_panel_wait_is_bounded_by_uptime(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                panel = os.path.join(td, "dpms")
                with open(panel, "w") as f:
                    f.write("Off\n")
                script = HANDSHAKE + "\n" + REPLAY + f"""
DPMS={panel!r}; PANEL_WAIT_MS=200; PANEL_POLL=0.01
dpms_on() {{ s=""; {{ IFS= read -r s < "$DPMS"; }} 2>/dev/null; case "$s" in On|on|ON) return 0;; *) return 1;; esac; }}
if panel_wait; then echo on; else echo timeout; fi
( sleep 0.1; echo On > "$DPMS" ) &
PANEL_WAIT_MS=2000
if panel_wait; then echo on; else echo timeout; fi
wait
"""
                start = time.monotonic()
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.split(), ["timeout", "on"])
                self.assertLess(time.monotonic() - start, 1.0)

    def test_replay_logs_after_contact_and_handshake_overlaps_delay(self):
        refire = read("sofod_touch.sh").split("refire() {", 1)[1]
        down = refire.index('if ! touch_down "$PX" "$PY"')
        self.assertGreater(refire.index('log "touch replay attempt'), down)
        self.assertGreater(refire.index('log "panel state='), down)
        self.assertNotIn("$(find_dev)", refire)
        self.assertLess(refire.index('sleep "$DELAY"'), refire.index("refresh_fod_wait sofod"))
        self.assertNotIn("sed -n", read("sofod_touch.sh"))


class SwitchHelperTests(unittest.TestCase):
    def test_nap_is_interrupted_by_usr1_and_reaps_its_child(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                script = "trap ':' USR1\n" + SWITCH + """
( sleep 0.2; kill -USR1 $$ ) &
start=$(date +%s%N)
refresh_nap 3
end=$(date +%s%N)
echo $(( (end - start) / 1000000 ))
"""
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(int(result.stdout.split()[-1]), 1500)

    def test_settings_worker_is_async_and_reaped(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = SWITCH + f"""
D={td!r}; SET_PID=""; SET_RC=$D/.rc; WANT=120; USER_ID=0; NEXT_SETTINGS=0
REFRESH_NOW=0
refresh_now() {{ REFRESH_NOW=$((REFRESH_NOW+1)); }}
refresh_framework() {{ sleep 0.4; echo "$1 $2" > "$D/votes"; }}
settings_start 120 0
settings_poll && exit 3            # still running; caller is not blocked
[ ! -f "$D/votes" ]
i=0; while ! settings_poll; do sleep 0.05; i=$((i+1)); [ $i -lt 100 ] || exit 4; done
[ "$(cat "$D/votes")" = "120 0" ]
[ "$FRAMEWORK_HZ" = 120 ] && [ -z "$SET_PID" ]
# A re-audit requested while in flight (wake/target change) is preserved.
settings_start 120 0; NEXT_SETTINGS=5
i=0; while ! settings_poll; do sleep 0.05; i=$((i+1)); [ $i -lt 100 ] || exit 5; done
[ "$NEXT_SETTINGS" = 5 ]
echo ok
"""
                start = time.monotonic()
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")


class FastControllerTests(unittest.TestCase):
    def slow_settings(self, dev, seconds):
        stub = dev.bin / "settings"
        text = stub.read_text().replace("#!/bin/sh\n", f"#!/bin/sh\nsleep {seconds}\n", 1)
        stub.write_text(text)

    def test_new_hold_at_verified_120_is_reobserved_without_a_new_pin(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.verified(120)
                time.sleep(0.2)
                requests = dev.contents("requests")
                scans = dev.contents("scans").count("scan")
                start = time.monotonic()
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                token = result.stdout.strip()
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:3] == ["120", token])
                self.assertLess(time.monotonic() - start, 0.5)
                self.assertEqual(dev.contents("requests"), requests)       # no redundant Binder pin
                self.assertGreater(dev.contents("scans").count("scan"), scans)  # but a fresh observation

    def test_slow_settings_cli_never_delays_the_pin_or_ack(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.setting("min_refresh_rate", "144")
                self.slow_settings(dev, 1.5)
                time.sleep(0.1)
                start = time.monotonic()
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                token = result.stdout.strip()
                dev.mode(2)
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:3] == ["120", token])
                self.assertLess(time.monotonic() - start, 0.6)
                dev.client(f"refresh_fod_end hbm '{token}'")
                start = time.monotonic(); dev.mode(3)
                self.assertLess(time.monotonic() - start, 0.6)     # 144 returns while votes still run
                dev.setting("min_refresh_rate", "144")             # votes still converge later
                dev.setting("peak_refresh_rate", "144")
                self.assertNotIn("iteration", dev.contents("fod/refresh.log"))

    def test_screen_off_fod_hbm_reuses_post_wake_sofod_ack(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, panel="On", power="Awake") as dev:
                dev.mode(3)
                dev.put("panel", "Off"); dev.mode(2)               # screen-off pre-arm
                dev.event("sensor pressed while screen off")
                first = dev.client('refresh_fod_request sofod; echo "$REFRESH_FOD_TOKEN"').stdout.strip()
                dev.put("panel", "On")
                result = dev.client('refresh_fod_begin sofod; echo "$REFRESH_FOD_TOKEN"')
                so_token = result.stdout.strip()
                self.assertNotEqual(first, so_token)
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:4:2] == ["120", so_token])
                start = time.monotonic()
                result = dev.client('refresh_fod_begin hbm; echo ok')
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertLess(time.monotonic() - start, 0.2)
                self.assertEqual(dev.contents("mode"), "2")

    def test_usr1_storm_never_kills_or_stalls_the_controller(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.wait(lambda: len(dev.contents("fod/.refresh_ready").split()) == 3)
                for _ in range(150):
                    os.kill(dev.proc.pid, signal.SIGUSR1)
                    time.sleep(0.002)
                self.assertIsNone(dev.proc.poll())
                dev.put("press", "1"); dev.mode(2)
                dev.put("press", "0"); dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.event("Authentication SUCCEEDED for fid 1"); dev.mode(3)

    def test_stop_during_settings_worker_leaves_no_worker_or_ack(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.setting("min_refresh_rate", "144")
                self.slow_settings(dev, 3)
                dev.put("press", "1"); dev.mode(2)
                time.sleep(0.2)
                os.kill(dev.proc.pid, signal.SIGTERM); os.kill(dev.proc.pid, signal.SIGTERM)
                dev.proc.communicate(timeout=5)
                for name in [".refresh.pid", ".refresh_applied", ".refresh_ready", ".refresh_settings_rc"]:
                    self.assertFalse((dev.data / name).exists(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
