#!/system/bin/sh
# X6886 v11.2 AOD/Doze double-tap-to-wake listener.
# v11.2: prefilter + stricter gesture (position / movement / multi-touch checks), wake gated on
#        "screen not already awake", faster wake path, log rotation, clean shutdown, node-move watchdog.
# Config (optional): /data/adb/fod/dt2w.conf   Log: /data/adb/fod/dt2w.log
MODDIR=${0%/*}
D=/data/adb/fod
LOG=$D/dt2w.log
PIDFILE=$D/.dt2w_main.pid
GPID=$D/.dt2w_getevent.pid
BUSY=$D/.sofod_busy          # set by sofod_touch.sh while it injects synthetic touches
STAMP=$D/dt2w_last_wake
mkdir -p "$D"

TAP_MIN_MS=80        # min gap between the two taps
TAP_MAX_MS=500       # max gap between the two taps
TAP_HOLD_MS=350      # a tap longer than this is a long-press, not a tap
MAX_DIST_PX=110      # max distance between the two taps
MAX_MOVE_PX=60       # max finger travel inside one tap (rejects swipes)
UNITS_PER_PX=16      # mtk-tpd reports 16 units per pixel on X6886
DEBOUNCE_S=1         # min seconds between two wake-ups
GATE_AWAKE=1         # 1 = do nothing when the screen is already awake
ARM_S=5              # seconds between gesture-register re-arms
WAKE_FAST=0          # 0 = v11.1 wake order (KEYCODE_WAKEUP, then cmd power wake-up); 1 = cmd power first, key only as fallback
[ -f "$D/dt2w.conf" ] && . "$D/dt2w.conf"

# single instance
if [ -r "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  case "$old" in ''|*[!0-9]*) old=0;; esac
  [ "$old" -gt 1 ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null && grep -q dt2w "/proc/$old/cmdline" 2>/dev/null && exit 0
fi
echo $$ > "$PIDFILE"

LC=0
log() {
  echo "$(date '+%F %T' 2>/dev/null) $*" >> "$LOG"
  LC=$((LC+1))
  if [ "$LC" -ge 40 ]; then
    LC=0
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ]; then
      tail -c 20000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    fi
  fi
}

find_touch_node() {
  for d in /sys/class/input/event*; do
    [ "$(cat "$d/device/name" 2>/dev/null)" = "mtk-tpd" ] && { echo "/dev/input/${d##*/}"; return 0; }
  done
  for d in /sys/class/input/event*; do
    case "$(cat "$d/device/name" 2>/dev/null)" in *touch*) echo "/dev/input/${d##*/}"; return 0;; esac
  done
  return 1
}

