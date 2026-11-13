#!/system/bin/sh
# One writer: 144 Hz interactive / verified 120 Hz FOD, sleep and wake guard.
# Boot-scoped state and monotonic deadlines; never persist/guess display mode IDs.
MODDIR=${0%/*}
# FIRST: FOD helpers / the bridge watcher wake the 50 ms nap with SIGUSR1. Install
# the trap before anything can publish this PID (default USR1 action would kill us).
trap ':' USR1
MAIN_PID=$$
D=/data/adb/fod
LOG=$D/refresh.log
CONF=$D/refresh.conf
SESSIONF=$D/.refresh_session
POWERF=$D/.refresh_power
GPID=$D/.refresh_logcat.pid
EPOCHF=$D/.refresh_epoch
RECONCILE_S=120
SETTINGS_RATE=1
mkdir -p "$D"
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance refresh
. "$MODDIR/refresh_fod.sh"
. "$MODDIR/settings_state.sh"
[ -f "$CONF" ] && . "$CONF"
case "$RECONCILE_S" in ''|*[!0-9]*) RECONCILE_S=120 ;; esac
[ "$RECONCILE_S" -ge 10 ] || RECONCILE_S=10
refresh_boot
REFRESH_TIMEOUT=0
if command -v timeout >/dev/null 2>&1 && timeout 1 true >/dev/null 2>&1; then REFRESH_TIMEOUT=1; fi
renice -n -8 -p $$ >/dev/null 2>&1
log() { echo "$(date +%T) $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
log "144/120 Hz wake-safe controller start (pid $$)"

# --- refresh helpers (regression-tested by .github/tests/test_fixes.py) ---
refresh_modes() {   # SurfaceFlinger dump -> base mode ID, FOD mode ID, base Hz
  awk '
  function field(s, k) {
    if (index(s, k "=") == 0) return ""
    sub(".*" k "=", "", s); sub("[, }].*", "", s); return s
  }
  /^[ \t]*(Virtual )?Display [0-9]+/ { block++; if ($0 ~ /Virtual/) external[block]=1 }
  /connectionType[=:]/ {
    if ($0 ~ /Internal/) { if (!internal) internal=block }
    else external[block]=1
  }
  /\{id=[0-9]+,.*resolution=.*vsyncRate=/ {
    id=field($0,"id"); res=field($0,"resolution"); rate=field($0,"vsyncRate")
    group=field($0,"group"); if (group == "") group="?"
    if (id !~ /^[0-9]+$/ || res !~ /^[0-9]+x[0-9]+$/ || rate !~ /^[0-9]+(\.[0-9]+)?$/) next
    if ($0 ~ /activeMode[=:]/) active[block]=res
    if (seen[block,id]++) next
    n++; b[n]=block; ids[n]=id; r[n]=res; g[n]=group; hz[n]=int(rate+0.5)
  }
  END {
    target=internal ? internal : (block ? 1 : 0)
    for (i=1;i<=n;i++) {
      if (b[i] != target || external[b[i]] || hz[i] != 120) continue
      if (active[target] != "" && r[i] != active[target]) continue
      if (!fp) fp=i
      for (j=1;j<=n;j++) {
        if (b[j] != target || hz[j] != 144 || r[j] != r[i]) continue
        # Same HWC group/resolution avoids a modeset/black frame. Old dumps
        # without group metadata can still use their same-resolution pair.
        if (g[i] == g[j]) { print ids[j], ids[i], 144; exit }
      }
    }
    if (fp) print ids[fp], ids[fp], 120
  }'
}
refresh_active() {   # dump -> active mode ID, physical Hz, render Hz (not a Binder success guess)
  awk '
  function field(s, k) {
    if (index(s, k "=") == 0) return ""
    sub(".*" k "=", "", s); sub("[, }].*", "", s); return s
  }
  /^[ \t]*(Virtual )?Display [0-9]+/ { block++; if ($0 ~ /Virtual/) external[block]=1 }
  /connectionType[=:]/ {
    if ($0 ~ /Internal/) { if (!internal) internal=block }
    else external[block]=1
  }
  /renderRate=/ { rate=field($0,"renderRate"); if (rate ~ /^[0-9]+(\.[0-9]+)?$/) render[block]=int(rate+0.5) }
  /activeMode[=:].*\{id=/ {
    mode=field($0,"id"); rate=field($0,"vsyncRate")
    if (mode ~ /^[0-9]+$/ && rate ~ /^[0-9]+(\.[0-9]+)?$/) {
      ids[block]=mode; hz[block]=int(rate+0.5); found[block]=1
    }
  }
  END {
    target=internal ? internal : (block ? 1 : 0)
    if (found[target] && !external[target]) print ids[target], hz[target], (render[target] ? render[target] : "-")
  }'
}
refresh_reply() {   # classification for diagnostics ONLY; even Parcel(NULL) may mean no-op/error
  [ "$1" = 0 ] || { echo error; return; }
  case "$2" in
    *"Parcel(00000000"*|*"Parcel( 00000000"*) echo zero ;;
    *"Parcel(NULL)"*|*"Parcel(    )"*|*"Parcel()"*) echo empty ;;
    *) echo rejected ;;
  esac
}
refresh_event_parse() {   # only events emitted by the bundled Transsion bridge
  REFRESH_EVENT=""
  case "$1" in
    *"ISession::authenticate called"*|*"ISession::enroll called"*|*"ISession::detectInteraction called"*|*"onUiReady"*|*"auto-starting authenticate for SOFOD"*) REFRESH_EVENT=session_on ;;
    *"ICancellationSignal::cancel invoked"*|*"ISession::close called"*|*"Authentication SUCCEEDED"*|*"Enrollment completed successfully"*|*"SOFOD authentication succeeded while display was fully asleep"*) REFRESH_EVENT=session_off ;;
    *"onPointerDown"*|*"display on, finger still held at ("*|*"sensor pressed while screen off"*) REFRESH_EVENT=touch_on ;;
    *"onPointerUp"*|*"onPointerCancel"*|*"Touch release (BTN_TOUCH 0)"*|*"Tracking ID lifted"*|*"FOD touch timed out"*) REFRESH_EVENT=touch_off ;;
  esac
}
refresh_event() { refresh_event_parse "$1"; printf '%s\n' "$REFRESH_EVENT"; }
refresh_framework() {   # Hz, user; lower min before peak on downshift (reverse on upshift)
  if [ "$1" = 120 ]; then
    module_setting_set system "$2" min_refresh_rate "$1" &&
      module_setting_set system "$2" peak_refresh_rate "$1"
  else
    module_setting_set system "$2" peak_refresh_rate "$1" &&
      module_setting_set system "$2" min_refresh_rate "$1"
  fi
}
refresh_seed_session() {   # - means unavailable/unknown, NOT proof that a prompt is absent
  dumpsys -t 1 fingerprint 2>/dev/null | awk '
    /Current (client|operation):/ {
      if (/Fingerprint(Authentication|Enroll|Detect)Client/) { print 1; found=1; exit }
      if (/:[ \t]*(null|None|none|<none>)[ \t]*$/) idle=1
    }
    END { if (!found) print (idle ? 0 : "-") }'
}
refresh_power_parse() {   # bundled bridge + Android power edges, no per-line subprocess
  REFRESH_POWER=""
  case "$1" in
    *"Waking up from "*|*"Waking up power group"*|*"[SleepState: AWAKE]"*) REFRESH_POWER=on ;;
    *"Going to sleep"*|*"Sleeping (uid"*|*"Sleeping power group"*|*"Powering off display group"*|*"Dozing..."*|*"[SleepState: OFF]"*|*"[SleepState: DOZE]"*) REFRESH_POWER=off ;;
  esac
}
refresh_panel() {   # authoritative DPMS first; backlight fallback, all builtin reads
  PANEL=unknown
  _rp_value=""
  if [ -r /sys/class/drm/card0-DSI-1/dpms ]; then
    { IFS= read -r _rp_value < /sys/class/drm/card0-DSI-1/dpms; } 2>/dev/null
    case "$_rp_value" in On|on|ON) PANEL=on ;; Off|off|OFF|Doze|DozeSuspend) PANEL=off ;; esac
    return
  fi
  for _rp_node in /sys/class/leds/lcd-backlight/brightness /sys/class/backlight/*/brightness; do
    [ -r "$_rp_node" ] || continue
    { IFS= read -r _rp_value < "$_rp_node"; } 2>/dev/null
    case "$_rp_value" in ''|*[!0-9]*) ;; 0) PANEL=off; return ;; *) PANEL=on; return ;; esac
  done
}
refresh_power_state() {   # slow independent fallback when both event/panel edges were missed
  dumpsys -t 1 power 2>/dev/null | awk '
    /mWakefulness=/ {
      sub(/.*mWakefulness=/, ""); sub(/[^A-Za-z].*/, "")
      if ($0 == "Awake" || $0 == "Dreaming") print "on"
      else if ($0 == "Asleep" || $0 == "Dozing") print "off"
      exit
    }'
}
refresh_exec() {   # bound Binder CLI stalls where Toybox/BusyBox timeout is available
  if [ "${REFRESH_TIMEOUT:-0}" = 1 ]; then timeout 1 "$@"; else command "$@"; fi
}
# --- end refresh helpers ---

