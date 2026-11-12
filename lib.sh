# X6886 shared helpers (sourced by the module scripts)
# single_instance NAME: exit this script if another live copy of NAME.sh is running.
# The PID file is advisory; /proc liveness + cmdline checks avoid stale-PID lockouts.
single_instance() {
  _pf=/data/adb/fod/.$1.pid
  mkdir -p /data/adb/fod
  if [ -r "$_pf" ]; then
    _o=$(cat "$_pf" 2>/dev/null)
    case "$_o" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$_o" != "$$" ] && [ "$_o" -gt 1 ] && kill -0 "$_o" 2>/dev/null &&
           grep -q "$1" "/proc/$_o/cmdline" 2>/dev/null; then
          exit 0
        fi
        ;;
    esac
  fi
  echo $$ > "$_pf"
}

# --- process identity helpers (host-tested in test_low_cpu.py) ---
# Read Linux's start-time field without a pidof/ps scan. A start-time stamp also
# detects PID reuse; never compare the large tick counter using 32-bit arithmetic.
process_stamp() {
  PROC_STAMP=""
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  _ps_line=""
  { IFS= read -r _ps_line < "/proc/$1/stat"; } 2>/dev/null || return 1
  case "$_ps_line" in "$1 ("*") "*) ;; *) return 1 ;; esac
  _ps_tail=${_ps_line##*) }
  _ps_had_f=0; case $- in *f*) _ps_had_f=1 ;; *) set -f ;; esac
  set -- $_ps_tail
  [ "$_ps_had_f" = 1 ] || set +f
  [ "$#" -ge 20 ] || return 1
  case "$1" in Z|X|x) return 1 ;; esac
  shift 19
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  PROC_STAMP=$1
}
process_unchanged() {   # PID, previously saved start time
  _pu_saved=$2
  [ -n "$_pu_saved" ] && process_stamp "$1" && [ "$PROC_STAMP" = "$_pu_saved" ]
}
# --- end process identity helpers ---
