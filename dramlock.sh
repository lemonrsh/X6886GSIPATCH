#!/system/bin/sh
# X6886 DRAM lock (v14.2) - MediaTek DVFSRC devfreq (mtk-dvfsrc-devfreq).
#   screen ON  -> DRAM locked at ON_FREQ  (default: max = 4266 MHz), applied the moment wake-up starts
#   screen OFF -> DRAM locked at OFF_FREQ (default: half = largest step <= ON/2 = 1866 MHz)
# "Screen off" means not interactive (Asleep or AOD/Dozing).
# v14.2: three independent triggers feed ONE reader (a plain pipe, no fifo), first one wins:
#   1. logcat screen_toggled event (1 = PhoneWindowManager.startedWakingUp, 0 = finishedGoingToSleep)
#   2. panel sysfs check every 0.5 s (dpms / backlight, read with shell builtins = no forks); a change
#      switches at once and is then confirmed with `dumpsys power` (so AOD still counts as off)
#   3. reconcile every RECONCILE_S s from `dumpsys power`, re-asserting the lock if anything undid it
# v14.1 relied on (1) plus a 60 s reconcile: when events did not arrive the clock stayed at the
# screen-off step with the screen on. The whole loop now also restarts itself if it ever ends.
# Config: /data/adb/fod/dram.conf   Log: /data/adb/fod/dram.log
# Manual: sh dramlock.sh status | reload       (reload = re-read dram.conf within 1 s)
# DRAM_LOCK=0 + reload (or reboot) gives the DRAM back to the stock governor.
MODDIR=${0%/*}
# (the DRAMLOCK_* environment overrides exist only for the host-side tests)
D=${DRAMLOCK_D:-/data/adb/fod}; CONF=$D/dram.conf; LOG=$D/dram.log; ORIG=$D/dram.orig
RELOADF=$D/.dram.reload; GENF=$D/.dram.gen
NODE=${DRAMLOCK_NODE:-/sys/class/devfreq/mtk-dvfsrc-devfreq}
BOOT_DELAY=${DRAMLOCK_BOOT_DELAY:-8}
SCREEN_NODES=${DRAMLOCK_SCREEN_NODES:-"/sys/class/drm/card0-DSI-1/dpms /sys/class/leds/lcd-backlight/brightness /sys/class/backlight/*/brightness"}
DRAM_LOCK=1; ON_FREQ=max; OFF_FREQ=half; RECONCILE_S=60; SCREEN_POLL=1

# --- dram helpers (regression-tested by .github/tests/test_fixes.py) ---
# Frequencies are compared in kHz: 4266000000 Hz does not fit in mksh's 32-bit arithmetic.
dram_khz() {   # $1 = Hz -> kHz digits (empty when not a number)
  case "$1" in ''|*[!0-9]*) echo ""; return ;; esac
  if [ ${#1} -le 3 ]; then echo 0; else echo "${1%???}"; fi
}
dram_avail() { cat "$NODE/available_frequencies" 2>/dev/null; }
dram_lowest() {   # lowest available Hz
  _lo=""; _lok=""
  for _f in $(dram_avail); do
    _k=$(dram_khz "$_f"); [ -n "$_k" ] || continue
    if [ -z "$_lok" ] || [ "$_k" -lt "$_lok" ]; then _lo=$_f; _lok=$_k; fi
  done
  echo "$_lo"
}
dram_highest() {
  _hi=""; _hik=""
  for _f in $(dram_avail); do
    _k=$(dram_khz "$_f"); [ -n "$_k" ] || continue
    if [ -z "$_hik" ] || [ "$_k" -gt "$_hik" ]; then _hi=$_f; _hik=$_k; fi
  done
  echo "$_hi"
}
dram_floor() {   # $1 = kHz limit -> largest available Hz <= limit (lowest step if none is)
  _best=""; _bestk=""
  for _f in $(dram_avail); do
    _k=$(dram_khz "$_f"); [ -n "$_k" ] || continue
    if [ "$_k" -le "$1" ] && { [ -z "$_bestk" ] || [ "$_k" -gt "$_bestk" ]; }; then _best=$_f; _bestk=$_k; fi
  done
  [ -n "$_best" ] && { echo "$_best"; return; }
  dram_lowest
}
dram_resolve() {   # $1 = max|min|half|<Hz>  $2 = resolved ON Hz (for half) -> available Hz
  case "$1" in
    max|'') dram_highest ;;
    min) dram_lowest ;;
    half) _ok=$(dram_khz "$2"); [ -n "$_ok" ] || _ok=$(dram_khz "$(dram_highest)")
          dram_floor $((_ok / 2)) ;;
    *[!0-9]*) echo "" ;;
    *) dram_floor "$(dram_khz "$1")" ;;
  esac
}
dram_gov() { _g=""; read -r _g 2>/dev/null < "$NODE/governor"; echo "$_g"; }
dram_set() {   # $1 = Hz: lock min = max = target = $1. Seamless both ways: the clock goes straight
  # from the old step to the new one (never through the lowest step) and works on kernels that
  # reject min > max. Up: max, target, min (target is hit on the 2nd write). Down: min, max, target.
  _g=""; _cmx=""
  read -r _g 2>/dev/null < "$NODE/governor"
  [ "$_g" = userspace ] || echo userspace > "$NODE/governor" 2>/dev/null
  read -r _cmx 2>/dev/null < "$NODE/max_freq"
  _nk=$(dram_khz "$1"); _ck=$(dram_khz "$_cmx")
  if [ -n "$_nk" ] && [ -n "$_ck" ] && [ "$_nk" -ge "$_ck" ]; then
    echo "$1" > "$NODE/max_freq" 2>/dev/null
    echo "$1" > "$NODE/userspace/set_freq" 2>/dev/null
    echo "$1" > "$NODE/min_freq" 2>/dev/null
  else
    _low=${LOW_HZ:-$(dram_lowest)}
    if [ -n "$_low" ]; then echo "$_low" > "$NODE/min_freq" 2>/dev/null; else echo "$1" > "$NODE/min_freq" 2>/dev/null; fi
    echo "$1" > "$NODE/max_freq" 2>/dev/null
    echo "$1" > "$NODE/userspace/set_freq" 2>/dev/null
    echo "$1" > "$NODE/min_freq" 2>/dev/null
  fi
}
dram_locked_at() {   # $1 = Hz -> success when governor/min/max already hold the lock
  _g=""; _mn=""; _mx=""
  read -r _g 2>/dev/null < "$NODE/governor"
  read -r _mn 2>/dev/null < "$NODE/min_freq"
  read -r _mx 2>/dev/null < "$NODE/max_freq"
  [ "$_g" = userspace ] && [ "$_mn" = "$1" ] && [ "$_mx" = "$1" ]
}
dram_event_state() {   # $1 = logcat line -> on | off | (empty)
  # brief: "I/screen_toggled( 1580): 1"  raw: "1"  some builds print "[1]"
  set -f; set -- $1; set +f
  [ $# -gt 0 ] || { echo ""; return; }
  eval "_last=\${$#}"
  _last=${_last#[}; _last=${_last%]}
  case "$_last" in 1) echo on ;; 0) echo off ;; *) echo "" ;; esac
}
dram_wake_state() {   # framework view: Awake/Dreaming = on, Asleep/Dozing (AOD) = off, unknown = empty
  _w=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
  case "$_w" in Awake|Dreaming) echo on ;; Asleep|Dozing) echo off ;; *) echo "" ;; esac
}
dram_screen_sig() {   # sets SIG: one 0/1 digit per readable panel node (dpms On / backlight > 0 = 1), no forks
  SIG=""
  for _sn in $SCREEN_NODES; do
    [ -r "$_sn" ] || continue
    _v=""; read -r _v 2>/dev/null < "$_sn"
    case "$_v" in On|on) _v=1 ;; ''|0) _v=0 ;; *[!0-9]*) _v=0 ;; *) _v=1 ;; esac
    SIG="$SIG$_v"
  done
}
dram_sig_state() {   # $1 = SIG -> on when any panel node says lit
  case "$1" in *1*) echo on ;; *) echo off ;; esac
}
# --- end dram helpers ---

