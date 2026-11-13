#!/system/bin/sh
# X6886_GSI_PATCH_level_1_by_lemonrsh installer
STOCK="789c228681e5f5c66bcf84bde58591f6e45ec2c4afbea8944dcd48b6eecf74af"
P12="8aff6aa4553978a65c6db2558464b14b745eeb360128dff6838afadd8527d260"
P123="eb42af99c471a25f2feef7f3c9e0eb9629a32871b662340cca877860cc134ebd"
N12="22467890811df0e2212e3947a490f0030cd74379e271ef6f654aaaa6433e103e"
N123="28ac013c65c32cbb55c682e66d9fc0e26a7f82a9cbfb7c26a57f512cc3104c84"
DATA=${FODDATA:-/data/adb}
# Stop any watchers left running by an older release before replacing the module.
for pid in $(ps -A -o PID,ARGS 2>/dev/null | awk 'NR>1 && (/\/screentime\.sh([[:space:]]|$)/ || /\/dt2w\.sh([[:space:]]|$)/ || /\/X6886[^[:space:]]*\/gpufix\.sh([[:space:]]|$)/) {print $1}'); do
  kill "$pid" 2>/dev/null
done
if [ -r "$DATA/fod/.dt2w_getevent.pid" ]; then
  gpid=$(cat "$DATA/fod/.dt2w_getevent.pid" 2>/dev/null)
  case "$gpid" in
    ''|*[!0-9]*) ;;
    *) [ "$gpid" -gt 1 ] && grep -q getevent "/proc/$gpid/cmdline" 2>/dev/null && kill "$gpid" 2>/dev/null ;;
  esac
fi
if [ -r "$DATA/fod/.gpufix.pid" ]; then
  gpid=$(cat "$DATA/fod/.gpufix.pid" 2>/dev/null)
  case "$gpid" in
    ''|*[!0-9]*) ;;
    *) [ "$gpid" -gt 1 ] && grep -q gpufix "/proc/$gpid/cmdline" 2>/dev/null && kill "$gpid" 2>/dev/null ;;
  esac
fi
CUR=$(sha256sum /odm/lib64/libgf_hal.so 2>/dev/null | cut -d' ' -f1)
ui_print "- /odm/lib64/libgf_hal.so sha256: ${CUR:-not found}"
if [ "$CUR" != "$STOCK" ] && [ "$CUR" != "$P12" ] && [ "$CUR" != "$P123" ] && [ "$CUR" != "$N12" ] && [ "$CUR" != "$N123" ]; then
  if [ -f "$DATA/fod/skip_hashcheck" ]; then
    ui_print "! Unknown Goodix HAL, but $DATA/fod/skip_hashcheck exists: continuing at your own risk."
    ui_print "! The patched HAL library will NOT be bound (HAL_PATCH=0); the bundled fingerprint service is still installed."
    SKIPHAL=1
  else
    ui_print "! Unsupported Goodix HAL build. Nothing will be installed."
    ui_print "! (To override after a firmware update: touch $DATA/fod/skip_hashcheck and flash again.)"
    abort "! This patch only supports the verified X6886 HAL hashes."
  fi
else
  ui_print "- Verified X6886 Goodix HAL."
fi

# the standalone modules this one replaces (v10: + dlfix = Download Lag Fix): disable them so nothing is mounted/run twice (applies on reboot)
for m in FSBP RU fod_gsi_x6886_lemonrsh gsi_perf_tweaks gsi_ultimate_battery_x6886 \
         messenger_background_fix otp_autofix dlfix DownloadLagFix x6886_batterycap battery_capacity_x6886 fod_hbm_x6886 fod_x6886 fod_all_x6886 batteryfix sffix; do
  if [ -d "$DATA/modules/$m" ]; then touch "$DATA/modules/$m/disable"; ui_print "- disabled old module: $m"; fi
done

set_perm_recursive "$MODPATH/libs" 0 0 0755 0644
set_perm "$MODPATH/system/vendor/bin/hw/android.hardware.biometrics.fingerprint-service" 0 2000 0755 "u:object_r:hal_fingerprint_default_exec:s0"
set_perm_recursive "$MODPATH/system/vendor/overlay" 0 0 0755 0644 "u:object_r:vendor_overlay_file:s0"

