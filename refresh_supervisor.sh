#!/system/bin/sh
# Keep the refresh controller alive after an early-boot exit. Both Magisk hooks
# launch this single supervisor; it attaches to an existing controller if needed.
MODDIR=${0%/*}
D=/data/adb/fod
mkdir -p "$D"
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance refresh_supervisor
LOG=$D/refresh_supervisor.log
ERRORS=$D/refresh_errors.log
for file in "$LOG" "$ERRORS"; do
  [ -f "$file" ] && [ "$(wc -c < "$file" 2>/dev/null || echo 0)" -gt 60000 ] && mv -f "$file" "$file.old"
done
log() { echo "$(date +%T) $*" >> "$LOG"; }
controller_pid() {
  _cp=""
  [ -r "$D/.refresh.pid" ] && read -r _cp < "$D/.refresh.pid"
  case "$_cp" in ''|*[!0-9]*) return ;; esac
  if [ "$_cp" -gt 1 ] && kill -0 "$_cp" 2>/dev/null &&
     grep -F -q "$MODDIR/refresh.sh" "/proc/$_cp/cmdline" 2>/dev/null; then echo "$_cp"; fi
}
should_run() {
  [ -d "$MODDIR" ] && [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] && [ ! -f "$D/.ui_stopping" ]
}
cleanup() {
  trap - EXIT
  _end=$(controller_pid)
  [ -n "$_end" ] && kill "$_end" 2>/dev/null
  rm -f "$D/.refresh_supervisor.pid"
}
trap 'exit 0' INT TERM
trap cleanup EXIT
log "supervisor start pid $$"
while should_run; do
  p=$(controller_pid)
  if [ -n "$p" ]; then
    while should_run && kill -0 "$p" 2>/dev/null; do sleep 1; done
    should_run && log "controller pid $p disappeared; restarting"
  else
    sh "$MODDIR/refresh.sh" >> "$ERRORS" 2>&1 &
    child=$!
    wait "$child"; result=$?
    should_run && log "controller pid $child exit=$result; restarting"
  fi
  should_run || break
  sleep 1
done
