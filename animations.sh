#!/system/bin/sh
# Android's three framework animation scales, globally (all Android users).
MODDIR=${0%/*}
D=/data/adb/fod
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh" && single_instance animations
. "$MODDIR/settings_state.sh"
mkdir -p "$D"
trap 'rm -f "$D/.animations.pid"; exit 0' INT TERM
until [ "$(getprop sys.boot_completed)" = 1 ]; do
  [ -f "$D/.ui_stopping" ] && exit 0
  sleep 2
done
while [ ! -f "$D/.ui_stopping" ]; do
  OK=1
  for key in window_animation_scale transition_animation_scale animator_duration_scale; do
    module_setting_set global 0 "$key" 0.4 || OK=0
  done
  # Retry a not-yet-ready settings provider; otherwise reconcile slowly, without
  # per-frame/per-touch work. Apps with their own animation engine may ignore this.
  if [ "$OK" = 1 ]; then sleep 60; else sleep 5; fi
done
rm -f "$D/.animations.pid"
