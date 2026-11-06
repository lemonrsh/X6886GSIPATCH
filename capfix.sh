#!/system/bin/sh
# v10.4 SAFETY: battery sysfs scaling has been disabled permanently.
# Do not bind-mount, write, or otherwise alter kernel battery nodes.
D=/data/adb/fod
mkdir -p "$D"
echo "$(date '+%m-%d %T') v10.4: CAP_FIX disabled; native battery/Health HAL values untouched" >> "$D/capfix.log"
exit 0
