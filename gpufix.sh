#!/system/bin/sh
# X6886 GPU DVFS governor for MT6789 / GED / gpufreqv2.
#
# Goal: the GPU follows load everywhere (UI, games, video), instead of sitting at the
# 390 MHz floor almost all the time.
#
# What the kernel allows, and why the old static tweak was wrong for this kernel:
#   * gpu_dvfs_enable=1            -> the driver scales by itself, nothing is pinned.
#   * [GPU-LimitC] CeilingIndex: 0 -> no limiter; the fastest OPP (1600 MHz) is allowed.
#   * [GPU-LimitF] FloorIndex: 44  -> only the "never below 390 MHz" floor is active.
#   * boost_gpu_enable=0 and gpu_cust_boost_freq=390000 -> GED's boost path is inert:
#     its target is the slowest OPP, so a boost asks for the clock the GPU already idles at.
# GED only raises the clock when *it* decides there is 3D work; ordinary UI scrolling
# rarely survives its sampling long enough, which is why it looks stuck at 390 MHz.
#
# This governor reads GED's own load counter (gpu_utilization) every INTERVAL s and
# moves the boost floor: MIN_HZ while idle, TOP_HZ while busy and for HOLD_S after.
# The ceiling stays 1600 MHz and DVFS stays on, so inside that window the clock still
# scales by demand - it is a floor, not a fixed frequency. Flip MODE=floor for an
# always-raised floor, MODE=off to always release.
#
# Two copies exist by design (the main patch ships it disabled, the standalone
# GPU-DVFS-X6886 module ships it enabled with GPU_FIX/ENABLED=1); CI checks that this
# file is byte-identical to gpumod/gpufix.sh.
#
# Modes:
#   status (default)  report + what the governor would do right now; writes nothing
#   probe [SECONDS]   sample frequency/load and say whether scaling works
#   apply [HZ]        one-shot: set the boost floor to HZ (default TOP_HZ)
#   release           set the boost floor back to MIN_HZ
#   verify [SECONDS]   like probe, with PASS/FAIL wording
#   run               the adaptive loop (foreground; service.sh runs it in background)
#   boot              what service.sh calls: start the loop when ENABLED=1
#   revert            restore the values saved by the first write (a reboot does too)
#
# Config: /data/adb/fod/gpu.conf   Snapshot: /data/adb/fod/gpu.orig   Log: /data/adb/fod/gpu.log
# Nothing is written while ENABLED=0. Every value written is a module parameter or a GED
# node, so a plain reboot restores the stock behaviour even if revert is never run.
MODDIR=${0%/*}
ME="sh $MODDIR/gpufix.sh"
D=/data/adb/fod
# The standalone GPU module keeps its own state so it never edits the main
# patch's /data/adb/fod config (both may be inspected on the same phone).
case "$MODDIR" in *gpu_dvfs_x6886*) D=${GPUFIX_STATE:-/data/adb/gpufix} ;; esac
CONF=$D/gpu.conf
ORIG=$D/gpu.orig
PIDF=$D/.gpufix.pid
LOG=$D/gpu.log
GED=/sys/kernel/ged/hal
P=/sys/module/ged/parameters
TABLES="/proc/gpufreqv2/gpu_working_opp_table /proc/gpufreqv2/stack_working_opp_table"
STATUS=/proc/gpufreqv2/gpufreq_status
N_CUR=$GED/current_freqency
N_UTIL=$GED/gpu_utilization
N_BOOST=$GED/custom_boost_gpu_freq
N_LEVELS=$GED/total_gpu_freq_level_count
P_DVFS=$P/gpu_dvfs_enable
P_BOOST=$P/boost_gpu_enable
P_CUST=$P/gpu_cust_boost_freq
P_BOTTOM=$P/gpu_bottom_freq
P_UPBOUND=$P/gpu_cust_upbound_freq

# Defaults; /data/adb/fod/gpu.conf may override them (validated below).
ENABLED=0            # 1 = start the adaptive governor at boot
MODE=adaptive        # adaptive | floor (always TOP_HZ) | off (always MIN_HZ)
MIN_HZ=390000        # floor while idle (390000 = stock floor)
TOP_HZ=1200000       # floor while the GPU is busy
LOAD_ON=60           # gpu_utilization load %, at or above this counts as busy
HOLD_S=20            # keep TOP_HZ this long after the last busy sample
INTERVAL=2           # loop period in seconds
TEMP_MAX=430         # at or above this battery temperature (deci-degC) release the floor
SYNC_PARAM=1         # keep gpu_cust_boost_freq (module parameter) in sync with the floor
SAMPLE_S=10          # default probe/verify window
num_or() {   # $1 value, $2 fallback -> prints a sane non-negative integer
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
mkdir -p "$D" 2>/dev/null
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
if [ -f "$CONF" ]; then . "$CONF"; fi
GPU_FIX=$(num_or "${GPU_FIX:-0}" 0)   # v11.3 name for the same switch; kept for old configs
[ "$GPU_FIX" = 1 ] && ENABLED=1
ENABLED=$(num_or "$ENABLED" 0)
MIN_HZ=$(num_or "$MIN_HZ" 390000)
TOP_HZ=$(num_or "$TOP_HZ" 1200000)
LOAD_ON=$(num_or "$LOAD_ON" 60)
HOLD_S=$(num_or "$HOLD_S" 20)
INTERVAL=$(num_or "$INTERVAL" 2)
TEMP_MAX=$(num_or "$TEMP_MAX" 430)
SYNC_PARAM=$(num_or "$SYNC_PARAM" 1)
SAMPLE_S=$(num_or "$SAMPLE_S" 10)
case "$MODE" in adaptive|floor|off) ;; *) MODE=adaptive ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1
[ "$LOAD_ON" -le 100 ] || LOAD_ON=100

log()  { echo "$(date +%F_%T) $*" >> "$LOG"; }
say()  { printf '%s\n' "$*"; }
both() { say "$*"; log "$*"; }
node_val() { read -r _v _rest < "$1" 2>/dev/null; printf '%s' "$_v"; }

# --- GPU OPP / node helpers (regression-tested by .github/tests/test_fixes.py) ---
opp_lines() {   # print "index freq" for every published OPP: best source first
  for _t in $TABLES; do
    [ -r "$_t" ] || continue
    _o=$(sed -n -e 's/.*Index: *\([0-9][0-9]*\).*Freq: *\([0-9][0-9]*\).*/\1 \2/p' \
                -e 's/^\[\([0-9][0-9]*\)\].*freq *= *\([0-9][0-9]*\).*/\1 \2/p' "$_t" 2>/dev/null)
    [ -n "$_o" ] && { printf '%s\n' "$_o"; return 0; }
  done
  return 1
}
ladder_stats() {   # sets L_N L_MIN L_MAX L_SLOW (index of the slowest OPP)
  L_N=0; L_MIN=""; L_MAX=""; L_SLOW=""
  _lines=$(opp_lines) || return 1
  [ -n "$_lines" ] || return 1
  while read -r _i _f; do
    case "$_i$_f" in ''|*[!0-9]*) continue;; esac
    L_N=$((L_N + 1))
    if [ -z "$L_MIN" ] || [ "$_f" -lt "$L_MIN" ]; then L_MIN=$_f; L_SLOW=$_i; fi
    if [ -z "$L_MAX" ] || [ "$_f" -gt "$L_MAX" ]; then L_MAX=$_f; fi
  done <<OPPEOF
