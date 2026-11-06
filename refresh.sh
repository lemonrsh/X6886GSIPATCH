#!/system/bin/sh
# X6886 fixed 120 Hz controller: no 144 Hz mode and no fingerprint-dependent switching.
D=/data/adb/fod
LOG=$D/refresh.log
CONF=$D/refresh.conf
CACHE=$D/refresh.cache
PIDF=$D/.refresh.pid
RECPID=$D/.refresh_rec.pid
STATE=$D/.refresh_want
TARGET_HZ=120
RECONCILE_S=120
SETTINGS_RATE=1
mkdir -p "$D"

# Single instance (post-fs-data and service.sh may both launch this).
if [ -f "$PIDF" ]; then
  OP=$(cat "$PIDF" 2>/dev/null)
  case "$OP" in
    ''|*[!0-9]*) ;;
    *) if [ "$OP" != "$$" ] && kill -0 "$OP" 2>/dev/null &&
         grep -q refresh.sh "/proc/$OP/cmdline" 2>/dev/null; then exit 0; fi ;;
  esac
fi
echo $$ > "$PIDF"
renice -n -8 -p $$ >/dev/null 2>&1

# Only permit the fixed 120 Hz target. Ignore old BASE_HZ/FP_HZ settings.
if [ -f "$CONF" ]; then
  . "$CONF"
  case "$RECONCILE_S" in ''|*[!0-9]*) RECONCILE_S=120;; esac
fi
TARGET_HZ=120
up() { read -r u _ < /proc/uptime 2>/dev/null; echo "${u:-?}"; }
log() { echo "$(date +%T.%N 2>/dev/null | cut -c1-12) up=$(up)s $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
: > "$LOG"
log "fixed 120 Hz controller start (pid $$)"

[ -f "$RECPID" ] && { OR=$(cat "$RECPID" 2>/dev/null); [ -n "$OR" ] && kill "$OR" 2>/dev/null; rm -f "$RECPID"; }

resolve() {
  dumpsys SurfaceFlinger 2>/dev/null |
    sed -n 's/.*{id=\([0-9]*\), hwcId=[0-9]*, resolution=[0-9x]*, vsyncRate=\([0-9]*\)\.\([0-9]\)[0-9]* Hz.*/\1 \2 \3/p' |
    while read -r id ip fp; do
      case "$fp" in [5-9]) ip=$((ip+1));; esac
      echo "$id $ip"
    done
}
pick120() {
  echo "$1" | while read -r id hz; do
    [ "$hz" = 120 ] && { echo "$id"; break; }
  done
}
MODE_ID=""
i=0
while [ -z "$MODE_ID" ]; do
  if [ -n "$(pidof surfaceflinger 2>/dev/null)" ]; then
    MODES=$(resolve)
    MODE_ID=$(pick120 "$MODES")
    if [ -z "$MODE_ID" ] && [ "$i" -ge 40 ] && [ -f "$CACHE" ]; then
      read -r CHZ CID < "$CACHE"
      [ "$CHZ" = 120 ] && MODE_ID=$CID
      [ -n "$MODE_ID" ] && log "using cached 120 Hz mode id $MODE_ID"
    fi
  fi
  i=$((i+1))
  if [ "$i" -lt 480 ]; then sleep 0.25; else sleep 3; fi
done
echo "120 $MODE_ID" > "$CACHE"
log "120 Hz mode id=$MODE_ID"

apply120() {
  OUT=$(service call SurfaceFlinger 1035 i32 "$MODE_ID" 2>&1)
  case "$OUT" in
    *"Parcel(00000000"*) echo "$MODE_ID" > "$STATE"; log "120 Hz applied ($1)"; return 0;;
    *) log "120 Hz apply failed ($1): $(echo "$OUT" | cut -c1-100)"; return 1;;
  esac
}
n=0
while [ "$n" -lt 40 ]; do
  apply120 "early boot" && break
  n=$((n+1)); sleep 0.25
done

# v11.2: also pin the framework's own refresh-rate settings (portable base; the SurfaceFlinger call below
# stays as the hard override). Removing the module: reset with `settings delete system min_refresh_rate`.
if [ "$SETTINGS_RATE" = 1 ]; then
  ( until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
    settings put system min_refresh_rate 120 >/dev/null 2>&1
    settings put system peak_refresh_rate 120 >/dev/null 2>&1
    log "settings min/peak_refresh_rate=120" ) &
fi

# v11.2: no more blind re-apply every 30 s. Re-apply when SurfaceFlinger restarts (checked via /proc, no fork),
# plus a slow safety reconcile every RECONCILE_S seconds (0 = off).
SFPID=$(pidof surfaceflinger | cut -d' ' -f1); T=0
while sleep 10; do
  T=$((T+10))
  if [ -z "$SFPID" ] || [ ! -r "/proc/$SFPID/comm" ]; then
    NSF=$(pidof surfaceflinger | cut -d' ' -f1)
    if [ -n "$NSF" ] && [ "$NSF" != "$SFPID" ]; then
      SFPID=$NSF; log "SurfaceFlinger restarted (pid $NSF)"; sleep 2
      NID=$(pick120 "$(resolve)"); [ -n "$NID" ] && MODE_ID=$NID
      apply120 "sf restart"; T=0
    fi
  fi
  if [ "$RECONCILE_S" -gt 0 ] && [ "$T" -ge "$RECONCILE_S" ]; then apply120 "reconcile"; T=0; fi
done
rm -f "$PIDF"
