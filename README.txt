X6886 GSI PATCH by lemonrsh — Level 2 v1 (versionCode 138)
====================================

LEVEL 2 v1: lower module overhead and stability; no tuning/feature changes.
Flash in Magisk and REBOOT. The existing module ID is retained for an in-place
update, so do not install a second copy alongside the previous version.

* Native, flushed FOD input filtering on more toolsets; no raw coordinate/SYN
  parsing in the shell when supported, and no added key-event buffering.
* Builtin reads replace repeated cat processes; bridge parsing avoids per-line
  subshells. Healthy HAL/SF watchdogs avoid repeated process-table scans.
* Skip unchanged status/ownership-file writes, not live settings reconciliation
  or actual display observations. Runtime snapshots are not heartbeat files.
* Stop the refresh controller/listener on live disable/remove flags, including
  when the supervisor is waiting for its launched child.
* Keep 0.4x animations, 144/120 Hz policy, FOD/ACK/replay timings, 4266/1866 MHz
  DRAM lock, HAL patches, HBM thermal/watchdog limits and all existing tuning.

86 host tests across bash/dash/mksh/BusyBox ash; not a measured phone CPU saving
or hardware FOD guarantee. Keep the previous ZIP for rollback. See CHANGELOG.txt.

Previous v14.4.1 hotfix (retained):
If FOD stayed at 144 Hz, this update includes the v14.4.1 controller recovery fix.
The report showed valid modes (120 Hz ID 0 / 144 Hz ID 1) but no refresh daemon.
A single supervisor now restarts it after an exit. HAL restarts clear session
state without killing the listener. Empty/zero Binder replies are not proof:
only an observed matching active mode and physical/render rate earn a FOD ACK.
0.4x animations, DRAM lock and HBM safety protections are preserved.

Plain-text diagnostics (copy/paste the output; no TAR upload needed):
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh refresh'
This is host-tested, not on-device confirmation of CPU savings or the hotfix.

NEW: 0.4x Android window, transition and animator-duration scales (global).
144 Hz normally; 120 Hz for fingerprint authentication, enrolment, HBM and
screen-off FOD replay. Successful completion/cancellation returns to 144 Hz
when no finger/glow/replay is held. Flash in Magisk and reboot; no setup needed.

Compatible same-resolution/HWC-group 144/120 modes are discovered automatically.
If 144 Hz is unavailable/incompatible, the controller stays at 120 Hz. Without a
120 Hz mode it leaves Android's policy alone. Unsupported SurfaceFlinger commands
fall back to framework votes; diagnostics stay in refresh.log, not pop-up errors.
FOD requests a token-specific 120 Hz acknowledgement before HBM/input replay;
this wait is bounded (about 300 ms), never an indefinite capture blocker.
Mode requests have one writer, including early boot and foreground-user changes.

The physical display/ROM controls transition latency and whether switching is
truly seamless. Not on-device validated: zero flicker/biometric errors cannot be
guaranteed. Custom app animations/FPS limits may ignore system preferences.
Original settings are saved once and restored on uninstall when still owned by
the module. The removal reboot clears the display pin. See README.md for details.

This release removes the non-working screen-on-time (SOT) watcher completely.
It does NOT calculate, reset, repair, or modify Android Settings battery history.
It does NOT delete battery-usage-db files or change UsageStats permissions.
The Android Settings SOT issue is separate and remains unresolved by this module.
Double-tap-to-wake (dt2w.sh / dt2w.conf) and the GPU governor (gpufix.sh / gpumod)
have also been removed from this module; GPU DVFS will live in a separate module
project. Screen-off FOD (fod_service.sh / sofod_touch.sh) remains active.

Preserved components (carried forward from v10.4):
* X6886 Goodix fingerprint HAL patch / FOD bridge and HBM handling
* Improved screen-off FOD touch replay: faster first retry, up to four verified attempts, input-node re-detection, and guaranteed touch release
* 144 Hz normal / 120 Hz fingerprint refresh (v14.4; replaces the old always-120 policy)
* 0.4x global framework animations (v14.4)
* Screen-aware DRAM lock (4266 MHz on / 1866 MHz off)
* SurfaceFlinger and background performance tweaks
* Download Lag Fix
* Messenger / Google Play services background handling
* OTP app-op helper (experimental)
* Existing UI overlays

Safety: battery sysfs scaling remains disabled (CAP_FIX=0). No writes or bind
mounts are made to charge_counter, charge_full, or charge_full_design. No
Batterystats reset, Health HAL restart, SELinux weakening, or Settings database
rebuild is performed. Native battery reporting is left alone.

Install: flash in Magisk and reboot. The installer disables the listed older
standalone modules to avoid duplicate services. The module ID is unchanged, so
this is an in-place update. Keep a copy of your current ZIP in case you need
to roll back.

Configs: /data/adb/fod/hbm.conf, refresh.conf, gsi.conf, dlfix.conf, dram.conf,
and sofod_touch.conf (optional). Logs are in /data/adb/fod/.

Diagnostics: run
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh'
The diagnostic script intentionally does not inspect or alter Settings SOT data.

Installer compatibility: the Goodix HAL hash is checked against the supported
X6886 hashes. Installation aborts if the device HAL is not recognized.

FOD tuning:
* sofod_touch.sh watches the Transsion UDFPS HAL log and replays the held
  touch after the panel reports ON.
* It verifies sys.phh.oplus.fppress and retries if SystemUI did not accept
  the synthetic touch. It does not bypass the lockscreen or PIN.
* Optional overrides remain available in /data/adb/fod/sofod_touch.conf.
* If FOD behaves incorrectly, remove/disable this module or restore v10.6.


v11.2+
------
Event-driven FOD waits (optional), adaptive download-lag fix, lighter refresh controller, and cleanup. Double-tap-to-wake (dt2w.sh / dt2w.conf) and gpufix have been removed. Full history in CHANGELOG.txt. Config: /data/adb/fod/bg.conf. Collect logs with:
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh bundle'
v14.4 restores saved animation and refresh settings on uninstall. If the saved
refresh settings came from an old always-120 release, reset Smooth Display in
Settings to return to ROM defaults (or, as root for the current user):
  settings --user current delete system min_refresh_rate
  settings --user current delete system peak_refresh_rate
