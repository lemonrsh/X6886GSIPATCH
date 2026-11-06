#!/system/bin/sh
# v10: also the place where the first-boot (verify-only) apps get their real compile, when idle.
# From gsi_perf_tweaks. In the original module this script sat in a "post-fs-data.d" folder INSIDE the module,
# which Magisk never executes, so it never ran. It now runs after boot (SurfaceFlinger does not exist earlier).
# The props from that module (debug.sf.latch_unsignaled, dex2oat-threads, ...) are in system.prop and always applied.
D=/data/adb/fod; CONF=$D/gsi.conf; LOG=$D/gsi.log
PERF_GOVERNOR=0   # 1 = pin every CPU policy to the performance governor (more heat and battery drain)
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
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    echo performance > "$p/scaling_governor" 2>/dev/null && echo "$p -> performance" >> $LOG || echo "$p: write failed" >> $LOG
  done
else
  echo "governor lock off (PERF_GOVERNOR=0)" >> $LOG
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
if [ "$DEXOPT" = 1 ]; then
  VC=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null); FL=$D/dexopt.$VC
  if [ ! -f "$FL" ]; then
    ( n=0
      while [ $n -lt 144 ]; do   # up to 12 h, check every 5 min
        sleep 300; n=$((n+1))
        dumpsys power 2>/dev/null | grep -q "mWakefulness=Asleep" || continue
        lvl=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); chg=$(dumpsys battery 2>/dev/null | grep -c "powered: true")
        [ "$chg" -gt 0 ] || [ "${lvl:-0}" -ge 40 ] || continue
        echo "$(date +%T) dexopt start" >> $LOG; cmd package bg-dexopt-job >/dev/null 2>&1
        echo "$(date +%T) dexopt job queued" >> $LOG; touch "$FL"; break
      done ) &
  fi
fi
if [ "$SF_BOOST" = 1 ]; then
  boost_sf
  ( LASTSF=$(pidof surfaceflinger | cut -d' ' -f1)
    while true; do sleep 30
      N=$(pidof surfaceflinger | cut -d' ' -f1)
      [ -n "$N" ] && [ "$N" != "$LASTSF" ] && { LASTSF=$N; echo "$(date +%T) SurfaceFlinger restarted" >> $LOG; boost_sf; }
    done ) &
fi
