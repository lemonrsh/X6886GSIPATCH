#!/system/bin/sh
# Reset Android BatteryStats once on each verified full-charge transition.
# This affects Android's battery-history/SOT baseline; it does not modify battery sysfs.
MODDIR=${0%/*}
D=/data/adb/fod
CONF=$D/sot_reset.conf
STATE=$D/.sot_full_reset_done
LOG=$D/sot_reset.log
CAPACITY=/sys/class/power_supply/battery/capacity
STATUS=/sys/class/power_supply/battery/status
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance sot_reset
mkdir -p "$D"
SOT_RESET=1
[ -f "$CONF" ] && . "$CONF"
[ "$SOT_RESET" = 1 ] || exit 0
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 5; done
sleep 30
while true; do
  _sot_capacity=""
  IFS= read -r _sot_capacity < "$CAPACITY" 2>/dev/null || :
  _sot_status=""
  IFS= read -r _sot_status < "$STATUS" 2>/dev/null || :
  case "$_sot_capacity" in 100) ;; *) _sot_capacity=0 ;; esac
  if [ "$_sot_capacity" = 100 ] && [ "$_sot_status" = Full ]; then
    if [ ! -f "$STATE" ]; then
      if dumpsys batterystats --reset >/dev/null 2>&1; then
        : > "$STATE"
        echo "$(date +%T) battery stats reset once at full charge" >> "$LOG"
      else
        echo "$(date +%T) battery stats reset failed; will retry while full" >> "$LOG"
      fi
    fi
  else
    # Re-arm only after leaving the full state, so a long full-charge dwell
    # or daemon restart cannot reset battery history repeatedly.
    rm -f "$STATE"
  fi
  sleep 60
done
