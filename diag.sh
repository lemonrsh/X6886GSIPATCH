#!/system/bin/sh
# Run as root while FOD, refresh-rate, or UI lag problems are happening:
#   su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh' > /sdcard/diag_v10.txt
D=/data/adb/fod
echo "== $(date) =="; grep -E '^version=' /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/module.prop
echo "== fppress=$(getprop sys.phh.oplus.fppress) dpms=$(cat /sys/class/drm/card0-DSI-1/dpms 2>/dev/null)"
echo "== gesture_function: $(cat /proc/gesture_function 2>/dev/null)  fts_gesture_mode: $(cat /sys/devices/platform/soc/11010000.spi1/spi_master/spi1/spi1.0/fts_gesture_mode 2>/dev/null)"
echo "== PSI"; for r in cpu io memory; do echo "$r: $(cat /proc/pressure/$r 2>/dev/null | tr '\n' ' ')"; done
echo "== dex2oat: $(pidof dex2oat dex2oat64 dex2oat32 odrefresh 2>/dev/null)"
echo "== top threads"; top -H -b -n 1 -m 15 2>/dev/null | head -25
echo "== module processes"; ps -A -o PID,NI,TIME,ARGS 2>/dev/null | grep -E 'getevent|logcat|fod_service|sofod|perf_tweaks|refresh.sh|dlfix|dramlock' | grep -v grep
echo "== wakefulness: $(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)"
echo "== touch node: $(for p in /sys/class/input/event*; do echo "${p##*/}=$(cat $p/device/name 2>/dev/null)"; done | tr '\n' ' ')"
echo "== refresh user=$(cmd activity get-current-user 2>/dev/null) min=$(settings --user current get system min_refresh_rate 2>/dev/null) peak=$(settings --user current get system peak_refresh_rate 2>/dev/null)"
echo "== refresh ACK (boot ID / requested Hz / HBM token / SOFOD token): $(cat "$D/.refresh_applied" 2>/dev/null)"
echo "== fingerprint session lease: $(cat "$D/.refresh_session" 2>/dev/null)"
echo "== animation scales: window=$(settings get global window_animation_scale 2>/dev/null) transition=$(settings get global transition_animation_scale 2>/dev/null) animator=$(settings get global animator_duration_scale 2>/dev/null)"
echo "== battery: capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
echo "== DRAM"; sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/dramlock.sh status 2>/dev/null
echo "== refresh timing (144 Hz normal / 120 Hz FOD)"; grep -E "start|modes:|Hz requested|unavailable|retaining" "$D/refresh.log" 2>/dev/null | tail -12
for l in refresh dlfix dram sofod_touch hbm gsi safe hal; do echo "== $l.log (last 25)"; tail -n 25 $D/$l.log 2>/dev/null; done

# bundle: sh diag.sh bundle  -> /sdcard/x6886_diag.tar.gz (all logs + this report) to paste/share in one go
if [ "$1" = bundle ]; then
  sh "$0" > $D/diag_report.txt 2>&1
  tar czf /sdcard/x6886_diag.tar.gz -C $D . 2>/dev/null && echo "bundle: /sdcard/x6886_diag.tar.gz"
fi
