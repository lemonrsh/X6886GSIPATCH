#!/system/bin/sh
# Run as root while FOD, refresh-rate, or UI lag problems are happening:
#   su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh' > /sdcard/diag_v10.txt
D=/data/adb/fod
MODDIR=${0%/*}
refresh_report() {
  echo "== refresh report $(date) =="
  grep -E '^version=' "$MODDIR/module.prop"
  for part in refresh_supervisor refresh; do
    p=""; [ -r "$D/.$part.pid" ] && read -r p < "$D/.$part.pid"
    running=no
    case "$p" in ''|*[!0-9]*) ;; *)
      if [ "$p" -gt 1 ] && kill -0 "$p" 2>/dev/null &&
         grep -F -q "$MODDIR/$part.sh" "/proc/$p/cmdline" 2>/dev/null; then running=yes; fi ;;
    esac
    echo "$part: running=$running pid=${p:--}"
  done
  echo "== last controller observation"; cat "$D/.refresh_runtime" 2>/dev/null
  echo "== verified ACK (boot / Hz / HBM token / SOFOD token)"; cat "$D/.refresh_applied" 2>/dev/null
  echo "== session (boot / expiry_cs / auth / touch / epoch / sequence / event / up_cs)"
  cat "$D/.refresh_session" 2>/dev/null
  echo "== power (boot / up_cs / state / epoch / sequence) / epoch"
  cat "$D/.refresh_power" "$D/.refresh_epoch" 2>/dev/null
  echo "== helper holds (boot / expiry_cs / token)"
  cat "$D/.refresh_hold.hbm" "$D/.refresh_hold.sofod" 2>/dev/null
  echo "== fppress=$(getprop sys.phh.oplus.fppress) user=$(cmd activity get-current-user 2>/dev/null)"
  echo "== min=$(settings --user current get system min_refresh_rate 2>/dev/null) peak=$(settings --user current get system peak_refresh_rate 2>/dev/null)"
  echo "== last SurfaceFlinger request/reply"; cat "$D/refresh_last_reply.txt" 2>/dev/null
  for name in refresh refresh_supervisor refresh_errors; do
    echo "== $name.log (last 30)"; tail -n 30 "$D/$name.log" 2>/dev/null
  done
  echo "== current SurfaceFlinger display state"
  dumpsys -t 2 SurfaceFlinger --displays 2>/dev/null
}
# Copy/paste-friendly targeted diagnostics; no archive or app/process dump needed.
if [ "$1" = refresh ]; then refresh_report; exit 0; fi
echo "== $(date) =="; grep -E '^version=' /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/module.prop
echo "== fppress=$(getprop sys.phh.oplus.fppress) dpms=$(cat /sys/class/drm/card0-DSI-1/dpms 2>/dev/null)"
echo "== gesture_function: $(cat /proc/gesture_function 2>/dev/null)  fts_gesture_mode: $(cat /sys/devices/platform/soc/11010000.spi1/spi_master/spi1/spi1.0/fts_gesture_mode 2>/dev/null)"
echo "== PSI"; for r in cpu io memory; do echo "$r: $(cat /proc/pressure/$r 2>/dev/null | tr '\n' ' ')"; done
echo "== dex2oat: $(pidof dex2oat dex2oat64 dex2oat32 odrefresh 2>/dev/null)"
echo "== top threads"; top -H -b -n 1 -m 15 2>/dev/null | head -25
echo "== module processes"; ps -A -o PID,NI,TIME,ARGS 2>/dev/null | grep -E 'getevent|logcat|fod_service|sofod|perf_tweaks|refresh.sh|refresh_supervisor|dlfix|dramlock' | grep -v grep
echo "== wakefulness: $(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)"
echo "== touch node: $(for p in /sys/class/input/event*; do echo "${p##*/}=$(cat $p/device/name 2>/dev/null)"; done | tr '\n' ' ')"
echo "== refresh user=$(cmd activity get-current-user 2>/dev/null) min=$(settings --user current get system min_refresh_rate 2>/dev/null) peak=$(settings --user current get system peak_refresh_rate 2>/dev/null)"
echo "== refresh ACK (boot ID / verified Hz / HBM token / SOFOD token): $(cat "$D/.refresh_applied" 2>/dev/null)"
echo "== fingerprint session lease: $(cat "$D/.refresh_session" 2>/dev/null)"
echo "== animation scales: window=$(settings get global window_animation_scale 2>/dev/null) transition=$(settings get global transition_animation_scale 2>/dev/null) animator=$(settings get global animator_duration_scale 2>/dev/null)"
echo "== battery: capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
echo "== DRAM"; sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/dramlock.sh status 2>/dev/null
echo "== refresh timing (144 Hz normal / 120 Hz FOD)"; grep -E "start|modes:|Hz verified|NOT verified|unavailable|retaining|exit|restarted" "$D/refresh.log" 2>/dev/null | tail -12
for l in refresh refresh_supervisor refresh_errors dlfix dram sofod_touch hbm gsi safe hal; do echo "== $l.log (last 25)"; tail -n 25 $D/$l.log 2>/dev/null; done

echo "== refresh runtime"; cat "$D/.refresh_runtime" "$D/refresh_last_reply.txt" 2>/dev/null

# bundle: sh diag.sh bundle  -> /sdcard/x6886_diag.tar.gz (all logs + this report) to paste/share in one go
if [ "$1" = bundle ]; then
  sh "$0" > $D/diag_report.txt 2>&1
  tar czf /sdcard/x6886_diag.tar.gz -C $D . 2>/dev/null && echo "bundle: /sdcard/x6886_diag.tar.gz"
fi
