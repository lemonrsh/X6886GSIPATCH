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
# scales by demand - it is a floor, not a fixed frequency.
#
# TOPPING OUT THE GPU FOR THE WHOLE SYSTEM:  TOP_HZ=0 means "the fastest OPP this
# driver publishes" (index 0, 1600 MHz here). Combined with MODE=floor the floor never
# leaves the top of the ladder, for every app and every screen state. Use the preset:
#     gpufix.sh preset max      # floor AND ceiling = 1600 MHz always (pinned)
#     gpufix.sh preset boost    # 390 idle -> 1200 busy (default)
#     gpufix.sh preset stock    # release everything (stock behaviour)
# Above TEMP_MAX battery temperature the floor drops to HOT_HZ (default MIN_HZ) until
# the phone cools, so a hot game session cannot sit at the ceiling indefinitely.
#
# THE LADDER MAY BE UNREADABLE: on some GSI/vendor combinations /proc/gpufreqv2 is
# denied to the shell even as root (the vendor power HAL keeps its own label). Index 0
# is the driver's own name for the fastest OPP and 0 is also what custom_upbound_gpu_freq
# wants, so 'preset max' still works: it writes index 0 to the floor and ceiling nodes and
# marks itself OFFLINE in the log. OFFLINE mode cannot tell 390 from 1600 by reading the
# ladder, so the thermal brake writes index TOP_INDEX (default 44 = slowest OPP, which is
# what the floor is at idle anyway) - override TOP_INDEX if your ladder differs.
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
#   preset NAME       stock | boost | max - writes the config and applies at once
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
N_UPBOUND=$GED/custom_upbound_gpu_freq
N_LEVELS=$GED/total_gpu_freq_level_count
P_DVFS=$P/gpu_dvfs_enable
P_BOOST=$P/boost_gpu_enable
P_CUST=$P/gpu_cust_boost_freq
P_BOTTOM=$P/gpu_bottom_freq
P_UPBOUND=$P/gpu_cust_upbound_freq
LADDER_OK=""        # "" = not probed yet, 1 = readable, 0 = denied to us (OFFLINE mode)

# Defaults; /data/adb/fod/gpu.conf may override them (validated below).
ENABLED=0            # 1 = start the adaptive governor at boot
MODE=adaptive        # adaptive | floor (always TOP_HZ) | off (always MIN_HZ)
MIN_HZ=390000        # floor while idle (390000 = stock floor)
TOP_HZ=1200000       # floor while the GPU is busy
LOAD_ON=60           # gpu_utilization load %, at or above this counts as busy
HOLD_S=20            # keep TOP_HZ this long after the last busy sample
INTERVAL=2           # loop period in seconds
TEMP_MAX=430         # at or above this battery temperature (deci-degC) release the floor
HOT_HZ=0             # floor while too hot; 0 = use MIN_HZ (e.g. 900000 to stay warm-but-fast)
CEIL_HZ=1600000      # GED upper bound to publish: kHz, or 0 for the fastest OPP
TOP_INDEX=44         # ladder index of the slowest OPP; used only when the ladder is unreadable
SYNC_PARAM=1         # keep gpu_cust_boost_freq (module parameter) in sync with the floor
SAMPLE_S=10          # default probe/verify window
num_or() {   # $1 value, $2 fallback -> prints a sane non-negative integer
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
num_req() {  # $1 value, $2 default -> an empty or invalid value becomes $2 (CEIL_HZ may be 0)
  case "$1" in
    '') printf '%s' "$2" ;;
    *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
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
HOT_HZ=$(num_or "$HOT_HZ" 0)
TOP_INDEX=$(num_or "$TOP_INDEX" 44)
CEIL_HZ=$(num_req "$CEIL_HZ" 1600000)    # 0 = top OPP; empty is not allowed for the ceiling
SYNC_PARAM=$(num_or "$SYNC_PARAM" 1)
SAMPLE_S=$(num_or "$SAMPLE_S" 10)
case "$MODE" in adaptive|floor|off) ;; *) MODE=adaptive ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1
[ "$LOAD_ON" -le 100 ] || LOAD_ON=100

