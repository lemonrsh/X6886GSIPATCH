X6886 GSI PATCH by lemonrsh — v11.4 (see CHANGELOG.txt; original base v10.7: 120 Hz always + FOD stability)
====================================

This release removes the non-working screen-on-time (SOT) watcher completely.
It does NOT calculate, reset, repair, or modify Android Settings battery history.
It does NOT delete battery-usage-db files or change UsageStats permissions.
The Android Settings SOT issue is separate and remains unresolved by this module.
Double-tap-to-wake (dt2w.sh / dt2w.conf) has also been removed from this module;
screen-off FOD (fod_service.sh / sofod_touch.sh) remains active.

Preserved components (carried forward from v10.4):
* X6886 Goodix fingerprint HAL patch / FOD bridge and HBM handling
* Improved screen-off FOD touch replay: faster first retry, up to four verified attempts, input-node re-detection, and guaranteed touch release
* Fixed 120 Hz refresh at all times (144 Hz and fingerprint switching removed)
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

Configs: /data/adb/fod/hbm.conf, refresh.conf, gsi.conf, dlfix.conf, gpu.conf, and
sofod_touch.conf (optional). Logs are in /data/adb/fod/.

Diagnostics: run
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh'
The diagnostic script intentionally does not inspect or alter Settings SOT data.

GPU (v11.4, optional): gpufix.sh controls the GPU floor. Three presets:
  su -c 'sh .../gpufix.sh preset max'    # fastest OPP (1600 MHz) always, whole system
  su -c 'sh .../gpufix.sh preset boost'  # 390 MHz idle -> 1200 MHz while busy (default)
  su -c 'sh .../gpufix.sh preset stock'  # release the floor
"max" pins floor = ceiling = 1600 MHz: maximum performance with the battery and heat
cost that implies; above 43 C battery the floor drops to HOT_HZ (default stock) until
the phone cools. "boost" follows GED's own load counter instead.
In this module the governor is off until ENABLED=1 in /data/adb/fod/gpu.conf, or install
the separate GPU-DVFS-X6886 module from the same release (same script, governor on,
state in /data/adb/gpufix).
Check: sh .../gpufix.sh status | probe 30      Undo: sh .../gpufix.sh revert (or reboot)

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
Event-driven FOD waits (optional), adaptive download-lag fix, lighter refresh controller, and cleanup. Double-tap-to-wake (dt2w.sh / dt2w.conf) has been removed. Full history in CHANGELOG.txt. Config: /data/adb/fod/bg.conf. Collect logs with:
  su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh bundle'
If you remove the module, Smooth Display may stay pinned at 120 Hz: run
  settings delete system min_refresh_rate; settings delete system peak_refresh_rate
