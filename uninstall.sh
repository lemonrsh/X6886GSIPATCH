#!/system/bin/sh
# Stop settings writers first, then restore only settings this module still owns.
MODDIR=${0%/*}
DATA=${FODDATA:-/data/adb}
D=$DATA/fod
RESTORE=$DATA/service.d/x6886_restore_settings.sh
mkdir -p "$D"
touch "$D/.ui_stopping"
for part in refresh_supervisor refresh animations; do
  p=""
  [ -r "$D/.$part.pid" ] && read -r p < "$D/.$part.pid"
  case "$p" in ''|*[!0-9]*) continue ;; esac
  if [ "$p" -gt 1 ] && grep -q "$part.sh" "/proc/$p/cmdline" 2>/dev/null; then
    kill "$p" 2>/dev/null || true
  fi
done
# Give an in-flight settings command time to finish before restoring its value.
sleep 1
[ -f "$MODDIR/settings_state.sh" ] && . "$MODDIR/settings_state.sh" && module_settings_restore
# Magisk normally removes modules before the settings provider is ready. Keep a
# tiny, module-owned service.d job outside MODDIR so the removal reboot can finish
# restoration after boot. Never discard snapshots just because a service is down.
PENDING=0
for orig in "$D"/settings.*.orig; do [ -f "$orig" ] && PENDING=1; done
if [ "$PENDING" = 1 ] && [ -f "$MODDIR/settings_state.sh" ]; then
  mkdir -p "$DATA/service.d"
  cp -f "$MODDIR/settings_state.sh" "$D/.settings_restore_lib.sh"
  chmod 0600 "$D/.settings_restore_lib.sh"
  {
    printf '#!/system/bin/sh\nD=\047%s\047\n' "$D"
    cat <<'RESTORE_JOB'
# One-shot X6886 settings restoration after Magisk's early-boot module removal.
if [ ! -f "$D/.ui_stopping" ]; then
  rm -f "$D/.settings_restore_lib.sh" "$0"
  exit 0
fi
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
[ -f "$D/.settings_restore_lib.sh" ] || exit 0
. "$D/.settings_restore_lib.sh"
n=0
while [ -f "$D/.ui_stopping" ] && [ "$n" -lt 12 ]; do
  module_settings_restore
  pending=0
  for orig in "$D"/settings.*.orig; do [ -f "$orig" ] && pending=1; done
  if [ "$pending" = 0 ]; then
    rm -f "$D/.settings_restore_lib.sh" "$0"
    exit 0
  fi
  n=$((n+1)); sleep 5
done
# If Android was still unavailable, retain the job and originals for next boot.
RESTORE_JOB
  } > "$RESTORE"
  chmod 0755 "$RESTORE"
else
  rm -f "$RESTORE" "$D/.settings_restore_lib.sh"
fi
# Restore display HBM only; never touch battery sysfs nodes. Magisk's removal
# reboot clears the SurfaceFlinger mode pin and all other module processes.
{ echo 0 > /sys/kernel/tran_display/lcm_hbm_state; } 2>/dev/null
rm -f "$D/.refresh_ready" "$D/.refresh_applied" "$D/.refresh_hold.hbm" "$D/.refresh_hold.sofod"
exit 0