log()  { echo "$(date +%F_%T) $*" >> "$LOG"; }
say()  { printf '%s\n' "$*"; }
both() { say "$*"; log "$*"; }
node_val() { read -r _v _rest 2>/dev/null < "$1"; printf '%s' "$_v"; }

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
offline_top() {   # no ladder: index 0 is the driver's name for the fastest OPP
  R_IDX=0; R_FREQ=0
  return 0
}
offline_index() {   # $1 = kHz -> index via the shell-only fallback; sets R_IDX R_FREQ
  case "$1" in
    ''|0) offline_top; return 0 ;;
  esac
  if [ -n "$L_MIN" ] && [ -n "$L_MAX" ] && [ -n "$L_SLOW" ] && [ "$1" -ge "$L_MAX" ]; then
    offline_top; return 0
  fi
  if [ -n "$L_MIN" ] && [ -n "$L_SLOW" ] && [ "$1" -le "$L_MIN" ]; then
    R_IDX=$L_SLOW; R_FREQ=$L_MIN; return 0
  fi
  return 1            # anything in between needs the real ladder
}
ladder_available() {   # remember once whether the kernel ladder can be read at all
  if [ -z "$LADDER_OK" ]; then
    if opp_lines >/dev/null 2>&1; then LADDER_OK=1; else LADDER_OK=0; fi
  fi
  [ "$LADDER_OK" = 1 ]
}
# --- end GPU OPP / node helpers ---

# --- preset helpers (regression-tested by .github/tests/test_fixes.py) ---
preset_values() {   # $1 preset -> "mode top_hz load_on hold_s interval ceil"; ceil 0 = top OPP
  # The ceiling is expressed as the ladder-agnostic 0 ("fastest OPP"), so a maxed preset
  # works even where /proc/gpufreqv2 is denied to us. "" leaves the ceiling alone.
  case "$1" in
    stock) printf '%s\n' "off 390000 60 0 2 " ;;
    boost) printf '%s\n' "adaptive 1200000 60 20 1 " ;;
    max)   printf '%s\n' "floor 0 60 20 1 0" ;;
    *) return 1 ;;
  esac
}
setkey() {   # $1 file, $2 key, $3 value - replace in place or append; keeps other keys
  [ -f "$1" ] || : > "$1"
  if grep -q "^$2=" "$1" 2>/dev/null; then
    sed "s|^$2=.*|$2=$3|" "$1" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}
