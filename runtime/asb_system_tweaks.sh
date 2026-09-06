#!/system/bin/sh
# asb_system_tweaks.sh - small system-behaviour settings that belong to the user.
#
# Both of these were already being set unconditionally somewhere in service.sh. Turning
# them into settings is not new capability - it is admitting that the module had an
# opinion the user never agreed to, and letting them disagree.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || exit 0
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_put() {
  # asb_settings_put records the original before the first write, which is what makes
  # "stock" recoverable at all. Fall back to a plain write if the baseline helper is not
  # loaded, rather than silently doing nothing.
  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put "$1" "$2" "$3"
  else
    settings put "$1" "$2" "$3" >/dev/null 2>&1 || true
  fi
}

_changed=""

# --- phantom process monitor ---------------------------------------------------------
case "$(_cfg phantom_procs)" in
  relaxed)
    _put global settings_enable_monitor_phantom_procs false
    _changed="${_changed}phantom=relaxed "
    ;;
  strict)
    _put global settings_enable_monitor_phantom_procs true
    _changed="${_changed}phantom=strict "
    ;;
  *)
    # stock means "put it back", not "walk away".
    #
    # Leaving the value alone made the setting one-way: strict -> stock reported stock in
    # the UI while phantom-process monitoring stayed off, because ASB had turned it off
    # and then declined to undo that. The user cannot restore it themselves - the key is
    # not in any settings screen.
    #
    # asb_settings_put recorded the original before the first write, so it is there to be
    # restored. When no record exists ASB never wrote the key, and leaving it is correct.
    if [ -f "${ASB_PROFILE_BASELINE:-/data/adb/asb/profile_runtime_baseline.v1}" ]; then
      _pp_orig="$(grep -m1 '^setting|global:settings_enable_monitor_phantom_procs|' \
                  "${ASB_PROFILE_BASELINE:-/data/adb/asb/profile_runtime_baseline.v1}" \
                  2>/dev/null | cut -d'|' -f3)"
      if [ -n "$_pp_orig" ]; then
        settings put global settings_enable_monitor_phantom_procs "$_pp_orig" >/dev/null 2>&1 \
          && _changed="${_changed}phantom=stock(restored) "
      fi
    fi
    ;;
esac

# Lock screen shortcuts were here and are gone: the keys they wrote
# (lockscreen_left_button_enabled / _right_button_enabled) are AOSP/Pixel settings that
# OxygenOS does not read. Verified by screenshot - the tweak was on and both shortcuts
# were still on the lock screen. A setting that cannot work is worse than a missing one.

[ -n "$_changed" ] && echo "system tweaks: $_changed"
exit 0
