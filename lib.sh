# X6886 shared helpers (sourced by the module scripts)
# single_instance NAME: exit this script if another copy of NAME.sh is already running
single_instance() {
  _pf=/data/adb/fod/.$1.pid
  mkdir -p /data/adb/fod
  if [ -r "$_pf" ]; then
    _o=$(cat "$_pf" 2>/dev/null)
    case "$_o" in
      ''|*[!0-9]*) ;;
      *) [ "$_o" != "$$" ] && grep -q "$1" "/proc/$_o/cmdline" 2>/dev/null && exit 0 ;;
    esac
  fi
  echo $$ > "$_pf"
}
