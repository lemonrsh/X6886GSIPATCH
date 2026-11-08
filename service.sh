#!/system/bin/sh
# X6886_GSI_PATCH_level_1_by_lemonrsh - launcher. Every part runs as its own background process so a
# blocking part (the FOD HBM loop) can never hold up the others. All parts live next to this file.
# v11.2: parts are staggered 1 s apart (less boot contention), and every
# long-running part now has a single-instance guard (lib.sh) so a re-run never duplicates listeners.
MODDIR=${0%/*}
# v10: refresh controller FIRST (fallback - normally post-fs-data.sh already started it; refresh.sh is single-instance)
[ -f "$MODDIR/refresh.sh" ] && ( sh "$MODDIR/refresh.sh" >/dev/null 2>&1 & )
# boot counter (safe mode, see post-fs-data.sh): reset once the phone is up for 20 s past boot completed
( while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done; sleep 20; echo 0 > /data/adb/fod/bootcount ) &
# v11.2.4: VoWiFi / WiFi Calling persistent enable (PHH GSI + MediaTek vendor)
# Set during early boot before persist props become read-only.
( while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done
  sleep 5
  setprop persist.sys.phh.ims.aosp true 2>/dev/null
  settings put global wifi_calling 1 2>/dev/null
  settings put global volte_provisioned 1 2>/dev/null
  echo "$(date +%T) VoWiFi: persist.sys.phh.ims.aosp=true, wifi_calling=1" >> /data/adb/fod/gsi.log 2>/dev/null
) &
(
  for part in fod_service.sh dt2w.sh dlfix.sh perf_tweaks.sh messenger_bg.sh otp_autofix.sh; do
    if [ -f "$MODDIR/$part" ]; then
      ( sh "$MODDIR/$part" >/dev/null 2>&1 & )
    fi
    sleep 1
  done
) &