# settings_state.sh still owns snapshot/restore semantics; only bound its CLI here.
settings() { refresh_exec settings "$@"; }
stop_events() {
  _se_pid=""
  [ -r "$GPID" ] && read -r _se_pid < "$GPID"
  case "$_se_pid" in ''|*[!0-9]*) ;; *)
    if [ "$_se_pid" -gt 1 ] && grep -q logcat "/proc/$_se_pid/cmdline" 2>/dev/null &&
       grep -q oplus_udfps_transsion "/proc/$_se_pid/cmdline" 2>/dev/null; then
      kill "$_se_pid" 2>/dev/null || true
    fi ;;
  esac
  if [ -n "$WATCH_PID" ]; then kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; fi
  WATCH_PID=""
  rm -f "$GPID" "$SESSIONF" "$POWERF"
}
cleanup() {
  stop_events
  if [ -n "$SET_PID" ]; then kill "$SET_PID" 2>/dev/null || true; fi
  rm -f "$SET_RC" "$SET_RC.tmp"
  rm -f "$D/.refresh.pid" "$D/.refresh_ready" "$D/.refresh_applied"
}
# A second TERM (uninstall + supervisor both stop us) must not cut cleanup short.
trap 'trap "" INT TERM; log "controller stopped by signal"; exit 0' INT TERM
trap '_exit=$?; trap - EXIT; trap "" INT TERM; log "controller exit rc=$_exit"; cleanup' EXIT
watch_events() {
  trap - INT TERM EXIT
  while [ ! -f "$D/.ui_stopping" ] && kill -0 "$MAIN_PID" 2>/dev/null; do
    sh -c 'echo $$ > "$1"; exec logcat -b all -T 1 -v brief oplus_udfps_transsion:I PowerManagerService:I PowerGroup:I "*:S"' x "$GPID" 2>/dev/null |
    (
      trap - INT TERM EXIT
      _we_session=0; _we_touch=0; _we_epoch=""; _we_seq=0
      while IFS= read -r line; do
        _we_owner=""; [ -r "$D/.refresh.pid" ] && read -r _we_owner < "$D/.refresh.pid"
        [ "$_we_owner" = "$MAIN_PID" ] && kill -0 "$MAIN_PID" 2>/dev/null || exit 0
        _we_new=""; [ -r "$EPOCHF" ] && read -r _we_new < "$EPOCHF"
        if [ "$_we_new" != "$_we_epoch" ]; then
          _we_session=0; _we_touch=0; _we_epoch=$_we_new
        fi
        refresh_power_parse "$line"
        if [ -n "$REFRESH_POWER" ]; then
          refresh_now
          _we_seq=$((_we_seq+1))
          printf '%s %s %s %s %s\n' "$REFRESH_BOOT" "$REFRESH_NOW" "$REFRESH_POWER" "$_we_epoch" "$_we_seq" > "$POWERF.tmp" &&
            mv -f "$POWERF.tmp" "$POWERF"
          # Wake/sleep edges are acted on at once, not after the next nap.
          kill -USR1 "$MAIN_PID" 2>/dev/null
        fi
        refresh_event_parse "$line"; _we_event=$REFRESH_EVENT
        case "$_we_event" in
          session_on) _we_session=1 ;;
          session_off) _we_session=0; _we_touch=0 ;;
          touch_on) _we_touch=1 ;;
          touch_off) _we_touch=0 ;;
          *) continue ;;
        esac
        refresh_now; _we_seq=$((_we_seq+1))
        # Lost terminal events cannot pin 120 forever: auth 5 min, touch-only 8 s.
        if [ "$_we_session" = 1 ]; then _we_ttl=30000; else _we_ttl=800; fi
        printf '%s %s %s %s %s %s %s %s\n' "$REFRESH_BOOT" "$((REFRESH_NOW + _we_ttl))" "$_we_session" "$_we_touch" "$_we_epoch" "$_we_seq" "$_we_event" "$REFRESH_NOW" > "$SESSIONF.tmp" &&
          mv -f "$SESSIONF.tmp" "$SESSIONF"
        kill -USR1 "$MAIN_PID" 2>/dev/null
      done
    )
    rm -f "$SESSIONF"
    touch "$D/.refresh_stream_reset"
    sleep 1
  done
}
WATCH_PID=""
stop_events
rm -f "$D/.refresh_ready" "$D/.refresh_applied" "$D/.refresh_want" "$D/refresh.cache" "$D/.refresh_stream_reset"
EPOCH_N=0; EPOCH=$$-0
printf '%s\n' "$EPOCH" > "$EPOCHF"
watch_events & WATCH_PID=$!

