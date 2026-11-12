#!/system/bin/sh
MODDIR=${0%/*}
# ---- FIRST THING: start the 144 Hz normal / 120 Hz FOD refresh controller ----
# It waits for SurfaceFlinger by itself (never gives up, no boot_completed dependency), runs at nice -8 and is a
# single instance (service.sh launches it again as a fallback; the second one just exits).
if [ -f "$MODDIR/refresh.sh" ]; then
  if command -v setsid >/dev/null 2>&1; then ( setsid sh "$MODDIR/refresh.sh" >/dev/null 2>&1 & )
  else ( sh "$MODDIR/refresh.sh" >/dev/null 2>&1 & ); fi
fi

D=/data/adb/fod; mkdir -p $D
HAL_PATCH=12
[ -f $D/hbm.conf ] && . $D/hbm.conf
LIB=/odm/lib64/libgf_hal.so
SRC=$MODDIR/libs/libgf_hal.p$HAL_PATCH.so
: > $D/hal.log
if [ "$HAL_PATCH" != 0 ] && [ -f "$SRC" ] && [ -f "$LIB" ]; then
  CTX=$(ls -dZ "$LIB" 2>/dev/null | cut -d' ' -f1)
  case "$CTX" in u:*) ;; *) CTX=u:object_r:vendor_file:s0;; esac
  chmod 0644 "$SRC"; chcon "$CTX" "$SRC" 2>/dev/null
  if mount -o bind "$SRC" "$LIB"; then echo "bound p$HAL_PATCH ctx=$CTX" >> $D/hal.log
  else echo "bind mount FAILED" >> $D/hal.log; fi
else
  echo "HAL patch not applied (HAL_PATCH=$HAL_PATCH)" >> $D/hal.log
fi

# SurfaceFlinger / dexopt props are applied here (config driven, with bootloop safe mode) instead of system.prop.
# Safe mode (v10): if 4 boots in a row never reach "boot completed + 20 s", the props are skipped until you delete
# /data/adb/fod/safe.flag. (v7: 3 boots / 60 s - installing several modules and rebooting quickly tripped it.)
# The refresh controller and the download-lag fix are NOT affected by safe mode.
SF_LATCH_UNSIGNALED=1; SF_BACKPRESSURE=1; SF_BUFFERS=3; SF_SKIA_THREADED=1
DEX_INSTALL_VERIFY=1   # install-time dexopt = "verify" (cheap); the idle background dexopt compiles apps later
CAP_FIX=0              # v10.4 SAFETY: never overlay or scale battery sysfs nodes.
FAST_FIRST_BOOT=1      # v10: first boot after install / OTA / module change: "optimizing apps" = verify only (very fast)
BOOT_THREADS=0         # v10: dex2oat threads used while booting; 0 = all CPU cores
[ -f $D/gsi.conf ] && . $D/gsi.conf
BC=$D/bootcount; N=$(cat $BC 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0;; esac
N=$((N+1)); echo $N > $BC
[ $N -ge 4 ] && [ ! -f $D/safe.flag ] && { touch $D/safe.flag; echo "$(date '+%m-%d %T') bootcount=$N -> safe mode ON" >> $D/safe.log; }
if [ -f $D/safe.flag ]; then
  echo "$(date '+%m-%d %T') safe mode: props skipped (rm $D/safe.flag to re-enable)" >> $D/safe.log
else
  RP=resetprop; command -v resetprop >/dev/null 2>&1 || RP=setprop
  [ "$SF_LATCH_UNSIGNALED" = 1 ] && $RP debug.sf.latch_unsignaled 1
  [ "$SF_BACKPRESSURE" = 1 ] && $RP debug.sf.disable_backpressure 1
  [ "$SF_BUFFERS" != 0 ] && $RP ro.surface_flinger.max_frame_buffer_acquired_buffers "$SF_BUFFERS"
  [ "$SF_SKIA_THREADED" = 1 ] && $RP debug.renderengine.backend skiaglthreaded
  if [ "$DEX_INSTALL_VERIFY" = 1 ]; then
    $RP pm.dexopt.install verify; $RP pm.dexopt.install-bulk verify
  fi
  if [ "$FAST_FIRST_BOOT" = 1 ]; then
    # compile NOTHING at boot (verify only); perf_tweaks.sh runs the real background dexopt when the phone is idle
    $RP pm.dexopt.first-boot verify
    $RP pm.dexopt.boot-after-ota verify
    $RP pm.dexopt.boot-after-mainline-update verify
    $RP pm.dexopt.post-boot verify
    case "$BOOT_THREADS" in ''|*[!0-9]*|0) BOOT_THREADS=$(nproc 2>/dev/null);; esac
    case "$BOOT_THREADS" in ''|*[!0-9]*|0) BOOT_THREADS=8;; esac
    $RP dalvik.vm.boot-dex2oat-threads "$BOOT_THREADS"
  fi
fi