mkdir -p "$DATA/fod"
if [ ! -f "$DATA/fod/hbm.conf" ]; then
cat > "$DATA/fod/hbm.conf" <<'CONF'
ENABLED=1
HAL_PATCH=12
MAX_S=3
MAX_N=60
TEMP_MAX=430
WAIT_N=30
KEYLOG=40
INJECT195=1
LEAD_S=0.04
CONF
fi
[ "$SKIPHAL" = 1 ] && sed -i 's/^HAL_PATCH=.*/HAL_PATCH=0/' "$DATA/fod/hbm.conf"
# v15.0: migrate the old always-120 controller. Mode IDs are resolved fresh from
# SurfaceFlinger; never reuse a cached ID across a reboot/HAL/ROM update.
cat > "$DATA/fod/refresh.conf" <<'CONF'
# 144 Hz interactive / 120 Hz FOD, sleep and wake guard (compatible modes only).
RECONCILE_S=120
SETTINGS_RATE=1
CONF
rm -f "$DATA/fod/refresh.cache" "$DATA/fod/.refresh_want" "$DATA/fod/.ui_stopping"
# A reinstallation owns the settings again; cancel only our deferred uninstall job.
rm -f "$DATA/service.d/x6886_restore_settings.sh" "$DATA/fod/.settings_restore_lib.sh" \
  "$DATA/fod/.rom_restore_lib.sh" "$DATA/fod/.rom_restore.dex" "$DATA/fod/.rom_restore.conf"
if [ ! -f "$DATA/fod/gsi.conf" ]; then
cat > "$DATA/fod/gsi.conf" <<'CONF'
PERF_GOVERNOR=0   # Leave CPU governor policy to Android/vendor defaults
SF_BOOST=1        # SurfaceFlinger -> top-app cpuset, nice -8
CONF
fi
# v11.2: new optional config (created once, never overwritten)
if [ ! -f "$DATA/fod/bg.conf" ]; then
cat > "$DATA/fod/bg.conf" <<'CONF'
# packages allowed to run in the background / bypass Doze (add e.g. com.whatsapp)
KEEP_PKGS="com.google.android.gms com.facebook.orca"
CONF
fi
# v14.1: DRAM lock (dramlock.sh): max while the screen is on, half while it is off (created once, never overwritten)
if [ ! -f "$DATA/fod/dram.conf" ]; then
cat > "$DATA/fod/dram.conf" <<'CONF'
DRAM_LOCK=1       # 0 = give the DRAM back to the stock MediaTek governor
ON_FREQ=max       # screen on:  max | min | a Hz value from available_frequencies (e.g. 3200000000)
OFF_FREQ=half     # screen off: half (largest step <= ON/2, 1866 MHz with a 4266 MHz max) | min | max | Hz
RECONCILE_S=60    # re-check screen state and re-assert the lock every N seconds (events are instant)
SCREEN_POLL=1     # also watch the panel (dpms/backlight) every 0.5 s in case screen events are missed
CONF
fi
grep -q "^SCREEN_POLL=" "$DATA/fod/dram.conf" 2>/dev/null || echo "SCREEN_POLL=1" >> "$DATA/fod/dram.conf"
# A manual always-max boot script would fight the screen-off half step: park it (reversible).
for f in "$DATA/service.d/lock_dram.sh" "$DATA/post-fs-data.d/lock_dram.sh" "$DATA"/service.d/*.sh "$DATA"/post-fs-data.d/*.sh; do
  if [ -f "$f" ] && grep -q mtk-dvfsrc-devfreq "$f" 2>/dev/null && grep -q userspace "$f" 2>/dev/null; then
    mv -f "$f" "$f.disabled_by_x6886" && chmod 0644 "$f.disabled_by_x6886"
    ui_print "- parked $f (DRAM lock is now handled by this module)"
  fi
done
# v7/v10: add new keys to existing configs without touching the user's values
addkey() { grep -q "^$2=" "$1" 2>/dev/null || echo "$2=$3" >> "$1"; }
addkey "$DATA/fod/hbm.conf" WAIT_SO 80
addkey "$DATA/fod/hbm.conf" FAST_FILTER 1
addkey "$DATA/fod/gsi.conf" VM_DIRTY 1
addkey "$DATA/fod/gsi.conf" DEX_INSTALL_VERIFY 1
addkey "$DATA/fod/gsi.conf" FAST_FIRST_BOOT 1
addkey "$DATA/fod/gsi.conf" BOOT_THREADS 0
# Level 2 v3: migrate the former force-latch default to the pictured safer auto mode.
# Other custom gsi.conf tuning is left intact.
if grep -q '^SF_LATCH_UNSIGNALED=' "$DATA/fod/gsi.conf"; then
  sed -i 's/^SF_LATCH_UNSIGNALED=.*/SF_LATCH_UNSIGNALED=0/' "$DATA/fod/gsi.conf"
