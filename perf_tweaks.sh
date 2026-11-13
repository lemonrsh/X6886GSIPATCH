#!/system/bin/sh
# v10: also the place where the first-boot (verify-only) apps get their real compile, when idle.
# From gsi_perf_tweaks. In the original module this script sat in a "post-fs-data.d" folder INSIDE the module,
# which Magisk never executes, so it never ran. It now runs after boot (SurfaceFlinger does not exist earlier).
# The props from that module (debug.sf.latch_unsignaled, dex2oat-threads, ...) are in system.prop and always applied.
D=/data/adb/fod; CONF=$D/gsi.conf; LOG=$D/gsi.log
PERF_GOVERNOR=0   # Optional one-time performance-governor request; disabled by default
SF_BOOST=1        # SurfaceFlinger -> top-app cpuset and nice -8 (re-applied if SurfaceFlinger restarts)
READ_AHEAD_KB=256 # storage read-ahead (0 = leave default); helps app launch / big file reads
VM_DIRTY=1        # v7: cap dirty page cache (64 MB background / 256 MB hard) so big downloads cannot cause long writeback stalls
DEXOPT=1          # once per module version: run Android's background dexopt when idle (screen off, charging or >=40%)
MODDIR=${0%/*}
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance perf_tweaks
mkdir -p $D
[ -f $CONF ] && . $CONF
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done
sleep 5
: > $LOG
if [ "$PERF_GOVERNOR" = 1 ]; then
  # Opt-in only; apply once and leave ongoing governor policy to Android/vendor HAL.
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    echo performance > "$p/scaling_governor" 2>/dev/null && echo "$p -> performance" >> "$LOG" || echo "$p: write failed" >> "$LOG"
  done
else
  echo "CPU governor left to Android/vendor policy" >> "$LOG"
fi
boost_sf() {
  SF=$(pidof surfaceflinger | cut -d' ' -f1)
  [ -n "$SF" ] || { echo "surfaceflinger pid not found" >> $LOG; return 1; }
  { echo $SF > /dev/cpuset/top-app/tasks; } 2>/dev/null || { echo $SF > /sys/fs/cgroup/cpuset/top-app/tasks; } 2>/dev/null
  renice -n -8 -p $SF >/dev/null 2>&1
  echo "$(date +%T) surfaceflinger pid $SF -> top-app, nice -8" >> $LOG
  # v7: the composer HAL does the actual layer composition for SF, give it the same priority
  for H in $(pgrep -f 'graphics.composer' 2>/dev/null); do
    renice -n -8 -p $H >/dev/null 2>&1
    echo "$(date +%T) composer HAL pid $H nice -8" >> $LOG
  done
}
if [ "$READ_AHEAD_KB" != 0 ]; then
  for b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
    [ -w "$b/queue/read_ahead_kb" ] && echo $READ_AHEAD_KB > "$b/queue/read_ahead_kb" 2>/dev/null
  done
  echo "read_ahead_kb=$READ_AHEAD_KB" >> $LOG
fi
if [ "$VM_DIRTY" = 1 ]; then
  echo 67108864  > /proc/sys/vm/dirty_background_bytes 2>/dev/null
  echo 268435456 > /proc/sys/vm/dirty_bytes 2>/dev/null
  echo "vm dirty caps set (bg 64M / hard 256M)" >> $LOG
fi
# v10: dex2oat/odrefresh/artd deprioritising moved to dlfix.sh (one place, no double work)
# --- dexopt idle helpers (regression-tested by .github/tests/test_fixes.py) ---
dexopt_screen_idle() {
  # AOD commonly reports Dozing rather than Asleep. Both are idle enough for the
  # framework's background dexopt job; Awake/Dreaming/unknown states are not.
  _dex_state=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
  case "$_dex_state" in Asleep|Dozing) return 0 ;; *) return 1 ;; esac
}
dexopt_power_ok() {
  _dex_lvl=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  case "$_dex_lvl" in ''|*[!0-9]*) _dex_lvl=0 ;; esac
  dumpsys battery 2>/dev/null | grep -q 'powered: true' && return 0
  [ "$_dex_lvl" -ge 40 ]
}
# --- end dexopt idle helpers ---
if [ "$DEXOPT" = 1 ]; then
  VC=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null); FL=$D/dexopt.$VC
  if [ ! -f "$FL" ]; then
    ( n=0
      while [ $n -lt 144 ]; do   # up to 12 h, check every 5 min
        sleep 300; n=$((n+1))
        dexopt_screen_idle || continue
        dexopt_power_ok || continue
        echo "$(date +%T) dexopt start (screen idle)" >> $LOG
        if cmd package bg-dexopt-job >/dev/null 2>&1; then
          echo "$(date +%T) dexopt job queued" >> $LOG; touch "$FL"; break
        else
          echo "$(date +%T) dexopt job failed; will retry" >> $LOG
        fi
      done ) &
  fi
fi
# --- SF watchdog (host-tested in test_low_cpu.py) ---
if [ "$SF_BOOST" = 1 ]; then
  boost_sf
  ( LASTSF=$SF
    LASTSTAMP=""; if process_stamp "$LASTSF"; then LASTSTAMP=$PROC_STAMP; fi
    while true; do sleep 30
      if process_unchanged "$LASTSF" "$LASTSTAMP"; then continue; fi
      N=$(pidof surfaceflinger | cut -d' ' -f1)
      [ -n "$N" ] || continue
      NSTAMP=""; if process_stamp "$N"; then NSTAMP=$PROC_STAMP; fi
      if [ "$N" != "$LASTSF" ] || { [ -n "$NSTAMP" ] && [ "$NSTAMP" != "$LASTSTAMP" ]; }; then
        echo "$(date +%T) SurfaceFlinger restarted" >> $LOG; boost_sf
      fi
      LASTSF=$N; LASTSTAMP=$NSTAMP
    done ) &
fi

# --- end SF watchdog ---