$_lines
OPPEOF
  [ -n "$L_MIN" ]
}
resolve_opp() {   # $1 = wanted kHz -> sets R_IDX R_FREQ (0 = fastest; else smallest OPP >= wanted)
  R_IDX=""; R_FREQ=""
  _fast_i=""; _fast_f=0
  _lines=$(opp_lines) || return 1
  [ -n "$_lines" ] || return 1
  while read -r _i _f; do
    case "$_i$_f" in ''|*[!0-9]*) continue;; esac
    if [ "$_f" -gt "$_fast_f" ]; then _fast_f=$_f; _fast_i=$_i; fi
    if [ "$1" -gt 0 ] && [ "$_f" -ge "$1" ] && { [ -z "$R_FREQ" ] || [ "$_f" -lt "$R_FREQ" ]; }; then
      R_IDX=$_i; R_FREQ=$_f
    fi
  done <<OPPEOF
$_lines
OPPEOF
  [ -n "$R_FREQ" ] || { R_IDX=$_fast_i; R_FREQ=$_fast_f; }
  [ -n "$R_FREQ" ]
}
# --- end GPU OPP / node helpers ---

# --- adaptive helpers (regression-tested by .github/tests/test_fixes.py) ---
sticky_step() {   # $1 sticky 0/1, $2 load %, $3 now s, $4 last busy s, $5 hold s -> "sticky last_busy"
  case "$1$2$3$4$5" in *[!0-9]*) printf '%s %s\n' "${1:-0}" "${4:-0}"; return 0;; esac
  if [ "$2" -ge "$LOAD_ON" ]; then
    printf '1 %s\n' "$3"
  elif [ "$1" = 1 ] && [ $(( $3 - $4 )) -lt "$5" ]; then
    printf '1 %s\n' "$4"
  else
    printf '0 %s\n' "$4"
  fi
}
pick_target() {   # $1 sticky 0/1 -> wanted floor in kHz
  if [ "$1" = 1 ]; then printf '%s\n' "$TOP_HZ"; else printf '%s\n' "$MIN_HZ"; fi
}
# --- end adaptive helpers ---

