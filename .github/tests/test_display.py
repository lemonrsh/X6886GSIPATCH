#!/usr/bin/env python3
"""0.4x animations + 144/120 Hz regressions. All Android services are fake.

No test writes real /data, sysfs, input, or device settings. These tests prove
ordering/state handling, not physical panel timing or on-device FOD success.
"""

import os
import pathlib
import signal
import subprocess
import tempfile
import time
import unittest

from test_fixes import REPO, SHELLS, marked_block, read, run_shell

HELPERS = marked_block(
    read("refresh.sh"),
    "# --- refresh helpers (regression-tested by .github/tests/test_fixes.py) ---",
    "# --- end refresh helpers ---",
)


def modes(base=3, fp=2, base_group=0, fp_group=0, base_res="1080x2400", fp_res="1080x2400"):
    return (
        "Display 123:\n  connectionType=Internal\n"
        "  {id=0, hwcId=0, resolution=1080x2400, vsyncRate=60.00 Hz, group=0}\n"
        + (f"  {{id={fp}, hwcId=2, resolution={fp_res}, vsyncRate=119.88 Hz, group={fp_group}}}\n" if fp is not None else "")
        + (f"  {{id={base}, hwcId=3, resolution={base_res}, vsyncRate=143.88 Hz, group={base_group}}}\n" if base is not None else "")
    )


