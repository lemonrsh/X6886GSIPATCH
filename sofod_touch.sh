#!/system/bin/sh
# X6886 screen-off FOD touch recovery v9 (fast one-touch)
# Replays the held sensor touch after the panel wakes; verifies SystemUI registration
# and retries only when the previous synthetic touch was not accepted. The 120 Hz
# handshake overlaps the panel wake / SystemUI delay instead of adding to it.
MODDIR=${0%/*}
D=/data/adb/fod
LOG=$D/sofod_touch.log
DELAY=0.08
HOLD=0.85
MAJOR=80
TID=901
TRIES=4
VERIFY_MS=650
GAP=0.08
PANEL_WAIT_MS=1200
PANEL_POLL=0.01
DPMS=/sys/class/drm/card0-DSI-1/dpms
FLAG=$D/.sofod_busy
mkdir -p "$D"
# Guard before touching logs/input: duplicate watchers can replay the same FOD touch twice.
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance sofod_touch
refresh_fod_begin() { :; }
refresh_fod_request() { :; }
refresh_fod_wait() { :; }
refresh_fod_end() { :; }
refresh_now() { _rn_up=0; read -r _rn_up _ < /proc/uptime; REFRESH_NOW=$((${_rn_up%.*} * 100)); }
REFRESH_FOD_TOKEN=""
[ -f "$MODDIR/refresh_fod.sh" ] && . "$MODDIR/refresh_fod.sh"
[ -f "$D/sofod_touch.conf" ] && . "$D/sofod_touch.conf"

log() {
  echo "$(date +%T) $*" >> "$LOG"
  if [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 150000 ]; then
    tail -c 40000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
}
which sendevent >/dev/null 2>&1 || { log "ERROR: sendevent missing"; exit 1; }

find_dev_var() {   # same lookup without a $(...) subshell fork -> FOUND_DEV
  FOUND_DEV=""
  for _fv in /sys/class/input/event*; do
    _so_name=""; { IFS= read -r _so_name < "$_fv/device/name"; } 2>/dev/null
    [ "$_so_name" = "mtk-tpd" ] && { FOUND_DEV="/dev/input/${_fv##*/}"; return 0; }
  done
  return 1
}
find_dev() {
  for p in /sys/class/input/event*; do
    _so_name=""; { IFS= read -r _so_name < "$p/device/name"; } 2>/dev/null
    [ "$_so_name" = "mtk-tpd" ] && {
      echo "/dev/input/${p##*/}"
      return 0
    }
  done
  return 1
}
DEV=""
i=0
while [ "$i" -lt 30 ]; do
  DEV=$(find_dev)
  [ -n "$DEV" ] && break
  sleep 1
  i=$((i+1))
done
[ -n "$DEV" ] || { log "ERROR: mtk-tpd input device not found"; exit 1; }

dpms_on() {
  [ ! -r "$DPMS" ] && return 0
  s=""; { IFS= read -r s < "$DPMS"; } 2>/dev/null
  case "$s" in On|on|ON) return 0;; *) return 1;; esac
}
pressed() { [ "$(getprop sys.phh.oplus.fppress)" = 1 ]; }

touch_up() {
  sendevent "$DEV" 3 47 0 2>/dev/null
  sendevent "$DEV" 3 57 -1 2>/dev/null
  sendevent "$DEV" 1 330 0 2>/dev/null
  sendevent "$DEV" 0 0 0 2>/dev/null
}
touch_down() {
  # Android input event codes: SLOT, TRACKING_ID, MT X/Y, TOUCH_MAJOR, BTN_TOUCH, SYN
  sendevent "$DEV" 3 47 0 || return 1
  sendevent "$DEV" 3 57 "$TID" || return 1
  sendevent "$DEV" 3 53 "$1" || return 1
  sendevent "$DEV" 3 54 "$2" || return 1
  sendevent "$DEV" 3 48 "$MAJOR" || return 1
  sendevent "$DEV" 1 330 1 || return 1
  sendevent "$DEV" 0 0 0 || return 1
}

