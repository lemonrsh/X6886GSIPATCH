# Shared, reversible Android settings writes. Never source saved values as shell code.
# D is the module's private state directory (/data/adb/fod).
module_setting_valid() {
  case "$1:$2:$3" in
    global:0:window_animation_scale|global:0:transition_animation_scale|global:0:animator_duration_scale) return 0 ;;
    system:*:min_refresh_rate|system:*:peak_refresh_rate)
      case "$2" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}
module_setting_value() {
  case "$1" in null) return 0 ;; ''|*[!0-9.]*|*.*.*|.) return 1 ;; *) return 0 ;; esac
}
module_setting_cmd() {   # namespace user operation key [value]
  if [ "$1" = global ]; then
    _msc_op=$3; shift 3
    settings "$_msc_op" global "$@" 2>/dev/null
  else
    _msc_user=$2; _msc_op=$3; shift 3
    settings --user "$_msc_user" "$_msc_op" system "$@" 2>/dev/null
  fi
}
module_setting_set() {   # namespace user key value (snapshot only on the first successful read)
  module_setting_valid "$1" "$2" "$3" || return 1
  module_setting_value "$4" && [ "$4" != null ] || return 1
  _mss_file=$D/settings.$1.$2.$3
  _mss_cur=$(module_setting_cmd "$1" "$2" get "$3") || return 1
  module_setting_value "$_mss_cur" || return 1
  if [ ! -f "$_mss_file.orig" ]; then
    printf '%s\n' "$_mss_cur" > "$_mss_file.orig.tmp.$$" &&
      mv -f "$_mss_file.orig.tmp.$$" "$_mss_file.orig" || return 1
  fi
  if [ "$_mss_cur" != "$4" ]; then
    module_setting_cmd "$1" "$2" put "$3" "$4" >/dev/null || return 1
  fi
  printf '%s\n' "$4" > "$_mss_file.last.tmp.$$" &&
    mv -f "$_mss_file.last.tmp.$$" "$_mss_file.last"
}
module_settings_restore() {
  for _msr_orig in "$D"/settings.*.orig; do
    [ -f "$_msr_orig" ] || continue
    _msr_name=${_msr_orig##*/}
    _msr_ns=${_msr_name#settings.}; _msr_ns=${_msr_ns%%.*}
    _msr_user=${_msr_name#settings."$_msr_ns".}; _msr_user=${_msr_user%%.*}
    _msr_key=${_msr_name#settings."$_msr_ns"."$_msr_user".}; _msr_key=${_msr_key%.orig}
    module_setting_valid "$_msr_ns" "$_msr_user" "$_msr_key" || continue
    _msr_value=""; _msr_last=""
    read -r _msr_value < "$_msr_orig"
    module_setting_value "$_msr_value" || continue
    _msr_base=${_msr_orig%.orig}
    [ -r "$_msr_base.last" ] || { rm -f "$_msr_orig"; continue; }
    read -r _msr_last < "$_msr_base.last"
    _msr_cur=$(module_setting_cmd "$_msr_ns" "$_msr_user" get "$_msr_key") || continue
    module_setting_value "$_msr_cur" || continue
    # Do not undo a setting the user/another module changed after our last write.
    if [ "$_msr_cur" = "$_msr_last" ]; then
      if [ "$_msr_value" = null ]; then
        module_setting_cmd "$_msr_ns" "$_msr_user" delete "$_msr_key" >/dev/null || continue
      else
        module_setting_cmd "$_msr_ns" "$_msr_user" put "$_msr_key" "$_msr_value" >/dev/null || continue
      fi
    fi
    rm -f "$_msr_orig" "$_msr_base.last"
  done
}