# --- end preset helpers ---

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
# --- plan helper (regression-tested by .github/tests/test_fixes.py) ---
plan_now() {   # prints "want_hz reason" for the current instant (MODE and heat respected)
  if hot; then
    if [ "$HOT_HZ" -gt 0 ]; then printf '%s hot\n' "$HOT_HZ"; else printf '%s hot\n' "$MIN_HZ"; fi
    return 0
  fi
  case "$MODE" in
    off)   printf '%s released\n' "$MIN_HZ" ;;
    floor) printf '%s floor\n' "$TOP_HZ" ;;
    *)     _l=$(num_or "$(node_val "$N_UTIL")" 0)
           if [ "$_l" -ge "$LOAD_ON" ]; then printf '%s busy\n' "$TOP_HZ"
           else printf '%s idle\n' "$MIN_HZ"; fi ;;
  esac
}
# --- end plan helper ---
now_s() { read -r _u _r 2>/dev/null < /proc/uptime; printf '%s' "${_u%%.*}"; }
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
    printf 'custom_upbound_gpu_freq=%s\n' "$(node_val "$N_UPBOUND")"
    printf 'gpu_cust_upbound_freq=%s\n' "$(node_val "$P_UPBOUND")"
  } > "$ORIG"
  log "snapshot $(tr '\n' ' ' < "$ORIG")"
}
hz_text() {   # $1 = kHz, "" -> human wording; 0 means "the top OPP" on this kernel
  case "$1" in
    0) printf 'the top OPP' ;;
    '') printf 'unknown' ;;
    *) printf '%s kHz' "$1" ;;
  esac
}
floor_freq() {   # prints the kHz of the OPP currently written to custom_boost_gpu_freq
  _fi=$(node_val "$N_BOOST")
  [ -n "$_fi" ] || return 1
  opp_lines | while read -r _i _f; do [ "$_i" = "$_fi" ] && { printf '%s\n' "$_f"; break; }; done
}
floor_to() {   # $1 = kHz; moves the GED boost floor (index) and optionally the parameter
  # exit codes: 0 = written, 2 = already there, 1 = failed
  if ! ladder_available; then
    offline_index "$1" || return 1
  elif ! resolve_opp "$1"; then
    return 1
  fi
  _cur=$(node_val "$N_BOOST")
  if [ "$_cur" = "$R_IDX" ]; then
    if [ "$SYNC_PARAM" != 1 ] || [ "$(node_val "$P_CUST")" = "$R_FREQ" ]; then return 2; fi
  fi
  snapshot
  write_node "$N_BOOST" "$R_IDX" || return 1
  if [ "$SYNC_PARAM" = 1 ] && [ -n "$R_FREQ" ] && [ "$R_FREQ" != 0 ]; then write_node "$P_CUST" "$R_FREQ"; fi
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
    _pw=$(plan_now)
    _pt=${_pw% *}; _pr=${_pw#* }
    if resolve_opp "$_pt"; then
      say "plan:  load ${_lvl_load:-?}% / mode $MODE / ${_pr} -> level $R_IDX ($(hz_text "$R_FREQ"))"
      [ "$R_FREQ" -ge "$L_MAX" ] && say "pin:   floor = ceiling = $R_FREQ kHz; the GPU cannot scale down on its own."
    fi
    _ff=$(floor_freq)
    [ -n "$_ff" ] && say "asked: level $(node_val "$N_BOOST") = $_ff kHz (module floor)"
  else
    say "opp:   ladder not readable ($TABLES) - middle-of-ladder writes unavailable"
    say "       (top-OPP/slowest-OPP writes still work: preset max / preset stock)"
  fi
  _dv=$(node_val "$P_DVFS"); _ceiling=$(limits | sed -n 's/.*C=\([0-9]*\).*/\1/p')
  _ub=$(node_val "$P_UPBOUND"); _ubi=$(node_val "$N_UPBOUND")
  [ "$_ubi" = 0 ] && [ -z "$L_MAX" ] && _ub=""   # offline: the kHz behind index 0 is unknown
  if [ -n "$_ub" ] && [ "$_ubi" = 0 ]; then
    say "ceil:  upper bound hal index 0 = the top OPP is allowed"
  elif [ -n "$_ub" ]; then
    if [ -n "$L_MAX" ] && [ "$_ub" = "$L_MAX" ]; then
      say "ceil:  upper bound $(hz_text "$_ub") (hal index $_ubi) - the top OPP is allowed"
    else
      say "ceil:  upper bound $(hz_text "$_ub") (hal index $_ubi) - GED will not go above this"
    fi
  elif [ -n "$_ubi" ]; then
    say "ceil:  upper bound hal index $_ubi"
  fi
  if [ -n "$LADDER_OK" ] && [ "$LADDER_OK" = 0 ]; then
    say "mode:  OFFLINE - /proc/gpufreqv2 is not readable to this shell, so only top-OPP"
    say "       and slowest-OPP writes are possible; preset max still works (index 0)."
  fi
  if [ "$_dv" != 1 ]; then
    say "verdict: gpu_dvfs_enable=$_dv - DVFS is off and the GPU is pinned. That is the real fault."
  elif [ -n "$_ceiling" ] && [ "$_ceiling" != 0 ]; then
    say "verdict: a limiter caps the GPU at index $_ceiling (not the fastest OPP)."
  elif [ "$ENABLED" != 1 ]; then
    say "verdict: governor is off (ENABLED=0 in $CONF). The GPU follows GED demand only,"
    say "         which on this kernel means it sits at $L_MIN kHz almost all the time."
  elif [ "$MODE" = floor ]; then
    say "verdict: governor on, MODE=floor - the floor stays at $(hz_text "$TOP_HZ")."
    say "         ceiling target: $(hz_text "$CEIL_HZ")."
    if [ -n "$_ub" ] && { [ "$_ubi" != 0 ] && [ "$_ub" != "$L_MAX" ]; }; then
      say "         BUT the live upper bound is $_ub kHz (hal index $_ubi): until that is the top"
      say "         OPP, GED will not go above it. Run 'preset max' to set it."
    fi
  else
    say "verdict: governor on - floor moves to $(hz_text "$TOP_HZ") while busy, back to $(hz_text "$MIN_HZ") when idle."
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
    read -r _idx _freq _rest 2>/dev/null < "$N_CUR"
    read -r _l _b _id 2>/dev/null < "$N_UTIL"
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
  FLOORF=""; _fni=""; _uni=""
  if ! ladder_available; then
    say "note:  the OPP ladder is not readable to this shell; judging by the nodes instead."
  fi
  if [ "$2" = verify ]; then   # one read can catch a mid-write - read again before judging
    _fni=$(node_val "$N_BOOST"); _uni=$(node_val "$N_UPBOUND")
  fi
  if ladder_stats; then
    say "floor: $L_MIN kHz (ladder index $L_SLOW), ceiling $L_MAX kHz"
    FLOORF=$(floor_freq)
    [ -n "$FLOORF" ] && say "asked: level $(node_val "$N_BOOST") = $(hz_text "$FLOORF") (by this module)"
  fi
  SCALE_OK=""
  if [ "$S_MAX" -eq 0 ]; then
    say "note:  GED nodes not readable - is this a MediaTek device with /sys/kernel/ged?"
  elif [ "$S_CHANGES" -gt 0 ]; then
    SCALE_OK=1
    say "result: the GPU changed frequency $S_CHANGES times ($S_MIN..$S_MAX kHz) - scaling works."
    [ "$S_IDLEHI" -gt 0 ] && say "warn:  it sat above $S_MIN kHz in $S_IDLEHI unloaded samples; a floor may be held too long."
  elif [ -n "$L_MAX" ] && [ "$S_LAST" -ge "$L_MAX" ]; then
    SCALE_OK=1
    say "result: held at the ceiling ($S_LAST kHz) - the floor is at the top OPP, nothing scales higher."
  elif [ -n "$FLOORF" ] && [ -n "$L_MIN" ] && [ "$FLOORF" -gt "$L_MIN" ] && [ "$S_LAST" -le "$L_MIN" ]; then
    SCALE_OK=0
    say "result: the floor was asked to be $FLOORF kHz, yet the clock stayed at $S_LAST kHz."
    say "        Something outside these nodes holds it (limiter, thermal or vendor power HAL)."
  elif [ -n "$L_MIN" ] && [ "$S_LAST" -le "$L_MIN" ]; then
    if [ "$S_LOADMAX" -ge 50 ]; then
      SCALE_OK=0
      say "result: flat at the $S_LAST kHz floor while load reached ${S_LOADMAX}% - no higher OPP was requested."
      say "        Raise the floor: $ME preset boost (or max), then verify again."
    else
      say "result: flat at the $S_LAST kHz floor and the GPU was mostly idle - this window proves nothing."
      say "        Repeat inside a 3D game or benchmark."
    fi
  elif [ -z "$L_MIN" ]; then
    _fl=$_fni; _ub=$_uni
    case "$_fl" in 0|'') ;; *) _fl=$(node_val "$N_BOOST") ;; esac
    case "$_ub" in 0|'') ;; *) _ub=$(node_val "$N_UPBOUND") ;; esac
    if [ "$_fl" = 0 ] && [ "$_ub" = 0 ]; then
      SCALE_OK=1
      say "result: floor and ceiling are both index 0, so a flat $S_LAST kHz is a pin at the top OPP."
    elif [ "$_fl" = 0 ]; then
      SCALE_OK=1
      say "result: floor is index 0 (top OPP); ceiling index $_ub. Flat $S_LAST kHz is the pin."
    else
      say "note:  floor index $_fl / ceiling index $_ub - without the ladder these cannot be"
      say "       translated to kHz. Raw nodes are in 'gpufix.sh status'."
    fi
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