is_root() { [ "$(id -u 2>/dev/null)" = 0 ]; }
now_s() { read -r _u _r < /proc/uptime 2>/dev/null; printf '%s' "${_u%%.*}"; }
hot() {   # 0 = too hot to raise the floor
  _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_t" in ''|*[!0-9]*) return 1;; esac
  [ "$_t" -ge "$TEMP_MAX" ]
}
limits() {   # one-line form of the driver's own limiter rows
  [ -r "$STATUS" ] || { printf 'n/a'; return; }
  grep -E '\[GPU-Limit[CF]\]' "$STATUS" 2>/dev/null |
    sed -n -e 's/.*\[GPU-LimitC\].*CeilingIndex: *\([0-9][0-9]*\).*/C=\1/p' \
           -e 's/.*\[GPU-LimitF\].*FloorIndex: *\([0-9][0-9]*\).*/F=\1/p' | tr '\n' ' ' | sed 's/ *$//'
}
write_node() {   # $1 node, $2 value; succeeds only if the readback matches
  [ -w "$1" ] || return 1
  printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
  [ "$(node_val "$1")" = "$2" ]
}
snapshot() {   # keep the pre-change values once; never overwrite a real snapshot
  [ -f "$ORIG" ] && return 0
  {
    printf 'boost_gpu_enable=%s\n' "$(node_val "$P_BOOST")"
    printf 'gpu_cust_boost_freq=%s\n' "$(node_val "$P_CUST")"
    printf 'custom_boost_gpu_freq=%s\n' "$(node_val "$N_BOOST")"
  } > "$ORIG"
  log "snapshot $(tr '\n' ' ' < "$ORIG")"
}
floor_to() {   # $1 = kHz; moves the GED boost floor (index) and optionally the parameter
  # exit codes: 0 = written, 2 = already there, 1 = failed
  resolve_opp "$1" || return 1
  _cur=$(node_val "$N_BOOST")
  if [ "$_cur" = "$R_IDX" ]; then
    if [ "$SYNC_PARAM" != 1 ] || [ "$(node_val "$P_CUST")" = "$R_FREQ" ]; then return 2; fi
  fi
  snapshot
  write_node "$N_BOOST" "$R_IDX" || return 1
  if [ "$SYNC_PARAM" = 1 ]; then write_node "$P_CUST" "$R_FREQ"; fi
  [ "$(node_val "$P_BOOST")" = 1 ] || write_node "$P_BOOST" 1
  return 0
}

