# Reversible screenshot defaults. State files contain data, NEVER shell code.
# MODDIR and D are supplied by the caller; overrides are used by the deferred uninstaller.
rom_prop_valid() {
  case "$1" in
    persist.sys.phh.disable_audio_effects|persist.sys.phh.disable_fast_audio|persist.sys.phh.touch_hint|\
    persist.sys.phh.mtk_ged_kpi|persist.sys.phh.enable_sf_gl_backpressure|persist.sys.phh.enable_sf_hwc_backpressure|\
    persist.sys.phh.sf_disable_backpressure|persist.sys.phh.sf_latch_unsignaled|persist.sys.phh.sf_auto_latch_unsignaled|\
    persist.sys.phh.disable_voice_call_in|persist.sys.phh.patch_smsc|persist.sys.phh.securize|\
    persist.sys.activity_anim_perf_override|persist.sys.phh.status_bar_padding_start|persist.sys.phh.status_bar_padding_end|\
    persist.sys.overlay.devinputjack|persist.sys.phh.lmk_tweaks|persist.sys.phh.dynamic_fps|persist.sys.overlay.aod|\
    persist.sys.phh.disable_display_doze_suspend|qemu.hw.mainkeys|persist.sys.phh.low_gamma_brightness|\
    persist.sys.phh.linear_brightness|persist.sys.phh.disable_buttons_light|persist.sys.phh.backlight.scale|\
    persist.sys.bt.le.disable_apcf_extended_features|persist.sys.phh.allow_binder_thread_on_incoming_calls|\
    persist.sys.phh.force_display_5g|persist.sys.phh.restart_ril|persist.sys.phh.xiaomi.dt2w|\
    persist.sys.phh.wifi_disable_sae|persist.sys.phh.force_sw_codecs|persist.sys.phh.virtual_sensors_are_real) return 0 ;;
    *) return 1 ;;
  esac
}
rom_prop_value() { case "$1" in *[!a-zA-Z0-9_.:-]*) return 1 ;; *) return 0 ;; esac; }
rom_prop_set() {   # name value; only claim a write after verifying it
  rom_prop_valid "$1" && rom_prop_value "$2" && [ -n "$2" ] || return 1
  _rps_base=$D/phh.prop.$1
  _rps_cur=$(getprop "$1" 2>/dev/null) || return 1
  rom_prop_value "$_rps_cur" || return 1
  if [ ! -f "$_rps_base.orig" ]; then
    printf '%s\n' "$_rps_cur" > "$_rps_base.orig.tmp.$$" &&
      mv -f "$_rps_base.orig.tmp.$$" "$_rps_base.orig" || return 1
  fi
  if [ "$_rps_cur" != "$2" ]; then setprop "$1" "$2" 2>/dev/null || return 1; fi
  [ "$(getprop "$1" 2>/dev/null)" = "$2" ] || return 1
  printf '%s\n' "$2" > "$_rps_base.last.tmp.$$" && mv -f "$_rps_base.last.tmp.$$" "$_rps_base.last"
}
rom_props_apply() {
  _rpa_handler=${ROM_PHH_HANDLER:-/system/bin/phh-prop-handler.sh}
  [ -f "$_rpa_handler" ] || return 0
  while IFS='|' read -r _rpa_type _rpa_key _rpa_value _rpa_prop _rpa_pvalue; do
    case "$_rpa_type" in boolean|string) ;; *) continue ;; esac
    rom_prop_valid "$_rpa_prop" || continue
    # Old PHH Securize removes root. Never call that action or synthesize its preference.
    if [ "$_rpa_prop" = persist.sys.phh.securize ]; then
      grep -F -q persist.sys.phh.securize "$_rpa_handler" 2>/dev/null || continue
    fi
    rom_prop_set "$_rpa_prop" "$_rpa_pvalue" || echo "property skipped: $_rpa_prop" >> "$D/rom-defaults.log"
  done < "${ROM_TABLE:-$MODDIR/phh-defaults.conf}"
}
rom_props_restore() {
  for _rpr_orig in "$D"/phh.prop.*.orig; do
    [ -f "$_rpr_orig" ] || continue
    _rpr_key=${_rpr_orig##*/phh.prop.}; _rpr_key=${_rpr_key%.orig}
    rom_prop_valid "$_rpr_key" || continue
    _rpr_value=; IFS= read -r _rpr_value < "$_rpr_orig"
    rom_prop_value "$_rpr_value" || continue
    _rpr_base=${_rpr_orig%.orig}; _rpr_last=
    if [ ! -r "$_rpr_base.last" ]; then rm -f "$_rpr_orig"; continue; fi
    IFS= read -r _rpr_last < "$_rpr_base.last"
    _rpr_cur=$(getprop "$_rpr_key" 2>/dev/null) || continue
    rom_prop_value "$_rpr_cur" || continue
    if [ "$_rpr_cur" = "$_rpr_last" ]; then
      setprop "$_rpr_key" "$_rpr_value" 2>/dev/null || continue
      if [ -z "$_rpr_value" ]; then
        # Clear BOTH persistent storage and the live property; otherwise it returns next boot.
        command -v resetprop >/dev/null 2>&1 || continue
        case "$_rpr_key" in persist.*) resetprop -p --delete "$_rpr_key" 2>/dev/null || continue ;; esac
        resetprop --delete "$_rpr_key" 2>/dev/null || continue
      fi
      [ "$(getprop "$_rpr_key" 2>/dev/null)" = "$_rpr_value" ] || continue
    fi
    rm -f "$_rpr_orig" "$_rpr_base.last"
  done
}
rom_java() {
  [ -f "${ROM_DEX:-$MODDIR/rom-defaults.dex}" ] || return 1
  CLASSPATH=${ROM_DEX:-$MODDIR/rom-defaults.dex} timeout 25 app_process /system/bin X6886RomDefaults \
    "$D" "${ROM_TABLE:-$MODDIR/phh-defaults.conf}" "$1" &
  _rj_pid=$!
  printf '%s\n' "$_rj_pid" > "$D/.rom_defaults_java.pid"
  wait "$_rj_pid"
  _rj_rc=$?
  _rj_saved=; [ -r "$D/.rom_defaults_java.pid" ] && read -r _rj_saved < "$D/.rom_defaults_java.pid"
  [ "$_rj_saved" != "$_rj_pid" ] || rm -f "$D/.rom_defaults_java.pid"
  return "$_rj_rc"
}
rom_resume_phh() {
  [ "${ROM_PHH_STOPPED:-0}" = 1 ] || return 0
  ROM_PHH_STOPPED=0
  timeout 8 am startservice --user 0 -n me.phh.treble.app/.EntryService >> "$D/rom-defaults.log" 2>&1 ||
    timeout 8 am broadcast --user 0 --include-stopped-packages -a me.phh.update \
      -n me.phh.treble.app/.Starter >> "$D/rom-defaults.log" 2>&1
}
rom_prefs_run() {   # apply or restore; stop ONLY PHH, and only when supported values differ
  _rpf_probe=$(rom_java "$1-probe" 2>> "$D/rom-defaults.log") || return 1
  [ "$_rpf_probe" = CHANGE ] || { [ "$_rpf_probe" = SAME ] || [ "$_rpf_probe" = ABSENT ]; return; }
  # No XML sed edits and no live cross-process SharedPreferences race.
  timeout 8 am force-stop --user 0 me.phh.treble.app >> "$D/rom-defaults.log" 2>&1 || return 1
  ROM_PHH_STOPPED=1
  _rpf_n=0
  while pidof me.phh.treble.app >/dev/null 2>&1 && [ "$_rpf_n" -lt 10 ]; do
    _rpf_n=$((_rpf_n+1)); sleep 0.1
  done
  if pidof me.phh.treble.app >/dev/null 2>&1; then
    echo 'PHH still running: preference update skipped' >> "$D/rom-defaults.log"
    rom_resume_phh; return 1
  fi
  rom_java "$1-prefs" >> "$D/rom-defaults.log" 2>&1
  _rpf_rc=$?
  rom_resume_phh
  return "$_rpf_rc"
}
rom_defaults_pending() {
  for _rdp_file in "$D"/phh.prop.*.orig "$D"/rom.*.orig; do [ -f "$_rdp_file" ] && return 0; done
  return 1
}
rom_defaults_restore() {
  rom_props_restore
  [ "$(getprop sys.boot_completed)" = 1 ] || return 0
  rom_java restore-settings >> "$D/rom-defaults.log" 2>&1
  rom_prefs_run restore
}