preset() {   # $1 = stock | boost | max
  _vals=$(preset_values "$1") || {
    say "usage: $ME preset [stock|boost|max]"
    say "  stock  release the floor, stock behaviour"
    say "  boost  follow load: 390 idle -> 1200 busy (default)"
    say "  max    floor at the fastest OPP (1600 MHz) all the time, whole system"
    return 2
  }
  _name=$1
  set -- $_vals
  MODE=$1; TOP_HZ=$2; LOAD_ON=$3; HOLD_S=$4; INTERVAL=$5; _ceil=$6; ENABLED=1
  setkey "$CONF" ENABLED 1
  setkey "$CONF" MODE "$MODE"
  setkey "$CONF" TOP_HZ "$TOP_HZ"
  setkey "$CONF" LOAD_ON "$LOAD_ON"
  setkey "$CONF" HOLD_S "$HOLD_S"
  setkey "$CONF" INTERVAL "$INTERVAL"
  [ -n "$_ceil" ] && setkey "$CONF" CEIL_HZ "$_ceil"
  : > "$D/.gpufix.reload"   # a running governor must pick this up before we touch the node
  both "preset $_name: MODE=$MODE TOP_HZ=$TOP_HZ LOAD_ON=$LOAD_ON HOLD_S=$HOLD_S INTERVAL=$INTERVAL"
  case "$MODE" in off) _want=$MIN_HZ ;; *) _want=$TOP_HZ ;; esac
  if ! is_root; then
    say "saved. Needs root to change the nodes now; it applies at the next tick or boot."
    return 0
  fi
  if ladder_available; then
    resolve_opp "$_want" || return 1
    _lvl="$R_IDX ($R_FREQ kHz)"
  else
    # Index 0 is the driver's own name for the fastest OPP, so a maxed preset still works
    # when /proc/gpufreqv2 is denied to us. Only the in-between steps need the ladder.
    case "$_name" in
      max) R_IDX=0; R_FREQ=0; _lvl="0 (top OPP)" ;;
      *)   say "the OPP ladder is not readable here (denied to this shell context), and this"
           say "preset needs a frequency in the middle of the ladder. Nothing was written."
           say "Use 'preset max' (index 0 = fastest OPP) or 'preset stock' on this build."
           return 1 ;;
    esac
  fi
  if [ "$MODE" = floor ]; then
    say "note: floor = the top OPP. Battery drain rises; above $TEMP_MAX deci-degC"
    say "      the floor drops to $([ "$HOT_HZ" -gt 0 ] && echo "$HOT_HZ" || echo "$MIN_HZ") kHz until it cools."
  elif [ "$MODE" = off ] && [ -z "$_ceil" ]; then
    say "note: the floor is released; the GED upper bound is left where it is."
    say "      A reboot (or '$ME revert') restores the stock ceiling too."
  fi
  floor_to "$_want"
  case $? in
    0) both "floor now level $_lvl" ;;
    2) say "floor already level $_lvl" ;;
    *) say "! could not move the floor (custom_boost_gpu_freq reads $(node_val "$N_BOOST"))"; return 1 ;;
  esac
  if [ "$MODE" = floor ]; then
    CEIL_HZ=$_ceil          # 0 = top OPP, which is what 'preset max' means
    ceil_to "$_ceil"
    case $? in
      0) both "ceiling now level $R_IDX ($(hz_text "$R_FREQ"))" ;;
      2) say "ceiling already level $R_IDX ($(hz_text "$R_FREQ"))" ;;
      *) say "! could not move the ceiling (custom_upbound_gpu_freq reads $(node_val "$N_UPBOUND"))" ;;
    esac
  fi
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
  if [ "$_want" -gt 0 ] && [ "$R_FREQ" -le "$L_MIN" ]; then
    say "$_want kHz resolves to the $L_MIN kHz floor - nothing to raise. Use a higher value,"
    say "or 0 for the fastest OPP ($L_MAX kHz)."
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

