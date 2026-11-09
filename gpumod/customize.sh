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
# Presets: sh gpufix.sh preset safer  (top OPP on load, lowest OPP screen-off - default)
#          sh gpufix.sh preset max    (floor at the fastest OPP, always, whole system)
#          sh gpufix.sh preset boost  (390 idle -> 1200 busy, mild)
#          sh gpufix.sh preset stock  (release everything)
ENABLED=1            # 0 = install but do nothing
MODE=safer           # safer (screen-aware) | adaptive | floor (always max) | off (always stock)
MIN_HZ=390000        # floor while idle, and always while the screen is off
SCREEN_OFF_MIN=1     # 1 = lowest OPP whenever the screen is off (recommended)
BAT_MIN=15           # below this battery % (not charging) do not raise the floor
TOP_HZ=0             # floor while busy; 0 = the fastest OPP (1600 MHz)
LOAD_ON=60           # gpu_utilization load %, at or above this counts as busy
HOLD_S=20            # keep the floor up this long after the last busy sample
INTERVAL=1           # governor period in seconds
HOT_HZ=0             # floor while above TEMP_MAX; 0 = MIN_HZ
TEMP_MAX=500         # ONLY at/above this temperature (deci-degC = 50 C) the floor drops
CEIL_HZ=1600000      # GED upper bound published by the governor; 0 = the fastest OPP
TOP_INDEX=44         # slowest OPP index, used only when /proc/gpufreqv2 is unreadable
SYNC_PARAM=1         # keep gpu_cust_boost_freq in sync with the floor
CONF
fi

# v1.3.0: single throttle point at 50 C (older installs carried 43 C).
if grep -q '^TEMP_MAX=430$' "$CFG" 2>/dev/null; then
  sed -i 's/^TEMP_MAX=430$/TEMP_MAX=500/' "$CFG"
  ui_print "- gpu.conf: TEMP_MAX 430 -> 500 (throttle only at 50 C)"
fi
grep -q '^TEMP_MIN=' "$CFG" 2>/dev/null && sed -i '/^TEMP_MIN=/d' "$CFG"

if [ ! -w /sys/kernel/ged/hal/custom_boost_gpu_freq ]; then
  ui_print "! /sys/kernel/ged/hal/custom_boost_gpu_freq is missing or read-only."
  ui_print "! This module needs MediaTek GED; the governor will report the problem and idle."
fi

# v1.3.0: choose the profile with the volume keys at install time. Both choices boost the
# GPU for the whole system; they differ in what happens when the GPU is idle / screen off.
# A non-interactive flash (twrp, CI) keeps SAFER without waiting.
ui_print "- Choose the profile: VOLUME UP = SAFER (recommended), VOLUME DOWN = MAX."
ui_print "  SAFER  top OPP for every app on load, lowest OPP when the screen is off"
ui_print "  MAX    pinned at the top OPP, always (fastest, hottest, thirstiest)"
ui_print "  no press in 20 s = SAFER"
ui_print " "
GPUFIX_STATE="$STATE" GPUFIX_CHOICE=$MODPATH/.choice sh "$MODPATH/gpufix.sh" choose >&2
_CH=$(cat "$MODPATH/.choice" 2>/dev/null)
rm -f "$MODPATH/.choice"
[ -n "$_CH" ] || _CH=safer
GPUFIX_STATE="$STATE" sh "$MODPATH/gpufix.sh" preset "$_CH" >&2 || true
ui_print "- Config: $CFG (MODE=${_CH}, ENABLED=1)"
ui_print "- Change it later: sh $MODPATH/gpufix.sh preset safer | preset max"
ui_print "- Log: $STATE/gpu.log   Check: sh $MODPATH/gpufix.sh status"
ui_print "- Reboot to start, or run: sh $MODPATH/gpufix.sh run &"
