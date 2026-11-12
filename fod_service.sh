#!/system/bin/sh
MODDIR=${0%/*}
# Guard before spawning helpers: a manual/service re-run must not duplicate the HBM driver.
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance fod_service
# Refresh controller is launched earlier by post-fs-data.sh.
[ -f "$MODDIR/sofod_touch.sh" ] && ( while true; do sh "$MODDIR/sofod_touch.sh" >/dev/null 2>&1; sleep 3; done & )
NODE=/sys/kernel/tran_display/lcm_hbm_state
D=/data/adb/fod; LOG=$D/hbm.log
# Best-effort handshake: request 120 Hz before HBM/key195, never block capture
# indefinitely if the refresh service/ROM does not support the pin.
refresh_fod_begin() { :; }
refresh_fod_end() { :; }
REFRESH_FOD_TOKEN=""
[ -f "$MODDIR/refresh_fod.sh" ] && . "$MODDIR/refresh_fod.sh"
ENABLED=1; HAL_PATCH=12; MAX_S=3; MAX_N=60; TEMP_MAX=430; WAIT_N=30; KEYLOG=40; INJECT195=1; LEAD_S=0.04
WAIT_SO=80      # v7: wait (x10 ms) for SystemUI to report the press when it was injected by sofod_touch (screen-off wake is slow)
PROP_WAIT=0     # v11.2.1: 1 = experimental resetprop -w waits instead of polling getprop (default OFF = v11.1 behaviour)
FAST_FILTER=1   # v7: pre-filter touch events with grep (0 = old slow shell loop)
mkdir -p $D
[ -f $D/hbm.conf ] && . $D/hbm.conf
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done
# 0) SELinux rules for screen-off FOD, applied live (sepolicy.rule is not loaded early on this GSI:
#    "unable to find pre-init dir"). Then restart the HAL once so it re-writes the touch IC nodes.
if command -v magiskpolicy >/dev/null 2>&1; then
  magiskpolicy --live \
    "allow hal_fingerprint_default proc_fingerprint_status file { open read write getattr setattr }" \
    "allow hal_fingerprint_default proc_gesture_function file { open read write getattr setattr }" \
    "allow hal_fingerprint_default vendor_tr_teeos_prop file { open read getattr map }" \
    "allow system_suspend sysfs file { open read getattr }" >/dev/null 2>&1
  setprop ctl.restart vendor.fingerprint-default
  sleep 4
fi
log() { echo "$(date +%T.%N | cut -c1-12) $*" >> $LOG; }
: > $LOG
# 1) make sure the running HAL really uses the patched library
if [ "$HAL_PATCH" != 0 ]; then
  WANT=$(sha256sum "$MODDIR/libs/libgf_hal.p$HAL_PATCH.so" | cut -d' ' -f1)
  P=$(pidof android.hardware.biometrics.fingerprint-service | cut -d' ' -f1)
  HAVE=$(sha256sum /proc/$P/root/odm/lib64/libgf_hal.so 2>/dev/null | cut -d' ' -f1)
  if [ "$HAVE" = "$WANT" ]; then log "HAL runs patched lib p$HAL_PATCH (pid $P)"
  else log "HAL lib differs (have=$HAVE) -> restarting HAL"; setprop ctl.restart vendor.fingerprint-default; sleep 3; fi
fi
# 1b) HAL watchdog: after a long sleep the HAL can be restarted by the system; make sure the new process still runs the patched lib
if [ "$HAL_PATCH" != 0 ]; then
  ( LASTP=$(pidof android.hardware.biometrics.fingerprint-service | cut -d' ' -f1); R=0
    while true; do
      sleep 15
      P=$(pidof android.hardware.biometrics.fingerprint-service | cut -d' ' -f1)
      [ -n "$P" ] && [ "$P" != "$LASTP" ] || continue
      sleep 3; log "HAL pid changed $LASTP -> $P"; LASTP=$P
      WANT=$(sha256sum "$MODDIR/libs/libgf_hal.p$HAL_PATCH.so" | cut -d' ' -f1)
      HAVE=$(sha256sum /proc/$P/root/odm/lib64/libgf_hal.so 2>/dev/null | cut -d' ' -f1)
      if [ "$HAVE" != "$WANT" ] && [ $R -lt 3 ]; then
        R=$((R+1)); log "restarted HAL does not run patched lib -> restart #$R"
        setprop ctl.restart vendor.fingerprint-default; sleep 4
        LASTP=$(pidof android.hardware.biometrics.fingerprint-service | cut -d' ' -f1)
      fi
    done ) &
fi
[ "$ENABLED" = 1 ] || { log "HBM driver disabled by config"; exit 0; }
# 2) HBM + FOD key driver (v7)
# v6 parsed EVERY touch event line in a shell loop (mksh reads pipes byte by byte -> tens of thousands of syscalls per
# second while scrolling) and polled getprop 30x on every touch-down. That load competed with SurfaceFlinger/UI.
# v7: grep filters the stream in C so the shell only sees BTN_TOUCH / key 195; the fppress poll is 2x lighter.
find_dev() { for d in /sys/class/input/event*; do [ "$(cat $d/device/name 2>/dev/null)" = "mtk-tpd" ] && { echo /dev/input/${d##*/}; return; }; done; }
DEV=""; for i in 1 2 3 4 5 6 7 8 9 10; do DEV=$(find_dev); [ -n "$DEV" ] && break; sleep 2; done
[ -n "$DEV" ] || { log "touch device mtk-tpd not found"; exit 1; }
[ -w $NODE ] || { log "node $NODE not writable"; exit 1; }
which sendevent >/dev/null 2>&1 || { log "sendevent missing -> key injection disabled"; INJECT195=0; }
FILTER_OK=0
if [ "$FAST_FILTER" = 1 ] && echo 0001 | grep --line-buffered -E '0001|x' >/dev/null 2>&1; then FILTER_OK=1; fi
SOFLAG=$D/.sofod_busy
GPID=$D/.getevent.pid
hot() { t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); [ -n "$t" ] && [ "$t" -ge "$TEMP_MAX" ]; }
# the HAL's touch thread reads EV_KEY 195: value 1 = finger down (starts capture), value 0 = finger up
inject() { sendevent $DEV 1 195 $1 >/dev/null 2>&1; sendevent $DEV 0 0 0 >/dev/null 2>&1; }
[ "$INJECT195" = 1 ] && inject 0
# --- HBM safety helpers (regression-tested by .github/tests/test_fixes.py) ---
ON=0; WD=""; KL=0; LC=0; HBM_SEQ=0
HBM_TOKEN_FILE=$D/.hbm.token
hbm_invalidate() {
  HBM_SEQ=$((HBM_SEQ+1))
  HBM_TOKEN=""
  [ -r /proc/sys/kernel/random/uuid ] && read -r HBM_TOKEN < /proc/sys/kernel/random/uuid
  case "$HBM_TOKEN" in
    ''|*[!0-9a-fA-F-]*) read -r _u _ < /proc/uptime; HBM_TOKEN="${_u}-$$-$HBM_SEQ" ;;
  esac
  printf '%s\n' "$HBM_TOKEN" > "$HBM_TOKEN_FILE"
}
hbm_cancel() {
  # Invalidate first, then stop/reap the old watchdog. Even if kill cannot stop an
  # orphaned sleep child, that child can no longer pass the token check below.
  hbm_invalidate
  if [ -n "$WD" ]; then
    kill "$WD" 2>/dev/null || true
    wait "$WD" 2>/dev/null || true
    WD=""
  fi
}
hbm_timeout() {
  [ "$(cat "$HBM_TOKEN_FILE" 2>/dev/null)" = "$1" ] || return 0
  echo 0 > "$NODE"
  refresh_fod_end hbm "$REFRESH_FOD_TOKEN"
}
hbm_start_watchdog() {
  ( sleep "$MAX_S"; hbm_timeout "$1" ) & WD=$!
}
hbm_off() {
  hbm_cancel
  echo 0 > "$NODE"
  refresh_fod_end hbm "$REFRESH_FOD_TOKEN"
  ON=0
}
hbm_on() {
  if hot; then log "skip: battery hot"; return 1; fi
  hbm_cancel
  refresh_fod_begin hbm
  echo 1 > "$NODE"
  ON=1
  hbm_start_watchdog "$HBM_TOKEN"
  return 0
}
# --- end HBM safety helpers ---
hbm_off; log "driver start dev=$DEV inject195=$INJECT195 fastfilter=$FILTER_OK"
# v11.2: event-driven waits. `resetprop -w NAME OLD` blocks until NAME differs from OLD, so the shell no longer
# forks getprop every 20-30 ms. Auto-detected at start; falls back to the old polling when unsupported.
PROPWAIT=0
if [ "$PROP_WAIT" != 0 ] && command -v timeout >/dev/null 2>&1 && timeout 2 resetprop -w sys.boot_completed 0 >/dev/null 2>&1; then
  timeout 0.1 sleep 1 >/dev/null 2>&1; [ $? = 124 ] && PROPWAIT=1   # fractional timeout must really work