BASE_ID=""; FP_ID=""; BASE_HZ=120; SFPID=""; SFSTAMP=""; HALPID=""; HALSTAMP=""
APPLIED=""; ACK=""; FRAMEWORK_HZ=""; USER_ID=""; BOOT=0; SEEDED=0
SF_ID=""; SF_HZ=""; SF_RENDER=""; REPLY=none; LAST_WANT=""; CHECKED_TOKENS="- -"
TICK=0; NEXT_SCAN=0; NEXT_SETTINGS=0; NEXT_CHECK=0; NEXT_VERIFY=0; NEXT_REQUEST=0; NEXT_SEED=0; NEXT_POWER=0; NEXT_RESCAN=0
LAST_MODES=unresolved; ATTEMPTS=0; WARNED=0; REVERIFY=0
SET_PID=""; SET_HZ=""; SET_USER=""; SET_STARTED=0; SET_RC=$D/.refresh_settings_rc
SCREEN=unknown; PANEL_LAST=unknown; POWER_KEY=""; SESSION_KEY=none; LAST_SESSION=none
SEED_AUTH=-; SEED_EVENT=none; SEED_UNTIL=0; WAKE_UNTIL=0; UP_AT=0; NEXT_GAP_LOG=0
refresh_now; START_UNTIL=$((REFRESH_NOW+150)); LAST_LOOP=$REFRESH_NOW
# --- refresh recovery helpers (host-tested in test_refresh_recovery.py) ---
invalidate() {
  APPLIED=""; ACK=""; ATTEMPTS=0; WARNED=0; REVERIFY=0
  NEXT_REQUEST=$REFRESH_NOW; NEXT_VERIFY=$REFRESH_NOW
  if [ "${1:-0}" = 1 ]; then FRAMEWORK_HZ=""; NEXT_SETTINGS=$REFRESH_NOW; fi
  rm -f "$D/.refresh_applied"
}
reverify() {   # a new FOD hold always needs a FRESH observation before its ACK
  if [ "$APPLIED" = 120 ] && [ "$WANT" = 120 ]; then
    # Already verified at 120: observe again right now and skip the redundant
    # Binder pin. A mismatch takes the normal repair path (re-pin + votes).
    ACK=""; REVERIFY=1; NEXT_VERIFY=$REFRESH_NOW
    rm -f "$D/.refresh_applied"
  else
    invalidate
  fi
}
new_epoch() {
  EPOCH_N=$((EPOCH_N+1)); EPOCH=$$-$EPOCH_N
  printf '%s\n' "$EPOCH" > "$EPOCHF.tmp" && mv -f "$EPOCHF.tmp" "$EPOCHF"
  rm -f "$SESSIONF" "$POWERF"
  SEEDED=0; SEED_AUTH=-; NEXT_SEED=0
}
power_edge() {   # pre-arm sleep; wake gets 1 s for HAL/SystemUI to re-register FOD
  SCREEN=$1
  [ "$1" = on ] && WAKE_UNTIL=$((REFRESH_NOW+100))
  invalidate 1
  NEXT_CHECK=$REFRESH_NOW; NEXT_SEED=0
  log "screen=$1 source=$2; invalidated display ACK"
}
recheck_gap() {   # a pause can happen BETWEEN loops or INSIDE an IPC/observation
  if [ "$1" = resume ]; then
    WAKE_UNTIL=$((REFRESH_NOW+100)); invalidate 1
  elif [ -n "$APPLIED" ]; then
    # A result observed before a long/paused iteration is stale too. Do not
    # confuse a known slow/failed CLI with another wake or reset its backoff.
    invalidate 1
  fi
  NEXT_VERIFY=$REFRESH_NOW; NEXT_CHECK=0; NEXT_SEED=0; NEXT_POWER=0
  if [ "$REFRESH_NOW" -ge "$NEXT_GAP_LOG" ]; then
    log "resume/loop gap; rechecking display and fingerprint state ($1)"
    NEXT_GAP_LOG=$((REFRESH_NOW+1000))
  fi
}
request_mode() {
  OUT=$(refresh_exec service call SurfaceFlinger 1035 i32 "$ID" 2>&1); RC=$?
  REPLY=$(refresh_reply "$RC" "$OUT")
  printf 'target=%s mode=%s exit=%s reply=%s\n%.1024s\n' "$WANT" "$ID" "$RC" "$REPLY" "$OUT" > "$D/refresh_last_reply.txt"
  # Fast initial retries, then bounded continued recovery (never a 3-call ceiling).
  [ "$ATTEMPTS" -ge 6 ] || ATTEMPTS=$((ATTEMPTS+1))
  refresh_now
  case "$ATTEMPTS" in 1|2) NEXT_REQUEST=$((REFRESH_NOW+10)) ;;
    3|4|5) NEXT_REQUEST=$((REFRESH_NOW+100)) ;; *) NEXT_REQUEST=$((REFRESH_NOW+500)) ;; esac
  NEXT_VERIFY=$REFRESH_NOW
}
read_session() {
  SESSION_KEY=none; AUTH=0; TOUCH=0; SESSION_EVENT=""
  _ss_boot=""; _ss_until=""; _ss_auth=0; _ss_touch=0; _ss_epoch=""; _ss_seq=""; SESSION_AT=0
  [ -r "$SESSIONF" ] || return 0
  read -r _ss_boot _ss_until _ss_auth _ss_touch _ss_epoch _ss_seq SESSION_EVENT SESSION_AT < "$SESSIONF"
  case "$_ss_until:$_ss_seq:$SESSION_AT" in *[!0-9:]*|:*|*::*) return 0 ;; esac
  case "$SESSION_AT" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_ss_boot" = "$REFRESH_BOOT" ] && [ "$_ss_epoch" = "$EPOCH" ] || return 0
  SESSION_KEY=$_ss_epoch-$_ss_seq
  if [ "$_ss_until" -gt "$REFRESH_NOW" ]; then AUTH=$_ss_auth; TOUCH=$_ss_touch; fi
}
seed_session() {   # never let a slow snapshot overwrite a newer bridge event
  read_session; _seed_before=$SESSION_KEY
  _seed=$(refresh_seed_session)
  refresh_now; read_session
  if [ "$SESSION_KEY" = "$_seed_before" ] &&
     { [ "$SESSION_KEY" = none ] || [ $((REFRESH_NOW-SESSION_AT)) -ge 100 ]; }; then
    case "$_seed" in 0|1)
      SEED_AUTH=$_seed; SEED_EVENT=$SESSION_KEY; SEED_UNTIL=$((REFRESH_NOW+30000)); SEEDED=1 ;;
    esac
  fi
  if [ "$SEEDED" = 0 ]; then NEXT_SEED=$((REFRESH_NOW+100))
  elif [ "$WANT" = 120 ]; then NEXT_SEED=$((REFRESH_NOW+500))
  else NEXT_SEED=$((REFRESH_NOW+3000)); fi
}
# --- end refresh recovery helpers ---
# --- runtime snapshot helper (host-tested in test_low_cpu.py) ---
RUNTIME_KEY=""
runtime() {
  _runtime_key="$$ $WATCH_PID $SFPID ${WANT:--} ${APPLIED:--} ${SF_ID:--} ${SF_HZ:--} ${SF_RENDER:--} $REPLY ${SCREEN:-unknown} ${WHY:--} ${ATTEMPTS:-0}"
  # Last state/observation, not a heartbeat: avoid identical per-second writes.
  if [ "${1:-0}" != 1 ] && [ "$_runtime_key" = "$RUNTIME_KEY" ] && [ -f "$D/.refresh_runtime" ]; then return 0; fi
  refresh_now
  printf 'pid=%s watcher=%s sfpid=%s up_cs=%s target=%s verified=%s active_id=%s physical_hz=%s render_hz=%s reply=%s screen=%s trigger=%s retries=%s\n' \
    "$$" "$WATCH_PID" "$SFPID" "$REFRESH_NOW" "${WANT:--}" "${APPLIED:--}" \
    "${SF_ID:--}" "${SF_HZ:--}" "${SF_RENDER:--}" "$REPLY" "${SCREEN:-unknown}" "${WHY:--}" "${ATTEMPTS:-0}" > "$D/.refresh_runtime.tmp" &&
    mv -f "$D/.refresh_runtime.tmp" "$D/.refresh_runtime" && RUNTIME_KEY=$_runtime_key
}
# --- end runtime snapshot helper ---
configure_modes() {
  _cm_old="$BASE_ID $FP_ID $BASE_HZ"
  _cm_dump=$(dumpsys -t 2 SurfaceFlinger --displays 2>/dev/null)
  _cm_modes=$(printf '%s\n' "$_cm_dump" | refresh_modes)
  if [ -z "$_cm_modes" ]; then
    _cm_full=$(dumpsys -t 2 SurfaceFlinger 2>/dev/null)
    [ -z "$_cm_full" ] || _cm_dump=$_cm_full
    _cm_modes=$(printf '%s\n' "$_cm_dump" | refresh_modes)
  fi
  refresh_now
  if [ -n "$_cm_modes" ]; then
    read -r BASE_ID FP_ID BASE_HZ <<EOF
$_cm_modes
EOF
  elif [ -n "$FP_ID" ] && [ -z "$_cm_dump" ]; then
    # A transient empty dump on the SAME SF process must not disable recovery.
    NEXT_SCAN=$((REFRESH_NOW+100)); return
  else
    BASE_ID=""; FP_ID=""; BASE_HZ=120
  fi
  if [ "$_cm_modes" != "$LAST_MODES" ]; then
    if [ -n "$FP_ID" ]; then
      log "modes: normal=$BASE_HZ Hz id=$BASE_ID, FOD=120 Hz id=$FP_ID"
      [ "$BASE_HZ" = 144 ] || log "no compatible 144/120 pair; safely retaining 120 Hz"
    else
      log "120 Hz mode unavailable; leaving display policy to Android"
    fi
    LAST_MODES=$_cm_modes
  fi
  [ "$_cm_modes" = "$_cm_old" ] || invalidate 1
  if [ -n "$FP_ID" ]; then
    # PID + start time: helpers signal only this exact process (never a reused PID).
    _cm_stamp=-; command -v process_stamp >/dev/null 2>&1 && process_stamp "$$" && _cm_stamp=$PROC_STAMP
    printf '%s %s %s\n' "$REFRESH_BOOT" "$$" "$_cm_stamp" > "$D/.refresh_ready.tmp" &&
      mv -f "$D/.refresh_ready.tmp" "$D/.refresh_ready"
    NEXT_SCAN=$((REFRESH_NOW + RECONCILE_S * 100))
  else
    rm -f "$D/.refresh_ready"
    NEXT_SCAN=$((REFRESH_NOW+100))
  fi
}
observe() {
  SF_ID=""; SF_HZ=""; SF_RENDER=""
  _obs=$(dumpsys -t 1 SurfaceFlinger --displays 2>/dev/null | refresh_active)
  if [ -n "$_obs" ]; then
    read -r SF_ID SF_HZ SF_RENDER <<EOF
$_obs
EOF
  fi
  [ "$SF_ID" = "$ID" ] && [ "$SF_HZ" = "$WANT" ] &&
    { [ "$SF_RENDER" = - ] || [ "$SF_RENDER" = "$WANT" ]; }
}
# --- fast switch helpers (host-tested in test_fast_fod.py) ---
SETTINGS_INFLIGHT=999999999
refresh_reap() {   # reap one child even if a USR1 poke interrupts wait (no zombie)
  _rr_n=0
  while [ "$_rr_n" -lt 4 ]; do
    wait "$1" 2>/dev/null
    [ "$?" -gt 128 ] || return 0
    _rr_n=$((_rr_n+1))
  done
}
settings_start() {   # Hz user. The settings CLI starts a Java process (100s of ms):
  # run it in ONE background worker so it never delays a pin, ACK or the next event.
  rm -f "$SET_RC" "$SET_RC.tmp"
  SET_HZ=$1; SET_USER=$2; refresh_now; SET_STARTED=$REFRESH_NOW
  NEXT_SETTINGS=$SETTINGS_INFLIGHT   # invalidate/target changes overwrite this marker
  (
    trap - INT TERM EXIT
    _ss_rc=1
    if [ ! -f "$D/.ui_stopping" ] && refresh_framework "$1" "$2"; then _ss_rc=0; fi
    printf '%s\n' "$_ss_rc" > "$SET_RC.tmp" && mv -f "$SET_RC.tmp" "$SET_RC"
  ) &
  SET_PID=$!
}
settings_poll() {   # reap a finished worker -> 0 when no worker is running
  [ -n "$SET_PID" ] || return 0
  _sp_rc=""
  if [ -r "$SET_RC" ]; then
    read -r _sp_rc < "$SET_RC"
  elif [ $((REFRESH_NOW-SET_STARTED)) -lt 1000 ]; then
    return 1
  else
    kill "$SET_PID" 2>/dev/null || true   # CLI hang without timeout support
  fi
  refresh_reap "$SET_PID"
  SET_PID=""; rm -f "$SET_RC"
  refresh_now
  # A wake/target change/repair during the run asked for a fresh audit: keep it.
  [ "$NEXT_SETTINGS" = "$SETTINGS_INFLIGHT" ] || return 0
  if [ "$_sp_rc" = 0 ] && [ "$SET_HZ" = "$WANT" ] && [ "$SET_USER" = "$USER_ID" ]; then
    FRAMEWORK_HZ=$WANT
    if [ "$WANT" = 120 ]; then NEXT_SETTINGS=$((REFRESH_NOW+500)); else NEXT_SETTINGS=$((REFRESH_NOW+1500)); fi
  elif [ "$_sp_rc" = 0 ]; then
    NEXT_SETTINGS=$REFRESH_NOW
  else
    NEXT_SETTINGS=$((REFRESH_NOW+100))
  fi
  return 0
}
refresh_nap() {   # interruptible sleep: a USR1 poke from a FOD helper ends it at once
  sleep "$1" & _nap_pid=$!
  wait "$_nap_pid"; _nap_rc=$?
  if [ "$_nap_rc" -gt 128 ]; then
    kill "$_nap_pid" 2>/dev/null; refresh_reap "$_nap_pid"
    return 0
  fi
  [ "$_nap_rc" = 0 ] || sleep 1   # no fractional sleep: never busy-loop
}
# --- end fast switch helpers ---
while [ ! -f "$D/.ui_stopping" ]; do
  refresh_now
  # /proc/uptime includes deep sleep; loop counters do not. Also catch a whole
  # sleep/wake cycle whose panel/log edges were both missed while suspended.
  if [ $((REFRESH_NOW-LAST_LOOP)) -ge 100 ]; then
    recheck_gap resume
  fi
  LOOP_START=$REFRESH_NOW
  # Builtin sysfs read every tick (no fork): catch the screen-off FOD wake fast.
  refresh_panel
  if [ "$PANEL" != unknown ] && [ "$PANEL" != "$PANEL_LAST" ]; then
    PANEL_LAST=$PANEL; power_edge "$PANEL" panel
  fi
  if [ -r "$POWERF" ]; then
    _pw_boot=""; _pw_at=""; _pw_state=""; _pw_epoch=""; _pw_seq=""
    read -r _pw_boot _pw_at _pw_state _pw_epoch _pw_seq < "$POWERF"
    if [ "$_pw_boot" = "$REFRESH_BOOT" ] && [ "$_pw_epoch" = "$EPOCH" ] && [ "$_pw_epoch-$_pw_seq" != "$POWER_KEY" ]; then
      POWER_KEY=$_pw_epoch-$_pw_seq
      case "$_pw_state" in on|off) power_edge "$_pw_state" event ;; esac
    fi
  fi
  if [ -n "$SFPID" ] && [ ! -r "/proc/$SFPID/comm" ]; then
    rm -f "$D/.refresh_ready"; invalidate 1; NEXT_CHECK=0
  fi
  if [ -f "$D/.refresh_stream_reset" ]; then
    rm -f "$D/.refresh_stream_reset"
    new_epoch; NEXT_CHECK=0; invalidate 1
    log "bridge log stream ended; reseeding fingerprint session"
  fi
  if [ "$REFRESH_NOW" -ge "$NEXT_CHECK" ]; then
    [ -d "$MODDIR" ] && [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || break
    NEXT_CHECK=$((REFRESH_NOW+100))
    if ! process_unchanged "$SFPID" "$SFSTAMP"; then
      _sf=$(pidof surfaceflinger 2>/dev/null); _sf=${_sf%% *}
      _sf_stamp=""; process_stamp "$_sf" && _sf_stamp=$PROC_STAMP
      if [ "$_sf:$_sf_stamp" != "$SFPID:$SFSTAMP" ]; then
        SFPID=$_sf; SFSTAMP=$_sf_stamp; BASE_ID=""; FP_ID=""; BASE_HZ=120
        NEXT_SCAN=0; invalidate 1; NEXT_SEED=0
        rm -f "$D/.refresh_ready"
        log "SurfaceFlinger identity changed; discovering fresh mode IDs"
      fi
    fi
    if ! process_unchanged "$HALPID" "$HALSTAMP"; then
      _hal=$(pidof android.hardware.biometrics.fingerprint-service 2>/dev/null); _hal=${_hal%% *}
      _hal_stamp=""; process_stamp "$_hal" && _hal_stamp=$PROC_STAMP
      if [ "$_hal:$_hal_stamp" != "$HALPID:$HALSTAMP" ]; then
        if [ -n "$HALPID" ]; then
          log "fingerprint HAL restarted; clearing stale session without stopping controller"
          new_epoch; invalidate 1
        fi
        HALPID=$_hal; HALSTAMP=$_hal_stamp
      fi
    fi
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      log "bridge watcher exited; starting a new listener"
      new_epoch; watch_events & WATCH_PID=$!; invalidate 1
    fi
    if [ "$BOOT" = 0 ] && [ "$(getprop sys.boot_completed)" = 1 ]; then
      BOOT=1; invalidate 1; NEXT_SEED=0
    fi
    if [ "$BOOT" = 1 ]; then
      _user=$(refresh_exec cmd activity get-current-user 2>/dev/null)
      case "$_user" in ''|*[!0-9]*) ;; *)
        if [ "$_user" != "$USER_ID" ]; then
          USER_ID=$_user; invalidate 1; NEXT_SEED=0
        fi ;;
      esac
    fi
    if [ "$REFRESH_NOW" -ge "$NEXT_POWER" ]; then
      _power=$(refresh_power_state)
      refresh_now; NEXT_POWER=$((REFRESH_NOW+1000))
      case "$_power" in on|off)
        [ "$_power" = "$SCREEN" ] || power_edge "$_power" framework ;;
      esac
    fi
    runtime
  fi
  if [ -n "$SFPID" ] && [ "$REFRESH_NOW" -ge "$NEXT_SCAN" ]; then configure_modes; fi
  refresh_now
  refresh_lease hbm; HBM_LEASE=$REFRESH_LEASE
  refresh_lease sofod; SO_LEASE=$REFRESH_LEASE
  if [ $((TICK % 2)) = 0 ]; then PRESS=$(getprop sys.phh.oplus.fppress); fi
  read_session
  # A fingerprint snapshot is usable only until the next bridge event/epoch.
  if [ "$SEED_EVENT" = "$SESSION_KEY" ] && [ "$SEED_UNTIL" -gt "$REFRESH_NOW" ] && [ "$SEED_AUTH" != - ]; then AUTH=$SEED_AUTH; fi
  WANT=$BASE_HZ; WHY=normal
  if [ "$BOOT" = 0 ] || { [ "$SEEDED" = 0 ] && [ "$REFRESH_NOW" -lt "$START_UNTIL" ]; }; then WANT=120; WHY=boot; fi
  if [ "$SCREEN" = off ]; then WANT=120; WHY=screen-off; fi
  if [ "$REFRESH_NOW" -lt "$WAKE_UNTIL" ]; then WANT=120; WHY=wake; fi
  if [ "$AUTH" = 1 ] || [ "$TOUCH" = 1 ]; then WANT=120; WHY=session; fi
  if [ "$PRESS" = 1 ]; then WANT=120; WHY=press; fi
  if [ "$HBM_LEASE" != - ]; then WANT=120; WHY=hbm; fi
  if [ "$SO_LEASE" != - ]; then WANT=120; WHY=sofod; fi
  # Downshifts are immediate. Coalesce terminal/up edges to avoid 120/144/120
  # thrashing between pointer-up, HBM-off and a new authentication callback.
  if [ "$WANT" = 120 ]; then UP_AT=0
  elif [ "$LAST_WANT" = 120 ]; then
    [ "$UP_AT" != 0 ] || UP_AT=$((REFRESH_NOW+15))
    if [ "$REFRESH_NOW" -lt "$UP_AT" ]; then WANT=120; WHY=settle; fi
  fi
  if [ "$WANT" != "$LAST_WANT" ]; then
    log "target=$WANT Hz trigger=$WHY"
    LAST_WANT=$WANT; invalidate
    NEXT_SETTINGS=$REFRESH_NOW
  fi
  TOKENS="$HBM_LEASE $SO_LEASE"
  if [ "$TOKENS" != "$CHECKED_TOKENS" ]; then
    CHECKED_TOKENS=$TOKENS
    # Even if target is already 120, a new hold must be re-observed before its ACK.
    if [ "$TOKENS" != "- -" ]; then reverify; fi
  fi
  if [ "$SESSION_KEY" != "$LAST_SESSION" ]; then
    LAST_SESSION=$SESSION_KEY
    case "$SESSION_EVENT" in session_on|touch_on) reverify ;; esac
  fi
  if [ -n "$FP_ID" ] && [ -n "$SFPID" ]; then
    if [ "$WANT" = 120 ]; then ID=$FP_ID; else ID=$BASE_ID; fi
    if [ "$APPLIED" != "$WANT" ] && [ "$REFRESH_NOW" -ge "$NEXT_REQUEST" ]; then request_mode; fi
    if [ "$REFRESH_NOW" -ge "$NEXT_VERIFY" ]; then
      if observe; then
        if [ "$APPLIED" != "$WANT" ]; then
          log "$WANT Hz verified: mode=$SF_ID physical=$SF_HZ render=$SF_RENDER reply=$REPLY trigger=$WHY"
        fi
        APPLIED=$WANT; WARNED=0; ATTEMPTS=0; REVERIFY=0
        refresh_now
        if [ "$WANT" = 120 ]; then NEXT_VERIFY=$((REFRESH_NOW+100)); else NEXT_VERIFY=$((REFRESH_NOW+500)); fi
      else
        refresh_now
        if [ "$WARNED" = 0 ] || [ -n "$APPLIED" ]; then
          log "$WANT Hz NOT verified: wanted_mode=$ID actual_mode=${SF_ID:--} physical=${SF_HZ:--} render=${SF_RENDER:--} reply=$REPLY trigger=$WHY"
          WARNED=1
        fi
        if [ -n "$APPLIED" ]; then
          # An external wake/policy override is a NEW failure, not an exhausted
          # old retry budget. Repair both physical pin and framework votes.
          ATTEMPTS=0; NEXT_REQUEST=$REFRESH_NOW; NEXT_SETTINGS=$REFRESH_NOW; FRAMEWORK_HZ=""
        fi
        APPLIED=""; ACK=""; rm -f "$D/.refresh_applied"
        if [ "$ATTEMPTS" -ge 3 ] && [ "$REFRESH_NOW" -ge "$NEXT_RESCAN" ]; then
          NEXT_SCAN=$REFRESH_NOW; NEXT_RESCAN=$((REFRESH_NOW+1000))
        fi
        REVERIFY=0
        if [ "$ATTEMPTS" -lt 3 ]; then NEXT_VERIFY=$((REFRESH_NOW+10)); else NEXT_VERIFY=$((REFRESH_NOW+100)); fi
      fi
      runtime 1
    fi
    # Only a matching observed mode + physical/render rate earns a token ACK.
    if [ "$APPLIED" = "$WANT" ] && [ "$REVERIFY" = 0 ]; then
      _ack="$REFRESH_BOOT $APPLIED $HBM_LEASE $SO_LEASE"
      if [ "$_ack" != "$ACK" ]; then
        printf '%s\n' "$_ack" > "$D/.refresh_applied.tmp" && mv -f "$D/.refresh_applied.tmp" "$D/.refresh_applied" && ACK=$_ack
      fi
    fi
    # Re-read live votes periodically, not only when our cached target changes.
    # After the pin/ACK, and asynchronous: framework votes never gate FOD.
    if [ "$BOOT" = 1 ] && [ "$SETTINGS_RATE" = 1 ] && [ -n "$USER_ID" ]; then
      refresh_now
      if settings_poll && [ "$REFRESH_NOW" -ge "$NEXT_SETTINGS" ]; then settings_start "$WANT" "$USER_ID"; fi
    fi
  fi
  # Seed AFTER the early pin, so a fingerprint dumpsys cannot delay pre-arming.
  if [ "$BOOT" = 1 ] && [ "$REFRESH_NOW" -ge "$NEXT_SEED" ]; then seed_session; fi
  TICK=$((TICK+1))
  refresh_now
  if [ $((REFRESH_NOW-LOOP_START)) -ge 100 ]; then recheck_gap iteration; fi
  LAST_LOOP=$REFRESH_NOW
  refresh_nap 0.05
done
