#!/system/bin/sh
# Download Lag Fix (merged from DownloadLagFix v1.1.0, rewritten for v10).
# Keeps download work (Play Store, dex2oat/artd app optimizer, Wi-Fi driver threads) from starving the UI.
# v10: the original ran `ps -A` and walked ~700 processes in shell every 5 s. This version asks the kernel only
#      for the few names it cares about (pidof / pgrep = ~3 forks per cycle) and does nothing for pids it has
#      already handled. It also never touches dex2oat during boot (first-boot "optimizing apps" runs at FULL speed);
#      it starts only after boot_completed + 20 s.
# Config: /data/adb/fod/dlfix.conf   Log: /data/adb/fod/dlfix.log   Stop: DL_ENABLED=0
MODDIR=${0%/*}; [ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance dlfix
D=/data/adb/fod; CONF=$D/dlfix.conf; LOG=$D/dlfix.log; FLAG=$D/.dlfix.nicefail
mkdir -p $D
if [ ! -f "$CONF" ]; then
  if [ -f /data/adb/dlfix.conf ]; then cp /data/adb/dlfix.conf "$CONF"   # migrate the standalone module's settings
  else
cat > "$CONF" <<'CFG'
DL_ENABLED=1
# Processes pushed to the background CPU group while they are NOT on screen (oom_score_adj > 0)
TARGETS="com.android.vending com.android.vending:background"
# Always pushed to the background group + nice 15 + idle IO (app optimizer after installs/updates)
FORCE_TARGETS="dex2oat64 dex2oat32 dex2oat artd odrefresh"
# Wi-Fi driver kernel threads lowered to WIFI_NICE (-10 -> 0). Set WIFI_THREADS="" to disable
WIFI_THREADS="hif_thread main_thread"
WIFI_NICE=0
# background = little cores only (strongest) | system-background = more cores
GROUP=system-background
INTERVAL=5
# v11.2 adaptive mode: only touch Play Store / Wi-Fi threads while CPU or IO pressure (PSI some avg10, %) is high
ADAPTIVE=1
PSI_CPU=8
PSI_IO=8
HOLD_S=30
INTERVAL_IDLE=10
CFG
  fi
fi
DL_ENABLED=1
TARGETS="com.android.vending com.android.vending:background"
FORCE_TARGETS="dex2oat64 dex2oat32 dex2oat artd odrefresh"
WIFI_THREADS="hif_thread main_thread"; WIFI_NICE=0; GROUP=system-background; INTERVAL=5
ADAPTIVE=1; PSI_CPU=8; PSI_IO=8; HOLD_S=30; INTERVAL_IDLE=10   # added in v11.2 (old configs lack them)
. "$CONF"
[ "$DL_ENABLED" = 1 ] || exit 0
WIFI_THREADS=$(echo "$WIFI_THREADS" | tr -d '[]')     # accept the old "[name]" notation

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
sleep 20
rm -f "$FLAG"
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 60000 ] && : > "$LOG"

CS=""; CC=""
[ -w /dev/cpuset/$GROUP/cgroup.procs ] && CS=/dev/cpuset/$GROUP
for d in /dev/cpuctl/$GROUP /dev/stune/$GROUP; do
  [ -w $d/cgroup.procs ] && CC=$d && break
done
echo "$(date +%F_%T) dlfix v11.2 start adaptive=$ADAPTIVE psi_cpu=$PSI_CPU psi_io=$PSI_IO group=$GROUP cpuset=${CS:-none} cpuctl=${CC:-none}" >> "$LOG"
[ -z "$CS" ] && [ -z "$CC" ] && { echo "no usable cgroup found, exiting" >> "$LOG"; exit 1; }

get_nice() { l=""; read -r l < /proc/$1/stat 2>/dev/null; r=${l##*) }; set -- $r; shift 16; echo $1; }
move_pid() {   # returns 1 when the pid is already in the group (= nothing to do)
  cur=""
  [ -n "$CS" ] && read -r cur < /proc/$1/cpuset 2>/dev/null
  [ -n "$CS" ] && [ "$cur" = "/$GROUP" ] && return 1
  [ -n "$CS" ] && echo $1 > $CS/cgroup.procs 2>/dev/null
  [ -n "$CC" ] && echo $1 > $CC/cgroup.procs 2>/dev/null
  return 0
}
is_kthread() { c=$(cat /proc/$1/cmdline 2>/dev/null | tr -d '\0'); [ -z "$c" ]; }

psi_read() {   # $1 = cpu|io -> PSI_V = integer part of "some avg10" (empty if unavailable); no fork
  _l=""; read -r _l 2>/dev/null < /proc/pressure/$1; set -- $_l; _v=${2#avg10=}; PSI_V=${_v%%.*}
}
HOT=1; HOT_UNTIL=0
while true; do
  if [ "$ADAPTIVE" = 1 ] && [ -r /proc/pressure/cpu ]; then
    read -r UP _ < /proc/uptime; UP=${UP%%.*}
    psi_read cpu; PC=$PSI_V; psi_read io; PI=$PSI_V
    case "$PC$PI" in
      ''|*[!0-9]*) HOT=1 ;;
      *) if [ "$PC" -ge "$PSI_CPU" ] || [ "$PI" -ge "$PSI_IO" ]; then HOT_UNTIL=$((UP+HOLD_S)); fi
         if [ "$UP" -lt "$HOT_UNTIL" ]; then HOT=1; else HOT=0; fi ;;
    esac
  else
    HOT=1
  fi
  # 1) apps (only while not on screen, and only under pressure in adaptive mode)
  if [ "$HOT" = 1 ] && [ -n "$TARGETS" ]; then
    for pid in $(pidof $TARGETS 2>/dev/null); do
      adj=""; read -r adj < /proc/$pid/oom_score_adj 2>/dev/null
      if [ -n "$adj" ] && [ "$adj" -gt 0 ]; then
        move_pid $pid && echo "$(date +%T) app pid $pid (adj=$adj) -> $GROUP" >> "$LOG"
      fi
    done
  fi
  # 2) app optimizer: background group + nice 15 + idle IO class, once per pid
  if [ -n "$FORCE_TARGETS" ]; then
    for pid in $(pidof $FORCE_TARGETS 2>/dev/null); do
      if move_pid $pid; then
        renice -n 15 -p $pid >/dev/null 2>&1
        ionice -c 3 -p $pid >/dev/null 2>&1
        echo "$(date +%T) $(cat /proc/$pid/comm 2>/dev/null) pid $pid -> $GROUP nice15 idle-io" >> "$LOG"
      fi
    done
  fi
  # 3) Wi-Fi driver kernel threads
  if [ "$HOT" = 1 ] && [ -n "$WIFI_THREADS" ] && [ ! -f "$FLAG" ]; then
    for w in $WIFI_THREADS; do
      for pid in $(pgrep -x $w 2>/dev/null); do
        n=$(get_nice $pid); [ -z "$n" ] && continue
        [ "$n" = "$WIFI_NICE" ] && continue
        is_kthread $pid || continue
        renice -n $WIFI_NICE -p $pid >/dev/null 2>&1
        a=$(get_nice $pid)
        if [ "$a" != "$WIFI_NICE" ]; then renice -n $((WIFI_NICE - n)) -p $pid >/dev/null 2>&1; a=$(get_nice $pid); fi
        if [ "$a" = "$WIFI_NICE" ]; then echo "$(date +%T) $w ($pid) nice $n -> $a" >> "$LOG"
        else echo "$(date +%T) renice failed for $w (nice still $a), disabling wifi nice" >> "$LOG"; touch "$FLAG"; break 2; fi
      done
    done
  fi
  if [ "$HOT" = 1 ]; then sleep $INTERVAL; else sleep $INTERVAL_IDLE; fi
done
