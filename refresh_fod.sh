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
refresh_fod_begin() {   # hbm | sofod; always fail open (never break fingerprint capture)
  case "$1" in hbm|sofod) ;; *) return 0 ;; esac
  REFRESH_FOD_TOKEN=""
  [ -f "$D/.ui_stopping" ] && return 0
  refresh_boot; refresh_now
  read -r REFRESH_FOD_TOKEN < /proc/sys/kernel/random/uuid
  [ -n "$REFRESH_FOD_TOKEN" ] || REFRESH_FOD_TOKEN=$$-$REFRESH_NOW
  printf '%s %s %s\n' "$REFRESH_BOOT" "$((REFRESH_NOW + 800))" "$REFRESH_FOD_TOKEN" > "$D/.refresh_hold.$1.tmp.$$" &&
    mv -f "$D/.refresh_hold.$1.tmp.$$" "$D/.refresh_hold.$1" || return 0
  # No added delay on ROMs without a working 120 Hz controller. A ready
  # controller normally ACKs on the next 50 ms tick, before HBM/key195/replay.
  _rf_ready=""; _rf_pid=""
  [ -r "$D/.refresh_ready" ] && read -r _rf_ready _rf_pid < "$D/.refresh_ready"
  [ "$_rf_ready" = "$REFRESH_BOOT" ] || return 0
  case "$_rf_pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$_rf_pid" 2>/dev/null || return 0
  _rf_n=0
  while [ "$_rf_n" -lt 30 ]; do
    _rf_boot=""; _rf_hz=""; _rf_hbm=""; _rf_so=""
    if [ -r "$D/.refresh_applied" ]; then
      read -r _rf_boot _rf_hz _rf_hbm _rf_so < "$D/.refresh_applied"
      if [ "$_rf_boot" = "$REFRESH_BOOT" ] && [ "$_rf_hz" = 120 ]; then
        case "$1" in hbm) [ "$_rf_hbm" = "$REFRESH_FOD_TOKEN" ] && return 0 ;;
                      sofod) [ "$_rf_so" = "$REFRESH_FOD_TOKEN" ] && return 0 ;; esac
      fi
    fi
    sleep 0.01 || break
    _rf_n=$((_rf_n+1))
  done
  return 0
}
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
