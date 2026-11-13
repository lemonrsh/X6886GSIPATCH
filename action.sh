#!/system/bin/sh
# Magisk module Action button: toggle or explicitly select the refresh policy.
MODDIR=${0%/*}
DATA=${FODDATA:-/data/adb}
D=$DATA/fod
MODE_FILE=$D/refresh_mode
umask 022

say() { printf '%s\n' "$*"; }

read_mode() {
  CURRENT_MODE=switch
  if [ -r "$MODE_FILE" ]; then
    _saved_mode=""
    IFS= read -r _saved_mode < "$MODE_FILE"
    case "$_saved_mode" in switch|120) CURRENT_MODE=$_saved_mode ;; esac
  fi
  case "$CURRENT_MODE" in
    switch) MODE_LABEL='144 Hz <-> 120 Hz auto-switch (144 normally, 120 for FOD)' ;;
    120) MODE_LABEL='120 Hz everywhere' ;;
  esac
}

pid_is_running() {   # PID file, script basename; leaves checked PID in CHECKED_PID
  CHECKED_PID=""
  [ -r "$1" ] || return 1
  IFS= read -r CHECKED_PID < "$1" || return 1
  case "$CHECKED_PID" in ''|*[!0-9]*) CHECKED_PID=""; return 1 ;; esac
  [ "$CHECKED_PID" -gt 1 ] || return 1
  kill -0 "$CHECKED_PID" 2>/dev/null || return 1
  [ -r "/proc/$CHECKED_PID/cmdline" ] || return 1
  # Match by script basename: Magisk can expose the same module through a
  # modules/ or modules_update/ path, while the PID files are stable in /data/adb.
  grep -F -q "$2.sh" "/proc/$CHECKED_PID/cmdline" 2>/dev/null
}

read_runtime() {
  RT_PID=-; RT_POLICY=-; RT_TARGET=-; RT_VERIFIED=-; RT_PHYSICAL=-; RT_RENDER=-
  if [ -r "$D/.refresh_runtime" ]; then
    _runtime_line=""
    IFS= read -r _runtime_line < "$D/.refresh_runtime"
    for _runtime_field in $_runtime_line; do
      case "$_runtime_field" in
        pid=*) RT_PID=${_runtime_field#pid=} ;;
        policy=*) RT_POLICY=${_runtime_field#policy=} ;;
        target=*) RT_TARGET=${_runtime_field#target=} ;;
        verified=*) RT_VERIFIED=${_runtime_field#verified=} ;;
        physical_hz=*) RT_PHYSICAL=${_runtime_field#physical_hz=} ;;
        render_hz=*) RT_RENDER=${_runtime_field#render_hz=} ;;
      esac
    done
  fi
}

print_status() {
  read_mode
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    MODULE_ENABLED=no
  else
    MODULE_ENABLED=yes
  fi
  if pid_is_running "$D/.refresh_supervisor.pid" refresh_supervisor; then
    SUPERVISOR_RUNNING=yes; SUPERVISOR_PID=$CHECKED_PID
  else
    SUPERVISOR_RUNNING=no; SUPERVISOR_PID=-
  fi
  if pid_is_running "$D/.refresh.pid" refresh; then
    CONTROLLER_RUNNING=yes; CONTROLLER_PID=$CHECKED_PID
  else
    CONTROLLER_RUNNING=no; CONTROLLER_PID=-
  fi

  case "$MODULE_ENABLED:$SUPERVISOR_RUNNING:$CONTROLLER_RUNNING" in
    no:*:*) MODULE_STATUS='NOT WORKING (module disabled or being removed)' ;;
    yes:yes:yes) MODULE_STATUS='WORKING (supervisor and refresh controller are running)' ;;
    yes:yes:no) MODULE_STATUS='NOT WORKING (supervisor is waiting for/restarting the controller)' ;;
    yes:no:yes) MODULE_STATUS='PARTIAL (controller runs, but its supervisor is missing)' ;;
    *) MODULE_STATUS='NOT WORKING (refresh supervisor/controller not running)' ;;
  esac
  read_runtime

  say ""
  say "--- X6886 GSI PATCH status ---"
  say "Module enabled: $MODULE_ENABLED"
  say "Refresh mode: $MODE_LABEL"
  say "Refresh supervisor: $SUPERVISOR_RUNNING (pid $SUPERVISOR_PID)"
  say "Refresh controller: $CONTROLLER_RUNNING (pid $CONTROLLER_PID)"
  if [ "$RT_PID" != - ] && [ "$RT_PID" = "$CONTROLLER_PID" ]; then
    say "Last controller observation: policy=${RT_POLICY}, target=${RT_TARGET} Hz, verified=${RT_VERIFIED} Hz, physical=${RT_PHYSICAL} Hz, render=${RT_RENDER} Hz"
  else
    say "Last display observation: unavailable or from an earlier controller run"
  fi
  say "Module status: $MODULE_STATUS"
}

write_mode() {
  case "$1" in switch|120) ;; *) return 1 ;; esac
  mkdir -p "$D" 2>/dev/null || return 1
  _mode_tmp=$MODE_FILE.tmp.$$
  if ! printf '%s\n' "$1" > "$_mode_tmp"; then
    rm -f "$_mode_tmp"
    return 1
  fi
  chmod 0644 "$_mode_tmp" 2>/dev/null || true
  if ! mv -f "$_mode_tmp" "$MODE_FILE"; then
    rm -f "$_mode_tmp"
    return 1
  fi
}

is_verified_snapshot() {
  case "$RT_TARGET" in 120|144) ;; *) return 1 ;; esac
  [ "$RT_VERIFIED" = "$RT_TARGET" ] && [ "$RT_PHYSICAL" = "$RT_TARGET" ] &&
    { [ "$RT_RENDER" = - ] || [ "$RT_RENDER" = "$RT_TARGET" ]; }
}

wait_for_mode() {   # policy; up to four seconds for a fresh verified observation
  _wait_count=0
  while [ "$_wait_count" -lt 20 ]; do
    if pid_is_running "$D/.refresh.pid" refresh; then
      _wait_pid=$CHECKED_PID
      read_runtime
      if [ "$RT_PID" = "$_wait_pid" ] && [ "$RT_POLICY" = "$1" ] && is_verified_snapshot; then
        return 0
      fi
    fi
    sleep 0.2
    _wait_count=$((_wait_count+1))
  done
  return 1
}

start_refresh_controller() {   # recover if boot hooks did not leave a live controller
  pid_is_running "$D/.refresh.pid" refresh && return 0
  [ -f "$MODDIR/refresh_supervisor.sh" ] || return 1
  mkdir -p "$D" 2>/dev/null || return 1
  if ! pid_is_running "$D/.refresh_supervisor.pid" refresh_supervisor; then
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$MODDIR/refresh_supervisor.sh" >> "$D/refresh_errors.log" 2>&1 </dev/null &
    else
      sh "$MODDIR/refresh_supervisor.sh" >> "$D/refresh_errors.log" 2>&1 </dev/null &
    fi
  fi
  _start_count=0
  while [ "$_start_count" -lt 25 ]; do
    pid_is_running "$D/.refresh.pid" refresh && return 0
    sleep 0.2
    _start_count=$((_start_count+1))
  done
  return 1
}

print_startup_errors() {
  if [ -s "$D/refresh_errors.log" ]; then
    say 'Recent refresh startup log:'
    tail -n 8 "$D/refresh_errors.log" 2>/dev/null
  fi
}

if [ ! -f "$MODDIR/module.prop" ]; then
  say 'ERROR: cannot find this module installation.'
  exit 1
fi
if [ "$(id -u 2>/dev/null)" != 0 ]; then
  say 'ERROR: Magisk did not run this action as root; no setting was changed.'
  print_status
  exit 1
fi

read_mode
case "${1:-toggle}" in
  toggle)
    if [ "$CURRENT_MODE" = switch ]; then TARGET_MODE=120; else TARGET_MODE=switch; fi
    ;;
  switch|auto) TARGET_MODE=switch ;;
  120|fixed|fixed120) TARGET_MODE=120 ;;
  status) print_status; exit 0 ;;
  *)
    say 'Usage: action.sh [toggle|switch|120|status]'
    print_status
    exit 2
    ;;
esac

if ! write_mode "$TARGET_MODE"; then
  say 'ERROR: could not save the refresh mode under /data/adb/fod.'
  print_status
  exit 1
fi

read_mode
say "Refresh policy changed to: $MODE_LABEL"
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  say 'The module is disabled/removing; the saved policy will apply when enabled again.'
elif start_refresh_controller; then
  pid_is_running "$D/.refresh.pid" refresh && kill -USR1 "$CHECKED_PID" 2>/dev/null || true
  say 'Refresh controller is running; waiting for its display observation...'
  if wait_for_mode "$TARGET_MODE"; then
    read_runtime
    say "APPLIED: policy=$RT_POLICY, target=$RT_TARGET Hz, verified=$RT_VERIFIED Hz, physical=$RT_PHYSICAL Hz, render=$RT_RENDER Hz."
  else
    say 'PENDING: policy was saved, but the controller has not verified the display mode yet.'
    say 'Check the panel/ROM mode table and refresh.log if this persists.'
    print_startup_errors
  fi
else
  say 'SAVED, NOT APPLIED: could not start the refresh controller. Check module files and startup log.'
  print_startup_errors
fi
print_status
