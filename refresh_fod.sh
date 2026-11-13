# FOD -> refresh handshake, sourced by the controller and both FOD helpers.
# Only refresh.sh writes display modes. Short, boot-scoped leases cannot stick
# after a crash/reboot; per-request tokens prevent an old 120 Hz ACK being reused.
refresh_now() {
  _rn_up=0; read -r _rn_up _ < /proc/uptime
  _rn_sec=${_rn_up%.*}; _rn_frac=${_rn_up#*.}00
  _rn_frac=${_rn_frac%"${_rn_frac#??}"}
  REFRESH_NOW=$((_rn_sec * 100 + 1$_rn_frac - 100))
}
refresh_boot() {
  REFRESH_BOOT=""
  read -r REFRESH_BOOT < /proc/sys/kernel/random/boot_id
}
refresh_lease() {   # source -> REFRESH_LEASE (token or -)
  REFRESH_LEASE=-
  _rl_boot=""; _rl_until=""; _rl_token=""
  [ -r "$D/.refresh_hold.$1" ] || return 0
  read -r _rl_boot _rl_until _rl_token < "$D/.refresh_hold.$1"
  case "$_rl_until" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_rl_boot" = "$REFRESH_BOOT" ] && [ "$_rl_until" -gt "$REFRESH_NOW" ] &&
    [ -n "$_rl_token" ] && REFRESH_LEASE=$_rl_token
  return 0
}
# --- fast FOD handshake (host-tested in test_fast_fod.py) ---
refresh_fod_live() {   # -> REFRESH_FOD_PID of a live controller with discovered 120 Hz
  REFRESH_FOD_PID=""; REFRESH_FOD_STAMP=""
  _rf_ready=""; _rf_pid=""; _rf_stamp=""
  [ -r "$D/.refresh_ready" ] && read -r _rf_ready _rf_pid _rf_stamp < "$D/.refresh_ready"
  [ "$_rf_ready" = "$REFRESH_BOOT" ] || return 1
  case "$_rf_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_rf_pid" 2>/dev/null || return 1
  REFRESH_FOD_PID=$_rf_pid; REFRESH_FOD_STAMP=$_rf_stamp
}
refresh_fod_poke() {   # wake the controller's 50 ms nap at once (identity-checked)
  # Only the PID+start-time written by the controller after it installed its USR1
  # trap is ever signalled; a stale/reused PID or missing stamp is never touched.
  [ -n "$REFRESH_FOD_PID" ] && [ -n "$REFRESH_FOD_STAMP" ] || return 0
  command -v process_stamp >/dev/null 2>&1 || return 0
  process_stamp "$REFRESH_FOD_PID" && [ "$PROC_STAMP" = "$REFRESH_FOD_STAMP" ] || return 0
  kill -USR1 "$REFRESH_FOD_PID" 2>/dev/null
  return 0
}
refresh_fod_request() {   # hbm | sofod -> REFRESH_FOD_TOKEN; writes the lease, never waits
  case "$1" in hbm|sofod) ;; *) return 0 ;; esac
  REFRESH_FOD_TOKEN=""; REFRESH_FOD_DEADLINE=0
  [ -f "$D/.ui_stopping" ] && return 0
  refresh_boot; refresh_now
  read -r REFRESH_FOD_TOKEN < /proc/sys/kernel/random/uuid
  [ -n "$REFRESH_FOD_TOKEN" ] || REFRESH_FOD_TOKEN=$$-$REFRESH_NOW
  printf '%s %s %s\n' "$REFRESH_BOOT" "$((REFRESH_NOW + 800))" "$REFRESH_FOD_TOKEN" > "$D/.refresh_hold.$1.tmp.$$" &&
    mv -f "$D/.refresh_hold.$1.tmp.$$" "$D/.refresh_hold.$1" || { REFRESH_FOD_TOKEN=""; return 0; }
  # The fail-open budget starts at the request, so callers can overlap it with
  # other work (panel wake / SystemUI delay) instead of paying it serially.
  REFRESH_FOD_DEADLINE=$((REFRESH_NOW + 30))
  refresh_fod_live && refresh_fod_poke
  return 0
}
refresh_fod_acked() {   # source -> 0 when the controller has OBSERVED 120 Hz for this hold
  _rf_boot=""; _rf_hz=""; _rf_hbm=""; _rf_so=""
  [ -r "$D/.refresh_applied" ] || return 1
  read -r _rf_boot _rf_hz _rf_hbm _rf_so < "$D/.refresh_applied"
  [ "$_rf_boot" = "$REFRESH_BOOT" ] && [ "$_rf_hz" = 120 ] || return 1
  case "$1" in
    hbm)
      [ "$_rf_hbm" = "$REFRESH_FOD_TOKEN" ] && return 0
      # Screen-off FOD: sofod_touch took a fresh lease AFTER the panel woke and
      # it is still held. An ACK carrying that live token was observed after the
      # wake, and the controller deletes the ACK on any later power edge,
      # override or mismatch. Re-using it removes a second serial wait.
      [ -n "$_rf_so" ] && [ "$_rf_so" != - ] || return 1
      refresh_lease sofod
      [ "$REFRESH_LEASE" = "$_rf_so" ] ;;
    sofod) [ "$_rf_so" = "$REFRESH_FOD_TOKEN" ] ;;
    *) return 1 ;;
  esac
}
refresh_fod_wait() {   # source; bounded by the request's uptime deadline, always fail open
  case "$1" in hbm|sofod) ;; *) return 0 ;; esac
  [ -n "$REFRESH_FOD_TOKEN" ] || return 0
  # Skip the wait when no live controller has discovered a 120 Hz mode. An
  # ACK requires observing the requested mode/rate, not just a Binder reply.
  refresh_fod_live || return 0
  while :; do
    refresh_fod_acked "$1" && return 0
    refresh_now
    [ "$REFRESH_NOW" -lt "${REFRESH_FOD_DEADLINE:-0}" ] || return 0
    sleep 0.01 || return 0
  done
}
refresh_fod_begin() {   # hbm | sofod; always fail open (never break fingerprint capture)
  case "$1" in hbm|sofod) ;; *) return 0 ;; esac
  refresh_fod_request "$1"
  refresh_fod_wait "$1"
  return 0
}
# --- end fast FOD handshake ---
refresh_fod_end() {   # source token; a stale watchdog/replay cannot release a newer lease
  case "$1" in hbm|sofod) ;; *) return 0 ;; esac
  [ -n "$2" ] || return 0
  _re_boot=""; _re_until=""; _re_token=""
  if [ -r "$D/.refresh_hold.$1" ]; then
    read -r _re_boot _re_until _re_token < "$D/.refresh_hold.$1"
    [ "$_re_token" = "$2" ] && rm -f "$D/.refresh_hold.$1"
  fi
  return 0
}
