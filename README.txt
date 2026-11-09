X6886 GSI PATCH by lemonrsh — v11.3 (see CHANGELOG.txt; original base v10.7: 120 Hz always + FOD stability)
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

GPU (v11.3, optional): gpufix.sh is read-only unless you enable it.
  sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/gpufix.sh status
  su -c 'sh .../gpufix.sh probe 30'    # run while scrolling / inside a 3D game
If, and only if, probe shows a flat clock under real load:
  set GPU_FIX=1 in /data/adb/fod/gpu.conf, then
  su -c 'sh .../gpufix.sh apply' and check again with 'verify 30' / 'probe 30'
  su -c 'sh .../gpufix.sh revert'  (or reboot) restores the stock values.
DVFS stays enabled: the GPU still drops to 390 MHz when idle; only the boost target changes.

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
