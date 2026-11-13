#!/usr/bin/env python3
"""Module-overhead regressions, not phone CPU or biometric benchmarks.

Use real host grep/awk pipes (kept open to detect buffering), synthetic /proc
records, counted command stubs, and the existing fake Android controller. Never
write to real /data, sysfs, input devices or Android services.
"""

import os
import pathlib
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from test_display import FakeAndroid, HELPERS
from test_fixes import REPO, SHELLS, marked_block, read, run_shell

INPUT = marked_block(read("fod_service.sh"),
                     "# --- FOD input helpers (host-tested in test_low_cpu.py) ---",
                     "# --- end FOD input helpers ---")
PROCESS = marked_block(read("lib.sh"),
                       "# --- process identity helpers (host-tested in test_low_cpu.py) ---",
                       "# --- end process identity helpers ---")
RUNTIME = marked_block(read("refresh.sh"),
                       "# --- runtime snapshot helper (host-tested in test_low_cpu.py) ---",
                       "# --- end runtime snapshot helper ---")


def stat_record(pid, stamp="42949672960", state="S", comm="Android ) helper (thread)"):
    # state is field 3; starttime is field 22. comm may contain spaces and ')'.
    tail = [state] + ["0"] * 18 + [stamp] + ["0"] * 5
    return f"{pid} ({comm}) " + " ".join(tail) + "\n"


