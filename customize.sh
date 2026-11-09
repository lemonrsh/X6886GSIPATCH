#!/system/bin/sh
# X6886_GSI_PATCH_level_1_by_lemonrsh installer
STOCK="789c228681e5f5c66bcf84bde58591f6e45ec2c4afbea8944dcd48b6eecf74af"
P12="8aff6aa4553978a65c6db2558464b14b745eeb360128dff6838afadd8527d260"
P123="eb42af99c471a25f2feef7f3c9e0eb9629a32871b662340cca877860cc134ebd"
N12="22467890811df0e2212e3947a490f0030cd74379e271ef6f654aaaa6433e103e"
N123="28ac013c65c32cbb55c682e66d9fc0e26a7f82a9cbfb7c26a57f512cc3104c84"
DATA=${FODDATA:-/data/adb}
# Stop any watchers left running by an older release before replacing the module.
for pid in $(ps -A -o PID,ARGS 2>/dev/null | awk 'NR>1 && (/\/screentime\.sh([[:space:]]|$)/ || /\/dt2w\.sh([[:space:]]|$)/) {print $1}'); do
  kill "$pid" 2>/dev/null
done
if [ -r "$DATA/fod/.dt2w_getevent.pid" ]; then
  gpid=$(cat "$DATA/fod/.dt2w_getevent.pid" 2>/dev/null)
  case "$gpid" in
    ''|*[!0-9]*) ;;
    *) [ "$gpid" -gt 1 ] && grep -q getevent "/proc/$gpid/cmdline" 2>/dev/null && kill "$gpid" 2>/dev/null ;;
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
# v10.6: fixed 120 Hz at all times; discard legacy 144/120 fingerprint switching config.
cat > "$DATA/fod/refresh.conf" <<'CONF'
TARGET_HZ=120
RECONCILE_S=120
SETTINGS_RATE=1
CONF
if [ ! -f "$DATA/fod/gsi.conf" ]; then
cat > "$DATA/fod/gsi.conf" <<'CONF'
PERF_GOVERNOR=0   # 1 = pin CPU policies to the performance governor (more heat and battery drain)
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
# v11.3: GPU DVFS helper (gpufix.sh). Read-only by default; GPU_FIX=1 is required for apply.
if [ ! -f "$DATA/fod/gpu.conf" ]; then
cat > "$DATA/fod/gpu.conf" <<'CONF'
# GPU DVFS on MT6789 / GED. Helper: sh gpufix.sh [status|probe 20|run|revert]
# Disabled here: the main patch only provides the tool. For the always-on
# governor install the separate GPU-DVFS-X6886 module instead.
ENABLED=0            # 1 = start the governor at boot (0 = never touch the GPU nodes)
MODE=adaptive        # adaptive (load-following) | floor (always max) | off (always stock)
MIN_HZ=390000        # floor while idle (stock floor)
TOP_HZ=0             # floor used by mode=floor: 0 = the fastest OPP (1600 MHz), whole system
LOAD_ON=60           # mode=adaptive only: gpu_utilization load % counted as busy
HOLD_S=20            # mode=adaptive only: keep the floor up this long after the last busy sample
INTERVAL=1           # governor period in seconds
HOT_HZ=0             # floor while above TEMP_MAX; 0 = MIN_HZ, e.g. 900000 to stay fast
TEMP_MAX=430         # >= this battery temperature (deci-degC) lowers the floor
SYNC_PARAM=1         # keep gpu_cust_boost_freq in sync with the floor
SAMPLE_S=10          # default probe/verify window in seconds
CONF
fi
# v7/v10: add new keys to existing configs without touching the user's values
addkey() { grep -q "^$2=" "$1" 2>/dev/null || echo "$2=$3" >> "$1"; }
addkey "$DATA/fod/hbm.conf" WAIT_SO 80
addkey "$DATA/fod/hbm.conf" FAST_FILTER 1
addkey "$DATA/fod/gsi.conf" VM_DIRTY 1
addkey "$DATA/fod/gsi.conf" DEX_INSTALL_VERIFY 1
addkey "$DATA/fod/gsi.conf" FAST_FIRST_BOOT 1
addkey "$DATA/fod/gsi.conf" BOOT_THREADS 0
addkey "$DATA/fod/gpu.conf" SYNC_PARAM 1
addkey "$DATA/fod/gpu.conf" TEMP_MAX 430
addkey "$DATA/fod/gpu.conf" SAMPLE_S 10
addkey "$DATA/fod/gpu.conf" MIN_HZ 390000
addkey "$DATA/fod/gpu.conf" LOAD_ON 60
addkey "$DATA/fod/gpu.conf" HOLD_S 20
addkey "$DATA/fod/gpu.conf" HOT_HZ 0
addkey "$DATA/fod/gpu.conf" TOP_HZ 0
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
# v10: Download Lag Fix settings: migrate the standalone module's config once
[ ! -f "$DATA/fod/dlfix.conf" ] && [ -f "$DATA/dlfix.conf" ] && cp "$DATA/dlfix.conf" "$DATA/fod/dlfix.conf"
rm -f "$DATA/fod/safe.flag" "$DATA/fod/bootcount" "$DATA/fod/.refresh.pid"
ui_print "- Configs in /data/adb/fod: hbm.conf refresh.conf gsi.conf dlfix.conf sofod_touch.conf(optional)"
ui_print "- v10.5: SOT watcher removed; Settings battery history/database are untouched."
ui_print "- Battery sysfs scaling remains disabled."
ui_print "- Logs in /data/adb/fod: hbm.log hal.log refresh.log dlfix.log sofod_touch.log gsi.log"
ui_print "- v10.6: fixed 120 Hz always; 144 Hz/FOD switching removed."
ui_print "- v11.4: GPU governor is opt-in: set ENABLED=1 in gpu.conf, or install GPU-DVFS-X6886."
ui_print "  Max performance always: su -c 'sh \$MODPATH/gpufix.sh preset max' after boot."
ui_print "- v11.2: see CHANGELOG.txt. Config: bg.conf. (DT2W removed)"
ui_print "- Reboot to apply."
