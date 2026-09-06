
# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

ASB_BASELINE="${ASB_BASELINE:-/data/adb/asb/baseline.txt}"
# Separate, short-lived snapshot for profile-owned runtime writes. It must not reuse the
# global baseline: that file also protects independent manual audio/WebUI controls, which
# Stock must leave alone. This ledger exists solely to return CPU/VM/network/UX profile
# writes to their exact pre-profile values during an immediate Stock transition.
ASB_PROFILE_BASELINE="${ASB_PROFILE_BASELINE:-/data/adb/asb/profile_runtime_baseline.v1}"

asb_profile_baseline_record() {
  _pb_type="$1" _pb_key="$2" _pb_value="$3"
  [ -n "$_pb_type" ] && [ -n "$_pb_key" ] || return 1
  # Use the configured snapshot directory. Production keeps /data/adb/asb, while host
  # contracts inject a temporary path and must not need permission to create /data.
  mkdir -p "$(dirname "$ASB_PROFILE_BASELINE")" 2>/dev/null || return 1
  [ -f "$ASB_PROFILE_BASELINE" ] || : > "$ASB_PROFILE_BASELINE" 2>/dev/null || return 1
  grep -Fq "$_pb_type|$_pb_key|" "$ASB_PROFILE_BASELINE" 2>/dev/null && return 0
  # Trim the trailing newline rather than rewriting every one.
  #
  # Same defect as the native recorder: a sysfs value arrives as "1200000\n" and was
  # stored as "1200000_", which restores as a string no numeric node accepts. Only an
  # embedded pipe still needs substituting, because it would break the record format.
  _pb_clean="$(printf '%s' "$_pb_value" | tr -d '\n\r' | tr '|' '_')"
  printf '%s|%s|%s\n' "$_pb_type" "$_pb_key" "$_pb_clean" >> "$ASB_PROFILE_BASELINE" 2>/dev/null
}

asb_profile_baseline_capture_path() {
  _pb_path="$1"
  [ -r "$_pb_path" ] || return 0
  asb_profile_baseline_record path "$_pb_path" "$(cat "$_pb_path" 2>/dev/null | tr -d '\r\n')"
}

asb_profile_baseline_capture_setting() {
  _pb_ns="$1" _pb_key="$2"
  command -v settings >/dev/null 2>&1 || return 0
  _pb_val="$(settings get "$_pb_ns" "$_pb_key" 2>/dev/null)"
  [ "$_pb_val" = "null" ] && _pb_val=""
  asb_profile_baseline_record setting "$_pb_ns:$_pb_key" "$_pb_val"
}

asb_profile_baseline_restore() {
  [ -f "$ASB_PROFILE_BASELINE" ] || return 0
  while IFS='|' read -r _pb_type _pb_key _pb_value; do
    case "$_pb_type" in
      path)
        [ -w "$_pb_key" ] && printf '%s\n' "$_pb_value" > "$_pb_key" 2>/dev/null || true
        ;;
      setting)
        _pb_ns="${_pb_key%%:*}"; _pb_name="${_pb_key#*:}"
        [ -n "$_pb_ns" ] && [ -n "$_pb_name" ] || continue
        if [ -z "$_pb_value" ]; then settings delete "$_pb_ns" "$_pb_name" >/dev/null 2>&1 || true
        else settings put "$_pb_ns" "$_pb_name" "$_pb_value" >/dev/null 2>&1 || true
        fi
        ;;
    esac
  done < "$ASB_PROFILE_BASELINE"
  rm -f "$ASB_PROFILE_BASELINE" 2>/dev/null || true
}

asb_baseline_init() {
  [ -f "$ASB_BASELINE" ] && return 0
  mkdir -p "$(dirname "$ASB_BASELINE")" 2>/dev/null
  : > "$ASB_BASELINE" 2>/dev/null || true
  chmod 0644 "$ASB_BASELINE" 2>/dev/null || true
}

# Load the apply ledger if it is present. Sourced rather than required: a stripped build
# or an old install must keep working, just without the extra record.
if ! command -v asb_ledger_settings >/dev/null 2>&1; then
  for _lgp in "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_apply_ledger.sh" \
              "$(dirname "$0")/asb_apply_ledger.sh"; do
    [ -f "$_lgp" ] && . "$_lgp" && break
  done
fi