log() { echo "$(date +%T) $*" >> "$LOG"; }
mhz() { _k=$(dram_khz "$1"); [ -n "$_k" ] && echo "$((_k / 1000)) MHz" || echo "?"; }
load_conf() {
  DRAM_LOCK=1; ON_FREQ=max; OFF_FREQ=half; RECONCILE_S=60; SCREEN_POLL=1
  [ -f "$CONF" ] && . "$CONF"
  case "$RECONCILE_S" in ''|*[!0-9]*) RECONCILE_S=60 ;; esac
  [ "$RECONCILE_S" -lt 10 ] && RECONCILE_S=10
  LOW_HZ=$(dram_lowest)
  ON_HZ=$(dram_resolve "$ON_FREQ" "")
  OFF_HZ=$(dram_resolve "$OFF_FREQ" "$ON_HZ")
  [ -n "$ON_HZ" ] || ON_HZ=$(dram_highest)
  [ -n "$OFF_HZ" ] || OFF_HZ=$ON_HZ
}
daemon_pid() {   # live dramlock daemon pid or empty
  _p=$(cat "$D/.dramlock.pid" 2>/dev/null)
  case "$_p" in ''|*[!0-9]*) return ;; esac
  [ "$_p" -gt 1 ] && kill -0 "$_p" 2>/dev/null && grep -q dramlock "/proc/$_p/cmdline" 2>/dev/null && echo "$_p"
}

