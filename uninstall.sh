#!/system/bin/sh
# v10.4 uninstall: restore display HBM only; do not touch battery sysfs nodes.
echo 0 > /sys/kernel/tran_display/lcm_hbm_state 2>/dev/null
# v11.2: undo the framework refresh-rate pin (best effort; if the settings service is not up yet, reset
# Smooth Display in Settings or run: settings delete system min_refresh_rate; settings delete system peak_refresh_rate)
settings delete system min_refresh_rate >/dev/null 2>&1
settings delete system peak_refresh_rate >/dev/null 2>&1
exit 0
