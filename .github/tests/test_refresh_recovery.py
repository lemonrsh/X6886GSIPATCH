#!/usr/bin/env python3
"""Wake/boot/override recovery with fake Android services, never a real phone.

Real shell processes, IPC timeouts and suspend-like gaps exercise the controller.
Software intervals below are test budgets, not guaranteed hardware latencies.
"""

import os
import pathlib
import signal
import tempfile
import time
import unittest

from test_display import FakeAndroid, HELPERS, modes
from test_fixes import SHELLS, marked_block, read, run_shell

RECOVERY = marked_block(
    read("refresh.sh"),
    "# --- refresh recovery helpers (host-tested in test_refresh_recovery.py) ---",
    "# --- end refresh recovery helpers ---",
)
CONFIGURE = "configure_modes() {" + read("refresh.sh").split("configure_modes() {", 1)[1].split("\nobserve() {", 1)[0]


class RecoveryHelperTests(unittest.TestCase):
    def test_power_edges_include_bridge_doze_and_early_framework_wake(self):
        cases = {
            "Waking up from Asleep due to android.policy:POWER": "on",
            "Waking up power group from Dozing": "on",
            "[SleepState: AWAKE] Screen is ON / active.": "on",
            "Going to sleep due to power button": "off",
            "Sleeping power group (groupId=0)": "off",
            "[SleepState: OFF] Screen reached fully sleep (Off).": "off",
            "[SleepState: DOZE] Screen reached Dozing/Doze (AOD).": "off",
            "Dozing...": "off",
            "Authentication FAILED": "",
        }
        for shell in SHELLS:
            for text, expected in cases.items():
                with self.subTest(shell=shell, text=text):
                    result = run_shell(shell, HELPERS + f"\nPATH=/no-tools; refresh_power_parse {text!r}; echo \"$REFRESH_POWER\"\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)

    def test_unavailable_fingerprint_dump_is_not_an_idle_session(self):
        for shell in SHELLS:
            for text in ["", "Can't find service: fingerprint", "Recent operations: FingerprintAuthenticationClient",
                         "Current operation: (unavailable)"]:
                with self.subTest(shell=shell, text=text):
                    result = run_shell(shell, HELPERS + f"\ndumpsys() {{ printf '%s\\n' {text!r}; }}\nrefresh_seed_session\n")
                    self.assertEqual(result.stdout.strip(), "-", result.stderr)

    def test_framework_wakefulness_fallback_distinguishes_doze_from_awake(self):
        for shell in SHELLS:
            for state, expected in [("Awake", "on"), ("Dreaming", "on"), ("Asleep", "off"),
                                    ("Dozing", "off"), ("Unknown", ""), ("Awakeish", "")]:
                with self.subTest(shell=shell, state=state):
                    result = run_shell(shell, HELPERS + f"\ndumpsys() {{ echo 'mWakefulness={state}'; }}\nrefresh_power_state\n")
                    self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_panel_read_is_builtin_and_unknown_is_not_screen_off(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                panel = pathlib.Path(td) / "dpms"
                block = HELPERS.replace("/sys/class/drm/card0-DSI-1/dpms", str(panel))
                block = block.replace("/sys/class/backlight", td + "/missing-backlight")
                block = block.replace("/sys/class/leds", td + "/missing-leds")
                result = run_shell(shell, block + f"""
set -eu
PATH=/no-external-tools
refresh_panel; [ "$PANEL" = unknown ]
for state in On on ON; do echo "$state" > {str(panel)!r}; refresh_panel; [ "$PANEL" = on ]; done
for state in Off off OFF Doze DozeSuspend; do echo "$state" > {str(panel)!r}; refresh_panel; [ "$PANEL" = off ]; done
echo garbage > {str(panel)!r}; refresh_panel; [ "$PANEL" = unknown ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_request_recovery_never_exhausts_and_backoff_is_bounded(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, HELPERS + "\n" + RECOVERY + f"""
set -eu
D={td!r}; ID=0; WANT=120; ATTEMPTS=0; REFRESH_NOW=100
refresh_now() {{ :; }}
refresh_exec() {{ echo call >> "$D/calls"; echo 'Result: Parcel(NULL)'; }}
for n in 1 2 3 4 5 6 7 8 9 10; do
  request_mode
  delay=$((NEXT_REQUEST-REFRESH_NOW))
  [ "$delay" -ge 10 ] && [ "$delay" -le 500 ]
  REFRESH_NOW=$NEXT_REQUEST
done
[ "$ATTEMPTS" = 6 ]
[ "$(wc -l < "$D/calls")" = 10 ]
[ "$REPLY" = empty ]
[ ! -f "$D/.refresh_applied" ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_fingerprint_seed_cannot_overwrite_a_newer_event_or_recent_cancel(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, RECOVERY + f"""
set -eu
D={td!r}; SESSIONF=$D/session; EPOCH=epoch; REFRESH_BOOT=boot; REFRESH_NOW=1000
SEED_AUTH=-; SEED_UNTIL=0; SEEDED=0; WANT=120
refresh_now() {{ :; }}
printf 'boot 30000 1 0 epoch 1 session_on 100\\n' > "$SESSIONF"
refresh_seed_session() {{
  printf 'boot 1800 0 0 epoch 2 session_off 1000\\n' > "$SESSIONF"
  echo 1
}}
seed_session
[ "$SEED_AUTH" = - ] && [ "$SESSION_KEY" = epoch-2 ]
# Even if cancellation preceded the dump, a briefly lagging HAL snapshot loses.
refresh_seed_session() {{ echo 1; }}
seed_session
[ "$SEED_AUTH" = - ]
# Once quiet, a real snapshot can recover a missed session-on event.
REFRESH_NOW=1200
seed_session
[ "$SEED_AUTH:$SEED_EVENT:$SEEDED" = 1:epoch-2:1 ]
# Missing/failed snapshots do not manufacture an idle client either.
refresh_seed_session() {{ echo -; }}
seed_session
[ "$SEED_AUTH:$SEED_EVENT:$SEEDED" = 1:epoch-2:1 ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalidation_rearms_request_verification_and_settings_from_uptime(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, RECOVERY + f"""
set -eu
D={td!r}; REFRESH_NOW=50000; TICK=4
APPLIED=120; ACK=old; FRAMEWORK_HZ=120; ATTEMPTS=6; WARNED=1
NEXT_REQUEST=999999; NEXT_VERIFY=999999; NEXT_SETTINGS=999999
echo stale > "$D/.refresh_applied"
invalidate 1
[ -z "$APPLIED$ACK$FRAMEWORK_HZ" ]
[ "$ATTEMPTS:$WARNED" = 0:0 ]
[ "$NEXT_REQUEST:$NEXT_VERIFY:$NEXT_SETTINGS" = 50000:50000:50000 ]
[ ! -f "$D/.refresh_applied" ]
# A pause inside an iteration invalidates an already-observed result as well.
NEXT_GAP_LOG=0; WAKE_UNTIL=0; APPLIED=120; ACK=old
log() {{ :; }}
recheck_gap iteration
[ -z "$APPLIED$ACK" ]
# Known slow/failed IPC must not reset a pending request's bounded backoff.
ATTEMPTS=6; NEXT_REQUEST=50500
recheck_gap iteration
[ "$ATTEMPTS:$NEXT_REQUEST:$WAKE_UNTIL" = 6:50500:0 ]
recheck_gap resume
[ "$ATTEMPTS:$NEXT_REQUEST:$WAKE_UNTIL" = 0:50000:50100 ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_transient_empty_discovery_keeps_known_pair_but_valid_no_120_clears_it(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, HELPERS + "\n" + RECOVERY + "\n" + CONFIGURE + f"""
set -eu
D={td!r}; REFRESH_BOOT=boot; REFRESH_NOW=100; RECONCILE_S=120
BASE_ID=1; FP_ID=0; BASE_HZ=144; LAST_MODES='1 0 144'
APPLIED=120; FRAMEWORK_HZ=120; ACK=old
refresh_now() {{ :; }}
log() {{ :; }}
dumpsys() {{ :; }}
configure_modes
[ "$BASE_ID:$FP_ID:$APPLIED:$NEXT_SCAN" = 1:0:120:200 ]
dumpsys() {{ printf '%s\\n' {modes(fp=None)!r}; }}
configure_modes
[ -z "$BASE_ID$FP_ID$APPLIED" ]
[ ! -f "$D/.refresh_ready" ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)


class WakeRecoveryTests(unittest.TestCase):
    def test_sleep_prearms_and_panel_wake_recovers_same_target_and_missing_auth_log(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, panel="On", power="Awake") as dev:
                dev.mode(3); dev.verified(144)
                dev.put("panel", "Off"); dev.mode(2); dev.verified(120)
                # Wake resets the physical mode behind the controller's cached 120.
                dev.put("mode", "3")
                dev.put("fingerprint", "Current operation: FingerprintAuthenticationClient")
                start = time.monotonic(); dev.put("panel", "On"); dev.mode(2)
                self.assertLess(time.monotonic() - start, 0.8)
                dev.verified(120)
                time.sleep(1.2)  # past the wake guard: active prompt must still hold 120
                self.assertEqual(dev.contents("mode"), "2")
                dev.put("fingerprint", "Current operation: null")
                dev.event("Authentication SUCCEEDED for fid 1"); dev.mode(3)
                dev.setting("peak_refresh_rate", "144")

    def test_doze_wake_log_rearms_when_panel_never_changes(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, panel="On", power="Awake") as dev:
                dev.mode(3); dev.verified(144)
                dev.event("[SleepState: DOZE] Screen reached Dozing/Doze (AOD).")
                dev.mode(2); dev.verified(120)
                dev.put("mode", "3")
                dev.event("Waking up from Dozing due to fingerprint")
                dev.mode(2); dev.verified(120)
                dev.mode(3)  # no active prompt, guard expires and normal 144 resumes
                self.assertIn("screen=on source=event", dev.contents("fod/refresh.log"))

    def test_bridge_screen_off_press_precedes_display_on_replay(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.verified(144)
                dev.event("SOFOD fake: sensor pressed while screen off -> KEY_WAKEUP, auto-capture after display on")
                dev.mode(2); dev.verified(120)
                dev.event("Watchdog: FOD touch timed out (1500ms) -> forcing HBM off")
                dev.mode(3)

    def test_more_than_three_failed_pins_recover_without_a_new_target(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.verified(144)
                before = len(dev.contents("requests").splitlines())
                dev.put("pin_ok", "0"); dev.put("press", "1")
                dev.wait(lambda: len(dev.contents("requests").splitlines()) >= before + 4)
                self.assertEqual(dev.contents("mode"), "3")
                self.assertFalse((dev.data / ".refresh_applied").exists())
                dev.put("pin_ok", "1")
                dev.mode(2); dev.verified(120)
                self.assertEqual(dev.contents("press"), "1")

    def test_repeated_external_overrides_do_not_exhaust_a_successful_target(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                for _ in range(4):
                    dev.put("mode", "3")
                    dev.mode(2); dev.verified(120)
                dev.put("press", "0"); dev.mode(3)

    def test_normal_144_is_also_observed_and_recovered_when_overridden(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.verified(144)
                dev.put("mode", "2")
                dev.wait(lambda: dev.contents("mode") == "3", limit=6)
                dev.verified(144)

    def test_override_repairs_live_votes_without_losing_saved_originals(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                dev.put("settings/system.0.min_refresh_rate", "144")
                dev.put("settings/system.0.peak_refresh_rate", "144")
                dev.put("mode", "3")
                dev.mode(2); dev.setting("min_refresh_rate", "120"); dev.setting("peak_refresh_rate", "120")
                self.assertEqual(dev.contents("fod/settings.system.0.min_refresh_rate.orig"), "null")
                dev.verified(120)
                dev.put("settings/system.0.min_refresh_rate", "144")
                dev.put("settings/system.0.peak_refresh_rate", "144")
                # With no physical override or target change, the live audit must repair votes.
                dev.wait(lambda: dev.contents("settings/system.0.peak_refresh_rate") == "120", limit=6)
                self.assertEqual(dev.contents("settings/system.0.min_refresh_rate"), "120")

    def test_new_fod_token_repins_immediately_even_if_target_is_already_120(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                dev.put("mode", "3")
                start = time.monotonic()
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(time.monotonic() - start, 0.8)
                self.assertEqual(dev.contents("mode"), "2")
                self.assertEqual(dev.contents("fod/.refresh_applied").split()[1:3], ["120", result.stdout.strip()])

    def test_mode_table_change_without_sf_restart_is_rediscovered_after_failures(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                dev.put("modes", modes(base=13, fp=12)); dev.put("mode", "13")
                dev.mode(12); dev.verified(120)
                dev.put("press", "0"); dev.mode(13)

    def test_suspend_like_gap_invalidates_cached_ack_even_without_panel_or_log_edges(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                os.kill(dev.proc.pid, signal.SIGSTOP)
                try:
                    dev.put("mode", "3")
                    time.sleep(1.15)
                finally:
                    os.kill(dev.proc.pid, signal.SIGCONT)
                start = time.monotonic(); dev.mode(2)
                self.assertLess(time.monotonic() - start, 0.8)
                dev.verified(120)
                self.assertIn("resume/loop gap", dev.contents("fod/refresh.log"))

    def test_early_boot_waits_for_display_modes_without_waiting_for_boot_completed(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, boot="0", display_modes="") as dev:
                dev.wait(lambda: "leaving display policy to Android" in dev.contents("fod/refresh.log"))
                self.assertEqual(dev.contents("requests"), "")
                dev.put("modes", modes())
                dev.mode(2); dev.verified(120)
                self.assertEqual(set(dev.contents("requests").splitlines()), {"2"})
                self.assertEqual(dev.contents("votes"), "")
                dev.put("boot", "1"); dev.mode(3)

    def test_cold_boot_simulation_rejects_old_holds_and_rediscovers_ids_before_boot_completed(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.verified(144)
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                old_token = result.stdout.strip(); dev.mode(2); dev.verified(120)
                os.killpg(dev.proc.pid, signal.SIGKILL); dev.proc.communicate(timeout=3)
                dev.put("boot_id", "boot-two"); dev.put("boot", "0")
                dev.put("modes", modes(base=13, fp=12))
                dev.proc = dev.start("refresh.sh")
                dev.mode(12); dev.verified(120)
                self.assertEqual(dev.contents("fod/.refresh_applied").split(), ["boot-two", "120", "-", "-"])
                self.assertNotIn(old_token, dev.contents("fod/.refresh_applied"))
                dev.put("boot", "1"); dev.mode(13); dev.verified(144)
                dev.setting("min_refresh_rate", "144")

    def test_terminal_edge_bounce_does_not_flash_144_between_fod_attempts(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2); dev.verified(120)
                before = dev.contents("requests")
                dev.put("press", "0"); time.sleep(0.08); dev.put("press", "1")
                time.sleep(0.25)
                self.assertEqual(dev.contents("mode"), "2")
                self.assertEqual(dev.contents("requests"), before)

    def test_hung_mode_cli_is_bounded_and_fod_wait_still_fails_open(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.verified(144); dev.put("pin_hang", "1")
                start = time.monotonic()
                result = dev.client('refresh_fod_begin hbm; echo ok')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertLess(time.monotonic() - start, 0.8)
                dev.wait(lambda: "exit=124" in dev.contents("fod/refresh_last_reply.txt"))
                self.assertFalse((dev.data / ".refresh_applied").exists())
                (dev.root / "pin_hang").unlink()
                dev.mode(2); dev.verified(120)
                self.assertIsNone(dev.proc.poll())


if __name__ == "__main__":
    unittest.main(verbosity=2)