ceil_to() {   # publishes GED's upper bound: index on the hal node, kHz on the parameter
  # $1 = kHz; 0 = fastest OPP.
  [ -n "$CEIL_HZ" ] || { say "ceiling control disabled (CEIL_HZ empty)"; return 2; }
  _want=$1; _want=$(num_or "$_want" "")        # 0 stays 0: index 0 is the fastest OPP
  if ! ladder_available; then
    case "$_want" in
      0) R_IDX=0; R_FREQ=0 ;;
      '') say "! CEIL_HZ is not a number"; return 1 ;;
      *)  say "! the ladder is unreadable here, so only a top OPP (CEIL_HZ=0) can be set"
          return 1 ;;
    esac
  else
    resolve_opp "$_want" || return 1
  fi
  _cur=$(node_val "$N_UPBOUND")
  if [ "$_cur" = "$R_IDX" ] && [ "$(node_val "$P_UPBOUND")" = "$R_FREQ" ]; then
    return 2
  fi
  snapshot
  write_node "$N_UPBOUND" "$R_IDX" || return 1
  # Only publish a frequency we actually know; offline we do not, and writing 0 kHz there
  # would just be noise in the reported value. The hal index is what GED enforces.
  [ -n "$R_FREQ" ] && [ "$R_FREQ" != 0 ] && write_node "$P_UPBOUND" "$R_FREQ" 2>/dev/null
  return 0
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
      custom_upbound_gpu_freq) _n=$N_UPBOUND ;;
      gpu_cust_upbound_freq) _n=$P_UPBOUND ;;
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
  say "       custom_upbound_gpu_freq=$(node_val "$N_UPBOUND") gpu_cust_upbound_freq=$(node_val "$P_UPBOUND")"
}