case "$1" in
  status)
    load_conf; dram_screen_sig
    _dp=$(daemon_pid)
    echo "daemon:    ${_dp:+running pid $_dp}${_dp:-NOT running}"
    echo "node:      $NODE"
    echo "governor:  $(cat "$NODE/governor" 2>/dev/null)"
    echo "cur_freq:  $(cat "$NODE/cur_freq" 2>/dev/null) ($(mhz "$(cat "$NODE/cur_freq" 2>/dev/null)"))"
    echo "min/max:   $(cat "$NODE/min_freq" 2>/dev/null) / $(cat "$NODE/max_freq" 2>/dev/null)"
    echo "available: $(dram_avail)"
    echo "config:    DRAM_LOCK=$DRAM_LOCK ON=$ON_HZ ($(mhz "$ON_HZ")) OFF=$OFF_HZ ($(mhz "$OFF_HZ")) SCREEN_POLL=$SCREEN_POLL"
    echo "screen:    $(dram_wake_state) (panel nodes: ${SIG:-none})"
    echo "--- last dram.log lines"; tail -n 8 "$LOG" 2>/dev/null
    exit 0 ;;
  reload)
    if [ -n "$(daemon_pid)" ]; then touch "$RELOADF"; echo "reload requested (applies within 1 s)"; exit 0; fi
    echo "dramlock is not running (reboot, or start it: sh $0 &)"; exit 1 ;;
esac

