#!/system/bin/sh
# X6886_GSI_PATCH_level_1_by_lemonrsh - launcher. Every part runs as its own background process so a
# blocking part (the FOD HBM loop) can never hold up the others. All parts live next to this file.
# v11.2: parts are staggered 1 s apart (less boot contention), and every
# long-running part now has a single-instance guard (lib.sh) so a re-run never duplicates listeners.
MODDIR=${0%/*}
# Refresh supervisor FIRST (fallback to the early post-fs-data launch).
[ -f "$MODDIR/refresh_supervisor.sh" ] && ( sh "$MODDIR/refresh_supervisor.sh" >/dev/null 2>&1 & )
# boot counter (safe mode, see post-fs-data.sh): reset once the phone is up for 20 s past boot completed
( while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done; sleep 20; echo 0 > /data/adb/fod/bootcount ) &
(
  for part in animations.sh fod_service.sh dramlock.sh dlfix.sh perf_tweaks.sh messenger_bg.sh otp_autofix.sh; do
    if [ -f "$MODDIR/$part" ]; then
      ( sh "$MODDIR/$part" >/dev/null 2>&1 & )
    fi
    sleep 1
  done
) &
