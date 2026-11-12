#!/system/bin/sh
# X6886: 144 Hz normally, 120 Hz for authentication/enrolment/HBM/SOFOD.
# One writer owns both the SurfaceFlinger pin and the matching framework votes.
MODDIR=${0%/*}
D=/data/adb/fod
LOG=$D/refresh.log
CONF=$D/refresh.conf
SESSIONF=$D/.refresh_session
GPID=$D/.refresh_logcat.pid
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
renice -n -8 -p $$ >/dev/null 2>&1
log() { echo "$(date +%T) $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
: > "$LOG"
log "144/120 Hz controller start (pid $$)"

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
refresh_event() {   # only events emitted by the bundled Transsion bridge
  case "$1" in
    *"ISession::authenticate called"*|*"ISession::enroll called"*|*"ISession::detectInteraction called"*|*"onUiReady"*|*"auto-starting authenticate for SOFOD"*) echo session_on ;;
    *"ICancellationSignal::cancel invoked"*|*"ISession::close called"*|*"Authentication SUCCEEDED"*|*"Enrollment completed successfully"*) echo session_off ;;
    *"onPointerDown"*|*"display on, finger still held at ("*) echo touch_on ;;
    *"onPointerUp"*|*"onPointerCancel"*|*"Touch release (BTN_TOUCH 0)"*|*"Tracking ID lifted"*|*"FOD touch timed out"*) echo touch_off ;;
  esac
}
refresh_framework() {   # Hz, user; lower min before peak on downshift (reverse on upshift)
  if [ "$1" = 120 ]; then
    module_setting_set system "$2" min_refresh_rate "$1" &&
      module_setting_set system "$2" peak_refresh_rate "$1"
  else
    module_setting_set system "$2" peak_refresh_rate "$1" &&
      module_setting_set system "$2" min_refresh_rate "$1"
  fi
}
refresh_seed_session() {   # startup during an already visible fingerprint prompt
  dumpsys fingerprint 2>/dev/null | awk '
    /Current (client|operation):/ && /Fingerprint(Authentication|Enroll|Detect)Client/ { print 1; found=1; exit }
    END { if (!found) print 0 }'
}
# --- end refresh helpers ---

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
  rm -f "$GPID" "$SESSIONF"
}
cleanup() {
  stop_events
  rm -f "$D/.refresh.pid" "$D/.refresh_ready" "$D/.refresh_applied"
}
trap 'cleanup; exit 0' INT TERM
watch_events() {
  while [ ! -f "$D/.ui_stopping" ]; do
    sh -c 'echo $$ > "$1"; exec logcat -b all -T 1 -v brief oplus_udfps_transsion:I "*:S"' x "$GPID" 2>/dev/null |
    (
      _we_session=0; _we_touch=0
      while IFS= read -r line; do
        _we_event=$(refresh_event "$line")
        case "$_we_event" in
          session_on) _we_session=1 ;;
          session_off) _we_session=0; _we_touch=0 ;;
          touch_on) _we_touch=1 ;;
          touch_off) _we_touch=0 ;;
          *) continue ;;
        esac
        refresh_now
        # A lost terminal log must not pin 120 Hz forever. Any new bridge
        # activity renews the 5 min session lease; touch-only leases last 8 s.
        if [ "$_we_session" = 1 ]; then _we_ttl=30000; else _we_ttl=800; fi
        printf '%s %s %s %s\n' "$REFRESH_BOOT" "$((REFRESH_NOW + _we_ttl))" "$_we_session" "$_we_touch" > "$SESSIONF.tmp" &&
          mv -f "$SESSIONF.tmp" "$SESSIONF"
      done
    )
    rm -f "$SESSIONF"
    sleep 1
  done
}
WATCH_PID=""
stop_events  # also stop a logcat child left by a previous crashed controller
rm -f "$D/.refresh_ready" "$D/.refresh_applied" "$D/.refresh_want" "$D/refresh.cache"
watch_events & WATCH_PID=$!

BASE_ID=""; FP_ID=""; BASE_HZ=120; SFPID=""; HALPID=""
APPLIED=""; ACK=""; SF_OK=1; FRAMEWORK_HZ=""; USER_ID=""; BOOT=0; SEEDED=0
TICK=0; NEXT_SCAN=0; NEXT_SETTINGS=0; NEXT_CHECK=0; LAST_MODES=unresolved; PIN_ERROR=0
configure_modes() {
  BASE_ID=""; FP_ID=""
  # --displays avoids dumping layers. Older ROMs may only support the full dump.
  _cm_modes=$(dumpsys SurfaceFlinger --displays 2>/dev/null | refresh_modes)
  [ -n "$_cm_modes" ] || _cm_modes=$(dumpsys SurfaceFlinger 2>/dev/null | refresh_modes)
  if [ -n "$_cm_modes" ]; then
    read -r BASE_ID FP_ID BASE_HZ <<EOF
$_cm_modes
EOF
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
  APPLIED=""; ACK=""; FRAMEWORK_HZ=""; SF_OK=1; PIN_ERROR=0
  rm -f "$D/.refresh_applied"
  # Keep a live controller's readiness during a slow reconcile so a new HBM
  # request still waits for its own ACK instead of bypassing the handshake.
  [ -n "$FP_ID" ] || rm -f "$D/.refresh_ready"
}
while [ ! -f "$D/.ui_stopping" ]; do
  refresh_now
  if [ -n "$SFPID" ] && [ ! -r "/proc/$SFPID/comm" ]; then
    rm -f "$D/.refresh_ready" "$D/.refresh_applied"
    APPLIED=""; ACK=""; SF_OK=0; NEXT_CHECK=$TICK
  fi
  if [ "$TICK" -ge "$NEXT_CHECK" ]; then
    NEXT_CHECK=$((TICK+20))
    if [ -z "$SFPID" ] || [ ! -r "/proc/$SFPID/comm" ]; then
      SFPID=$(pidof surfaceflinger 2>/dev/null | cut -d' ' -f1)
      NEXT_SCAN=$TICK
    fi
    if [ -n "$HALPID" ] && [ ! -r "/proc/$HALPID/comm" ]; then
      log "fingerprint HAL restarted; clearing stale session"
      stop_events; watch_events & WATCH_PID=$!
      HALPID=""; SEEDED=0
    fi
    [ -n "$HALPID" ] || HALPID=$(pidof android.hardware.biometrics.fingerprint-service 2>/dev/null | cut -d' ' -f1)
    if [ "$BOOT" = 0 ] && [ "$(getprop sys.boot_completed)" = 1 ]; then BOOT=1; fi
    if [ "$BOOT" = 1 ]; then
      _user=$(cmd activity get-current-user 2>/dev/null)
      case "$_user" in ''|*[!0-9]*) ;; *)
        if [ "$_user" != "$USER_ID" ]; then USER_ID=$_user; FRAMEWORK_HZ=""; NEXT_SETTINGS=0; fi ;;
      esac
      if [ "$SEEDED" = 0 ]; then
        _seed=$(refresh_seed_session); refresh_now
        # Do not overwrite a newer real event that arrived during dumpsys.
        ( set -C; printf '%s %s %s 0\n' "$REFRESH_BOOT" "$((REFRESH_NOW+30000))" "$_seed" > "$SESSIONF" ) 2>/dev/null || true
        SEEDED=1
      fi
    fi
  fi
  if [ -n "$SFPID" ] && [ "$TICK" -ge "$NEXT_SCAN" ]; then
    configure_modes
    NEXT_SCAN=$((TICK + RECONCILE_S * 20))
    [ -n "$FP_ID" ] || NEXT_SCAN=$((TICK+200))
  fi
  refresh_now
  refresh_lease hbm; HBM_LEASE=$REFRESH_LEASE
  refresh_lease sofod; SO_LEASE=$REFRESH_LEASE
  # The property is a backup for missed logs; no dumpsys or mode discovery in
  # this hot path. Shared helper leases are checked on every 50 ms tick.
  if [ $((TICK % 2)) = 0 ]; then PRESS=$(getprop sys.phh.oplus.fppress); fi
  WANT=$BASE_HZ
  _ss_boot=""; _ss_until=""; _ss_auth=0; _ss_touch=0
  if [ -r "$SESSIONF" ]; then
    read -r _ss_boot _ss_until _ss_auth _ss_touch < "$SESSIONF"
    case "$_ss_until" in ''|*[!0-9]*) _ss_until=0 ;; esac
    if [ "$_ss_boot" = "$REFRESH_BOOT" ] && [ "$_ss_until" -gt "$REFRESH_NOW" ] &&
       { [ "$_ss_auth" = 1 ] || [ "$_ss_touch" = 1 ]; }; then WANT=120; fi
  fi
  if [ "$PRESS" = 1 ] || [ "$HBM_LEASE" != - ] || [ "$SO_LEASE" != - ]; then WANT=120; fi
  if [ -n "$FP_ID" ]; then
    if [ "$WANT" = 120 ]; then ID=$FP_ID; else ID=$BASE_ID; fi
    if [ "$APPLIED" != "$WANT" ] && [ "$SF_OK" = 1 ]; then
      OUT=$(service call SurfaceFlinger 1035 i32 "$ID" 2>&1)
      RC=$?
      case "$RC:$OUT" in
        0:*"Parcel(00000000"*|0:*"Parcel( 00000000"*)
          APPLIED=$WANT
          printf '%s %s\n' "$REFRESH_BOOT" "$$" > "$D/.refresh_ready"
          log "$WANT Hz requested (mode $ID)" ;;
        *)
          SF_OK=0; APPLIED=""
          rm -f "$D/.refresh_ready" "$D/.refresh_applied"
          if [ "$PIN_ERROR" = 0 ]; then log "SurfaceFlinger pin unavailable; using framework refresh votes until next scan"; PIN_ERROR=1; fi ;;
      esac
    fi
    # Publish a token-specific ACK only after the 120 Hz transaction succeeded.
    # It cannot be mistaken for a newer press if 144 Hz was already in flight.
    if [ -n "$APPLIED" ]; then
      _ack="$REFRESH_BOOT $APPLIED $HBM_LEASE $SO_LEASE"
      if [ "$_ack" != "$ACK" ]; then
        printf '%s\n' "$_ack" > "$D/.refresh_applied.tmp" && mv -f "$D/.refresh_applied.tmp" "$D/.refresh_applied"
        ACK=$_ack
      fi
    fi
    if [ "$BOOT" = 1 ] && [ "$SETTINGS_RATE" = 1 ] && [ -n "$USER_ID" ] &&
       [ "$TICK" -ge "$NEXT_SETTINGS" ] && [ "$FRAMEWORK_HZ" != "$WANT" ]; then
      if refresh_framework "$WANT" "$USER_ID"; then FRAMEWORK_HZ=$WANT; fi
      NEXT_SETTINGS=$((TICK+20))
    fi
  fi
  TICK=$((TICK+1))
  sleep 0.05 || sleep 1
done
cleanup
