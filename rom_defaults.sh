#!/system/bin/sh
# Finite boot task for the screenshot settings; never a hot polling daemon.
MODDIR=${0%/*}
D=/data/adb/fod
mkdir -p "$D"
. "$MODDIR/lib.sh"
single_instance rom_defaults
. "$MODDIR/rom_defaults_lib.sh"
trap 'rom_resume_phh' EXIT
trap 'exit 0' HUP INT TERM
rom_stopping() {
  [ -f "$D/.ui_stopping" ] || [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]
}
while [ "$(getprop sys.boot_completed)" != 1 ]; do
  rom_stopping && exit 0
  sleep 2
done
rom_stopping && exit 0
if [ -f "$D/safe.flag" ] || [ -f "$D/rom-defaults.disabled" ]; then
  rom_defaults_restore
  exit 0
fi
: > "$D/rom-defaults.log"
# Framework settings do not depend on PHH, and lock timeout is in Settings.Secure.
rom_java apply-settings >> "$D/rom-defaults.log" 2>&1
# CE preferences and PIN-length metadata are unavailable until the owner's first
# unlock. Retry at low cadence for at most 10 minutes, then defer to the next boot.
n=0
while [ "$n" -lt 60 ]; do
  rom_stopping && exit 0
  if [ -f "$D/safe.flag" ] || [ -f "$D/rom-defaults.disabled" ]; then rom_defaults_restore; exit 0; fi
  if rom_java ready >/dev/null 2>> "$D/rom-defaults.log"; then
    rom_prefs_run apply
    # Auto-confirm uses LockPatternUtils AFTER unlock, not an invented settings key.
    rom_java apply-unlocked >> "$D/rom-defaults.log" 2>&1
    exit 0
  fi
  n=$((n+1)); sleep 10
done
echo 'owner still locked/unavailable; CE/PIN defaults deferred until next boot' >> "$D/rom-defaults.log"
