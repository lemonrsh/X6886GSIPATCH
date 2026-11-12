X6886 GSI PATCH by lemonrsh — v14.4 (versionCode 136)
====================================

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
