#!/system/bin/sh
# X6886 GPU DVFS helper (v11.3). Read-only unless you explicitly ask it to change something.
#
# What the kernel side of this device actually says (MT6789 / GED / gpufreqv2):
#   * gpu_dvfs_enable=1            -> dynamic scaling is ON, the driver is not pinned.
#   * [GPU-LimitC] CeilingIndex: 0 -> no active limiter; the fastest OPP is allowed.
#   * [GPU-LimitF] FloorIndex: 44  -> only the usual "never below 390 MHz" floor.
#   * boost_gpu_enable=0 and gpu_cust_boost_freq=390000 -> GED's boost path is a no-op:
#     even when boost fires, its target is the slowest OPP, i.e. the frequency the GPU
#     is already at. ged_boost_enable=1 on its own therefore changes nothing.
# So "stuck at 390 MHz" is not a fault by itself - the GPU is only ever asked for 390.
# Whether that is a problem depends on the load; `probe` measures it instead of guessing.
#
# This script never locks the GPU to a fixed frequency. It gives GED a boost target so a
# real 3D workload can ramp up fast, and it leaves DVFS enabled so idle still drops back.
#
# Modes:
#   status (default)   read-only report and verdict, nothing is written
#   probe [SECONDS]    sample current_freqency / gpu_utilization and say whether the GPU
#                      ever left its floor (run it while actually scrolling or playing)
#   apply              guarded write of the boost target (refuses unless GPU_FIX=1)
#   verify [SECONDS]   same sampling as probe, worded as PASS/FAIL after an apply
#   revert             restore the values saved by apply (a reboot does the same)
#   boot               what service.sh calls; does nothing unless GPU_FIX=1
#
# Config: /data/adb/fod/gpu.conf   Snapshot: /data/adb/fod/gpu.orig   Log: /data/adb/fod/gpu.log
# Every value this script writes is a module parameter or a GED node, so plain rebooting
# restores the kernel defaults even if revert is never run.
MODDIR=${0%/*}
ME="sh $MODDIR/gpufix.sh"
D=/data/adb/fod
CONF=$D/gpu.conf
ORIG=$D/gpu.orig
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

# Defaults; /data/adb/fod/gpu.conf may override them (values are validated below).
GPU_FIX=0            # 1 = apply the boost target at boot
BOOST_FREQ=900000    # boost target in kHz (0 = fastest OPP the driver publishes)
BOOST_ENABLE=1       # also set boost_gpu_enable=1
SYNC_PARAM=1         # keep gpu_cust_boost_freq (module parameter) in sync with the target
TEMP_MAX=430         # never apply at or above this battery temperature (deci-degC)
SAMPLE_S=10          # default probe/verify window
REASSERT_S=0         # >0 = re-check the boost nodes every N s (some vendor power HALs rewrite them)
mkdir -p "$D" 2>/dev/null
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$LOG" "$LOG.old"
if [ -f "$CONF" ]; then . "$CONF"; fi
num_or() {   # $1 value, $2 fallback -> prints a sane non-negative integer
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
GPU_FIX=$(num_or "$GPU_FIX" 0)
BOOST_FREQ=$(num_or "$BOOST_FREQ" 900000)
BOOST_ENABLE=$(num_or "$BOOST_ENABLE" 1)
SYNC_PARAM=$(num_or "$SYNC_PARAM" 1)
TEMP_MAX=$(num_or "$TEMP_MAX" 430)
SAMPLE_S=$(num_or "$SAMPLE_S" 10)
REASSERT_S=$(num_or "$REASSERT_S" 0)

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

is_root() { [ "$(id -u 2>/dev/null)" = 0 ]; }
hot() {   # 0 = too hot to touch GPU settings
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
snapshot() {   # keep the pre-apply values once; never overwrite a real snapshot
  [ -f "$ORIG" ] && return 0
  {
    printf 'boost_gpu_enable=%s\n' "$(node_val "$P_BOOST")"
    printf 'gpu_cust_boost_freq=%s\n' "$(node_val "$P_CUST")"
    printf 'custom_boost_gpu_freq=%s\n' "$(node_val "$N_BOOST")"
  } > "$ORIG"
  log "snapshot $(tr '\n' ' ' < "$ORIG")"
}

status() {
  say "== gpufix status ($(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"
  say "root:  $(is_root && echo yes || echo 'no (read-only)')   config: $( [ -f "$CONF" ] && echo "$CONF" || echo defaults)"
  say "ged:   dvfs=$(cat "$P_DVFS" 2>/dev/null) boost_gpu_enable=$(cat "$P_BOOST" 2>/dev/null) ged_boost_enable=$(cat "$P/ged_boost_enable" 2>/dev/null) smart_boost=$(cat "$P/ged_smart_boost" 2>/dev/null)"
  say "ged:   bottom_freq=$(cat "$P_BOTTOM" 2>/dev/null) cust_boost_freq=$(cat "$P_CUST" 2>/dev/null) cust_upbound_freq=$(cat "$P_UPBOUND" 2>/dev/null)"
  say "live:  $(cat "$N_CUR" 2>/dev/null) | util(load block idle): $(cat "$N_UTIL" 2>/dev/null)"
  say "ged:   boost target level=$(node_val "$N_BOOST") levels=$(node_val "$N_LEVELS")"
  say "limit: $(limits)"
  if ladder_stats; then
    say "opp:   $L_N levels, $L_MIN..$L_MAX kHz (slowest = index $L_SLOW)"
    _cur_i=$(node_val "$N_CUR")
    if [ -n "$_cur_i" ]; then
      _cur_f=$(opp_lines | while read -r _i _f; do [ "$_i" = "$_cur_i" ] && { printf '%s' "$_f"; break; }; done)
      [ -n "$_cur_f" ] && say "now:   index $_cur_i = ${_cur_f} kHz"
    fi
  else
    say "opp:   ladder not readable ($TABLES) - apply is disabled"
  fi

  _dv=$(node_val "$P_DVFS")
  _ceiling=$(limits | sed -n 's/.*C=\([0-9]*\).*/\1/p')
  _boost_on=$(node_val "$P_BOOST")
  _lvl=$(node_val "$N_BOOST")
  if [ "$_dv" != 1 ]; then
    say "verdict: gpu_dvfs_enable=$_dv - DVFS is off and the GPU is pinned. That is the real fault."
  elif [ -n "$_ceiling" ] && [ "$_ceiling" != 0 ]; then
    say "verdict: a limiter caps the GPU at index $_ceiling (not the fastest OPP)."
  elif [ "$_boost_on" = 0 ] && [ -n "$L_SLOW" ] && [ "$_lvl" = "$L_SLOW" ]; then
    say "verdict: boost path inert (boost_gpu_enable=0, target = slowest OPP $L_MIN kHz)."
    say "         Nothing is broken; the GPU follows demand only. Run '$ME probe 20' while"
    say "         scrolling or playing to see whether demand ever asks for more."
    say "         Faster ramp-up without giving up idle: GPU_FIX=1 in $CONF, then '$ME apply'."
  else
    say "verdict: boost target level $_lvl is in use (boost_gpu_enable=$_boost_on)."
  fi
  [ -f "$ORIG" ] && say "state: applied by gpufix (undo: '$ME revert' or reboot)"
  log "status: dvfs=$_dv boost=$_boost_on level=$_lvl"
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
  # verdict: SCALE_OK 1 = the GPU moved (or held above the floor); 0 = stuck at the floor; "" = unknown
  SCALE_OK=""
  if [ "$S_MAX" -eq 0 ]; then
    say "note:  GED nodes not readable - is this a MediaTek device with /sys/kernel/ged?"
  elif [ "$S_CHANGES" -gt 0 ]; then
    SCALE_OK=1
    say "result: the GPU changed frequency $S_CHANGES times ($S_MIN..$S_MAX kHz) - scaling works."
    [ "$S_IDLEHI" -gt 0 ] && say "warn:  it sat above $S_MIN kHz in $S_IDLEHI unloaded samples; a boost floor may be too high."
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
    say "        Check idle afterwards: the clock should drop back to $L_MIN kHz."
  fi
  if [ "$2" = verify ]; then
    case "$SCALE_OK" in
      1) say "verify: PASS - the GPU is not stuck at its floor." ;;
      0) say "verify: FAIL - still flat at the floor under load; the boost target did not take effect." ;;
      *) say "verify: INCONCLUSIVE - no usable samples or no readable ladder." ;;
    esac
  fi
  log "sample/$2: ${_secs}s min=$S_MIN max=$S_MAX last=$S_LAST changes=$S_CHANGES loadmax=$S_LOADMAX verdict=${SCALE_OK:-unknown}"
}