status() {
  say "== gpufix status ($(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"
  say "state: enabled=$ENABLED mode=$MODE min=$MIN_HZ top=$TOP_HZ load_on=${LOAD_ON}% hold=${HOLD_S}s every=${INTERVAL}s"
  say "root:  $(is_root && echo yes || echo 'no (read-only)')   config: $( [ -f "$CONF" ] && echo "$CONF" || echo defaults)"
  say "ged:   dvfs=$(cat "$P_DVFS" 2>/dev/null) boost_gpu_enable=$(cat "$P_BOOST" 2>/dev/null) bottom_freq=$(cat "$P_BOTTOM" 2>/dev/null) cust_boost_freq=$(cat "$P_CUST" 2>/dev/null) cust_upbound_freq=$(cat "$P_UPBOUND" 2>/dev/null)"
  say "live:  $(cat "$N_CUR" 2>/dev/null) | util(load block idle): $(cat "$N_UTIL" 2>/dev/null)"
  say "ged:   boost target level=$(node_val "$N_BOOST") levels=$(node_val "$N_LEVELS")"
  say "limit: $(limits)"
  _lvl_load=$(node_val "$N_UTIL")
  if ladder_stats; then
    say "opp:   $L_N levels, $L_MIN..$L_MAX kHz (slowest = index $L_SLOW)"
    _tgt=$(pick_target "$(sticky_step 0 "${_lvl_load:-0}" "$(now_s)" 0 "$HOLD_S" | cut -d' ' -f1)")
    resolve_opp "$_tgt" && say "plan:  load ${_lvl_load:-?}% would ask for level $R_IDX ($R_FREQ kHz)"
  else
    say "opp:   ladder not readable ($TABLES) - apply refused"
  fi
  _dv=$(node_val "$P_DVFS"); _ceiling=$(limits | sed -n 's/.*C=\([0-9]*\).*/\1/p')
  if [ "$_dv" != 1 ]; then
    say "verdict: gpu_dvfs_enable=$_dv - DVFS is off and the GPU is pinned. That is the real fault."
  elif [ -n "$_ceiling" ] && [ "$_ceiling" != 0 ]; then
    say "verdict: a limiter caps the GPU at index $_ceiling (not the fastest OPP)."
  elif [ "$ENABLED" != 1 ]; then
    say "verdict: governor is off (ENABLED=0 in $CONF). The GPU follows GED demand only,"
    say "         which on this kernel means it sits at $L_MIN kHz almost all the time."
  else
    say "verdict: governor on - floor moves to $TOP_HZ kHz while busy, back to $MIN_HZ kHz when idle."
  fi
  [ -f "$ORIG" ] && say "state: nodes were changed (undo: '$ME revert' or reboot)"
  if [ -f "$PIDF" ]; then
    _p=$(cat "$PIDF" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) ;; *) kill -0 "$_p" 2>/dev/null && say "loop:  running (pid $_p)";; esac
  fi
  log "status: enabled=$ENABLED mode=$MODE load=${_lvl_load:-?} dvfs=$_dv"
}

