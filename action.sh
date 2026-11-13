#!/system/bin/sh
# Magisk module Action button: select the live refresh-rate policy with volume keys.
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
  grep -F -q "$MODDIR/$2.sh" "/proc/$CHECKED_PID/cmdline" 2>/dev/null
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

signal_controller() {
  pid_is_running "$D/.refresh.pid" refresh || return 1
  kill -USR1 "$CHECKED_PID" 2>/dev/null
}

find_key_devices() {
  getevent -lp 2>/dev/null | awk '
    /^add device [0-9]+:/ {
      if (device != "" && (has_volume || has_power)) print device
      device=$4; sub(/:$/, "", device)
      has_volume=0; has_power=0
      next
    }
    /KEY_VOLUMEUP|KEY_VOLUMEDOWN/ { has_volume=1 }
    /KEY_POWER/ { has_power=1 }
    END { if (device != "" && (has_volume || has_power)) print device }
  '
}

next_input_event() {
  if [ -n "$KEY_DEVICES" ]; then
    # Android input device paths contain no spaces; pass only volume/power devices.
    set -- $KEY_DEVICES
    getevent -lc 1 "$@" 2>/dev/null
  else
    getevent -lc 1 2>/dev/null
  fi
}

if [ ! -f "$MODDIR/module.prop" ]; then
  say 'Cannot find this module installation.'
  print_status
  exit 1
fi

say 'X6886 GSI PATCH - refresh-rate mode'
say 'Choose with the hardware volume keys:'
say '  Volume UP   = 144 Hz <-> 120 Hz auto-switch (120 Hz for FOD)'
say '  Volume DOWN = 120 Hz everywhere'
say '  Power       = cancel (if exposed by the device input driver)'
print_status

if [ "$(id -u 2>/dev/null)" != 0 ]; then
  say ''
  say 'ERROR: Magisk did not run this action as root; no setting was changed.'
  exit 1
fi
if ! command -v getevent >/dev/null 2>&1; then
  say ''
  say 'ERROR: getevent is unavailable; use a Magisk action environment with Android input tools.'
  exit 1
fi

KEY_DEVICES=$(find_key_devices)
if [ -z "$KEY_DEVICES" ]; then
  say ''
  say 'Volume-key input device was not identified; listening for volume keys on available input devices.'
fi
say ''
say 'Waiting for Volume UP, Volume DOWN, or Power to cancel...'
CHOICE=""
while [ -z "$CHOICE" ]; do
  _event=$(next_input_event)
  case "$_event" in
    *KEY_VOLUMEUP*DOWN*|*KEY_VOLUMEUP*00000001*|*0001*0073*00000001*) CHOICE=switch ;;
    *KEY_VOLUMEDOWN*DOWN*|*KEY_VOLUMEDOWN*00000001*|*0001*0072*00000001*) CHOICE=120 ;;
    *KEY_POWER*DOWN*|*KEY_POWER*00000001*|*0001*0074*00000001*) CHOICE=cancel ;;
    *) [ -n "$_event" ] || sleep 1 ;;
  esac
done

if [ "$CHOICE" = cancel ]; then
  say ''
  say 'Cancelled; the refresh mode was not changed.'
  print_status
  exit 0
fi

if ! write_mode "$CHOICE"; then
  say ''
  say 'ERROR: could not save the refresh mode under /data/adb/fod.'
  print_status
  exit 1
fi

say ''
if [ "$CHOICE" = switch ]; then
  say 'Saved: 144 Hz normally, with automatic 120 Hz switching for FOD.'
else
  say 'Saved: 120 Hz everywhere.'
fi
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  say 'The module is disabled/removing; this choice will apply when it is enabled again.'
elif signal_controller; then
  say 'Refresh controller notified; the new policy will apply live.'
else
  say 'Mode saved; it will apply when the refresh controller starts.'
fi
# Give the controller a moment to publish its updated policy/observation.
sleep 1
print_status
