X6886 GSI PATCH by lemonrsh — v11.2 (see CHANGELOG.txt; original base v10.7: 120 Hz always + FOD stability)
====================================

This release removes the non-working screen-on-time (SOT) watcher completely.
It does NOT calculate, reset, repair, or modify Android Settings battery history.
It does NOT delete battery-usage-db files or change UsageStats permissions.
The Android Settings SOT issue is separate and remains unresolved by this module.

Preserved components (carried forward from v10.4):
* X6886 Goodix fingerprint HAL patch / FOD bridge and HBM handling
* Improved screen-off FOD touch replay: faster first retry, up to four verified attempts, input-node re-detection, and guaranteed touch release
* Fixed 120 Hz refresh at all times (144 Hz and fingerprint switching removed)
* DT2W and AOD/doze re-arming
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

Configs: /data/adb/fod/hbm.conf, refresh.conf, gsi.conf, dlfix.conf, and
sofod_touch.conf (optional). Logs are in /data/adb/fod/.

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


v11.0 AOD/DT2W update
---------------------
* DT2W listener now watches mtk-tpd key-down codes 00c3, 00c6 and 00fb instead of only 00c6.
* Touchscreen input node is found by device name, not a fixed event number.
* Gesture switches are re-armed every ARM_S seconds (default 5), including during AOD/Doze.
* Logs detected events and listener restarts to /data/adb/fod/dt2w.log.
* This is a candidate-code implementation: getevent -lp reports supported codes, not which code your firmware emits for a double tap. After flashing, test AOD double-tap and inspect dt2w.log. If no gesture line is recorded, collect `su -c 'getevent -lt /dev/input/event4'` while double-tapping with AOD active so the exact vendor event can be mapped.
* No PIN/password or biometric security bypass is included.


v11.1 AOD/DT2W correction
-------------------------
The supplied v11 log reported candidate key 00c3, but the accompanying raw
getevent capture showed BTN_TOUCH and multitouch events without an EV_KEY
gesture code. v11.1 therefore detects two BTN_TOUCH DOWN transitions 80-500 ms
apart, while retaining support for native 00c3/00c6/00fb key events.
It injects KEYCODE_WAKEUP and then invokes the non-toggle `cmd power wake-up`
fallback. Events are logged to /data/adb/fod/dt2w.log.
This is a software fallback based on the observed raw touch stream; it still
requires the touchscreen driver to deliver touch events while AOD is active.
No PIN/password or biometric security bypass is included.


v11.2
-----
Stricter and lighter double-tap detection (position/movement/multi-touch checks, wake only when the screen is not
already awake), event-driven FOD waits, adaptive download-lag fix, lighter refresh controller, cleanup. Full list in
CHANGELOG.txt. New configs: /data/adb/fod/dt2w.conf and bg.conf. Collect logs with:
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh bundle'
If you remove the module, Smooth Display may stay pinned at 120 Hz: run
  settings delete system min_refresh_rate; settings delete system peak_refresh_rate