sample() {   # $1 seconds, $2 label; sets S_* and prints the numbers
  _secs=$(num_or "$1" "$SAMPLE_S")
  [ "$_secs" -ge 1 ] || _secs=1
  [ "$_secs" -le 300 ] || _secs=300
  _n=$((_secs * 4)); _step=0.25
  sleep 0.25 2>/dev/null || { _n=$_secs; _step=1; }
  S_MIN=""; S_MAX=""; S_LAST=""; S_LOADMAX=0; S_LOADSUM=0; S_LOADED=0; S_IDLEHI=0; S_CHANGES=0; _i=0
  while [ "$_i" -lt "$_n" ]; do
    read -r _idx _freq _rest < "$N_CUR" 2>/dev/null
    read -r _l _b _id < "$N_UTIL" 2>/dev/null
    case "$_freq" in ''|*[!0-9]*) _freq="";; esac
    _l=$(num_or "$_l" 0)
    if [ -n "$_freq" ]; then
      if [ -z "$S_MIN" ] || [ "$_freq" -lt "$S_MIN" ]; then S_MIN=$_freq; fi
      if [ -z "$S_MAX" ] || [ "$_freq" -gt "$S_MAX" ]; then S_MAX=$_freq; fi
      if [ -n "$S_LAST" ] && [ "$_freq" != "$S_LAST" ]; then S_CHANGES=$((S_CHANGES + 1)); fi
      if [ "$_l" -eq 0 ] && [ -n "$S_MIN" ] && [ "$_freq" -gt "$S_MIN" ]; then S_IDLEHI=$((S_IDLEHI + 1)); fi
      S_LAST=$_freq
    fi
    [ "$_l" -gt "$S_LOADMAX" ] && S_LOADMAX=$_l
    [ "$_l" -gt 0 ] && S_LOADED=$((S_LOADED + 1))
    S_LOADSUM=$((S_LOADSUM + _l))
    _i=$((_i + 1))
    [ "$_i" -lt "$_n" ] && sleep "$_step" 2>/dev/null
  done
  [ -n "$S_MIN" ] || S_MIN=0
  [ -n "$S_MAX" ] || S_MAX=0
  if [ "$_n" -gt 0 ]; then _mean=$((S_LOADSUM / _n)); else _mean=0; fi
  say "== $2: ${_secs}s, $_n samples"
  say "freq:  min $S_MIN  max $S_MAX  last $S_LAST  changes $S_CHANGES kHz"
  say "load:  max ${S_LOADMAX}%  mean ${_mean}%  samples with load>0: $S_LOADED/$_n"
  ladder_stats && say "floor: $L_MIN kHz (ladder index $L_SLOW), ceiling $L_MAX kHz"
  SCALE_OK=""
  if [ "$S_MAX" -eq 0 ]; then
    say "note:  GED nodes not readable - is this a MediaTek device with /sys/kernel/ged?"
  elif [ "$S_CHANGES" -gt 0 ]; then
    SCALE_OK=1
    say "result: the GPU changed frequency $S_CHANGES times ($S_MIN..$S_MAX kHz) - scaling works."
    [ "$S_IDLEHI" -gt 0 ] && say "warn:  it sat above $S_MIN kHz in $S_IDLEHI unloaded samples; a floor may be held too long."
  elif [ -n "$L_MIN" ] && [ "$S_LAST" -le "$L_MIN" ]; then
    if [ "$S_LOADMAX" -ge 50 ]; then
      SCALE_OK=0
      say "result: flat at the $S_LAST kHz floor while load reached ${S_LOADMAX}% - no higher OPP was requested."
    else
      say "result: flat at the $S_LAST kHz floor and the GPU was mostly idle - this window proves nothing."
      say "        Repeat inside a 3D game or benchmark."
    fi
  elif [ -z "$L_MIN" ]; then
    say "note:  the OPP ladder is not readable ($TABLES), so the floor cannot be judged."
  else
    SCALE_OK=1
    say "result: held at $S_LAST kHz for the whole window (above the floor) - demand was met at that step."
    say "        Check idle afterwards: with the governor on it should drop back to $MIN_HZ kHz."
  fi
  if [ "$2" = verify ]; then
    case "$SCALE_OK" in
      1) say "verify: PASS - the GPU is not stuck at its floor." ;;
      0) say "verify: FAIL - still flat at the floor under load; the floor did not take effect." ;;
      *) say "verify: INCONCLUSIVE - no usable samples or no readable ladder." ;;
    esac
  fi
  log "sample/$2: ${_secs}s min=$S_MIN max=$S_MAX last=$S_LAST changes=$S_CHANGES loadmax=$S_LOADMAX verdict=${SCALE_OK:-unknown}"
}