# --- fast replay helpers (host-tested in test_fast_fod.py) ---
held_xy() {   # "... held at (X, Y) ..." -> X Y; pure shell, no echo|sed forks
  HX=""; HY=""
  # Quoted patterns: mksh (Android sh) would read a bare "(" as an extglob.
  _hx=${1#*"held at ("}
  [ "$_hx" != "$1" ] || return 1
  _hx=${_hx%%")"*}
  HX=${_hx%%","*}; HY=${_hx#*","}
  while :; do case "$HX" in ' '*) HX=${HX# } ;; *) break ;; esac; done
  while :; do case "$HY" in ' '*) HY=${HY# } ;; *) break ;; esac; done
  case "$HX:$HY" in *[!0-9:]*|:*|*:) HX=""; HY=""; return 1 ;; esac
  [ "$_hx" != "$HX" ] || { HX=""; HY=""; return 1; }
  return 0
}
panel_wait() {   # builtin DPMS reads; uptime-bounded (sleep forks are not counted)
  PANEL_WAITED=0
  [ -r "$DPMS" ] || return 0
  refresh_now; _pw_t0=$REFRESH_NOW
  while ! dpms_on; do
    refresh_now; PANEL_WAITED=$((REFRESH_NOW-_pw_t0))
    [ "$((PANEL_WAITED*10))" -lt "$PANEL_WAIT_MS" ] || return 1
    sleep "$PANEL_POLL" || sleep 0.02
  done
  refresh_now; PANEL_WAITED=$((REFRESH_NOW-_pw_t0))
  return 0
}
# --- end fast replay helpers ---

refire() {
  # Pin 120 Hz before waking/replaying (non-blocking): the controller works while
  # the panel powers on, including the unregistered-touch path.
  refresh_fod_request sofod
  # HAL log coordinates are pixels; mtk-tpd reports 16 units per pixel on X6886.
  PX=$(( $1 * 16 ))
  PY=$(( $2 * 16 ))
  [ "$PX" -lt 0 ] && PX=0
  [ "$PY" -lt 0 ] && PY=0
  [ "$PX" -gt 17279 ] && PX=17279
  [ "$PY" -gt 38399 ] && PY=38399

  PANEL_STATE=none
  if [ -r "$DPMS" ]; then
    panel_wait
    { IFS= read -r PANEL_STATE < "$DPMS"; } 2>/dev/null
  fi
  # A FRESH hold after the panel is on: its ACK proves 120 Hz was observed after
  # the wake, so fod_service can reuse it for HBM without a second wait. The
  # SystemUI settle delay and the ACK wait run in parallel (max, not sum).
  refresh_fod_request sofod
  sleep "$DELAY"
  refresh_fod_wait sofod

  t=1
  ok=0
  while [ "$t" -le "$TRIES" ]; do
    _old_dev=$DEV
    find_dev_var && DEV=$FOUND_DEV
    touch_up
    if ! touch_down "$PX" "$PY"; then
      log "ERROR: sendevent failed; releasing contact"
      touch_up
      break
    fi
    # Logging forks date/wc: do it AFTER the contact is down, never before it.
    [ "$DEV" = "$_old_dev" ] || log "input node changed $_old_dev -> $DEV"
    [ "$t" != 1 ] || log "panel state=$PANEL_STATE wait=$((PANEL_WAITED*10))ms"
    log "touch replay attempt=$t pixel=($1,$2)"

    v=0
    while [ "$v" -lt "$((VERIFY_MS/20))" ] && ! pressed; do
      sleep 0.02
      v=$((v+1))
    done
    if pressed; then
      ok=1
      log "SystemUI press accepted attempt=$t after=$((v*20))ms"
      break
    fi
    touch_up
    log "press not accepted attempt=$t; retry"
    sleep "$GAP"
    t=$((t+1))
  done

  if [ "$ok" = 1 ]; then
    sleep "$HOLD"
    touch_up
    log "synthetic touch released"
  else
    touch_up
    log "WARNING: no press confirmation after $TRIES attempts"
  fi
  refresh_fod_end sofod "$REFRESH_FOD_TOKEN"
  rm -f "$FLAG"
}

# The single-instance guard above replaces the old broad pkill. Reboot after an
# in-place module update so any pre-guard watcher from the old install is stopped.
# The flag is per-trigger and expires if a previous run was killed.
rm -f "$FLAG"
log "watcher v9 started dev=$DEV delay=$DELAY hold=$HOLD tries=$TRIES"

while true; do
  logcat -b all -T 1 -v brief oplus_udfps_transsion:I '*:S' 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"display on, finger still held at ("*)
        if [ -f "$FLAG" ]; then
          age=$(( $(date +%s) - $(stat -c %Y "$FLAG" 2>/dev/null || echo 0) ))
          [ "$age" -gt 8 ] && rm -f "$FLAG" || continue
        fi
        held_xy "$line" || continue
        : > "$FLAG"
        refire "$HX" "$HY" &
        ;;
    esac
  done
  log "logcat stream ended; restarting"
  sleep 1
done