class NativeInputFilterTests(unittest.TestCase):
    def make_tools(self, root, backend):
        tools = root / "bin"; tools.mkdir()
        grep = shutil.which("grep")
        awk = shutil.which("awk")
        busybox = shutil.which("busybox")
        if backend == "busybox" and not busybox:
            self.skipTest("BusyBox is optional locally; CI installs it")
        # Explicitly simulate Android greps without GNU --line-buffered. Do not
        # depend on which grep/awk happens to be selected in the host's PATH.
        bodies = {
            "grep": f'#!/bin/sh\nexec {grep} "$@"\n' if backend == "grep" else '#!/bin/sh\nexit 2\n',
            "awk": f'#!/bin/sh\nexec {awk} "$@"\n' if backend == "awk" else '#!/bin/sh\nexit 127\n',
            "busybox": f'#!/bin/sh\nexec {busybox} "$@"\n' if backend == "busybox" else '#!/bin/sh\nexit 127\n',
        }
        for name, body in bodies.items():
            tool = tools / name; tool.write_text(body); tool.chmod(0o755)
        return tools

    def stream_filter(self, shell, backend):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            tools = self.make_tools(root, backend)
            block = INPUT.replace("/data/adb/magisk/busybox", str(root / "no-magisk-busybox"))
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
            script = block + f"""
FAST_FILTER=1
fod_filter_init
[ "$FILTER_OK:$FILTER_KIND" = '1:{backend}' ] || exit 90
fod_filter_events
"""
            proc = subprocess.Popen([shell, "-c", script], env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    bufsize=0, start_new_session=True)
            received = b""
            try:
                for index, line in enumerate([
                    b"0001 014a 00000001\n", b"/dev/input/event7: 0001 00c3 00000001\n",
                    b"0001 00c3 00000000\n", b"/dev/input/event7: 0001 014a 00000000\n",
                ]):
                    # Coordinate/SYN/other-key traffic must never reach the shell.
                    noise = (b"0003 0035 000001f4\n0003 0036 000007d0\n0000 0000 00000000\n"
                             b"0001 0074 00000001\n") * 2000
                    payload = memoryview(noise + line)
                    while payload:
                        payload = payload[proc.stdin.write(payload):]
                    proc.stdin.flush()
                    target = received + line
                    deadline = time.monotonic() + 2
                    while len(received) < len(target):
                        ready, _, _ = select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))
                        if not ready:
                            self.fail(f"{backend} buffered key event {index} until EOF")
                        part = os.read(proc.stdout.fileno(), 4096)
                        self.assertTrue(part, f"{backend} exited before delivering an event")
                        received += part
                    self.assertEqual(received, target)
                    self.assertIsNone(proc.poll(), "the stream must still be open")
                proc.stdin.close(); proc.stdin = None
                rest, errors = proc.communicate(timeout=3)
                self.assertEqual(proc.returncode, 0, errors.decode())
                self.assertEqual(rest, b"")
                self.assertEqual(len(received.splitlines()), 4)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate(timeout=3)

    def test_gnu_grep_filters_and_flushes_without_eof(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.stream_filter(shell, "grep")

    def test_no_line_buffered_grep_uses_flushed_native_awk(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.stream_filter(shell, "awk")

    def test_no_system_awk_uses_flushed_busybox_awk(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.stream_filter(shell, "busybox")

    def test_no_supported_filter_and_explicit_opt_out_keep_original_fallback(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                tools = self.make_tools(root, "none")
                block = INPUT.replace("/data/adb/magisk/busybox", str(root / "no-magisk-busybox"))
                result = run_shell(shell, block + """
FAST_FILTER=1; fod_filter_init
[ "$FILTER_OK:$FILTER_KIND" = 0:none ] || exit 1
# An explicit FAST_FILTER=0 must not run capability probes at all.
grep() { echo probe > "$PROBE"; return 1; }; awk() { echo probe > "$PROBE"; return 1; }
FAST_FILTER=0; fod_filter_init
[ "$FILTER_OK:$FILTER_KIND" = 0:none ] && [ ! -f "$PROBE" ]
""", env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", PROBE=str(root / "probe")))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_magisk_private_busybox_is_found_without_path_awk_or_busybox(self):
        busybox = shutil.which("busybox")
        if not busybox:
            self.skipTest("BusyBox is optional locally; CI installs it")
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                tools = self.make_tools(root, "none")
                block = INPUT.replace("/data/adb/magisk/busybox", busybox)
                result = run_shell(shell, block + f"""
FAST_FILTER=1; fod_filter_init
[ "$FILTER_OK:$FILTER_KIND" = 1:busybox ] && [ "$FILTER_BB" = {busybox!r} ]
""", env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}"))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_sofod_device_and_panel_reads_keep_original_on_off_semantics(self):
        text = read("sofod_touch.sh")
        helpers = "find_dev() {" + text.split("find_dev() {", 1)[1].split('\nDEV=""', 1)[0]
        helpers += "\ndpms_on() {" + text.split("dpms_on() {", 1)[1].split("\npressed()", 1)[0]
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                event = root / "input/event4/device"; event.mkdir(parents=True)
                (event / "name").write_text("mtk-tpd\n")
                panel = root / "dpms"; panel.write_text("On\n")
                block = helpers.replace("/sys/class/input", str(root / "input"))
                result = run_shell(shell, block + f"""
set -eu
PATH=/no-external-tools; DPMS={str(panel)!r}
find_dev
for state in On on ON; do echo "$state" > "$DPMS"; dpms_on; done
for state in Off off unknown; do
  echo "$state" > "$DPMS"; if dpms_on; then exit 1; fi
done
DPMS={str(root / 'missing-panel')!r}; dpms_on
""")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "/dev/input/event4")

    def test_sysfs_reads_use_builtins_and_keep_thermal_boundary(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                event = root / "input/event9/device"; event.mkdir(parents=True)
                (event / "name").write_text("mtk-tpd\n")
                temp = root / "temp"; temp.write_text("429\n")
                block = INPUT.replace("/sys/class/input", str(root / "input"))
                block = block.replace("/sys/class/power_supply/battery/temp", str(temp))
                result = run_shell(shell, block + f"""
set -eu
PATH=/no-external-tools
TEMP_MAX=430
find_dev
if hot; then exit 1; fi
echo 430 > {str(temp)!r}; hot
echo invalid > {str(temp)!r}; if hot; then exit 1; fi
""")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "/dev/input/event9")


class ProcessIdentityTests(unittest.TestCase):
    def test_live_identity_and_shell_options_need_no_external_tools(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = run_shell(shell, PROCESS + """
set -eu
PATH=/no-external-tools
process_stamp $$
saved=$PROC_STAMP
process_unchanged $$ "$saved"
if process_unchanged $$ wrong-stamp; then exit 1; fi
case $- in *f*) exit 1 ;; esac
set -f
process_stamp $$
case $- in *f*) ;; *) exit 1 ;; esac
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_parses_comm_parentheses_large_stamp_and_rejects_stale_or_invalid_pid(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                (root / "42").mkdir()
                (root / "42/stat").write_text(stat_record(42))
                block = PROCESS.replace('"/proc/$1/stat"', '"$PROCROOT/$1/stat"')
                result = run_shell(shell, block + f"""
set -eu
PROCROOT={td!r}; PATH=/no-external-tools
process_stamp 42
[ "$PROC_STAMP" = 42949672960 ]
process_unchanged 42 42949672960
for p in '' ../42 -42 abc 99; do
  if process_stamp "$p"; then exit 1; fi
  [ -z "$PROC_STAMP" ]
done
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_zombies_dead_malformed_and_reused_pid_are_not_unchanged(self):
        for shell in SHELLS:
            for text in [stat_record(42, state="Z"), stat_record(42, state="X"),
                         stat_record(42, stamp="42949672961"), "42 (truncated) S 1\n",
                         stat_record(43), stat_record(42, stamp="not-a-tick")]:
                with self.subTest(shell=shell, record=text), tempfile.TemporaryDirectory() as td:
                    root = pathlib.Path(td); (root / "42").mkdir()
                    (root / "42/stat").write_text(text)
                    block = PROCESS.replace('"/proc/$1/stat"', '"$PROCROOT/$1/stat"')
                    result = run_shell(shell, block + f"""
PROCROOT={td!r}; PATH=/no-external-tools
if process_unchanged 42 42949672960; then exit 1; fi
""")
                    self.assertEqual(result.returncode, 0, result.stderr)

    def watchdog(self, shell, kind, change):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            for pid in [41, 42]:
                (root / str(pid)).mkdir()
                (root / f"{pid}/stat").write_text(stat_record(pid, stamp=str(pid * 100)))
            (root / "pid").write_text("41\n")
            block = marked_block(read("fod_service.sh" if kind == "hal" else "perf_tweaks.sh"),
                                 f"# --- {'HAL' if kind == 'hal' else 'SF'} watchdog (host-tested in test_low_cpu.py) ---",
                                 f"# --- end {'HAL' if kind == 'hal' else 'SF'} watchdog ---")
            # Run just the actual loop synchronously; the bounded sleep stub exits
            # its subshell after three checks. No daemon or real sleep is started.
            block = block.replace("done ) &", "done )")
            process = PROCESS.replace('"/proc/$1/stat"', '"$PROCROOT/$1/stat"')
            action = {
                "none": ":",
                "restart": f"rm -f {td!r}/41/stat; printf '42\\n' > {td!r}/pid",
                "reuse": f"printf '%s\\n' {stat_record(41, stamp='4101').strip()!r} > {td!r}/41/stat",
                "unreadable": f"rm -f {td!r}/41/stat",
            }[change]
            script = process + f"""
D={td!r}; PROCROOT=$D; MODDIR=$D
HAL_PATCH=12; SF_BOOST=1; WDTICK=0
pidof() {{ echo scan >> "$D/scans"; IFS= read -r p < "$D/pid"; echo "$p"; }}
boost_sf() {{ IFS= read -r SF < "$D/pid"; echo "$SF" >> "$D/boosts"; }}
sha256sum() {{ echo 'samehash  lib.so'; }}
setprop() {{ echo "$*" >> "$D/restarts"; }}
log() {{ echo "$*" >> "$D/log"; }}
date() {{ echo now; }}
LOG=$D/log
sleep() {{
  case "$1" in
    15|30)
      WDTICK=$((WDTICK+1)); [ "$WDTICK" -le 3 ] || exit 0
      if [ "$WDTICK" = 1 ]; then {action}; fi ;;
  esac
  return 0
}}
{block}
"""
            result = run_shell(shell, script)
            self.assertEqual(result.returncode, 0, result.stderr)
            scans = (root / "scans").read_text().splitlines() if (root / "scans").exists() else []
            if kind == "hal":
                self.assertEqual(len(scans), 1 if change == "none" else 4 if change == "unreadable" else 2)
                self.assertEqual((root / "log").exists(), change in ["restart", "reuse"])
                self.assertFalse((root / "restarts").exists(), "matching patched HAL must not be restarted")
            else:
                self.assertEqual(len(scans), 0 if change == "none" else 3 if change == "unreadable" else 1)
                self.assertEqual(len((root / "boosts").read_text().splitlines()),
                                 2 if change in ["restart", "reuse"] else 1)

    def test_healthy_hal_and_sf_watchdogs_skip_repeat_pidof_scans(self):
        for shell in SHELLS:
            for kind in ["hal", "sf"]:
                with self.subTest(shell=shell, kind=kind):
                    self.watchdog(shell, kind, "none")

    def test_watchdogs_still_detect_restart_pid_reuse_and_fallback_when_stat_unavailable(self):
        for shell in SHELLS:
            for kind in ["hal", "sf"]:
                for change in ["restart", "reuse", "unreadable"]:
                    with self.subTest(shell=shell, kind=kind, change=change):
                        self.watchdog(shell, kind, change)


class RedundantWorkTests(unittest.TestCase):
    def test_cpu_governor_is_not_forced_or_polled_by_default(self):
        perf = read("perf_tweaks.sh")
        config = read("customize.sh")
        self.assertIn("PERF_GOVERNOR=0", perf)
        self.assertIn("PERF_GOVERNOR=0", config)
        self.assertIn('if [ "$PERF_GOVERNOR" = 1 ]; then', perf)
        self.assertIn("CPU governor left to Android/vendor policy", perf)
        self.assertNotIn("apply_performance_governor", perf)
        self.assertNotIn("sleep 30; apply_performance_governor", perf)

    def test_runtime_deduplicates_idle_writes_but_preserves_observations_changes_and_retries(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, RUNTIME + f"""
set -eu
D={td!r}; WATCH_PID=10; SFPID=11; WANT=144; APPLIED=144
SF_ID=1; SF_HZ=144; SF_RENDER=144; REPLY=zero; REFRESH_NOW=0; MOVES=0; FAIL=0
refresh_now() {{ REFRESH_NOW=$((REFRESH_NOW+1)); }}
mv() {{ MOVES=$((MOVES+1)); [ "$FAIL" = 0 ] || return 1; command mv "$@"; }}
runtime
for i in 1 2 3 4 5 6 7 8 9 10; do runtime; done
[ "$MOVES:$REFRESH_NOW" = 1:1 ]
runtime 1
[ "$MOVES:$REFRESH_NOW" = 2:2 ]
WATCH_PID=12; runtime
[ "$MOVES" = 3 ]
rm "$D/.refresh_runtime"; runtime
[ "$MOVES" = 4 ]
# A failed atomic replace must not poison the cache and suppress its retry.
FAIL=1; WANT=120
if runtime; then exit 1; fi
FAIL=0; runtime
[ "$MOVES" = 6 ]
grep -q 'target=120' "$D/.refresh_runtime"
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_setting_markers_skip_identical_writes_without_skipping_live_reconciliation(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as td:
                result = run_shell(shell, read("settings_state.sh") + f"""
set -eu
D={td!r}; cur=1; MOVES=0; PUTS=0
settings() {{
  case "$1" in get) echo "$cur" ;; put) cur=$4; PUTS=$((PUTS+1)) ;; esac
}}
mv() {{ MOVES=$((MOVES+1)); command mv "$@"; }}
module_setting_set global 0 animator_duration_scale 0.4
for i in 1 2 3 4 5 6 7 8 9 10; do module_setting_set global 0 animator_duration_scale 0.4; done
[ "$MOVES:$PUTS" = 2:1 ]
cur=0.8; module_setting_set global 0 animator_duration_scale 0.4
[ "$MOVES:$PUTS:$cur" = 2:2:0.4 ]
module_setting_set global 0 animator_duration_scale 0.5
[ "$MOVES:$PUTS" = 3:3 ]
[ "$(cat "$D/settings.global.0.animator_duration_scale.orig")" = 1 ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_bridge_event_parser_sets_and_clears_result_without_subshell_output(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = run_shell(shell, HELPERS + """
set -eu
PATH=/no-external-tools
refresh_event_parse 'ISession::authenticate called'
[ "$REFRESH_EVENT" = session_on ]
refresh_event_parse 'Authentication FAILED'
[ -z "$REFRESH_EVENT" ]
refresh_event_parse 'ICancellationSignal::cancel invoked'
[ "$REFRESH_EVENT" = session_off ]
""")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
        self.assertNotIn('_we_event=$(refresh_event', read("refresh.sh"))

    def test_idle_controller_does_not_rewrite_runtime_each_second_and_still_updates_on_fod(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), FakeAndroid(shell) as dev:
                dev.mode(3)
                dev.wait(lambda: (dev.data / ".refresh_applied").exists())
                snapshot = dev.data / ".refresh_runtime"
                before = snapshot.stat()
                text = snapshot.read_text()
                time.sleep(1.5)
                self.assertIsNone(dev.proc.poll())
                self.assertEqual(snapshot.stat().st_mtime_ns, before.st_mtime_ns)
                self.assertEqual(snapshot.stat().st_ino, before.st_ino)
                self.assertEqual(snapshot.read_text(), text)
                dev.put("press", "1"); dev.mode(2)
                dev.wait(lambda: "verified=120" in dev.contents("fod/.refresh_runtime"))
                self.assertIn("physical_hz=120", dev.contents("fod/.refresh_runtime"))

    def test_owned_controller_and_supervisor_stop_on_live_disable_or_remove_flags(self):
        for shell in SHELLS:
            for flag in ["disable", "remove"]:
                with self.subTest(shell=shell, flag=flag), FakeAndroid(shell) as dev:
                    dev.mode(3)
                    old = dev.proc.pid
                    dev.proc.terminate(); dev.proc.communicate(timeout=4)
                    supervisor = dev.start("refresh_supervisor.sh")
                    dev.wait(lambda: dev.contents("fod/.refresh.pid") not in ["", str(old)],
                             check_controller=False)
                    dev.wait(lambda: (dev.data / ".refresh_applied").exists(), check_controller=False)
                    (dev.mod / flag).touch()
                    supervisor.communicate(timeout=4)
                    self.assertEqual(supervisor.returncode, 0)
                    for name in [".refresh.pid", ".refresh_supervisor.pid", ".refresh_applied", ".refresh_logcat.pid"]:
                        self.assertFalse((dev.data / name).exists(), name)

    def test_existing_timing_safety_and_tuning_defaults_are_preserved(self):
        fod = read("fod_service.sh")
        for literal in ["MAX_S=3", "MAX_N=60", "TEMP_MAX=430", "WAIT_N=30", "WAIT_SO=80",
                        "LEAD_S=0.04", "PROP_WAIT=0", "sleep 15", "sleep 10", "[ $R -lt 3 ]"]:
            self.assertIn(literal, fod)
        refresh = read("refresh.sh")
        self.assertIn("refresh_nap 0.05", refresh)
        self.assertIn('[ "$_nap_rc" = 0 ] || sleep 1', refresh)
        self.assertIn("TICK % 2", refresh)
        self.assertIn("RECONCILE_S=120", refresh)
        self.assertIn('module_setting_set global 0 "$key" 0.4', read("animations.sh"))
        self.assertIn("sleep 30", read("perf_tweaks.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