apply() {   # $1 = Hz for the floor, default TOP_HZ
  _want=$(num_or "$1" "$TOP_HZ")
  is_root || { say "apply needs root (su -c '$ME apply')"; return 1; }
  if ! ladder_stats; then
    say "cannot read the GPU OPP ladder ($TABLES). Refusing to guess an OPP index."
    return 1
  fi
  if hot; then
    say "battery is at $(cat /sys/class/power_supply/battery/temp 2>/dev/null) deci-degC (TEMP_MAX=$TEMP_MAX); not applying."
    return 1
  fi
  resolve_opp "$_want" || { say "no OPP resolved for $_want kHz"; return 1; }
  if [ "$R_FREQ" -le "$L_MIN" ]; then
    say "$_want kHz resolves to the $L_MIN kHz floor - nothing to raise. Use a higher value."
    return 1
  fi
  say "floor: level $R_IDX = $R_FREQ kHz (requested $_want, ladder $L_MIN..$L_MAX)"
  floor_to "$_want"
  case $? in
    0) both "floor set to level $R_IDX ($R_FREQ kHz)" ;;
    2) say "floor already at level $R_IDX ($R_FREQ kHz) - nothing written" ;;
    *) say "! could not move the floor (custom_boost_gpu_freq readback $(node_val "$N_BOOST"))"; return 1 ;;
  esac
  say "check:  $ME probe 20   (use the phone normally)"
  say "undo:   $ME revert    (or reboot)"
}

release() {
  is_root || { say "release needs root"; return 1; }
  ladder_stats || { say "ladder not readable"; return 1; }
  resolve_opp "$MIN_HZ" || return 1
  floor_to "$MIN_HZ"
  case $? in
    0) both "floor released to level $R_IDX ($R_FREQ kHz)" ;;
    2) say "floor already at $R_FREQ kHz" ;;
    *) say "! could not release the floor"; return 1 ;;
  esac
}

revert() {
  is_root || { say "revert needs root"; return 1; }
  if [ ! -f "$ORIG" ]; then
    say "no snapshot at $ORIG - this script changed nothing. A reboot also restores the kernel defaults."
    return 1
  fi
  _ok=0; _fail=0
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|\#*) continue;; esac
    case "$_v" in ''|*[!0-9]*) continue;; esac
    case "$_k" in
      boost_gpu_enable) _n=$P_BOOST ;;
      gpu_cust_boost_freq) _n=$P_CUST ;;
      custom_boost_gpu_freq) _n=$N_BOOST ;;
      *) continue ;;
    esac
    if write_node "$_n" "$_v"; then _ok=$((_ok + 1)); both "restored $_k=$_v"
    else _fail=$((_fail + 1)); say "! could not restore $_k=$_v ($_n)"; fi
  done < "$ORIG"
  if [ "$_fail" -eq 0 ]; then
    rm -f "$ORIG"
    say "reverted ($_ok values)."
    log "reverted"
  else
    say "some values did not restore; a reboot will."
  fi
  say "state: boost_gpu_enable=$(node_val "$P_BOOST") custom_boost_gpu_freq=$(node_val "$N_BOOST") gpu_cust_boost_freq=$(node_val "$P_CUST")"
}

