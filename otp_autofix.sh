#!/system/bin/sh
# KernelSU service script: run after Android services have started.
LOG="/data/adb/ksu_otp_fix.log"
PKG="com.google.android.gms"

sleep 30

UID_NUM="$(/system/bin/cmd package list packages -U "$PKG" 2>/dev/null \
    | /system/bin/sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' \
    | /system/bin/head -n 1)"

if [ -z "$UID_NUM" ]; then
    UID_NUM="$(/system/bin/pm list packages -U 2>/dev/null \
        | /system/bin/grep "$PKG " \
        | /system/bin/sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' \
        | /system/bin/head -n 1)"
fi

if [ -z "$UID_NUM" ]; then
    echo "$(date): Google Play services UID not found" >> "$LOG"
    exit 1
fi

RESULT="$(/system/bin/cmd appops set "$UID_NUM" READ_OTP_SMS allow 2>&1)"
RC=$?
echo "$(date): UID=$UID_NUM; appops exit=$RC; output=$RESULT" >> "$LOG"
exit "$RC"
