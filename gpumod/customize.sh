#!/system/bin/sh
# Installer for the standalone X6886 GPU governor. The logic lives in gpufix.sh, which is
# also the main patch's copy; CI checks the two stay identical.
MODDIR=${0%/*}
STATE=/data/adb/gpufix
CFG=$STATE/gpu.conf
mkdir -p "$STATE"

# Stop a governor from an earlier install (own PID file, no pkill).
if [ -r "$STATE/.gpufix.pid" ]; then
  OLD=$(cat "$STATE/.gpufix.pid" 2>/dev/null)
  case "$OLD" in
    ''|*[!0-9]*) ;;
    *) [ "$OLD" -gt 1 ] && grep -q gpufix "/proc/$OLD/cmdline" 2>/dev/null && kill "$OLD" 2>/dev/null ;;
  esac
  rm -f "$STATE/.gpufix.pid"
fi

if [ ! -f "$CFG" ]; then
cat > "$CFG" <<'CONF'
# X6886 GPU governor. Applies at boot when ENABLED=1.
# Presets: sh gpufix.sh preset max    (floor at the fastest OPP, whole system)
#          sh gpufix.sh preset boost  (390 idle -> 1200 busy, the default below)
#          sh gpufix.sh preset stock  (release everything)
ENABLED=1            # 0 = install but do nothing
MODE=adaptive        # adaptive (load-following) | floor (always max) | off (always stock)
MIN_HZ=390000        # floor while idle (stock floor)
TOP_HZ=1200000       # floor while busy; 0 = the fastest OPP (1600 MHz)
LOAD_ON=60           # gpu_utilization load %, at or above this counts as busy
HOLD_S=20            # keep the floor up this long after the last busy sample
INTERVAL=1           # governor period in seconds
HOT_HZ=0             # floor while above TEMP_MAX; 0 = MIN_HZ
TEMP_MAX=430         # >= this battery temperature (deci-degC) lowers the floor
SYNC_PARAM=1         # keep gpu_cust_boost_freq in sync with the floor
CONF
fi

if [ ! -w /sys/kernel/ged/hal/custom_boost_gpu_freq ]; then
  ui_print "! /sys/kernel/ged/hal/custom_boost_gpu_freq is missing or read-only."
  ui_print "! This module needs MediaTek GED; the governor will report the problem and idle."
fi
ui_print "- Config: $CFG (ENABLED=1, MODE=adaptive, TOP_HZ=1200000)"
ui_print "- Max performance always: sh $MODPATH/gpufix.sh preset max"
ui_print "- Log: $STATE/gpu.log   Check: sh $MODPATH/gpufix.sh status"
ui_print "- Reboot to start, or run: sh $MODPATH/gpufix.sh run &"