fi
log "event-driven prop waits: $PROPWAIT (PROP_WAIT=$PROP_WAIT)"
now_cs() { read -r _u _ < /proc/uptime; NOW_CS=${_u%.*}${_u#*.}; }   # uptime in 10 ms units, no fork
wait_fp1() {   # $1 = budget in 10 ms units; real elapsed time is measured, so an instantly returning wait cannot eat the budget
  now_cs; T0=$NOW_CS; i=0
  while :; do
    [ "$(getprop sys.phh.oplus.fppress)" = 1 ] && return 0
    now_cs; i=$((NOW_CS-T0)); [ $i -ge $1 ] && break
    S=$NOW_CS
    if [ $PROPWAIT = 1 ]; then
      timeout 0.1 resetprop -w sys.phh.oplus.fppress 0 >/dev/null 2>&1
      now_cs; [ $((NOW_CS-S)) -lt 2 ] && sleep 0.02
    else sleep 0.02; fi
  done
  [ "$(getprop sys.phh.oplus.fppress)" = 1 ]
}
hold_fp() {    # $1 = max loops (~30 ms each); sets n
  now_cs; T0=$NOW_CS; n=0
  while [ "$(getprop sys.phh.oplus.fppress)" = 1 ]; do
    now_cs; E=$((NOW_CS-T0)); n=$((E/3)); [ $E -ge $(($1*3)) ] && break
    S=$NOW_CS
    if [ $PROPWAIT = 1 ]; then
      timeout 0.1 resetprop -w sys.phh.oplus.fppress 1 >/dev/null 2>&1
      now_cs; [ $((NOW_CS-S)) -lt 2 ] && sleep 0.03
    else sleep 0.03; fi
  done
}
press() {   # BTN_TOUCH went down
  [ "$ON" = 0 ] || return
  W=$WAIT_N; [ -f $SOFLAG ] && W=$WAIT_SO
  wait_fp1 $W
  [ "$(getprop sys.phh.oplus.fppress)" = 1 ] || return
  hbm_on || return
  log "finger on sensor (fppress, waited $i) -> HBM on"
  INJ=0
  if [ "$INJECT195" = 1 ]; then sleep $LEAD_S; inject 1; INJ=1; log "injected key195 down"; fi
  hold_fp $MAX_N
  if [ "$INJ" = 1 ]; then inject 0; log "injected key195 up"; fi
  hbm_off; log "HBM off (held=$n)"
}
handle() {  # $1=type $2=code $3=value (hex, as printed by getevent)
  if [ "$1" = 0001 ] && [ $KL -lt $KEYLOG ]; then log "key $2 $3"; KL=$((KL+1)); fi
  case "$1 $2" in
    "0001 00c3")   # real key 195 from the touch IC (ignored when we inject our own, to avoid feedback)
      if [ "$INJECT195" != 1 ]; then
        if [ "$3" = 00000001 ]; then hbm_on && log "real key195 down -> HBM on"; else hbm_off; log "real key195 up -> HBM off"; fi
      fi;;
    "0001 014a")
      if [ "$3" = 00000001 ]; then press; else [ "$ON" = 1 ] && hbm_off; fi;;
  esac
}
read_events() {
  while read -r f1 f2 f3 f4; do
    case "$f1" in *:) handle "$f2" "$f3" "$f4";; *) handle "$f1" "$f2" "$f3";; esac
    LC=$((LC+1))
    if [ $LC -ge 100 ]; then
      LC=0
      if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 150000 ]; then tail -c 40000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; fi
    fi
  done
}
start_pipe() {
  # first stage records getevent's own pid (exec keeps it) so only OUR getevent is ever killed
  if [ "$FILTER_OK" = 1 ]; then
    sh -c 'echo $$ > "$1"; exec getevent "$2"' x "$GPID" "$DEV" 2>/dev/null | grep --line-buffered -E '0001 (014a|00c3) ' | read_events
  else
    sh -c 'echo $$ > "$1"; exec getevent "$2"' x "$GPID" "$DEV" 2>/dev/null | read_events
  fi
}
# supervisor: restart the pipeline if it dies or if the touch node moves (v6 kept a stale node until reboot,
# one cause of "FOD does not glow" until reboot)
while true; do
  DEV=$(find_dev); [ -n "$DEV" ] || { sleep 2; continue; }
  start_pipe &
  RP=$!
  while kill -0 $RP 2>/dev/null; do
    sleep 10
    D2=$(find_dev)
    if [ -n "$D2" ] && [ "$D2" != "$DEV" ]; then log "touch node moved $DEV -> $D2 -> restarting driver"; break; fi
  done
  GP=$(cat $GPID 2>/dev/null); [ -n "$GP" ] && kill $GP 2>/dev/null
  kill $RP 2>/dev/null
  hbm_off
  sleep 1
done
