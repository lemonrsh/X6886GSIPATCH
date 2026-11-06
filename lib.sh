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