run() {   # the adaptive loop
  is_root || { say "run needs root"; return 1; }
  [ -w "$N_BOOST" ] || { say "$N_BOOST is not writable; cannot govern the GPU."; return 1; }
  log "run: mode=$MODE min=$MIN_HZ top=$TOP_HZ load_on=$LOAD_ON hold=$HOLD_S interval=$INTERVAL temp_max=$TEMP_MAX"
  ST=0; LAST=0; _n=0; _hot_logged=0; _last_floor=""
  while :; do
    # Re-read the config every ~15 ticks, or at once when `preset` asked for it -
    # otherwise a running loop would keep its old MODE/TOP_HZ and undo the preset.
    if [ $((_n % 15)) -eq 0 ] || [ -f "$D/.gpufix.reload" ]; then
      rm -f "$D/.gpufix.reload"
      [ -f "$CONF" ] && . "$CONF"
      ST=0; LAST=0   # a new MODE starts fresh; do not inherit a "busy" hold from the old one
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
    read -r _idx _freq _rest 2>/dev/null < "$N_CUR"
    read -r _l _b _i 2>/dev/null < "$N_UTIL"
    LOAD=$(num_or "$_l" 0)
    REASON=""; _hot_new=0
    if hot; then
      if [ "$_hot_logged" != 1 ]; then
        _hot_new=1; _hot_logged=1
        log "run: battery hot ($(cat /sys/class/power_supply/battery/temp 2>/dev/null) >= $TEMP_MAX), floor -> $([ "$HOT_HZ" -gt 0 ] && echo "$HOT_HZ" || echo "$MIN_HZ") kHz"
      fi
      _res="0 $LAST"; REASON=hot
    else
      _hot_logged=0
      case "$MODE" in
        off)   _res="0 $LAST"; REASON=off ;;
        floor) _res="1 $NW"; REASON=mode ;;
        *)     _res=$(sticky_step "$ST" "$LOAD" "$NW" "$LAST" "$HOLD_S") ;;
      esac
    fi
    ST=${_res% *}; LAST=${_res#* }
    case "$ST" in 0|1) ;; *) ST=0 ;; esac
    if [ "$REASON" = hot ] && [ "$HOT_HZ" -gt 0 ]; then
      WANT=$HOT_HZ
    else
      WANT=$(pick_target "$ST")
    fi
    # Offline mode (ladder denied to us): use the shell-only index rules. The thermal
    # brake writes TOP_INDEX (44 on MT6789 = slowest OPP = the idle floor) because we
    # cannot name a mid-ladder index there - with a readable ladder HOT_HZ works fully.
    if ! ladder_available; then
      if [ "$REASON" = hot ]; then
        WANT=; R_IDX=$TOP_INDEX; R_FREQ=$MIN_HZ
      elif offline_index "$WANT"; then : ; else R_IDX=""; fi
      if [ -n "$R_IDX" ] && { [ "$(node_val "$N_BOOST")" != "$R_IDX" ]; }; then
        snapshot
        if write_node "$N_BOOST" "$R_IDX" &&
           { [ "$SYNC_PARAM" != 1 ] || [ -z "$R_FREQ" ] || [ "$R_FREQ" = 0 ] || write_node "$P_CUST" "$R_FREQ"; }; then
          log "run(offline): floor -> level $R_IDX (${R_FREQ:-top OPP} kHz), reason ${REASON:-busy}"
        else
          [ $((_n % 60)) -eq 0 ] && log "run(offline): could not set level $R_IDX; node reads $(node_val "$N_BOOST")"
        fi
      fi
      [ -n "$CEIL_HZ" ] && [ $((_n % 15)) -eq 0 ] && ceil_to "$CEIL_HZ" >/dev/null 2>&1
      sleep "$INTERVAL"
      continue
    fi
    # Always go through floor_to(): it re-reads the node, so a vendor power HAL that
    # rewrites custom_boost_gpu_freq gets corrected on the next tick (exit 2 = no write).
    if resolve_opp "$WANT"; then
      floor_to "$WANT"
      _rc=$?
      if [ "$_rc" = 0 ]; then
        case "$REASON$ST" in
          hot*) [ "$_hot_new" = 1 ] || log "run: too hot -> floor $R_FREQ kHz (level $R_IDX)" ;;
          mode*) log "run: mode=floor -> floor $R_FREQ kHz (level $R_IDX)" ;;
          1) log "run: load ${LOAD}% -> floor $R_FREQ kHz (level $R_IDX), hold ${HOLD_S}s" ;;
          *) log "run: idle ${LOAD}% -> floor $R_FREQ kHz (level $R_IDX)" ;;
        esac
      elif [ $((_n % 60)) -eq 0 ]; then
        log "run: could not set level $R_IDX ($R_FREQ kHz); node reads $(node_val "$N_BOOST")"
      fi
    fi
    [ -n "$CEIL_HZ" ] && [ $((_n % 15)) -eq 0 ] && ceil_to "$CEIL_HZ" >/dev/null 2>&1
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
  preset) shift; preset "$1" ;;
  release) release ;;
  run) run ;;
  revert) revert ;;
  boot) boot ;;
  help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) say "usage: $ME [status|probe [s]|apply [hz]|release|preset stock|boost|max|verify [s]|run|revert|boot]"; exit 2 ;;
esac
