#!/system/bin/sh
# Stop settings writers first, then restore only values this module still owns.
MODDIR=${0%/*}
DATA=${FODDATA:-/data/adb}
D=$DATA/fod
RESTORE=$DATA/service.d/x6886_restore_settings.sh
mkdir -p "$D"
touch "$D/.ui_stopping"
for part in refresh_supervisor refresh animations rom_defaults sot_reset; do
  p=""
  [ -r "$D/.$part.pid" ] && read -r p < "$D/.$part.pid"
  case "$p" in ''|*[!0-9]*) continue ;; esac
  if [ "$p" -gt 1 ] && grep -q "$part.sh" "/proc/$p/cmdline" 2>/dev/null; then
    kill "$p" 2>/dev/null || true
  fi
done
# The bounded app_process child must not outlive the boot task and race restoration.
p=""; [ -r "$D/.rom_defaults_java.pid" ] && read -r p < "$D/.rom_defaults_java.pid"
case "$p" in ''|*[!0-9]*) ;; *)
  if [ "$p" -gt 1 ] && grep -q X6886RomDefaults "/proc/$p/cmdline" 2>/dev/null; then kill "$p" 2>/dev/null || true; fi ;;
esac
# Give an in-flight settings command time to finish before restoring its value.
sleep 1
[ -f "$MODDIR/settings_state.sh" ] && . "$MODDIR/settings_state.sh" && module_settings_restore
[ -f "$MODDIR/rom_defaults_lib.sh" ] && . "$MODDIR/rom_defaults_lib.sh" && rom_defaults_restore
# Magisk normally removes modules before providers/owner CE storage are ready.
# Persist ONLY our helpers outside MODDIR so the removal reboot can finish safely.
PENDING=0
for orig in "$D"/settings.*.orig "$D"/phh.prop.*.orig "$D"/rom.*.orig; do [ -f "$orig" ] && PENDING=1; done
if [ "$PENDING" = 1 ] && [ -f "$MODDIR/settings_state.sh" ]; then
  mkdir -p "$DATA/service.d"
  cp -f "$MODDIR/settings_state.sh" "$D/.settings_restore_lib.sh"
  chmod 0600 "$D/.settings_restore_lib.sh"
  if [ -f "$MODDIR/rom_defaults_lib.sh" ] && [ -f "$MODDIR/rom-defaults.dex" ] && [ -f "$MODDIR/phh-defaults.conf" ]; then
    cp -f "$MODDIR/rom_defaults_lib.sh" "$D/.rom_restore_lib.sh"
    cp -f "$MODDIR/rom-defaults.dex" "$D/.rom_restore.dex"
    cp -f "$MODDIR/phh-defaults.conf" "$D/.rom_restore.conf"
    chmod 0600 "$D/.rom_restore_lib.sh" "$D/.rom_restore.dex" "$D/.rom_restore.conf"
  fi
  {
    printf '#!/system/bin/sh\nD=\047%s\047\n' "$D"
    cat <<'RESTORE_JOB'
# One-shot X6886 settings restoration after Magisk's early-boot module removal.
restore_cleanup() {
  rm -f "$D/.settings_restore_lib.sh" "$D/.rom_restore_lib.sh" "$D/.rom_restore.dex" "$D/.rom_restore.conf" "$0"
}
if [ ! -f "$D/.ui_stopping" ]; then restore_cleanup; exit 0; fi
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
[ -f "$D/.settings_restore_lib.sh" ] || exit 0
. "$D/.settings_restore_lib.sh"
ROM_DEX=$D/.rom_restore.dex; ROM_TABLE=$D/.rom_restore.conf
[ -f "$D/.rom_restore_lib.sh" ] && . "$D/.rom_restore_lib.sh"
trap 'command -v rom_resume_phh >/dev/null 2>&1 && rom_resume_phh' EXIT
trap 'exit 0' HUP INT TERM
n=0
while [ -f "$D/.ui_stopping" ] && [ "$n" -lt 60 ]; do
  module_settings_restore
  command -v rom_defaults_restore >/dev/null 2>&1 && rom_defaults_restore
  pending=0
  for orig in "$D"/settings.*.orig "$D"/phh.prop.*.orig "$D"/rom.*.orig; do [ -f "$orig" ] && pending=1; done
  if [ "$pending" = 0 ]; then restore_cleanup; exit 0; fi
  n=$((n+1)); sleep 10
done
# If Android/owner CE was still unavailable, retain helpers and originals for next boot.
RESTORE_JOB
  } > "$RESTORE"
  chmod 0755 "$RESTORE"
else
  rm -f "$RESTORE" "$D/.settings_restore_lib.sh" "$D/.rom_restore_lib.sh" "$D/.rom_restore.dex" "$D/.rom_restore.conf"
fi
# Restore display HBM only; never touch battery sysfs nodes. Magisk's removal
# reboot clears the SurfaceFlinger mode pin and all other module processes.
{ echo 0 > /sys/kernel/tran_display/lcm_hbm_state; } 2>/dev/null
rm -f "$D/.refresh_ready" "$D/.refresh_applied" "$D/.refresh_hold.hbm" "$D/.refresh_hold.sofod" \
  "$D/.refresh_power" "$D/.refresh_session" "$D/.refresh_epoch" "$D/.refresh_stream_reset"
exit 0