[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance dramlock
mkdir -p "$D"
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep "$BOOT_DELAY"   # let the vendor power HAL finish its own boot-time DVFSRC setup first
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
: > "$LOG"
rm -f "$D/.dram.fifo" "$RELOADF"   # v14.1 leftovers
[ -d "$NODE" ] || { log "no $NODE on this kernel - DRAM lock not available"; exit 0; }
grep -qw userspace "$NODE/available_governors" 2>/dev/null || { log "userspace governor not offered - exiting"; exit 0; }
# Remember the stock policy once per boot, before we touch it (used by DRAM_LOCK=0).
G0=$(dram_gov)
if [ -n "$G0" ] && [ "$G0" != userspace ]; then
  echo "$G0 $(cat "$NODE/min_freq" 2>/dev/null) $(cat "$NODE/max_freq" 2>/dev/null)" > "$ORIG"
fi
load_conf
# 0.5 s panel checks need a fractional sleep; never busy-loop if this sleep cannot do it.
POLL=0.5; sleep 0.05 2>/dev/null || POLL=1
dram_screen_sig
log "start pid $$: ON $ON_HZ ($(mhz "$ON_HZ")) OFF $OFF_HZ ($(mhz "$OFF_HZ")) stock=$(cat "$ORIG" 2>/dev/null) lock=$DRAM_LOCK panel=${SIG:-none} poll=${POLL}s"

STATE=""; RELEASED=0
apply() {   # $1 = on|off  $2 = why
  if [ "$DRAM_LOCK" != 1 ]; then
    if [ "$RELEASED" = 0 ]; then
      OG=""; OMIN=""; OMAX=""
      [ -r "$ORIG" ] && read -r OG OMIN OMAX < "$ORIG"
      if [ -z "$OG" ]; then   # booted already locked (e.g. an old lock_dram.sh): stock = first other governor, full range
        for _g in $(cat "$NODE/available_governors" 2>/dev/null); do [ "$_g" != userspace ] && { OG=$_g; break; }; done
        OMIN=$(dram_lowest); OMAX=$(dram_highest)
      fi
      _low=$(dram_lowest); [ -n "$_low" ] && echo "$_low" > "$NODE/min_freq" 2>/dev/null
      [ -n "$OMAX" ] && echo "$OMAX" > "$NODE/max_freq" 2>/dev/null
      [ -n "$OMIN" ] && echo "$OMIN" > "$NODE/min_freq" 2>/dev/null
      [ -n "$OG" ] && echo "$OG" > "$NODE/governor" 2>/dev/null
      log "DRAM_LOCK=0 -> stock policy restored ($OG $OMIN-$OMAX)"
    fi
    RELEASED=1; STATE=$1; return
  fi
  RELEASED=0
  if [ "$1" = on ]; then F=$ON_HZ; else F=$OFF_HZ; fi
  if [ "$1" = "$STATE" ] && dram_locked_at "$F"; then return; fi
  dram_set "$F"
  log "screen $1 ($2) -> $(mhz "$F"), cur=$(mhz "$(cat "$NODE/cur_freq" 2>/dev/null)")"
  STATE=$1
}

# Producers: every trigger writes one short line into the same pipe; the single reader below
# serialises all devfreq writes. GEN lets an orphaned logcat loop notice a restarted pipeline.
events() {   # $1 = generation
  while :; do
    _gen=""; read -r _gen 2>/dev/null < "$GENF"; [ "$_gen" = "$1" ] || exit 0
    logcat -b events -v brief -T 1 -s screen_toggled 2>/dev/null
    sleep 3   # logd restarted / logcat refused: follow again
  done
}
ticker() {   # panel checks, reconcile ticks, reload requests
  _tk=0; _last=$SIG
  if [ "$POLL" = 1 ]; then _every=$RECONCILE_S; else _every=$((RECONCILE_S * 2)); fi
  [ -n "$_last" ] || [ "$POLL" = 1 ] || _every=20   # no panel node: confirm state every 10 s instead
  while :; do
    sleep "$POLL"
    if [ -f "$RELOADF" ]; then rm -f "$RELOADF"; echo reload; fi
    if [ "$SCREEN_POLL" = 1 ] && [ -n "$_last" ]; then
      dram_screen_sig
      [ "$SIG" != "$_last" ] && { _last=$SIG; echo "panel $(dram_sig_state "$SIG")"; }
    fi
    _tk=$((_tk + 1)); [ "$_tk" -ge "$_every" ] && { _tk=0; echo tick; }
  done
}
reader() {
  while read -r LINE; do
    case "$LINE" in
      tick)
        S=$(dram_wake_state); [ -n "$S" ] && apply "$S" reconcile ;;
      reload)
        load_conf; STATE=""; log "reload: ON $(mhz "$ON_HZ") OFF $(mhz "$OFF_HZ") lock=$DRAM_LOCK"
        S=$(dram_wake_state); [ -n "$S" ] || S=on; apply "$S" reload ;;
      "panel on"|"panel off")
        apply "${LINE#panel }" panel          # instant switch on the panel edge ...
        S=$(dram_wake_state); [ -n "$S" ] && apply "$S" confirm ;;   # ... framework decides (AOD = off)
      *)
        S=$(dram_event_state "$LINE"); [ -n "$S" ] && apply "$S" event ;;
    esac
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ]; then tail -c 20000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; fi
  done
}

S=$(dram_wake_state); [ -n "$S" ] || S=on
apply "$S" boot
G=0
while :; do
  G=$((G + 1)); echo "$$.$G" > "$GENF"
  { events "$$.$G" & ticker; } | reader
  log "event loop ended - restarting"
  sleep 2
done
