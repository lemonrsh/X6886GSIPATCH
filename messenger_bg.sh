#!/system/bin/sh
MODDIR=${0%/*}
# v11.2: package list is configurable in /data/adb/fod/bg.conf (KEEP_PKGS="pkg1 pkg2 ...")
KEEP_PKGS="com.google.android.gms com.facebook.orca"
[ -f /data/adb/fod/bg.conf ] && . /data/adb/fod/bg.conf
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 3
done
for p in $KEEP_PKGS; do
    cmd deviceidle whitelist +$p >/dev/null 2>&1
    appops set $p RUN_IN_BACKGROUND allow
    appops set $p RUN_ANY_IN_BACKGROUND allow
done