else
  echo 'SF_LATCH_UNSIGNALED=0' >> "$DATA/fod/gsi.conf"
fi
if grep -q '^SF_AUTO_LATCH_UNSIGNALED=' "$DATA/fod/gsi.conf"; then
  sed -i 's/^SF_AUTO_LATCH_UNSIGNALED=.*/SF_AUTO_LATCH_UNSIGNALED=1/' "$DATA/fod/gsi.conf"
else
  echo 'SF_AUTO_LATCH_UNSIGNALED=1' >> "$DATA/fod/gsi.conf"
fi
addkey "$DATA/fod/hbm.conf" PROP_WAIT 0
sed -i 's/^PROP_WAIT=.*/PROP_WAIT=0/' "$DATA/fod/hbm.conf"   # v11.2.1: back to proven polling
addkey "$DATA/fod/dlfix.conf" ADAPTIVE 1
addkey "$DATA/fod/dlfix.conf" PSI_CPU 8
addkey "$DATA/fod/dlfix.conf" PSI_IO 8
addkey "$DATA/fod/dlfix.conf" HOLD_S 30
addkey "$DATA/fod/dlfix.conf" INTERVAL_IDLE 10
# v10.4 safety override: never permit battery sysfs scaling, even from an old config.
if grep -q "^CAP_FIX=" "$DATA/fod/gsi.conf" 2>/dev/null; then
  sed -i 's/^CAP_FIX=.*/CAP_FIX=0/' "$DATA/fod/gsi.conf"
else
  echo "CAP_FIX=0" >> "$DATA/fod/gsi.conf"
fi
# v10.5: SOT watcher/config removed; this module does not manage Settings battery history.
rm -f "$DATA/fod/screentime.conf" "$DATA/fod/screentime.now"
# Double-tap-to-wake listener/config removed.
rm -f "$DATA/fod/dt2w.conf" "$DATA/fod/dt2w.log" "$DATA/fod/dt2w_last_wake" "$DATA/fod/.dt2w_main.pid" "$DATA/fod/.dt2w_getevent.pid"
# GPU governor (gpufix) removed; clean up legacy main-module state in /data/adb/fod only
# (leaves any separate standalone GPU module state untouched).
rm -f "$DATA/fod/gpu.conf" "$DATA/fod/gpu.orig" "$DATA/fod/gpu.log" "$DATA/fod/.gpufix.pid" "$DATA/fod/.gpufix.reload"
# v10: Download Lag Fix settings: migrate the standalone module's config once
[ ! -f "$DATA/fod/dlfix.conf" ] && [ -f "$DATA/dlfix.conf" ] && cp "$DATA/dlfix.conf" "$DATA/fod/dlfix.conf"
# Live PID files belong to the running controller; stale PIDs are checked on launch.
rm -f "$DATA/fod/safe.flag" "$DATA/fod/bootcount"
ui_print "- Configs in /data/adb/fod: hbm.conf refresh.conf gsi.conf dlfix.conf dram.conf sofod_touch.conf(optional)"
ui_print "- v10.5: SOT watcher removed; Settings battery history/database are untouched."
ui_print "- Battery sysfs scaling remains disabled."
ui_print "- Logs in /data/adb/fod: hbm.log hal.log refresh.log dlfix.log dram.log sofod_touch.log gsi.log"
ui_print "- Level 2 v2: wake/boot-safe refresh recovery; other tuning is retained."
ui_print "- Android animation scales = 0.4x (window / transition / animator)."
ui_print "- 144 Hz normal / verified 120 Hz FOD; 120 Hz pre-armed during sleep/early boot."
ui_print "- Wake guard, continued retries and live-vote recovery; compatible modes only."
ui_print "- Uses compatible display modes; falls back to 120 Hz if 144 Hz is unavailable."
ui_print "- DRAM lock - 4266 MHz screen on / 1866 MHz screen off. dram.conf"
ui_print "- Reboot to apply."