class RefreshHelperTests(unittest.TestCase):
    def parse(self, text, expected):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = run_shell(shell, HELPERS + "\nrefresh_modes <<'MODES'\n" + text + "MODES\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_resolves_real_mode_ids_and_fractional_rates(self):
        self.parse(modes(base=27, fp=15), "27 15 144")

    def test_mode_zero_is_valid(self):
        self.parse(modes(base=0, fp=1).replace("  {id=0, hwcId=0, resolution=1080x2400, vsyncRate=60.00 Hz, group=0}\n", ""), "0 1 144")

    def test_old_dump_without_group(self):
        self.parse(modes().replace(", group=0", ""), "3 2 144")

    def test_missing_144_uses_120(self):
        self.parse(modes(base=None), "2 2 120")

    def test_missing_120_does_not_guess_an_id(self):
        self.parse(modes(fp=None), "")

    def test_mismatched_group_or_resolution_does_not_modeset(self):
        self.parse(modes(base_group=1), "2 2 120")
        self.parse(modes(base_res="720x1600"), "2 2 120")

    def test_external_display_modes_are_not_used(self):
        self.parse(modes(base=None) + "Display 456:\n  connectionType=External\n"
                   "  {id=99, hwcId=1, resolution=1080x2400, vsyncRate=144.00 Hz, group=0}\n", "2 2 120")
        self.parse("Display 456:\n  connectionType=External\n"
                   "  {id=99, hwcId=1, resolution=1080x2400, vsyncRate=144.00 Hz, group=0}\n"
                   + modes(), "3 2 144")

    def test_legacy_flat_dump(self):
        self.parse(modes().replace("Display 123:\n  connectionType=Internal\n", ""), "3 2 144")

    def test_real_device_dump_selects_fod_id_zero_and_observes_actual_rates(self):
        text = (REPO / ".github/tests/fixtures/x6886-sf-displays.txt").read_text()
        self.parse(text, "1 0 144")
        for shell in SHELLS:
            result = run_shell(shell, HELPERS + "\nrefresh_active <<'MODES'\n" + text + "MODES\n")
            self.assertEqual(result.stdout.strip(), "1 144 144", result.stderr)

    def test_binder_reply_classification_does_not_imply_verification(self):
        cases = [("0", "Result: Parcel(NULL)", "empty"),
                 ("0", "Result: Parcel(    )", "empty"),
                 ("0", "Result: Parcel(00000000)", "zero"),
                 ("0", "Result: Parcel(ffffffff)", "rejected"),
                 ("1", "Result: Parcel(NULL)", "error")]
        for shell in SHELLS:
            for rc, reply, expected in cases:
                result = run_shell(shell, HELPERS + f"\nrefresh_reply {rc} '{reply}'\n")
                self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_auth_enrolment_cancel_success_and_touch_events(self):
        cases = {
            "ISession::authenticate called (op_id=0x0)": "session_on",
            "ISession::enroll called (challenge=0x5)": "session_on",
            "ISession::detectInteraction called": "session_on",
            "onUiReady": "session_on",
            "ICancellationSignal::cancel invoked": "session_off",
            "ISession::close called": "session_off",
            "Authentication SUCCEEDED for fid 1": "session_off",
            "Enrollment completed successfully (final fid 1)": "session_off",
            "onPointerDownWithContext at (500, 2000)": "touch_on",
            "SOFOD fake: display on, finger still held at (500,2000)": "touch_on",
            "onPointerUpWithContext": "touch_off",
            "onPointerCancelWithContext": "touch_off",
            "Watchdog: FOD touch timed out (1500ms) -> forcing HBM off": "touch_off",
            "Authentication FAILED (unrecognized finger, keeping session active for next touch)": "",
            "IFingerprint::getSensorProps called": "",
        }
        for shell in SHELLS:
            for line, expected in cases.items():
                with self.subTest(shell=shell, line=line):
                    result = run_shell(shell, HELPERS + f"\nrefresh_event '{line}'\n")
                    self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_framework_votes_are_ordered(self):
        script = HELPERS + """
module_setting_set() { echo "$3=$4"; }
refresh_framework 120 0
refresh_framework 144 10
"""
        for shell in SHELLS:
            result = run_shell(shell, script)
            self.assertEqual(result.stdout.splitlines(), [
                "min_refresh_rate=120", "peak_refresh_rate=120",
                "peak_refresh_rate=144", "min_refresh_rate=144",
            ], result.stderr)

    def test_session_seed_ignores_historical_clients(self):
        for shell in SHELLS:
            for current, expected in [("null", "0"), ("FingerprintAuthenticationClient", "1"),
                                      ("FingerprintEnrollClient", "1"), ("FingerprintDetectClient", "1")]:
                script = HELPERS + f"""
dumpsys() {{
  echo 'Current operation: {current}'
  echo 'Recent operations: FingerprintAuthenticationClient'
}}
refresh_seed_session
"""
                result = run_shell(shell, script)
                self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_fod_hooks_precede_hbm_and_replay_and_release_after_hbm(self):
        hbm = marked_block(read("fod_service.sh"),
                           "# --- HBM safety helpers (regression-tested by .github/tests/test_fixes.py) ---",
                           "# --- end HBM safety helpers ---")
        with tempfile.TemporaryDirectory() as td:
            script = f"""
set -eu
D={td!r}; NODE=$D/node; REFRESH_FOD_TOKEN=token
hot() {{ return 1; }}
log() {{ :; }}
refresh_fod_begin() {{ [ "$(cat "$NODE")" = 0 ]; }}
refresh_fod_end() {{ [ "$(cat "$NODE")" = 0 ]; }}
{hbm}
hbm_start_watchdog() {{ :; }}
echo 0 > "$NODE"
hbm_on
[ "$(cat "$NODE")" = 1 ]
hbm_off
[ "$(cat "$NODE")" = 0 ]
"""
            for shell in SHELLS:
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)
        sofod = read("sofod_touch.sh").split("refire() {", 1)[1]
        self.assertLess(sofod.index("refresh_fod_begin sofod"), sofod.index("touch_down"))
        self.assertLess(sofod.index("touch_up\n    log \"synthetic touch released\""), sofod.index("refresh_fod_end sofod"))

    def test_boot_scoped_leases_expire_and_stale_release_cannot_clear_new_token(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = read("refresh_fod.sh") + f"""
set -eu
D={td!r}; REFRESH_BOOT=this-boot; REFRESH_NOW=500
printf 'old-boot 900 old-token\\n' > "$D/.refresh_hold.hbm"
refresh_lease hbm
[ "$REFRESH_LEASE" = - ]
printf 'this-boot 400 old-token\\n' > "$D/.refresh_hold.hbm"
refresh_lease hbm
[ "$REFRESH_LEASE" = - ]
printf 'this-boot 900 new-token\\n' > "$D/.refresh_hold.hbm"
refresh_lease hbm
[ "$REFRESH_LEASE" = new-token ]
refresh_fod_end hbm old-token
[ -f "$D/.refresh_hold.hbm" ]
refresh_fod_end hbm new-token
[ ! -f "$D/.refresh_hold.hbm" ]
"""
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_old_120_ack_is_not_accepted_for_a_new_press_and_wait_is_bounded(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = read("refresh_fod.sh") + f"""
D={td!r}
refresh_boot
printf '%s %s\\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
printf '%s 120 old-token -\\n' "$REFRESH_BOOT" > "$D/.refresh_applied"
refresh_fod_begin hbm
echo ok
"""
                start = time.monotonic()
                result = run_shell(shell, script)
                elapsed = time.monotonic() - start
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertGreater(elapsed, 0.25)
                self.assertLess(elapsed, 1.5)

    def test_missing_controller_does_not_delay_or_fail_capture(self):
        with tempfile.TemporaryDirectory() as td:
            for shell in SHELLS:
                start = time.monotonic()
                result = run_shell(shell, read("refresh_fod.sh") + f"\nD={td!r}; refresh_fod_begin hbm; echo ok\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "ok")
                self.assertLess(time.monotonic() - start, 0.25)


class SettingsStateTests(unittest.TestCase):
    def test_snapshots_are_not_overwritten_and_uninstall_is_reversible(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = read("settings_state.sh") + f"""
set -eu
D={td!r}; cur=0.75
settings() {{
  if [ "$1" = --user ]; then shift 2; fi
  case "$1" in get) echo "$cur" ;; put) cur=$4 ;; delete) cur=null ;; esac
}}
module_setting_set global 0 animator_duration_scale 0.4
[ "$cur" = 0.4 ]
module_setting_set global 0 animator_duration_scale 0.4
[ "$(cat "$D/settings.global.0.animator_duration_scale.orig")" = 0.75 ]
module_settings_restore
[ "$cur" = 0.75 ]
[ ! -f "$D/settings.global.0.animator_duration_scale.orig" ]
cur=null
module_setting_set system 10 min_refresh_rate 144
module_setting_set system 10 min_refresh_rate 120
[ "$(cat "$D/settings.system.10.min_refresh_rate.orig")" = null ]
module_settings_restore
[ "$cur" = null ]
"""
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_restore_does_not_clobber_a_later_manual_change(self):
        with tempfile.TemporaryDirectory() as td:
            for shell in SHELLS:
                script = read("settings_state.sh") + f"""
set -eu
D={td!r}; cur=1
settings() {{ case "$1" in get) echo "$cur" ;; put) cur=$4 ;; esac; }}
module_setting_set global 0 window_animation_scale 0.4
cur=0.5
module_settings_restore
[ "$cur" = 0.5 ]
"""
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_get_or_put_does_not_invent_an_original_or_mark_success(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                script = read("settings_state.sh") + f"""
set -eu
D={td!r}
settings() {{ echo 'provider unavailable'; return 1; }}
if module_setting_set global 0 window_animation_scale 0.4; then exit 1; fi
[ ! -f "$D/settings.global.0.window_animation_scale.orig" ]
settings() {{ [ "$1" = get ] && {{ echo 1; return 0; }}; return 1; }}
if module_setting_set global 0 window_animation_scale 0.4; then exit 1; fi
[ "$(cat "$D/settings.global.0.window_animation_scale.orig")" = 1 ]
[ ! -f "$D/settings.global.0.window_animation_scale.last" ]
"""
                result = run_shell(shell, script)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_settings_names_and_error_text_are_rejected(self):
        for shell in SHELLS:
            script = read("settings_state.sh") + """
set -eu
settings() { exit 99; }
if module_setting_set secure 0 arbitrary 0.4; then exit 1; fi
if module_setting_set system current min_refresh_rate 144; then exit 1; fi
if module_setting_value 'Error: unavailable'; then exit 1; fi
if module_setting_value ''; then exit 1; fi
if module_setting_value '.'; then exit 1; fi
if module_setting_value '1.2.3'; then exit 1; fi
"""
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)


class FakeAndroid:
    """A complete script instance with file-backed Android command stubs."""

    def __init__(self, shell, display_modes=None, boot="1", pin_ok=True, seed=False, reply="zero", panel=None, power="Unknown"):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.mod = self.root / "mod"; self.mod.mkdir()
        self.data = self.root / "fod"; self.data.mkdir()
        self.bin = self.root / "bin"; self.bin.mkdir()
        self.settings = self.root / "settings"; self.settings.mkdir()
        self.shell = shell
        for name in ["refresh.sh", "refresh_supervisor.sh", "refresh_fod.sh", "settings_state.sh", "animations.sh", "lib.sh", "uninstall.sh", "diag.sh", "module.prop"]:
            text = read(name).replace("/data/adb/fod", str(self.data))
            text = text.replace("/sys/kernel/tran_display/lcm_hbm_state", str(self.root / "hbm"))
            text = text.replace("/sys/class/drm/card0-DSI-1/dpms", str(self.root / "panel"))
            text = text.replace("/proc/sys/kernel/random/boot_id", str(self.root / "boot_id"))
            (self.mod / name).write_text(text)
        for name, value in {"press": "0", "boot": boot, "user": "0", "pin_ok": "1" if pin_ok else "0", "reply": reply,
                            "modes": modes() if display_modes is None else display_modes,
                            "fingerprint": "Current operation: FingerprintAuthenticationClient" if seed else "Current operation: null",
                            "boot_id": "boot-one", "power": f"mWakefulness={power}"}.items():
            self.put(name, value)
        if panel is not None:
            self.put("panel", panel)
        self.events = self.root / "events"
        os.mkfifo(self.events)
        self.event_fd = os.open(self.events, os.O_RDWR | os.O_NONBLOCK)
        stubs = {
            "getprop": '''#!/bin/sh
case "$1" in sys.boot_completed) cat "$TESTROOT/boot" ;; sys.phh.oplus.fppress) cat "$TESTROOT/press" ;; esac
''',
            "pidof": '''#!/bin/sh
case "$1" in surfaceflinger) cat "$TESTROOT/sfpid" ;; *) cat "$TESTROOT/halpid" ;; esac
''',
            "dumpsys": '''#!/bin/sh
if [ "$1" = -t ]; then shift 2; fi
case "$1" in
  SurfaceFlinger)
    echo scan >> "$TESTROOT/scans"
    id=$(cat "$TESTROOT/mode" 2>/dev/null)
    [ -f "$TESTROOT/observed_mode" ] && id=$(cat "$TESTROOT/observed_mode")
    if [ -z "$id" ]; then id=0; fi
    render=$(cat "$TESTROOT/render_override" 2>/dev/null)
    awk -v id="$id" -v render="$render" '
      /activeMode=/ || /renderRate=/ { next }
      { print }
      /\{id=/ {
        line=$0; sub(/.*\{id=/,"",line); sub(/,.*/,"",line)
        if (line == id) {
          active=$0; sub(/^[^{]*/,"",active)
          rate=$0; sub(/.*vsyncRate=/,"",rate); sub(/ Hz.*/,"",rate)
        }
      }
      END { if (active != "") { print "    activeMode=" active; print "    renderRate=" (render != "" ? render : rate) " Hz" } }
    ' "$TESTROOT/modes"
    ;;

  fingerprint) cat "$TESTROOT/fingerprint" ;;
  power) cat "$TESTROOT/power" ;;
esac
''',
            "cmd": '#!/bin/sh\ncat "$TESTROOT/user"\n',
            "renice": '#!/bin/sh\nexit 0\n',
            "service": '''#!/bin/sh
printf '%s\\n' "$5" >> "$TESTROOT/requests"
[ ! -f "$TESTROOT/pin_hang" ] || exec sleep 30
if [ "$(cat "$TESTROOT/pin_ok")" = 1 ]; then
  printf '%s\\n' "$5" > "$TESTROOT/mode"
  printf '%s\\n' "$5" >> "$TESTROOT/calls"
  case "$(cat "$TESTROOT/reply")" in
    empty) echo 'Result: Parcel(NULL)' ;;
    blank) echo 'Result: Parcel(    )' ;;
    *) echo "Result: Parcel(00000000 '....')" ;;
  esac
else
  echo "Result: Parcel(ffffffff '....')"
fi
''',
            "settings": '''#!/bin/sh
[ -f "$TESTROOT/settings_down" ] && exit 1
user=0
if [ "$1" = --user ]; then user=$2; shift 2; fi
[ "$user" = current ] && user=$(cat "$TESTROOT/user")
op=$1; ns=$2; key=$3; value=$4
f=$TESTROOT/settings/$ns.$user.$key
case "$op" in
  get) if [ -f "$f" ]; then cat "$f"; else echo null; fi ;;
  put) printf '%s\\n' "$value" > "$f"; echo "$user $key $value" >> "$TESTROOT/votes" ;;
  delete) rm -f "$f" ;;
esac
''',
            "logcat": '''#!/usr/bin/python3
import os
with open(os.environ["TESTROOT"] + "/events") as stream:
    for line in stream:
        print(line, end="", flush=True)
''',
        }
        for name, body in stubs.items():
            file = self.bin / name; file.write_text(body); file.chmod(0o755)
        import shutil
        (self.bin / "sh").symlink_to(shutil.which(shell) or shell)
        self.env = dict(os.environ, TESTROOT=str(self.root), FODDATA=str(self.root),
                        PATH=f"{self.bin}:{os.environ['PATH']}")
        self.sf = subprocess.Popen(["sleep", "60"])
        self.hal = subprocess.Popen(["sleep", "60"])
        self.put("sfpid", str(self.sf.pid)); self.put("halpid", str(self.hal.pid))
        self.procs = []
        self.proc = self.start("refresh.sh")

    def put(self, name, value):
        file = self.root / name
        tmp = file.with_name(file.name + ".new")
        tmp.write_text(str(value) + "\n"); tmp.replace(file)

    def start(self, script):
        proc = subprocess.Popen([self.shell, str(self.mod / script)], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.procs.append(proc)
        return proc

    def contents(self, name):
        try:
            return (self.root / name).read_text().strip()
        except FileNotFoundError:
            return ""

    def wait(self, condition, limit=3, check_controller=True):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            if condition():
                return
            if check_controller and self.proc.poll() is not None:
                raise AssertionError(f"controller exited: {self.proc.returncode}; {self.proc.communicate()}")
            time.sleep(0.01)
        raise AssertionError("timed out: " + self.contents("fod/refresh.log"))

    def mode(self, value):
        self.wait(lambda: self.contents("mode") == str(value))

    def verified(self, hz, limit=3):
        self.wait(lambda: self.contents("fod/.refresh_applied").split()[1:2] == [str(hz)], limit=limit)

    def event(self, text):
        os.write(self.event_fd, ("I/oplus_udfps_transsion: " + text + "\n").encode())

    def setting(self, key, value, user=0, ns="system"):
        self.wait(lambda: self.contents(f"settings/{ns}.{user}.{key}") == value)

    def client(self, script):
        return run_shell(self.shell, f"D={str(self.data)!r}\n. {str(self.mod / 'refresh_fod.sh')!r}\n" + script,
                         env=self.env)

    def close(self):
        for proc in self.procs:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate(timeout=5)
        for proc in [self.sf, self.hal]:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        os.close(self.event_fd)
        self.tmp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class DisplayDaemonTests(unittest.TestCase):
    def test_property_fallback_is_fast_and_idle_does_not_spam_binder(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.setting("min_refresh_rate", "144")
                dev.put("press", "1")
                start = time.monotonic(); dev.mode(2)
                self.assertLess(time.monotonic() - start, 0.8)
                dev.setting("min_refresh_rate", "120")
                dev.put("press", "0"); dev.mode(3)
                dev.setting("peak_refresh_rate", "144")
                calls = dev.contents("calls")
                time.sleep(0.3)
                self.assertEqual(dev.contents("calls"), calls)

    def test_auth_and_enrolment_stay_120_between_touches_then_return_144(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.event("onPointerDown at (500,2000)")
                dev.event("onPointerUp")
                dev.event("Authentication FAILED (unrecognized finger, keeping session active for next touch)")
                time.sleep(0.2); self.assertEqual(dev.contents("mode"), "2")
                dev.event("ICancellationSignal::cancel invoked"); dev.mode(3)
                dev.event("ISession::enroll called (challenge=0x5)"); dev.mode(2)
                dev.event("Enrollment completed successfully (final fid 1)"); dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x1)"); dev.mode(2)
                dev.event("Authentication SUCCEEDED for fid 1"); dev.mode(3)

    def test_hbm_and_sofod_tokens_are_acked_and_overlap_safely(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.wait(lambda: (dev.data / ".refresh_ready").exists())
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                self.assertEqual(result.returncode, 0, result.stderr)
                hbm_token = result.stdout.strip()
                dev.mode(2)
                self.assertEqual(dev.contents("fod/.refresh_applied").split()[2], hbm_token)
                result = dev.client('refresh_fod_begin sofod; echo "$REFRESH_FOD_TOKEN"')
                so_token = result.stdout.strip()
                self.assertEqual(dev.contents("fod/.refresh_applied").split()[3], so_token)
                dev.client(f"refresh_fod_end hbm '{hbm_token}'")
                time.sleep(0.15); self.assertEqual(dev.contents("mode"), "2")
                dev.client(f"refresh_fod_end sofod '{so_token}'"); dev.mode(3)

    def test_early_fod_is_not_overwritten_by_boot_completed_settings(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, boot="0") as dev:
                dev.mode(2)  # pre-arm 120 as soon as SF is ready, before boot_completed
                self.assertNotIn("3", dev.contents("requests").splitlines())
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                token = result.stdout.strip(); dev.mode(2)
                dev.put("boot", "1")
                dev.setting("min_refresh_rate", "120")
                dev.setting("peak_refresh_rate", "120")
                self.assertNotIn("rate 144", dev.contents("votes"))
                dev.client(f"refresh_fod_end hbm '{token}'"); dev.mode(3)

    def test_sf_restart_resolves_new_ids_and_keeps_fod_at_120(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.put("press", "1"); dev.mode(2)
                dev.sf.terminate(); dev.sf.wait(timeout=5)
                dev.sf = subprocess.Popen(["sleep", "60"])
                dev.put("sfpid", str(dev.sf.pid)); dev.put("modes", modes(base=13, fp=12))
                dev.mode(12)
                dev.put("press", "0"); dev.mode(13)

    def test_missing_144_and_cross_group_pair_fall_back_without_144_votes(self):
        for shell in SHELLS:
            for dump in [modes(base=None), modes(base_group=1)]:
                with self.subTest(shell=shell, dump=dump), FakeAndroid(shell, display_modes=dump) as dev:
                    dev.mode(2); dev.setting("peak_refresh_rate", "120")
                    self.assertNotIn("rate 144", dev.contents("votes"))
                    self.assertIn("safely retaining 120 Hz", dev.contents("fod/refresh.log"))

    def test_no_120_leaves_android_policy_untouched(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, display_modes=modes(fp=None)) as dev:
                dev.wait(lambda: "leaving display policy to Android" in dev.contents("fod/refresh.log"))
                self.assertEqual(dev.contents("calls"), "")
                self.assertEqual(dev.contents("votes"), "")

    def test_pin_failure_uses_framework_without_false_ack_or_spam(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, pin_ok=False) as dev:
                dev.setting("min_refresh_rate", "144")
                self.assertFalse((dev.data / ".refresh_applied").exists())
                self.assertNotIn("Hz verified", dev.contents("fod/refresh.log"))
                dev.put("press", "1"); dev.setting("peak_refresh_rate", "120")
                dev.wait(lambda: any("120 Hz NOT verified" in line and "trigger=press" in line
                                     for line in dev.contents("fod/refresh.log").splitlines()))
                warnings = dev.contents("fod/refresh.log").count("120 Hz NOT verified")
                time.sleep(0.3)
                self.assertEqual(dev.contents("fod/refresh.log").count("120 Hz NOT verified"), warnings)
                self.assertFalse((dev.data / ".refresh_applied").exists())

    def test_foreground_user_switch_gets_own_votes_and_originals(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3); dev.setting("min_refresh_rate", "144")
                dev.put("user", "10"); dev.setting("min_refresh_rate", "144", user=10)
                self.assertEqual(dev.contents("fod/settings.system.10.min_refresh_rate.orig"), "null")
                self.assertEqual(dev.contents("fod/settings.system.0.min_refresh_rate.orig"), "null")

    def test_starting_during_an_existing_prompt_seeds_120(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, seed=True) as dev:
                dev.mode(2); dev.setting("min_refresh_rate", "120")
                dev.put("fingerprint", "Current operation: null")
                dev.event("ICancellationSignal::cancel invoked"); dev.mode(3)

    def test_three_global_animation_scales_and_uninstall_restore(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.put("settings/global.0.window_animation_scale", "0.75")
                dev.put("settings/global.0.transition_animation_scale", "1")
                dev.start("animations.sh")
                for key in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]:
                    dev.setting(key, "0.4", ns="global")
                dev.setting("min_refresh_rate", "144")
                result = subprocess.run([shell, str(dev.mod / "uninstall.sh")], env=dev.env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(dev.contents("settings/global.0.window_animation_scale"), "0.75")
                self.assertEqual(dev.contents("settings/global.0.transition_animation_scale"), "1")
                self.assertFalse((dev.settings / "global.0.animator_duration_scale").exists())
                self.assertFalse((dev.settings / "system.0.min_refresh_rate").exists())
                self.assertFalse((dev.settings / "system.0.peak_refresh_rate").exists())
                self.assertFalse((dev.data / ".refresh_applied").exists())

    def test_early_boot_uninstall_defers_restoration_outside_deleted_module(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.put("settings/global.0.window_animation_scale", "0.75")
                dev.start("animations.sh")
                dev.setting("window_animation_scale", "0.4", ns="global")
                dev.setting("min_refresh_rate", "144")
                dev.put("settings_down", "1")
                result = subprocess.run([shell, str(dev.mod / "uninstall.sh")], env=dev.env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                restore = dev.root / "service.d/x6886_restore_settings.sh"
                self.assertTrue(restore.exists())
                self.assertEqual(dev.contents("fod/settings.global.0.window_animation_scale.orig"), "0.75")
                (dev.mod / "settings_state.sh").unlink()  # Magisk removed the original module
                (dev.root / "settings_down").unlink()
                result = subprocess.run([shell, str(restore)], env=dev.env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(dev.contents("settings/global.0.window_animation_scale"), "0.75")
                self.assertFalse((dev.settings / "system.0.min_refresh_rate").exists())
                self.assertFalse(restore.exists())
                self.assertFalse((dev.data / ".settings_restore_lib.sh").exists())

    def test_hal_restart_clears_an_old_auth_session(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.hal.terminate(); dev.hal.wait(timeout=5)
                dev.hal = subprocess.Popen(["sleep", "60"])
                dev.put("halpid", str(dev.hal.pid))
                dev.mode(3)
                dev.event("ISession::enroll called (challenge=0x5)"); dev.mode(2)
                dev.event("ICancellationSignal::cancel invoked"); dev.mode(3)

    def test_graceful_shutdown_removes_ack_and_logcat(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.wait(lambda: (dev.data / ".refresh_logcat.pid").exists())
                logger = int(dev.contents("fod/.refresh_logcat.pid"))
                dev.proc.terminate()
                output, errors = dev.proc.communicate(timeout=3)
                self.assertEqual(dev.proc.returncode, 0, errors)
                self.assertEqual(output, b"")
                self.assertFalse((dev.data / ".refresh_applied").exists())
                self.assertFalse((dev.data / ".refresh_ready").exists())
                self.assertFalse((pathlib.Path("/proc") / str(logger)).exists())

    def test_real_device_mode_zero_and_empty_binder_reply_are_not_a_failure(self):
        dump = (REPO / ".github/tests/fixtures/x6886-sf-displays.txt").read_text()
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, display_modes=dump, reply="empty") as dev:
                dev.mode(1)
                dev.wait(lambda: (dev.data / ".refresh_ready").exists())
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                self.assertEqual(result.returncode, 0, result.stderr)
                dev.mode(0)
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:3] == ["120", result.stdout.strip()])
                dev.client(f"refresh_fod_end hbm '{result.stdout.strip()}'")
                dev.mode(1)

    def test_reply_alone_cannot_ack_a_display_still_at_144(self):
        dump = (REPO / ".github/tests/fixtures/x6886-sf-displays.txt").read_text()
        for shell in SHELLS:
            for reply in ["empty", "zero"]:
                with self.subTest(shell=shell, reply=reply), FakeAndroid(shell, display_modes=dump, reply=reply) as dev:
                    dev.mode(1)
                    dev.wait(lambda: (dev.data / ".refresh_applied").exists())
                    dev.put("observed_mode", "1")  # driver ignores the next request
                    result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    dev.wait(lambda: "120 Hz NOT verified" in dev.contents("fod/refresh.log"))
                    self.assertFalse((dev.data / ".refresh_applied").exists())
                    self.assertIn("actual_mode=1 physical=144", dev.contents("fod/refresh.log"))
                    self.assertIn("Result: Parcel(", dev.contents("fod/refresh_last_reply.txt"))

    def test_physical_120_with_render_rate_144_is_not_acknowledged(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.put("render_override", "144")
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                dev.wait(lambda: "physical=120 render=144" in dev.contents("fod/refresh.log"))
                self.assertFalse((dev.data / ".refresh_applied").exists())
                (dev.root / "render_override").unlink()
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:3] == ["120", result.stdout.strip()])

    def test_fresh_hbm_token_rechecks_a_previously_verified_120_mode(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:2] == ["120"])
                dev.put("observed_mode", "3")
                result = dev.client('refresh_fod_begin hbm; echo "$REFRESH_FOD_TOKEN"')
                self.assertFalse((dev.data / ".refresh_applied").exists())
                (dev.root / "observed_mode").unlink()
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:3] == ["120", result.stdout.strip()])

    def test_reported_empty_reply_then_hal_restart_keeps_controller_and_listener(self):
        dump = (REPO / ".github/tests/fixtures/x6886-sf-displays.txt").read_text()
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, display_modes=dump, reply="empty") as dev:
                dev.mode(1)
                dev.wait(lambda: (dev.data / ".refresh_applied").exists())
                logger = dev.contents("fod/.refresh_logcat.pid")
                dev.hal.terminate(); dev.hal.wait(timeout=5)
                dev.hal = subprocess.Popen(["sleep", "60"])
                dev.put("halpid", str(dev.hal.pid))
                dev.wait(lambda: "without stopping controller" in dev.contents("fod/refresh.log"))
                self.assertIsNone(dev.proc.poll())
                self.assertEqual(dev.contents("fod/.refresh_logcat.pid"), logger)
                dev.put("press", "1"); dev.mode(0)
                dev.setting("min_refresh_rate", "120")
                dev.setting("peak_refresh_rate", "120")
                dev.put("press", "0"); dev.mode(1)
                dev.event("ISession::enroll called (challenge=0x5)"); dev.mode(0)
                dev.event("ICancellationSignal::cancel invoked"); dev.mode(1)

    def test_logcat_death_recovers_and_press_fallback_still_downshifts(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.wait(lambda: (dev.data / ".refresh_logcat.pid").exists())
                logger = int(dev.contents("fod/.refresh_logcat.pid"))
                os.kill(logger, signal.SIGKILL)
                dev.put("press", "1"); dev.mode(2)
                dev.wait(lambda: dev.contents("fod/.refresh_logcat.pid") not in ["", str(logger)])
                dev.put("press", "0"); dev.mode(3)
                dev.event("ISession::authenticate called (op_id=0x0)"); dev.mode(2)
                dev.event("ICancellationSignal::cancel invoked"); dev.mode(3)

    def test_supervisor_recovers_a_killed_controller_and_stops_on_uninstall(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                supervisor = dev.start("refresh_supervisor.sh")
                dev.wait(lambda: (dev.data / ".refresh_supervisor.pid").exists())
                old = dev.proc.pid
                dev.put("press", "1")
                dev.proc.kill(); dev.proc.wait(timeout=3)
                dev.wait(lambda: dev.contents("fod/.refresh.pid") not in ["", str(old)],
                         limit=5, check_controller=False)
                dev.wait(lambda: dev.contents("fod/.refresh_applied").split()[1:2] == ["120"],
                         check_controller=False)
                self.assertIsNone(supervisor.poll())
                result = subprocess.run([shell, str(dev.mod / "uninstall.sh")], env=dev.env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                supervisor.communicate(timeout=3)
                time.sleep(1.1)
                self.assertFalse((dev.data / ".refresh.pid").exists())
                self.assertFalse((dev.data / ".refresh_supervisor.pid").exists())
                self.assertFalse((dev.data / ".refresh_applied").exists())

    def test_targeted_diagnostics_are_plain_text_and_show_liveness_and_actual_mode(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell, reply="empty") as dev:
                dev.mode(3)
                dev.wait(lambda: (dev.data / ".refresh_applied").exists())
                dev.start("refresh_supervisor.sh")
                dev.wait(lambda: (dev.data / ".refresh_supervisor.pid").exists())
                result = subprocess.run([shell, str(dev.mod / "diag.sh"), "refresh"], env=dev.env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                for text in ["version=Level 2 v3", "refresh: running=yes", "refresh_supervisor: running=yes",
                             "verified ACK", "physical_hz=144", "Parcel(NULL)", "activeMode={id=3"]:
                    self.assertIn(text, result.stdout)
                self.assertNotIn("== top threads", result.stdout)

    def test_two_magisk_launches_share_one_supervisor(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                first = dev.start("refresh_supervisor.sh")
                dev.wait(lambda: dev.contents("fod/.refresh_supervisor.pid") == str(first.pid))
                second = dev.start("refresh_supervisor.sh")
                second.communicate(timeout=3)
                self.assertEqual(second.returncode, 0)
                self.assertIsNone(first.poll())
                self.assertEqual(dev.contents("fod/.refresh_supervisor.pid"), str(first.pid))
                self.assertEqual(dev.contents("fod/.refresh.pid"), str(dev.proc.pid))

    def test_wiring_and_version(self):
        self.assertIn("animations.sh", read("service.sh"))
        self.assertIn("single_instance refresh", read("refresh.sh"))
        self.assertIn("single_instance animations", read("animations.sh"))
        self.assertIn("single_instance refresh_supervisor", read("refresh_supervisor.sh"))
        self.assertIn("refresh_supervisor.sh", read("post-fs-data.sh"))
        self.assertIn("refresh_supervisor.sh", read("service.sh"))
        self.assertNotIn('stop_events; watch_events', read("refresh.sh"))
        self.assertIn('if [ "$1" = refresh ]', read("diag.sh"))
        self.assertNotIn("TARGET_HZ=120", read("customize.sh"))
        self.assertNotIn("fixed 120 Hz", read("diag.sh"))
        self.assertIn("version=Level 2 v3\nversionCode=140", read("module.prop"))
        self.assertIn("id=X6886_GSI_PATCH_level_1_by_lemonrsh\n", read("module.prop"))
        self.assertIn("module_settings_restore", read("uninstall.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