apply() {
  is_root || { say "apply needs root (su -c '$ME apply')"; return 1; }
  if ! ladder_stats; then
    say "cannot read the GPU OPP ladder ($TABLES). Refusing to guess an OPP index."
    return 1
  fi
  if ! resolve_opp "$BOOST_FREQ"; then
    say "no OPP resolved for BOOST_FREQ=$BOOST_FREQ"
    return 1
  fi
  if hot; then
    say "battery is at $(cat /sys/class/power_supply/battery/temp 2>/dev/null) deci-degC (TEMP_MAX=$TEMP_MAX); not applying."
    return 1
  fi
  if [ "$R_FREQ" -le "$L_MIN" ]; then
    say "BOOST_FREQ=$BOOST_FREQ resolves to the $L_MIN kHz floor - that is what the GPU already uses."
    say "Nothing to apply. Set a higher BOOST_FREQ in $CONF."
    return 1
  fi
  say "target: level $R_IDX = $R_FREQ kHz (requested $BOOST_FREQ, ladder $L_MIN..$L_MAX)"
  [ "$R_FREQ" -ge "$L_MAX" ] && say "note: BOOST_FREQ is at or above the fastest OPP, so this is a full-speed request."
  snapshot
  if ! write_node "$N_BOOST" "$R_IDX"; then
    say "! could not set $N_BOOST to $R_IDX (readback $(node_val "$N_BOOST"))"
    return 1
  fi
  both "set custom_boost_gpu_freq -> level $R_IDX ($R_FREQ kHz)"
  if [ "$SYNC_PARAM" = 1 ]; then
    if write_node "$P_CUST" "$R_FREQ"; then both "set gpu_cust_boost_freq -> $R_FREQ"
    else say "! could not set $P_CUST (harmless, the GED node above is the one that counts)"; fi
  fi
  if [ "$BOOST_ENABLE" = 1 ]; then
    if write_node "$P_BOOST" 1; then both "set boost_gpu_enable -> 1"
    else say "! could not set $P_BOOST; the target above stays inert"; return 1; fi
  fi
  say "applied. Verify with real load:"
  say "  $ME probe 30     (scroll or play while it runs)"
  say "  $ME revert       (or reboot - these nodes are module parameters)"
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

reassert() {   # rewrite the boost target only if something else changed it
  ladder_stats || return 1
  resolve_opp "$BOOST_FREQ" || return 1
  [ "$R_FREQ" -le "$L_MIN" ] && return 1
  _now_lvl=$(node_val "$N_BOOST")
  _now_on=$(node_val "$P_BOOST")
  if [ "$_now_lvl" = "$R_IDX" ] && { [ "$BOOST_ENABLE" != 1 ] || [ "$_now_on" = 1 ]; }; then
    return 0
  fi
  if write_node "$N_BOOST" "$R_IDX"; then
    log "reassert: custom_boost_gpu_freq was $_now_lvl, set back to $R_IDX ($R_FREQ kHz)"
    [ "$SYNC_PARAM" = 1 ] && [ "$(node_val "$P_CUST")" != "$R_FREQ" ] && write_node "$P_CUST" "$R_FREQ"
    return 0
  fi
  return 1
}

boot() {
  [ "$GPU_FIX" = 1 ] || { log "boot: GPU_FIX=0, nothing to do"; exit 0; }
  [ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance gpufix
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
  sleep 20
  log "boot: GPU_FIX=1 -> apply (REASSERT_S=$REASSERT_S)"
  apply >> "$LOG" 2>&1
  [ "$REASSERT_S" -ge 30 ] || return 0
  while sleep "$REASSERT_S"; do
    hot || reassert
  done
}

case "$1" in
  ''|status) status ;;
  probe) sample "${2:-$SAMPLE_S}" probe ;;
  verify) sample "${2:-$SAMPLE_S}" verify ;;
  apply) apply ;;
  revert) revert ;;
  boot) boot ;;
  help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) say "usage: $ME [status|probe [s]|apply|verify [s]|revert|boot]"; exit 2 ;;
esac