asb_settings_put() {
  local _ns="$1" _key="$2" _val="$3"
  [ -z "$_ns" ] || [ -z "$_key" ] && return 1
  asb_baseline_init
  # Only profile_core enables this flag around its profile-owned apply transaction. Manual
  # WebUI audio changes intentionally do not enter the Stock runtime baseline.
  [ "${ASB_PROFILE_BASELINE_CAPTURE:-0}" = "1" ] && asb_profile_baseline_capture_setting "$_ns" "$_key"
  if ! grep -qE "^settings\|${_ns}\|${_key}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _orig
    _orig="$(settings get "$_ns" "$_key" 2>/dev/null)"
    [ "$_orig" = "null" ] && _orig=""
    printf 'settings|%s|%s|%s\n' "$_ns" "$_key" "$_orig" >> "$ASB_BASELINE" 2>/dev/null
  fi
  # Record what the device actually did with it.
  #
  # The `|| true` below is deliberate and stays: one rejected key must not abort a profile
  # apply. But swallowing the result also meant a write the ROM ignored looked identical
  # to one that took effect, and the WebUI would report "on" either way. The ledger is
  # where that difference now lives; the control flow is unchanged.
  if command -v asb_ledger_settings >/dev/null 2>&1; then
    asb_ledger_settings "$_ns" "$_key" "$_val" "" || true
  else
    settings put "$_ns" "$_key" "$_val" >/dev/null 2>&1 || true
  fi
}

# Restore one ASB-owned settings key to the value present before its first ASB write. This is
# intentionally narrower than asb_baseline_replay(): a live control returning to stock must not
# reset unrelated manual audio, network or accessibility controls.
asb_baseline_restore_setting() {
  _brs_ns="$1" _brs_key="$2"
  [ -n "$_brs_ns" ] && [ -n "$_brs_key" ] && [ -f "$ASB_BASELINE" ] || return 1
  if ! _brs_val="$(awk -F'|' -v ns="$_brs_ns" -v key="$_brs_key" '
    $1=="settings" && $2==ns && $3==key { found=1; print $4; exit }
    END { exit !found }
  ' "$ASB_BASELINE" 2>/dev/null)"; then
    return 1
  fi
  if [ -z "$_brs_val" ]; then
    settings delete "$_brs_ns" "$_brs_key" >/dev/null 2>&1 || return 1
  else
    settings put "$_brs_ns" "$_brs_key" "$_brs_val" >/dev/null 2>&1 || return 1
  fi
  return 0
}

asb_persist_safe() {
  local _prop="$1" _val="$2"
  [ -z "$_prop" ] && return 1
  asb_baseline_init
  if ! grep -qE "^prop\|${_prop}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _orig
    _orig="$(getprop "$_prop" 2>/dev/null)"
    printf 'prop|%s|%s\n' "$_prop" "$_orig" >> "$ASB_BASELINE" 2>/dev/null
  fi
  setprop "$_prop" "$_val" 2>/dev/null || true
}

asb_pm_disable() {
  local _pkg="$1"
  [ -z "$_pkg" ] && return 1
  asb_baseline_init
  if ! grep -qE "^pm\|${_pkg}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _state="disabled"
    pm list packages -e 2>/dev/null | grep -qE "^package:${_pkg}$" && _state="enabled"
    printf 'pm|%s|%s\n' "$_pkg" "$_state" >> "$ASB_BASELINE" 2>/dev/null
  fi
  pm disable-user --user 0 "$_pkg" >/dev/null 2>&1 || true
}

asb_baseline_replay() {
  [ -f "$ASB_BASELINE" ] || return 0
  while IFS='|' read -r _type _a1 _a2 _a3; do
    case "$_type" in
      settings)
        if [ -z "$_a3" ]; then
          settings delete "$_a1" "$_a2" >/dev/null 2>&1 || true
        else
          settings put "$_a1" "$_a2" "$_a3" >/dev/null 2>&1 || true
        fi
        ;;
      prop)
        if [ -z "$_a2" ]; then
          resetprop -p --delete "$_a1" >/dev/null 2>&1 || resetprop --delete "$_a1" >/dev/null 2>&1 || true
        else
          setprop "$_a1" "$_a2" 2>/dev/null || true
        fi
        ;;
      pm)
        [ "$_a2" = "enabled" ] && pm enable --user 0 "$_a1" >/dev/null 2>&1 || true
        ;;
    esac
  done < "$ASB_BASELINE"
}