run() {   # the adaptive loop
  is_root || { say "run needs root"; return 1; }
  [ -w "$N_BOOST" ] || { say "$N_BOOST is not writable; cannot govern the GPU."; return 1; }
  log "run: mode=$MODE min=$MIN_HZ top=$TOP_HZ load_on=$LOAD_ON hold=$HOLD_S interval=$INTERVAL temp_max=$TEMP_MAX"
  ST=0; LAST=0; CUR_IDX=""; _n=0; _hot_logged=0; _last_floor=""
  while :; do
    if [ $((_n % 15)) -eq 0 ]; then   # re-read the config every ~15 ticks
      [ -f "$CONF" ] && . "$CONF"
      case "$MODE" in adaptive|floor|off) ;; *) MODE=adaptive ;; esac
      MIN_HZ=$(num_or "$MIN_HZ" 390000); TOP_HZ=$(num_or "$TOP_HZ" 1200000)
      LOAD_ON=$(num_or "$LOAD_ON" 60);   HOLD_S=$(num_or "$HOLD_S" 20)
      TEMP_MAX=$(num_or "$TEMP_MAX" 430); INTERVAL=$(num_or "$INTERVAL" 2)
      [ "$INTERVAL" -ge 1 ] || INTERVAL=1
      if [ "$(num_or "${ENABLED:-0}" 0)" != 1 ]; then
        log "run: ENABLED is no longer 1 -> releasing the floor and exiting"
        resolve_opp "$MIN_HZ" && floor_to "$MIN_HZ"
        rm -f "$PIDF"; exit 0
      fi
    fi
    _n=$((_n + 1))
    NW=$(now_s)
    read -r _idx _freq _rest < "$N_CUR" 2>/dev/null
    read -r _l _b _i < "$N_UTIL" 2>/dev/null
    LOAD=$(num_or "$_l" 0)
    REASON=""
    if hot; then
      [ "$_hot_logged" = 1 ] || { log "run: battery hot ($(cat /sys/class/power_supply/battery/temp 2>/dev/null) >= $TEMP_MAX), holding floor at $MIN_HZ"; _hot_logged=1; }
      _res="0 $LAST"; REASON=hot
    else
      _hot_logged=0
      case "$MODE" in
        off)   _res="0 $LAST" ;;
        floor) _res="1 $NW" ;;
        *)     _res=$(sticky_step "$ST" "$LOAD" "$NW" "$LAST" "$HOLD_S") ;;
      esac
    fi
    ST=${_res% *}; LAST=${_res#* }
    case "$ST" in 0|1) ;; *) ST=0 ;; esac
    WANT=$(pick_target "$ST")
    if resolve_opp "$WANT" && [ "$R_IDX" != "$CUR_IDX" ]; then
      floor_to "$WANT"
      case $? in
        0)
          CUR_IDX=$R_IDX
          case "$REASON$ST" in
            hot*) log "run: too hot -> floor $R_FREQ kHz (level $R_IDX)" ;;
            1)    log "run: load ${LOAD}% -> floor $R_FREQ kHz (level $R_IDX), hold ${HOLD_S}s" ;;
            *)    log "run: idle  ${LOAD}% -> floor $R_FREQ kHz (level $R_IDX)" ;;
          esac ;;
        2) CUR_IDX=$R_IDX ;;
      esac
    fi
    sleep "$INTERVAL"
  done
}

boot() {
  [ "$ENABLED" = 1 ] || { log "boot: ENABLED=0, nothing to do"; exit 0; }
  # single instance without depending on the host module's lib.sh
  if [ -f "$PIDF" ]; then
    _o=$(cat "$PIDF" 2>/dev/null)
    case "$_o" in
      ''|*[!0-9]*) ;;
      *) if [ "$_o" != "$$" ] && kill -0 "$_o" 2>/dev/null &&
            grep -q gpufix "/proc/$_o/cmdline" 2>/dev/null; then
           log "boot: already running (pid $_o)"; exit 0
         fi ;;
    esac
  fi
  echo $$ > "$PIDF"
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
  sleep 20
  log "boot: ENABLED=1 mode=$MODE -> starting governor (pid $$)"
  run
  rm -f "$PIDF"
}

case "$1" in
  ''|status) status ;;
  probe) sample "${2:-$SAMPLE_S}" probe ;;
  verify) sample "${2:-$SAMPLE_S}" verify ;;
  apply) apply "$2" ;;
  release) release ;;
  run) run ;;
  revert) revert ;;
  boot) boot ;;
  help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) say "usage: $ME [status|probe [s]|apply [hz]|release|verify [s]|run|revert|boot]"; exit 2 ;;
esac