find_fts_node() {
  for f in \
    /sys/devices/platform/soc/11010000.spi1/spi_master/spi1/spi1.0/fts_gesture_mode \
    /sys/devices/platform/*/*/fts_gesture_mode \
    /sys/devices/platform/*/fts_gesture_mode; do
    [ -e "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

PROC_GESTURE=/proc/gesture_function
FTS=$(find_fts_node 2>/dev/null)
arm_gesture() {
  [ -w "$PROC_GESTURE" ] && echo cc1 > "$PROC_GESTURE" 2>/dev/null
  [ -n "$FTS" ] && [ -w "$FTS" ] && echo 1 > "$FTS" 2>/dev/null
}

ARMPID=""
cleanup() {
  [ -n "$ARMPID" ] && kill "$ARMPID" 2>/dev/null
  gp=$(cat "$GPID" 2>/dev/null); [ -n "$gp" ] && kill "$gp" 2>/dev/null
  rm -f "$PIDFILE" "$GPID"
  exit 0
}
trap cleanup TERM INT HUP

(
  while true; do
    [ -e "$FTS" ] || FTS=$(find_fts_node 2>/dev/null)
    arm_gesture
    sleep "$ARM_S"
  done
) >/dev/null 2>&1 &
ARMPID=$!

last_wake=0
[ -r "$STAMP" ] && last_wake=$(cat "$STAMP" 2>/dev/null)
case "$last_wake" in ''|*[!0-9]*) last_wake=0;; esac

is_awake() { dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'; }

wake_now() {
  reason=$1
  [ -f "$BUSY" ] && return          # synthetic FOD touches in progress: not a real double tap
  now=$(date +%s 2>/dev/null)
  case "$now" in ''|*[!0-9]*) now=0;; esac
  [ "$now" -gt 0 ] && [ $((now-last_wake)) -lt "$DEBOUNCE_S" ] && return
  if [ "$GATE_AWAKE" = 1 ] && is_awake; then return; fi
  last_wake=$now
  echo "$now" > "$STAMP" 2>/dev/null
  if [ "$WAKE_FAST" = 1 ]; then
    log "$reason -> cmd power wake-up (fast)"
    cmd power wake-up >/dev/null 2>&1
    sleep 0.3
    if ! is_awake; then
      log "still not awake -> KEYCODE_WAKEUP fallback"
      input keyevent 224 >/dev/null 2>&1
    fi
  else
    # v11.1 order: the key event wakes with a key reason, which SystemUI needs to start FOD/biometric auth
    log "$reason -> KEYCODE_WAKEUP"
    input keyevent 224 >/dev/null 2>&1
    sleep 0.25
    cmd power wake-up >/dev/null 2>&1
  fi
}

PAT='BTN_TOUCH|ABS_MT_(SLOT|TRACKING_ID|POSITION_[XY])|EV_KEY[[:space:]]+00(c3|c6|fb)'
FILTER_OK=0
echo "BTN_TOUCH" | grep --line-buffered -E "$PAT" >/dev/null 2>&1 && FILTER_OK=1
prefilter() { if [ "$FILTER_OK" = 1 ]; then grep --line-buffered -E "$PAT"; else cat; fi; }

detector() {
  awk -v tmin="$TAP_MIN_MS" -v tmax="$TAP_MAX_MS" -v thold="$TAP_HOLD_MS" \
      -v dist="$((MAX_DIST_PX*UNITS_PER_PX))" -v mv="$((MAX_MOVE_PX*UNITS_PER_PX))" '
    function gettime(s,  a) {
      if (match(s, /\[[[:space:]]*[0-9]+\.[0-9]+\]/)) {
        a=substr(s,RSTART+1,RLENGTH-2); gsub(/[[:space:]]/,"",a); return a+0
      }
      return -1
    }
    function hex(s,  i,c,v,d) {
      v=0; s=tolower(s)
      for (i=1;i<=length(s);i++) { d=index("0123456789abcdef",substr(s,i,1))-1; if (d<0) return -1; v=v*16+d }
      return v
    }
    function ab(a) { return a<0?-a:a }
    BEGIN { slot=0; x=0; y=0; fv=0 }
    {
      t=gettime($0); if (t < 0) next
      if ($0 ~ /EV_KEY[[:space:]]+00c3[[:space:]]+DOWN/) { print "VENDOR_00C3"; fflush(); next }
      if ($0 ~ /EV_KEY[[:space:]]+00c6[[:space:]]+DOWN/) { print "VENDOR_00C6"; fflush(); next }
      if ($0 ~ /EV_KEY[[:space:]]+00fb[[:space:]]+DOWN/) { print "VENDOR_00FB"; fflush(); next }
      if ($0 ~ /ABS_MT_SLOT/) { slot=hex($NF); next }
      if ($0 ~ /ABS_MT_TRACKING_ID/) { if (slot>0 && tolower($NF)!="ffffffff") fv=0; next }   # 2nd finger: cancel
      if ($0 ~ /ABS_MT_POSITION_X/) { if (slot==0) x=hex($NF); next }
      if ($0 ~ /ABS_MT_POSITION_Y/) { if (slot==0) y=hex($NF); next }
      if ($0 ~ /BTN_TOUCH[[:space:]]+DOWN/) {
        if (fv && (t-ft)>=tmin/1000 && (t-ft)<=tmax/1000 && ab(x-fx)<=dist && ab(y-fy)<=dist) {
          print "TOUCH_DOUBLETAP"; fflush(); fv=0
        } else { ft=t; fx=x; fy=y; fv=1 }
        next
      }
      if ($0 ~ /BTN_TOUCH[[:space:]]+UP/) {
        # first tap must be short and must not have travelled (swipe)
        if (fv && ((t-ft)>thold/1000 || ab(x-fx)>mv || ab(y-fy)>mv)) fv=0
      }
    }'
}

while true; do
  NODE=$(find_touch_node)
  if [ -z "$NODE" ] || [ ! -r "$NODE" ]; then
    log "touchscreen not found; retrying"
    sleep 2
    continue
  fi
  log "listening on $NODE (prefilter=$FILTER_OK gate_awake=$GATE_AWAKE)"
  (
    sh -c 'echo $$ > "$1"; exec getevent -lt "$2"' x "$GPID" "$NODE" 2>/dev/null | prefilter | detector | while read -r event; do
      case "$event" in
        VENDOR_00C3) wake_now "vendor gesture 00c3" ;;
        VENDOR_00C6) wake_now "vendor gesture 00c6" ;;
        VENDOR_00FB) wake_now "vendor gesture 00fb" ;;
        TOUCH_DOUBLETAP) wake_now "BTN_TOUCH double-tap" ;;
      esac
    done
  ) &
  RP=$!
  while kill -0 "$RP" 2>/dev/null; do
    sleep 10
    N2=$(find_touch_node)
    if [ -n "$N2" ] && [ "$N2" != "$NODE" ]; then log "touch node moved $NODE -> $N2; restarting"; break; fi
  done
  gp=$(cat "$GPID" 2>/dev/null); [ -n "$gp" ] && kill "$gp" 2>/dev/null
  kill "$RP" 2>/dev/null
  log "listener ended; restarting"
  sleep 1
done
