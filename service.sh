#!/system/bin/sh
# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

if [ ! -f /data/adb/asb/debug ] && [ "$(getprop persist.asb.debug 2>/dev/null)" != "1" ]; then
  exec >/dev/null 2>&1
fi
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
asb_resolve_moddir() {
  for _d in     "$MODDIR"     "/data/adb/modules/$MODID"     "/data/adb/modules_update/$MODID"     "/data/adb/modules/${MODID}_TMP"     "/data/adb/modules_update/${MODID}_TMP"
  do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] && { echo "$_d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(asb_resolve_moddir)"

# Debug-only passive lifecycle evidence for slow reboot investigation. Keep the same strict
# numeric suffix grammar as the recorder/asbdiag: V64-debug4 is a debug build, V64-debug4x is not.
# The local gate prevents any extra helper process in a release boot.
ASB_TIMELINE_DEBUG=0
_asb_timeline_version=""
while IFS='=' read -r _asb_timeline_key _asb_timeline_value; do
  [ "$_asb_timeline_key" = "version" ] || continue
  _asb_timeline_version="$_asb_timeline_value"
  break
done < "$MODDIR/module.prop"
_asb_timeline_seq="${_asb_timeline_version##*-debug}"
case "$_asb_timeline_version:$_asb_timeline_seq" in
  *-debug[1-9]*:[1-9]*)
    case "$_asb_timeline_seq" in *[!0-9]*) ;; *) ASB_TIMELINE_DEBUG=1 ;; esac
    ;;
esac
asb_timeline_mark() {
  [ "$ASB_TIMELINE_DEBUG" = "1" ] || return 0
  [ -f "$MODDIR/runtime/asb_boot_timeline.sh" ] || return 0
  ASB_BOOT_TIMELINE_MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_boot_timeline.sh" mark "$1" >/dev/null 2>&1 || true
}
asb_timeline_mark service_enter

mkdir -p /data/adb/asb 2>/dev/null
for _legacy_pair in \
    "asb_active_profile:active_profile" \
    "asb_baseline.txt:baseline.txt" \
    "asb_profile_switches.log:profile_switches.log" \
    "asb_user_config:user_config" \
    "asb_vendor_boot_counter:vendor_boot_counter" \
    "asb_vendor_mounts.log:vendor_mounts.log" \
    "asb_vendor_overlay_active:vendor_overlay_active" \
    "asb_recovery_disabled:recovery_disabled" \
    "asb_recovery_lock:recovery_lock" \
    "asb_debug:debug"; do
  _old="${_legacy_pair%:*}"
  _new="${_legacy_pair#*:}"
  if [ -e "/data/adb/$_old" ] && [ ! -e "/data/adb/asb/$_new" ]; then
    mv "/data/adb/$_old" "/data/adb/asb/$_new" 2>/dev/null || true
  elif [ -e "/data/adb/$_old" ]; then
    rm -f "/data/adb/$_old" 2>/dev/null || true
  fi
done

# ── V56 learning-reset boot sweep ──────────────────────────────────────────── Must run BEFORE
# asb_utils.sh is sourced below (sourcing it auto-starts the governor), i.e.
if [ -f /data/adb/asb/learning_reset_pending ]; then
  rm -f /data/adb/asb/buckets.bin /data/adb/asb/buckets.bin.bak \
        /data/adb/asb/pstats_balanced.json /data/adb/asb/pstats_battery.json \
        /data/adb/asb/smart_appheat.bin /data/adb/asb/auto_battery_state \
        /data/adb/asb/session_history.jsonl \
        /data/adb/asb/session_history_migrated_v47 2>/dev/null
  rm -f /data/adb/asb/learning_reset_pending 2>/dev/null
  : > /data/adb/asb/v56_resurrect_sweep_done 2>/dev/null
elif [ -f /data/adb/asb/v56_learning_reset_done ] && [ ! -f /data/adb/asb/v56_resurrect_sweep_done ]; then
  rm -f /data/adb/asb/buckets.bin /data/adb/asb/buckets.bin.bak \
        /data/adb/asb/pstats_balanced.json /data/adb/asb/pstats_battery.json \
        /data/adb/asb/smart_appheat.bin /data/adb/asb/auto_battery_state 2>/dev/null
  : > /data/adb/asb/v56_resurrect_sweep_done 2>/dev/null
fi

# Build capability-derived policy before asb_utils.sh starts the native governor.  These
# probes are read-only and bounded; a failed probe leaves the derived manifest inactive.
[ -f "$MODDIR/tools/asb_discover.sh" ] && sh "$MODDIR/tools/asb_discover.sh" >/dev/null 2>&1
[ -f "$MODDIR/tools/asb_synthesize_bounds.sh" ] && sh "$MODDIR/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1
[ -f "$MODDIR/runtime/asb_active_efficiency_envelope.sh" ] && \
  sh "$MODDIR/runtime/asb_active_efficiency_envelope.sh" >/dev/null 2>&1

# Non-Stock profiles previously started the native governor while Android was still bringing
# up system services.  Stock is fast precisely because it does not keep that writer/metrics
# loop alive during startup.  Source the helpers now, but defer the actual process until
# boot_completed below; profile state is already persisted in current_profile.
ASB_DEFER_GOVERNOR_START=1
[ -r "$MODDIR/runtime/asb_utils.sh" ]   && . "$MODDIR/runtime/asb_utils.sh"
[ -r "$MODDIR/runtime/asb_arbiter.sh" ] && . "$MODDIR/runtime/asb_arbiter.sh"
[ -r "$MODDIR/runtime/profile_core.sh" ] && . "$MODDIR/runtime/profile_core.sh"
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"
[ -r "$MODDIR/runtime/asb_device_tier.sh" ] && . "$MODDIR/runtime/asb_device_tier.sh"
ASB_STATE_LOG="/dev/.asb_profile_state/runtime_apply.log"
asb_log(){ echo "[$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo now)] $*" >> "$ASB_STATE_LOG" 2>/dev/null || true; }

# Keep an append-only log from growing for the life of the install.
# The governor's own persist log already rotates in C; the shell-side ones never did, and
# profile_switches alone gets a line per switch - field logs show four an hour, which is tens
# of thousands of lines a year that nobody will ever read past the last few dozen.
asb_trim_log() {
  _tl_f="$1"; _tl_max="${2:-65536}"
  [ -f "$_tl_f" ] || return 0
  _tl_sz="$(wc -c < "$_tl_f" 2>/dev/null)"
  case "$_tl_sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_tl_sz" -le "$_tl_max" ] && return 0
  tail -n 200 "$_tl_f" > "${_tl_f}.trim" 2>/dev/null &&     mv -f "${_tl_f}.trim" "$_tl_f" 2>/dev/null
  rm -f "${_tl_f}.trim" 2>/dev/null
}
for _tl in vendor_mounts.log ram_expand.log profile_switches.log; do
  asb_trim_log "/data/adb/asb/$_tl"
done

# Apply optional vendor/system properties only after the active feature set and
# the exact build fingerprint have been validated. Module-level system.prop is
# intentionally blank in this build, so no property can bypass this gate early.
if [ -r "$MODDIR/runtime/asb_apply_managed_props.sh" ]; then
  sh "$MODDIR/runtime/asb_apply_managed_props.sh" >/dev/null 2>&1 || \
    asb_log "managed_props: helper execution failed"
fi

# active_profile lives in /data/adb/asb, which survives module removal - so this restore
# put a profile back on a phone where the user had just installed clean and chosen
# nothing. It is meant to survive a REBOOT, not an uninstall, and the marker below tells
# the two apart: install.sh writes it when it deliberately leaves no profile selected.
if [ -r /data/adb/asb/active_profile ] && [ ! -f /data/adb/asb/no_profile_chosen ]; then
  _saved_profile="$(cat /data/adb/asb/active_profile 2>/dev/null)"
  case "$_saved_profile" in
    stock|battery|balanced|performance|smart)
      _current_profile="$(cat "$MODDIR/current_profile" 2>/dev/null)"
      if [ "$_saved_profile" != "$_current_profile" ]; then
        echo "$_saved_profile" > "$MODDIR/current_profile" 2>/dev/null
        asb_log "profile restored from active_profile: $_current_profile -> $_saved_profile"
      fi
      ;;
  esac
fi

# Smart Mode default-on for fresh installs; preserve previous behaviour for upgrades.
mkdir -p /data/adb/asb 2>/dev/null
if [ ! -f /data/adb/asb/smart_mode_enabled ]; then
  _prior_signs=0
  [ -r /data/adb/asb/active_profile ] && _prior_signs=1
  [ -r /data/adb/asb/user_config ] && _prior_signs=1
  [ -d /data/adb/asb/learn ] && _prior_signs=1
  [ -r /data/adb/asb/pstats_battery.json ] && _prior_signs=1
  [ -r /data/adb/asb/pstats_balanced.json ] && _prior_signs=1
  if [ "$_prior_signs" = "1" ]; then
    echo "0" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    _cur_prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"
    [ -z "$_cur_prof" ] && _cur_prof=balanced
    echo "$_cur_prof" > /data/adb/asb/smart_prev_profile 2>/dev/null
    asb_log "smart_migration: existing user state detected, smart_mode=off, prev_profile=$_cur_prof"
  else
    # Smart is available, not applied. Writing current_profile here was the last place
    # that chose for the user - the WebUI said "not selected" while this had already
    # picked smart and the module card showed a profile. The learner still starts, so
    # tapping Smart later has history behind it.
    echo "1" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    echo "balanced" > /data/adb/asb/smart_prev_profile 2>/dev/null
    asb_log "smart_migration: fresh install, smart_mode=on, no profile applied yet"
  fi
fi

asb_load_profile
asb_timeline_mark service_profile_loaded
if [ "${ASB_STOCK_PROFILE:-0}" = "1" ]; then
  command -v asb_stock_enter >/dev/null 2>&1 && asb_stock_enter
fi

rm -f /data/adb/asb/v45_cleanup_done /data/adb/asb/v46_athena_cleanup_done /data/adb/asb/session_history_migrated_v47 2>/dev/null

# Undo the task-snapshot properties earlier builds set.
#
# persist.* properties are written into the device's own property store, so simply
# removing them from system.prop stops us SETTING them but leaves the value already on
# disk. Anyone who ran an earlier build still has task snapshots off - and therefore still
# has no Cards/Simple selector in Recent Tasks Manager - until they are actively cleared.
# resetprop --delete puts the property back to whatever the ROM decides, which is what a
# device without this module has.
# Clear a persisted anim_level that earlier builds wrote.
#
# The rule that set persist.sys.oplus.anim_level=0 whenever blur was off is gone from both
# the installer and the runtime script - but that only stops us WRITING it. The property
# already lives in the device's own store on anyone who ran an earlier build, and it keeps
# Recents flat there forever. Removing the line from system.prop cannot undo a value that
# is no longer coming from system.prop.
#
# Only cleared when the user has NOT asked for flat effects: an explicit choice stays.
# Checked EVERY boot, not once.
#
# This used to be guarded by a marker file that was written whether or not anything was
# actually cleaned. Someone whose first boot had "flat" set got the marker and no cleanup -
# correct at that moment - and then switching to normal later could never clear the
# property, because the marker said the job was done. The condition it depends on is a
# setting the user can change at any time, so the check has to run at any time too.
#
# It is cheap: one getprop, and it only acts when the value is actually 0 and the user has
# not asked for flat.
# Non-reference devices are moved off "flat" once.
#
# The option is no longer offered to them in the WebUI, because there the setting removes
# the Cards/Simple selector from Recent Tasks Manager and only OP15 puts the property back
# on its own. Hiding the button is not enough for someone who already chose it: the value
# stays in the config, the card shows a state its own control can no longer reach, and the
# selector stays gone. Migrate it, say so in the log, and let the cleanup below clear the
# property on the same boot.
if [ "$(cat "$MODDIR/overlay_device_class" 2>/dev/null)" = "generic" ]; then
  case "$(grep -E '^[[:space:]]*ui_effects_level=' "$MODDIR/config/governor.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')" in
    flat|0)
      sed -i 's|^[[:space:]]*ui_effects_level=.*|ui_effects_level=stock|' \
        "$MODDIR/config/governor.conf" 2>/dev/null
      asb_log "ui_effects_level: flat is not offered on this model - moved to stock, Recents selector returns after a reboot"
      ;;
  esac
fi

_al_ue="$(grep -E '^[[:space:]]*ui_effects_level=' "$MODDIR/config/governor.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')"
case "$_al_ue" in
  flat|0) : ;;
  *)
    if [ "$(getprop persist.sys.oplus.anim_level 2>/dev/null)" = "0" ]; then
      resetprop --delete persist.sys.oplus.anim_level >/dev/null 2>&1
      asb_log "anim_level cleared - Recents cards and the Cards/Simple selector return after a reboot"
    fi
    ;;
esac

if [ ! -f /data/adb/asb/tasksnap_restored ]; then
  _ts_any=0
  for _tsp in persist.enable_task_snapshots \
              persist.vendor.enable_task_snapshots \
              persist.tasksnapshot.starting_window_enable \
              persist.vendor.tasksnapshot.starting_window_enable; do
    case "$(getprop "$_tsp" 2>/dev/null)" in
      false|0)
        resetprop --delete "$_tsp" >/dev/null 2>&1 && _ts_any=1
        ;;
    esac
  done
  mkdir -p /data/adb/asb 2>/dev/null
  touch /data/adb/asb/tasksnap_restored 2>/dev/null
  [ "$_ts_any" = "1" ] && \
    asb_log "task snapshots restored - Recents card previews and the Cards/Simple selector come back after a reboot"
fi

if [ ! -f /data/adb/asb/stale_props_cleaned ]; then
  # Remove props an OLDER ASB set - and only those.
  #
  # This used to delete every listed prop that existed, without asking who put it there.
  # On a device where the vendor sets persist.sys.oplus.athena.* natively that meant ASB
  # quietly wiping OEM configuration for the background process manager, which is exactly the
  # kind of thing that gets reported as "the module disables Athena".
  #
  # baseline.txt records "prop|<name>|<original>" for everything ASB has ever set.
  # No record at all means we never touched it - leave it alone.
  _asb_bl="/data/adb/asb/baseline.txt"
  for _stale_p in \
      persist.sys.oplus.athena.reclaim_enable \
      persist.sys.oplus.athena.force_kill \
      persist.sys.oplus.athena.limit_count \
      persist.sys.oplus.deepthinker.reclaim_hint \
      ro.audio.audiozoom \
      persist.bluetooth.spatial_audio_support; do
    [ -n "$(getprop "$_stale_p" 2>/dev/null)" ] || continue
    _stale_rec="$(grep -m1 "^prop|${_stale_p}|" "$_asb_bl" 2>/dev/null)"
    [ -n "$_stale_rec" ] || continue                 # not ours - do not touch
    _stale_orig="${_stale_rec#prop|${_stale_p}|}"
    if [ -n "$_stale_orig" ]; then
      resetprop "$_stale_p" "$_stale_orig" >/dev/null 2>&1 || true
    else
      resetprop --delete "$_stale_p" >/dev/null 2>&1 || true
    fi
  done
  touch /data/adb/asb/stale_props_cleaned 2>/dev/null
fi

# Athena: never disabled by this module, and say so when it is found disabled.
#
# A tester reported "61-debug-51 disables Athena" and had to re-enable it by hand.
# No current code path touches com.oplus.athena - it is not in _BG_TRIM_DISABLE and there is no
# pm record for it in baseline.txt - so a disabled Athena on a device running this build is
# left over from an older version that did disable it and never recorded the fact, which is why
# uninstall could not put it back either.
#
# Re-enabling it automatically would be the wrong call: the XDA thread that circulates with
# this package recommends removing it, so some people disable it deliberately, and silently
# undoing a user's own decision is worse than leaving it.
# Backgrounded: this waits on PackageManager, and boot waits on it.
#
# `pm list packages` blocks until PackageManager is up, which on a cold boot is one of
# the last services to arrive. Running it inline in service.sh holds the whole module
# start behind it, and users report the phone taking noticeably longer to boot with
# the module installed than without.
#
# Nothing here needs to happen early, or at all, for the module to work: it writes two
# log lines about a package ASB never touches, once per install. Deferring it costs
# nothing and gives the boot back.
(
  if [ ! -f /data/adb/asb/athena_state_checked ]; then
    if pm list packages -d 2>/dev/null | grep -q '^package:com.oplus.athena$'; then
      if ! grep -q "^pm|com.oplus.athena|" /data/adb/asb/baseline.txt 2>/dev/null; then
        asb_log "athena: com.oplus.athena is DISABLED and ASB has no record of doing it (legacy build?)."
        asb_log "athena: ASB never disables it. To restore: pm enable com.oplus.athena"
      fi
    fi
    touch /data/adb/asb/athena_state_checked 2>/dev/null
  fi
) &

# Reset vm.oom_kill_allocating_task to kernel default (0) at every boot.
if [ -w /proc/sys/vm/oom_kill_allocating_task ]; then
  echo 0 > /proc/sys/vm/oom_kill_allocating_task 2>/dev/null || true
fi

command -v asb_update_desc >/dev/null 2>&1 && asb_update_desc 2>/dev/null
# Snapshot the profile next to the description update: both run whenever the active
# profile is settled, and the backup is what an install after a manual uninstall reads.
command -v asb_backup_profile >/dev/null 2>&1 && asb_backup_profile 2>/dev/null

asb_migrate_governor_conf() {
  # Schema 20 makes the duplicate-key safety migration and the new independent
  # radio_policy_enable=0 default run once for existing installs. Historical shell
  # readers used the first key, so migration keeps the first occurrence rather than
  # silently changing the user's intent.
  local _expected_schema=20
  local _conf_dir="$MODDIR/config"
  local _user_conf="$_conf_dir/governor.conf"
  local _shipped_conf="$_conf_dir/governor.conf.shipped"
  local _schema_marker="$_conf_dir/.schema_version"

  [ -f "$_user_conf" ] || return 0

  local _current_schema=0
  if [ -f "$_schema_marker" ]; then
    _current_schema="$(cat "$_schema_marker" 2>/dev/null || echo 0)"
    case "$_current_schema" in
      ''|*[!0-9]*) _current_schema=0 ;;
    esac
  fi

  if [ "$_current_schema" -ge "$_expected_schema" ]; then
    asb_log "config_migrate: schema=$_current_schema already current, skipping"
    return 0
  fi

  asb_log "config_migrate: schema=$_current_schema -> $_expected_schema, additive merge"

  if [ ! -f "$_shipped_conf" ]; then
    asb_log "config_migrate: WARN no governor.conf.shipped found, leaving existing config"
    echo "$_expected_schema" > "$_schema_marker" 2>/dev/null
    chmod 644 "$_schema_marker" 2>/dev/null || true
    return 0
  fi

  local _ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
  local _backup="$_user_conf.bak.schema${_current_schema}.${_ts}"
  if ! cp "$_user_conf" "$_backup" 2>/dev/null; then
    asb_log "config_migrate: WARN could not create backup at $_backup, aborting"
    return 1
  fi

  # Collapse historical duplicates before additive merge. The native daemon now
  # rejects duplicates because they previously made shell/native policies diverge.
  local _dedupe="$_user_conf.dedupe.$$"
  if ! awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { p=index($0,"="); if (!p) next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (++seen[k] > 1) bad=1 }
    END { exit bad ? 1 : 0 }
  ' "$_user_conf"; then
    awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      { p=index($0,"="); if (!p) { print; next }; k=substr($0,1,p-1); probe=k; gsub(/^[[:space:]]+|[[:space:]]+$/, "", probe); if (!seen[probe]++) print }
    ' "$_user_conf" > "$_dedupe" 2>/dev/null || { rm -f "$_dedupe"; return 1; }
    if mv -f "$_dedupe" "$_user_conf" 2>/dev/null; then
      asb_log "config_migrate: removed duplicate keys, preserved first historical values (backup: $_backup)"
    else
      rm -f "$_dedupe" 2>/dev/null
      asb_log "config_migrate: WARN duplicate cleanup failed, original preserved"
      return 1
    fi
  fi

  local _added=0 _kept=0
  local _tmp="$_user_conf.merge.$$"
  cp "$_user_conf" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }

  local _line _k
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      ''|\#*) continue ;;
      *=*) _k="${_line%%=*}" ;;
      *) continue ;;
    esac
    if grep -q "^[[:space:]]*${_k}=" "$_tmp" 2>/dev/null; then
      _kept=$((_kept + 1))
    else
      printf '%s\n' "$_line" >> "$_tmp"
      _added=$((_added + 1))
    fi
  done < "$_shipped_conf"

  if mv "$_tmp" "$_user_conf" 2>/dev/null; then
    chmod 644 "$_user_conf" 2>/dev/null || true
    asb_log "config_migrate: kept $_kept user values, added $_added new keys (backup: $_backup)"
  else
    rm -f "$_tmp" 2>/dev/null
    asb_log "config_migrate: WARN merge write failed, original preserved"
    return 1
  fi

  echo "$_expected_schema" > "$_schema_marker" 2>/dev/null
  chmod 644 "$_schema_marker" 2>/dev/null || true

  asb_log "config_migrate: complete, schema=$_expected_schema"
}
asb_migrate_governor_conf

# Refresh device facts at boot (read-only; rewrites /data/adb/asb/device_caps.env so it tracks
# kernel/topology changes between installs).
(
  [ -f "$MODDIR/tools/asb_discover.sh" ] && sh "$MODDIR/tools/asb_discover.sh" >/dev/null 2>&1
  [ -f "$MODDIR/tools/asb_synthesize_bounds.sh" ] && sh "$MODDIR/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1
  [ -f "$MODDIR/runtime/asb_active_efficiency_envelope.sh" ] && \
    sh "$MODDIR/runtime/asb_active_efficiency_envelope.sh" >/dev/null 2>&1
  # Retire the interactive prime ceilings from any bounds file written by an earlier build.
  if [ -f /data/adb/asb/device_bounds.env ] && \
     grep -qE '^(BALANCED|PERFORMANCE)_CPU_MAX_PRIME=' /data/adb/asb/device_bounds.env 2>/dev/null; then
    sed -i '/^BALANCED_CPU_MAX_PRIME=/d; /^PERFORMANCE_CPU_MAX_PRIME=/d' \
      /data/adb/asb/device_bounds.env 2>/dev/null
    asb_log "device_bounds: dropped retired interactive prime ceilings"
  fi
) &

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  asb_feature_enabled SOTER_REPAIR || exit 0
  _soter_state="$(getprop init.svc.vendor.soter 2>/dev/null)"
  if [ -z "$_soter_state" ]; then
    asb_log "soter_repair: vendor.soter not declared on this device, skipping"
    exit 0
  fi
  _attempt=0
  _delays="1 5 30"
  for _d in $_delays; do
    _attempt=$((_attempt + 1))
    _state="$(getprop init.svc.vendor.soter 2>/dev/null)"
    if [ "$_state" = "running" ]; then
      asb_log "soter_repair: vendor.soter running, no action needed"
      break
    fi
    asb_log "soter_repair: attempt $_attempt — state=$_state, restarting"
    stop vendor.soter
    sleep 1
    start vendor.soter
    sleep "$_d"
    _state="$(getprop init.svc.vendor.soter 2>/dev/null)"
    if [ "$_state" = "running" ]; then
      asb_log "soter_repair: succeeded after attempt $_attempt"
      break
    fi
  done
  _final="$(getprop init.svc.vendor.soter 2>/dev/null)"
  [ "$_final" != "running" ] && asb_log "soter_repair: gave up after 3 attempts, final state=$_final"
) &

(
  _t=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_t" -lt 180 ]; do
    sleep 5
    _t=$((_t + 5))
  done
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    # The bundled DSP chain is selected by actual effect ABI and staged files. It must
    # remain available to supported devices even when no optional fingerprint pack exists;
    # otherwise overlay bind and attacher never run and the loudness slider has no effect.
    if asb_feature_enabled AUDIO; then
    echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null
    # Re-apply the /odm runtime binds.
    # post-fs-data already tries this, but KernelSU mounts its own module overlay on /odm AFTER
    # post-fs-data runs, so that early bind gets shadowed and the framework still reads the
    # stock config (observed: the boot log said action=boot, yet grep asb
    # /odm/etc/audio_effects_config.xml stayed 0 until a manual mount --bind).
    if [ ! -f /data/adb/asb/vendor_overlay_blocked ] && [ -f /data/adb/asb/odm_bind_manifest.txt ]; then
      _rb_any=0
      while IFS='|' read -r _rb_t _rb_p; do
        case "$_rb_t" in ''|'#'*) continue ;; esac
        [ -f "$_rb_t" ] && [ -f "$_rb_p" ] || continue
        cmp -s "$_rb_t" "$_rb_p" 2>/dev/null && continue
        if command -v nsenter >/dev/null 2>&1 \
           && nsenter -t 1 -m -- mount --bind "$_rb_p" "$_rb_t" 2>/dev/null; then
          _rb_any=1
        elif mount --bind "$_rb_p" "$_rb_t" 2>/dev/null; then
          _rb_any=1
        fi
      done < /data/adb/asb/odm_bind_manifest.txt
      if [ "$_rb_any" = "1" ]; then
        echo "ts=$(date +%s) action=odm_bind_late result=applied" >> /data/adb/asb/vendor_mounts.log 2>/dev/null
        setprop ctl.restart audioserver 2>/dev/null || true
      fi
    fi
    # Launch the attacher daemon from OUR data dir (post-fs-data staged it there and made it
    # executable; the copy inside the module dir stays 0644 because the root manager resets
    # module file permissions after installation).
    # This is what actually makes the DSP audible on OxygenOS: the framework never applies the
    # config's <postprocess> section here - AudioPolicyEffects logs "no output processing
    # needed" even for the stock music_helper - so effects have to be created programmatically,
    # exactly like ViperFX and OPlus' own effect do.
    _att_bin="/data/adb/asb/asb_dsp_attach"
    if [ -f "$MODDIR/bin/asb_dsp_attach" ]; then
      mkdir -p /data/adb/asb 2>/dev/null
      # Refresh unconditionally. Copying only when the file was missing meant a rebuilt
      # daemon shipped in a module update never took effect - the stale binary from the
      # previous install stayed in /data/adb/asb and kept being launched.
      cp -f "$MODDIR/bin/asb_dsp_attach" "$_att_bin" 2>/dev/null
    fi
    # Where the daemon's stdout goes.
    #
    # It used to be an unconditional ">>" onto /data/adb/asb/dsp_attach.log, which is append
    # with no truncation and no rotation - so the file only ever grew, for the life of the
    # install.
    # In steady state the daemon is quiet, but it logs three lines for every audioserver
    # restart (camera, calls, BT connect - dozens a day), one per settings change, and, worst
    # of all, it keeps logging create failures roughly every five minutes forever on a device
    # where the effect never registered.
    #
    # Normal installs now discard it entirely - the daemon's state is visible on the action
    # screen and in asbdiag, so a permanent on-device log buys nothing.
    # It is kept only when debug is on, and even then truncated per boot rather than appended,
    # so it is bounded by one session instead of by the lifetime of the install.
    _att_log="/dev/null"
    if [ -f /data/adb/asb/debug ] || [ "$(getprop persist.asb.debug 2>/dev/null)" = "1" ]; then
      _att_log="/data/adb/asb/dsp_attach.log"
      : > "$_att_log" 2>/dev/null
    else
      # Reclaim whatever an earlier build left behind, on the first boot after updating.
      rm -f /data/adb/asb/dsp_attach.log 2>/dev/null
    fi

    if [ -f "$_att_bin" ]; then
      chmod 0755 "$_att_bin" 2>/dev/null
      pkill -f asb_dsp_attach 2>/dev/null
      sleep 1
      if [ -x "$_att_bin" ]; then
        nohup "$_att_bin" >> "$_att_log" 2>&1 &
        _att_how="direct"
      else
        # Last resort: hand the binary to the dynamic linker. That runs it without needing
        # the exec bit, covering a noexec mount or an SELinux label that forbids exec.
        nohup /system/bin/linker64 "$_att_bin" >> "$_att_log" 2>&1 &
        _att_how="linker64"
      fi
      echo "ts=$(date +%s) action=dsp_attach_started via=$_att_how" >> /data/adb/asb/vendor_mounts.log 2>/dev/null
      # Publish the DSP properties the effect reads.
      #
      # "mirror" only republishes what the property store already holds, and that is the right
      # thing while the overlay is still coming up - computing from config there would read the
      # missing library as "needs reboot" and write enable=0 on every boot.
      # So a fresh device with dsp_loudness set at install time came up with the effect
      # registered, the library live, and enable never set - reported from the field as
      # "persist.asb.dsp.enable is not 1" on a working DSP.
      #
      # By this point boot is complete and the overlay is up, so if the library is actually
      # visible we can compute for real.
      # If media_loudness asks for a reshape and the overlay copy does not carry our marker,
      # the file was never built for the current setting - rebuild it now so the NEXT boot is
      # correct instead of waiting for a reinstall nobody knows to perform.
      _vt_want="$(grep -E '^[[:space:]]*media_loudness=' "$MODDIR/config/governor.conf" 2>/dev/null \
                  | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
      case "$_vt_want" in
        mild|strong|max)
          if ! grep -q 'ASB:VOLCURVE' "$MODDIR/system/vendor/etc/default_volume_tables.xml" 2>/dev/null; then
            [ -f "$MODDIR/runtime/asb_media_apply.sh" ] && \
              sh "$MODDIR/runtime/asb_media_apply.sh" >/dev/null 2>&1
            asb_log "media_loudness=$_vt_want: overlay volume table rebuilt, active next boot"
          fi
          ;;
      esac

      if [ -f "$MODDIR/runtime/asb_audio_apply.sh" ]; then
        if { [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; } \
           && [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" != "1" ]; then
          sh "$MODDIR/runtime/asb_audio_apply.sh" dsp >/dev/null 2>&1
        else
          sh "$MODDIR/runtime/asb_audio_apply.sh" mirror >/dev/null 2>&1
        fi
      fi
    fi
    else
      asb_log "audio_dsp: skipped (AUDIO disabled)"
    fi
  fi
) >/dev/null 2>&1 &

asb_device_guard() {
  local _soc
  _soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_soc" ] && _soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_soc" in
    # ro.board.platform reports the PLATFORM CODENAME, not the SoC model: a OnePlus 15 returns
    # "canoe", never "sm8850", so the flagship it is was classified generic and the log claimed
    # "conservative limits apply" while nothing of the sort happened.
    # Both spellings are matched now because different OEM builds populate different props, and
    # device_caps.env carries the model separately.
    sun|canoe|ossi|sm8850*|sm8750*|pineapple) ASB_DEVICE_TIER="flagship" ;;
    taro|sm8550*|sm8650*|kalama|crow)         ASB_DEVICE_TIER="high" ;;
    *)                                        ASB_DEVICE_TIER="generic" ;;
  esac
  asb_log "device_guard: soc=$_soc tier=$ASB_DEVICE_TIER"
  [ "$ASB_DEVICE_TIER" = "generic" ] && \
    asb_log "device_guard: unknown SoC, conservative limits apply"
}

asb_probe_paths() {
  for _pp in \
    "policy0_max:/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" \
    "policy6_max:/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq" \
    "gpu_max:/sys/class/kgsl/kgsl-3d0/max_pwrlevel" \
    "vm_swappiness:/proc/sys/vm/swappiness" \
    "uclamp_topapp:/dev/cpuctl/top-app/cpu.uclamp.max"; do
    _label="${_pp%%:*}"; _path="${_pp#*:}"
    if [ ! -e "$_path" ]; then
      asb_log "probe: $_label MISSING"
    elif [ -w "$_path" ]; then
      asb_log "probe: $_label writable"
    else
      asb_log "probe: $_label read-only"
    fi
  done
}

asb_conflict_scan() {
  local _found=0 _mods="/data/adb/modules"
  for _m in "$_mods"/*/; do
    [ -f "$_m/disable" ] && continue
    [ "$(basename "$_m")" = "$MODID" ] && continue
    [ ! -f "$_m/module.prop" ] && continue
    local _name; _name="$(grep '^name=' "$_m/module.prop" 2>/dev/null | cut -d= -f2)"
    case "$_name" in *thermal*|*kernel*tuner*|*cpu*freq*|*governor*|*performance*tweak*)
      asb_log "conflict: potential overlap with $_name"; _found=$((_found+1)) ;;
    esac
    grep -ql "scaling_max_freq\|cpufreq" "$_m/service.sh" 2>/dev/null && \
      { asb_log "conflict: $_name may write cpufreq"; _found=$((_found+1)); }
  done
  [ $_found -eq 0 ] && asb_log "conflict: none detected"
}

asb_read_msm_perf_cap() {
  _cpu="$1"
  _path="/sys/kernel/msm_performance/parameters/cpu_max_freq"
  [ -r "$_path" ] || return 1
  awk -v cpu="$_cpu" '{
    for (i = 1; i <= NF; i++) {
      split($i, a, ":")
      if (a[1] == cpu) { print a[2]; exit }
    }
  }' "$_path" 2>/dev/null
}
asb_drift_check() {
  local _prof="$1"; [ -z "$_prof" ] && return 0
  sleep 1
  asb_load_profile

  # Caps are per-device PERCENTAGES now, not the absolute CPU_MAX_* in the
  for _dchk in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_dchk" ] || continue
    local _mn _mx
    _mn="$(cat "$_dchk/scaling_min_freq" 2>/dev/null)"
    _mx="$(cat "$_dchk/scaling_max_freq" 2>/dev/null)"
    [ -n "$_mn" ] && [ -n "$_mx" ] && [ "$_mn" -gt "$_mx" ] 2>/dev/null && \
      asb_log "drift(cpu): $(basename "$_dchk") min=${_mn} > max=${_mx}"
  done

  # Cap-drift comparison intentionally omitted: caps are per-device percents (and
  :
  local _gmin_path="/sys/class/kgsl/kgsl-3d0/devfreq/min_freq"
  local _gmax_path="/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"
  if [ -r "$_gmin_path" ] && [ -r "$_gmax_path" ]; then
    local _gmin _gmax
    _gmin="$(cat "$_gmin_path" 2>/dev/null)"
    _gmax="$(cat "$_gmax_path" 2>/dev/null)"
    [ -n "$_gmin" ] && [ -n "$_gmax" ] && [ "$_gmin" -gt "$_gmax" ] 2>/dev/null &&       asb_log "drift(gpu): min_freq=${_gmin} > max_freq=${_gmax}"
  fi
}

asb_device_guard
# Keep the unrotated logs bounded.
#
# session_history.jsonl has proper stream rotation in the governor (500 entries plus a byte
# cap) and is fine.
asb_trim_logs() {
  for _tl in governor_persist.log ram_expand.log profile_switches.log; do
    _tlf="/data/adb/asb/$_tl"
    [ -f "$_tlf" ] || continue
    _tln="$(wc -l < "$_tlf" 2>/dev/null)"
    case "$_tln" in ''|*[!0-9]*) continue ;; esac
    [ "$_tln" -ge 800 ] || continue
    if tail -n 400 "$_tlf" > "$_tlf.trim" 2>/dev/null && [ -s "$_tlf.trim" ]; then
      mv -f "$_tlf.trim" "$_tlf" 2>/dev/null || rm -f "$_tlf.trim" 2>/dev/null
    else
      rm -f "$_tlf.trim" 2>/dev/null
    fi
  done
}
asb_trim_logs
asb_probe_paths
asb_conflict_scan
asb_timeline_mark service_maintenance_complete

# ASB:CPU:BEGIN
KREL="$(uname -r 2>/dev/null)"
IS_WILD=0
echo "$KREL" | grep -qi "wild" && IS_WILD=1
cpu_present="$(cat /sys/devices/system/cpu/present 2>/dev/null | tr -d '\n')"
cpu_max="7"
case "$cpu_present" in
  *-*) cpu_max="${cpu_present##*-}" ;;
  *) cpu_max="$cpu_present" ;;
esac
[ -n "$cpu_max" ] || cpu_max="7"
N=$((cpu_max + 1))
_ref_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
_big_start="$N"
if [ -n "$_ref_freq" ]; then
  _i=1
  while [ $_i -le $cpu_max ]; do
    _f="$(cat /sys/devices/system/cpu/cpu${_i}/cpufreq/cpuinfo_max_freq 2>/dev/null)"
    if [ -n "$_f" ] && [ "$_f" != "$_ref_freq" ]; then
      _big_start=$_i
      break
    fi
    _i=$((_i + 1))
  done
fi
[ "$_big_start" -ge "$N" ] && _big_start=$((N / 2))
[ "$_big_start" -lt 2 ] && _big_start=2
little_end=$((_big_start - 1))
LITTLE_POLICY="/sys/devices/system/cpu/cpufreq/policy0"
BIG_POLICY="/sys/devices/system/cpu/cpufreq/policy${_big_start}"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n | tail -1)"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$LITTLE_POLICY"
# The camera guard (governor, src/asb_writer.h) raises the foreground/top-app cpuset, the
# uclamp.max ceilings and swappiness for as long as a capture is streaming, and it restores
# exactly what it found when the camera closes.
# Every runtime re-apply below has to stay off those knobs while it holds them - otherwise a
# profile switch mid recording writes the ceilings straight back down
# (apply_runtime_profile_now runs on EVERY switch, and again 10 s later in a background
# subshell), and worse, the guard then restores its pre-switch snapshot over the new profile's
# values and leaves the device on stale caps until the next switch.
asb_cam_guard_active() { [ -f /dev/.asb/camera_guard ]; }

apply_cpuset_groups() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  writef_retry /dev/cpuset/background/cpus        "0-${little_end}" 2 0.06 || true
  writef_retry /dev/cpuset/system-background/cpus "0-${little_end}" 2 0.06 || true
  if asb_cam_guard_active; then
    return 0
  fi
  if [ "$ASB_PROFILE" = "battery" ]; then
    writef_retry /dev/cpuset/foreground/cpus      "0-${little_end}" 2 0.06 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${little_end}" 2 0.06 || true
  else
    writef_retry /dev/cpuset/foreground/cpus      "0-${cpu_max}" 2 0.06 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${cpu_max}" 2 0.06 || true
  fi
}
apply_cpuset_groups_all() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  for _cg_root in /dev/cpuset /sys/fs/cgroup; do
    [ -d "$_cg_root" ] || continue
    _bg="0-${little_end}"
    _fg="0-${cpu_max}"
    if [ "$ASB_PROFILE" = "battery" ]; then
      _fg="0-${little_end}"
    fi
    for _grp in background system-background; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_bg" 2 0.06 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_bg" 2 0.06 || true
    done
    # Native camera guard owns foreground/top-app placement until it restores
    # its snapshot. Keep background economy, but do not overwrite the lease.
    asb_cam_guard_active && continue
    for _grp in foreground top-app; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_fg" 2 0.06 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_fg" 2 0.06 || true
    done
  done
}
apply_uclamp() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  writef_retry /dev/cpuctl/top-app/uclamp.latency_sensitive $_P_LATENCY_SENSITIVE 2 0.06 || true
  writef_retry /dev/cpuctl/background/cpu.uclamp.min        $_P_UCL_BG  2 0.06 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.min $_P_UCL_BG  2 0.06 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.min        $_P_UCL_FG 2 0.06 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.min           $_P_UCL_TOP 2 0.06 || true
  # uclamp.MIN above is a floor and never fights the guard, so it always applies.
  # The MAX ceilings below are exactly what the guard lifts - leave them alone.
  # The camera guard must not leave the ceilings unset.
  #
  # Returning here skips every uclamp.max write, which is right while the camera holds
  # its lease - deadline work must not be capped. But on a cold boot nothing has
  # written these nodes yet, and cpuctl defaults to 0: a diag taken shortly after boot
  # reads "top-app uclamp.max = 0.00", meaning the scheduler is told the foreground app
  # needs no CPU at all. That is the strongest possible throttle, applied by accident,
  # and it is the shape of "slow and hot for the first minutes after a reboot".
  #
  # Publish an unrestricted ceiling before stepping aside. 100 means "no limit", so the
  # camera keeps the free hand it needs and the nodes are never left at zero.
  if asb_cam_guard_active; then
    # Write the profile rail, not 100.
    #
    # 100 means no ceiling at all - higher than the profile ever asks for. A phone left
    # there runs hotter than intended and silently ignores the setting the user chose. The
    # only safe value to publish here is the one the normal path would write moments later.
    for _cg_e in "top-app:${UCL_TOP_MAX:-85}" "foreground:${UCL_FG_MAX:-70}" \
                 "background:${UCL_BG_MAX:-40}" "system-background:${UCL_BG_MAX:-40}"; do
      _cg_t="${_cg_e%%:*}"; _cg_v="${_cg_e##*:}"
      for _cg_n in "/dev/cpuctl/$_cg_t/cpu.uclamp.max" "/dev/cpuctl/$_cg_t/uclamp.max"; do
        [ -e "$_cg_n" ] || continue
        case "$(cat "$_cg_n" 2>/dev/null)" in
          0|0.00) writef_retry "$_cg_n" "$_cg_v" 2 0.06 || true ;;
        esac
      done
    done
    return 0
  fi
  _ucl_bg_max="${UCL_BG_MAX:-40}"
  _ucl_fg_max="${UCL_FG_MAX:-70}"
  _ucl_top_max="${UCL_TOP_MAX:-85}"
  writef_retry /dev/cpuctl/background/cpu.uclamp.max        $_ucl_bg_max 2 0.06 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.max $_ucl_bg_max 2 0.06 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.max        $_ucl_fg_max 2 0.06 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.max           $_ucl_top_max 2 0.06 || true
  writef_retry /dev/cpuctl/background/uclamp.min        $_P_UCL_BG  2 0.06 || true
  writef_retry /dev/cpuctl/system-background/uclamp.min $_P_UCL_BG  2 0.06 || true
  writef_retry /dev/cpuctl/foreground/uclamp.min        $_P_UCL_FG 2 0.06 || true
  writef_retry /dev/cpuctl/top-app/uclamp.min           $_P_UCL_TOP 2 0.06 || true
  for _cg_root in /sys/fs/cgroup /dev/cgroup; do
    [ -d "$_cg_root" ] || continue
    for _tier in background system-background foreground top-app; do
      _uval=$_P_UCL_BG
      [ "$_tier" = "foreground" ] && _uval=$_P_UCL_FG
      [ "$_tier" = "top-app" ]    && _uval=$_P_UCL_TOP
      _node="$_cg_root/$_tier/cpu.uclamp.min"
      [ -f "$_node" ] && writef_retry "$_node" "$_uval" 2 0.06 || true
      _mnode="$_cg_root/$_tier/cpu.uclamp.max"
      _mval=$_ucl_bg_max
      [ "$_tier" = "foreground" ] && _mval=$_ucl_fg_max
      [ "$_tier" = "top-app" ] && _mval=$_ucl_top_max
      [ -f "$_mnode" ] && writef_retry "$_mnode" "$_mval" 2 0.06 || true
    done
    _lat="$_cg_root/top-app/cpu.uclamp.latency_sensitive"
    [ -f "$_lat" ] && writef_retry "$_lat" $_P_LATENCY_SENSITIVE 2 0.06 || true
  done
}
# Fast boot policy: cgroup/uclamp/cpuset writes can wait for Android's own
# boot-completed gate. Their old retry loops occupied six seconds on OP15 before
# the first UI. Stock/vendor placement is safe until the post-boot core worker
# reapplies the same ASB policy; native governor dispatch is not delayed.
asb_feature_enabled CPU && asb_log "boot: CPU/cgroup policy deferred until boot_completed"
apply_cpugov_hints() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  _rate="${SCHED_RATE:-3000}"
  _up_rate="${SCHED_UP_RATE:-1200}"
  _down_rate="${SCHED_DOWN_RATE:-4000}"
  _hispeed="${SCHED_HISPEED_LOAD:-88}"
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    [ -w "$_pol/schedutil/rate_limit_us" ] && writef_retry "$_pol/schedutil/rate_limit_us" "$_rate" 2 0.06 || true
    [ -w "$_pol/schedutil/up_rate_limit_us" ] && writef_retry "$_pol/schedutil/up_rate_limit_us" "$_up_rate" 2 0.06 || true
    [ -w "$_pol/schedutil/down_rate_limit_us" ] && writef_retry "$_pol/schedutil/down_rate_limit_us" "$_down_rate" 2 0.06 || true
    [ -w "$_pol/schedutil/hispeed_load" ] && writef_retry "$_pol/schedutil/hispeed_load" "$_hispeed" 2 0.06 || true
    [ -w "$_pol/schedutil/hispeed_freq" ] && [ -n "$SCHED_HISPEED_FREQ" ] && writef_retry "$_pol/schedutil/hispeed_freq" "$SCHED_HISPEED_FREQ" 2 0.06 || true
  done
}
asb_feature_enabled CPU && asb_log "boot: CPU governor hints deferred until boot_completed"
asb_timeline_mark service_cpu_deferred
# ASB:CPU:END
if has pm; then
  if command -v asb_pm_disable >/dev/null 2>&1; then
    asb_pm_disable com.android.traceur
  else
    asb_pm_disable com.android.traceur
  fi
fi
# ASB:VM:BEGIN
apply_vm() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  asb_cam_guard_active || sysctlw vm.swappiness $_P_SWAP
  if [ -e /proc/sys/vm/dirty_bytes ] && [ -e /proc/sys/vm/dirty_background_bytes ]; then
    sysctlw vm.dirty_ratio 0
    sysctlw vm.dirty_background_ratio 0
    case "$ASB_PROFILE" in
      performance)
        sysctlw vm.dirty_bytes 33554432
        sysctlw vm.dirty_background_bytes 8388608 ;;
      battery)
        sysctlw vm.dirty_bytes 134217728
        sysctlw vm.dirty_background_bytes 33554432 ;;
      *)
        sysctlw vm.dirty_bytes 67108864
        sysctlw vm.dirty_background_bytes 16777216 ;;
    esac
  else
    case "$ASB_PROFILE" in
      performance) sysctlw vm.dirty_ratio 5; sysctlw vm.dirty_background_ratio 2 ;;
      battery) sysctlw vm.dirty_ratio 40; sysctlw vm.dirty_background_ratio 10 ;;
      *) sysctlw vm.dirty_ratio 20; sysctlw vm.dirty_background_ratio 5 ;;
    esac
  fi
  sysctlw vm.dirty_expire_centisecs $_P_DEXP
  sysctlw vm.dirty_writeback_centisecs $_P_DWB
  sysctlw vm.vfs_cache_pressure $_P_VFS

  if [ -e /proc/sys/vm/compaction_proactiveness ]; then
    case "$ASB_PROFILE" in
      performance) sysctlw vm.compaction_proactiveness 0 ;;
      battery)     sysctlw vm.compaction_proactiveness 20 ;;
      *)           sysctlw vm.compaction_proactiveness 10 ;;
    esac
  fi

  [ -w /sys/kernel/mm/lru_gen/enabled ] && echo 7 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null

  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval $_P_STATINT
  # VM_PAGE_CLUSTER belongs to the selected profile. Hardcoding another value here
  # silently overrode profile_core.sh (and made Battery apply 3 although its profile
  # explicitly requests 0), so use one source of truth for every apply path.
  case "${VM_PAGE_CLUSTER:-}" in
    ''|*[!0-9]*) asb_log "vm: profile has no valid VM_PAGE_CLUSTER; leaving kernel value unchanged" ;;
    *) writef_retry /proc/sys/vm/page-cluster "$VM_PAGE_CLUSTER" 1 0 || true ;;
  esac
  sysctlw vm.watermark_scale_factor $_P_WMARK
  sysctlw vm.min_free_kbytes $_P_MINFREE
  # Do not set vm.oom_kill_allocating_task=1 (see boot-time reset above): it
  if [ "$ASB_PROFILE" = "battery" ]; then
    [ -e /proc/sys/vm/drop_caches ] || true
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 1 || true
    [ -e /proc/sys/vm/block_dump ] && writef_retry /proc/sys/vm/block_dump 0 1 0 || true
  else
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 0 || true
  fi
}
asb_feature_enabled VM && asb_log "boot: VM policy deferred until boot_completed"
asb_timeline_mark service_vm_deferred
# ASB:VM:END
sysctl_try() {
  k="$1"; shift
  p="/proc/sys/$(echo "$k" | tr . /)"
  avail=""
  if [ "$k" = "net.ipv4.tcp_congestion_control" ] && [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  fi
  for v in "$@"; do
    if [ -n "$avail" ]; then
      echo "$avail" | grep -qw "$v" || continue
    fi
    if has sysctl; then
      sysctl -w "${k}=${v}" >/dev/null 2>&1 && return 0
    fi
    [ -e "$p" ] || return 0
    echo "$v" > "$p" 2>/dev/null && return 0
  done
  return 0
}
# ASB:NET:BEGIN

# Stock network values, captured once before anything is changed.
#
# "auto" used to mean "do not touch", and this function had already run by then - so auto
# reported bbr and fq_codel, which is what ASB set, not what the phone shipped with.
#
# "Stock" for this setting cannot be a number baked into the module: every SoC and every ROM
# trips at a different temperature, and 65 is only ASB's opening guess.
# Read the first passive trip point of the CPU thermal zone - that is what the vendor actually
# uses - so "сток" means this phone's value rather than a guess about phones in general.
asb_thermal_stock_capture() {
  _tsf="/data/adb/asb/thermal_stock"
  # current implementation adds type/provenance. Retain an already verified snapshot, but
  # replace legacy `SOURCE=trip_point` files that never proved the trip was passive.
  if [ -f "$_tsf" ]; then
    case "$(grep -E '^SOURCE=' "$_tsf" 2>/dev/null | head -1 | sed 's/.*=//')" in
      passive_trip_point|active_fallback|none) return 0 ;;
      *) rm -f "$_tsf" 2>/dev/null ;;
    esac
  fi
  mkdir -p /data/adb/asb 2>/dev/null
  _ts_best=""; _ts_zone=""; _ts_idx=""; _ts_type=""; _ts_raw=""
  _active_best=""; _active_zone=""; _active_idx=""; _active_raw=""
  for _tz in /sys/class/thermal/thermal_zone*; do
    [ -r "$_tz/type" ] || continue
    case "$(cat "$_tz/type" 2>/dev/null)" in
      *cpu*|*CPU*|*apc*|*silver*|*gold*) : ;;
      *) continue ;;
    esac
    for _tp in "$_tz"/trip_point_*_temp; do
      [ -r "$_tp" ] || continue
      _base="${_tp%_temp}"
      _typef="${_base}_type"
      [ -r "$_typef" ] || continue
      _tt="$(tr '[:upper:]' '[:lower:]' < "$_typef" 2>/dev/null | tr -d ' \r\n')"
      _raw="$(cat "$_tp" 2>/dev/null)"
      case "$_raw" in ''|*[!0-9]*) continue ;; esac
      _tv="$_raw"
      # Zones report millidegrees on almost everything, plain degrees on a few.
      [ "$_tv" -gt 1000 ] && _tv=$(( _tv / 1000 ))
      [ "$_tv" -lt 45 ] && continue
      [ "$_tv" -gt 80 ] && continue
      _zone="${_tz##*/}"
      _name="${_tp##*/}"; _idx="${_name#trip_point_}"; _idx="${_idx%_temp}"
      case "$_tt" in
        passive)
          if [ -z "$_ts_best" ] || [ "$_tv" -lt "$_ts_best" ]; then
            _ts_best="$_tv"; _ts_zone="$_zone"; _ts_idx="$_idx"; _ts_type="$_tt"; _ts_raw="$_raw"
          fi ;;
        active)
          # Keep a diagnostic candidate, but never represent it as a stock throttle point.
          if [ -z "$_active_best" ] || [ "$_tv" -lt "$_active_best" ]; then
            _active_best="$_tv"; _active_zone="$_zone"; _active_idx="$_idx"; _active_raw="$_raw"
          fi ;;
      esac
    done
  done
  if [ -n "$_ts_best" ]; then
    {
      printf 'STOCK_THERMAL=%s\nSOURCE=passive_trip_point\nZONE=%s\nINDEX=%s\nTYPE=%s\nRAW=%s\nRESOLVED=%s\n' \
        "$_ts_best" "$_ts_zone" "$_ts_idx" "$_ts_type" "$_ts_raw" "$_ts_best"
    } > "$_tsf" 2>/dev/null
    asb_log "thermal stock: ${_ts_best}C from passive ${_ts_zone}/trip_point_${_ts_idx}"
  elif [ -n "$_active_best" ]; then
    {
      printf 'STOCK_THERMAL=%s\nSOURCE=active_fallback\nZONE=%s\nINDEX=%s\nTYPE=active\nRAW=%s\nRESOLVED=%s\n' \
        "$_active_best" "$_active_zone" "$_active_idx" "$_active_raw" "$_active_best"
    } > "$_tsf" 2>/dev/null
    asb_log "thermal stock: passive trip unavailable; recorded active fallback for diagnostics only"
  else
    printf 'STOCK_THERMAL=65\nSOURCE=none\nZONE=\nINDEX=\nTYPE=\nRAW=\nRESOLVED=65\n' > "$_tsf" 2>/dev/null
    asb_log "thermal stock: no readable passive CPU trip point; leaving configured threshold unchanged"
  fi
}
asb_thermal_stock_capture

# Resolve the mode into the number the governor actually reads.
#
# The C side parses sustained_temp_enter as a temperature, so the mode cannot live in that key
# as a word.
# Writing it here, once per boot, means the governor never has to know modes exist.
# Is the configured throttle point reachable on THIS device?
#
# A static slider floor is a guess about hardware we have not seen. The governor compares
# the point against the hottest CPU zone, and those sit well above the shell: a OnePlus 15
# at rest reads 48C on the CPU with a 38C shell. A point at or below that means SUSTAINED
# is entered permanently - prime pinned around the clock, work stretched out, and the phone
# ends up hotter than with no module at all. That is the opposite of the setting's purpose,
# so it is worth measuring rather than assuming.
#
# Raised, not refused: the user asked for aggressive thermal behaviour and gets the most
# aggressive one that is still a threshold rather than a permanent state.
asb_thermal_sanity() {
  # Drop a floor written by an older build before recomputing.
  #
  # The previous version took the hottest CPU zone, which on a device with a few warm
  # sensors produced a floor of 70 - the top of the slider. The governor then raised the
  # user's chosen 60 to that, so the setting was overridden by its own safety check and
  # games ran to 72 C with throttle never engaging. A stale file would keep doing that
  # after the fix, because the floor is only rewritten when the new value is higher.
  rm -f /data/adb/asb/thermal_floor 2>/dev/null
  _ts_conf="$MODDIR/config/governor.conf"
  _ts_set="$(grep -E '^[[:space:]]*sustained_temp_enter=' "$_ts_conf" 2>/dev/null \
             | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_ts_set" in ''|*[!0-9]*) return 0 ;; esac
  _ts_idle=0
  _ts_list=""
  for _ts_z in /sys/class/thermal/thermal_zone*; do
    _ts_type="$(cat "$_ts_z/type" 2>/dev/null)"
    case "$_ts_type" in *cpu*|*CPU*) : ;; *) continue ;; esac
    # Trip points are not temperatures.
    #
    # cpu-hw-trip-0/1 match "*cpu*" and read a constant 95000 - they are the hardware
    # shutdown thresholds, not sensors. Two of them among twenty real zones dragged the
    # median up enough that the floor still came out at 70 after the median fix, which is
    # why the chosen 60 was still being overridden. The max rule was one bug; including
    # trip points was a second one underneath it.
    case "$_ts_type" in
      *trip*|*limit*|*shutdown*|*crit*|*alarm*) continue ;;
    esac
    _ts_v="$(cat "$_ts_z/temp" 2>/dev/null)"
    case "$_ts_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_ts_v" -gt 1000 ] && _ts_v=$(( _ts_v / 1000 ))
    [ "$_ts_v" -lt 20 ] && continue
    [ "$_ts_v" -gt 110 ] && continue
    # A zone reading above 85 while the phone is booting is not idle temperature either -
    # it is a constant, a fault, or a sensor for something that is not the CPU. Excluded
    # rather than trusted: this figure only exists to answer "what is normal here".
    [ "$_ts_v" -gt 85 ] && continue
    # Collect, do not maximise. Taking the hottest zone means one outlier - a package
    # sensor, or a core that just finished something - sets the floor for the whole phone.
    # On this device three zones read above 60 C while the rest sit at 43-44, and the max
    # rule turned a chosen threshold of 60 into a floor of 70: the highest the slider can
    # express, i.e. the setting was overridden completely by its own safety check.
    _ts_list="$_ts_list $_ts_v"
  done
  # Median, not maximum: it answers "what is this phone's normal temperature" rather than
  # "what is the hottest thing on it right now", which is the question this check needs.
  _ts_idle="$(printf '%s\n' $_ts_list | grep -E '^[0-9]+$' | sort -n \
              | awk '{a[NR]=$1} END{ if(NR) print a[int((NR+1)/2)] }')"
  _ts_n="$(printf '%s\n' $_ts_list | grep -cE '^[0-9]+$')"
  case "$_ts_idle" in ''|*[!0-9]*) _ts_idle=0 ;; esac
  [ "$_ts_idle" -gt 0 ] || return 0
  # Only trust a genuinely cool reading.
  #
  # This runs at boot, and boot is not idle: the phone has just powered up every core,
  # mounted partitions and started services. A capture taken after a reinstall shows a
  # median of 57 C, which produced a floor of 61 - above the user's chosen 60, so the
  # setting was overridden again, by a measurement of the wrong moment rather than the
  # wrong zones this time.
  #
  # Above 50 C the sample says nothing about what this device idles at, so no floor is
  # written at all. A missing floor means the user's threshold stands, which is the right
  # default: this check exists to catch a threshold set below idle temperature, and it can
  # only do that from an idle reading.
  if [ "$_ts_idle" -gt 50 ] 2>/dev/null; then
    rm -f /data/adb/asb/thermal_floor 2>/dev/null
    asb_log "thermal: boot-time median ${_ts_idle}C over ${_ts_n} zone(s) is too warm to be idle - no floor applied, your threshold stands"
    return 0
  fi
  _ts_min=$(( _ts_idle + 4 ))
  # Never above what the slider can express.
  #
  # The raise had no ceiling, so on a device whose CPU idles hot it produced values
  # outside the control's own range - a user set 55 and the card showed 109, which is
  # not a number they could ever have chosen or can now undo from the UI. The slider
  # tops out at 70; anything the sanity check wants above that is a sign the setting
  # cannot help on this device, not licence to invent a value.
  [ "$_ts_min" -gt 70 ] && _ts_min=70
  if [ "$_ts_set" -lt "$_ts_min" ]; then
    # Published as a runtime floor, not written into governor.conf.
    #
    # Editing the config made the card show a number the user never chose - a clean
    # install with the shipped 65 came back as 70 - and left no way to see that this
    # was a correction rather than their own setting. The governor and the writer read
    # this file and clamp against it; the config keeps saying what the user asked for.
    mkdir -p /data/adb/asb 2>/dev/null
    printf '%s\n' "$_ts_min" > /data/adb/asb/thermal_floor 2>/dev/null
    # Log the sample too, not just the verdict.
    #
    # The floor came out at 70 on a device whose visible zones sat at 40 C, and there was
    # no way to tell from the outside whether the median was wrong or the reading was -
    # this phone has 98 thermal zones and asbdiag prints a subset, so the numbers a human
    # can see are not the numbers this computed from. Two diagnoses were possible and the
    # log distinguished neither; now the sample size and the median are both recorded.
    asb_log "thermal: point ${_ts_set}C is at or below this device's own CPU temperature (median ${_ts_idle}C over ${_ts_n} zone(s)) - clamping to ${_ts_min}C at runtime, config left as chosen"
  else
    rm -f /data/adb/asb/thermal_floor 2>/dev/null
  fi
}

asb_thermal_mode_apply() {
  _tm="$(grep -E '^[[:space:]]*sustained_temp_mode=' "$MODDIR/config/governor.conf" 2>/dev/null \
         | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # Publish whether the slider outranks the per-profile presets.
  #
  # The C side reads sustained_temp_enter only for Battery unless this flag is set; on
  # Performance, Balanced and Smart the shipped preset wins. Manual means someone chose a
  # number on purpose, and that has to beat a default.
  _tm_ovr=0
  case "$_tm" in manual) _tm_ovr=1 ;; esac
  if [ -x "$MODDIR/runtime/asb_config_safe.sh" ]; then
    sh "$MODDIR/runtime/asb_config_safe.sh" set sustained_temp_user_override "$_tm_ovr" >/dev/null 2>&1 || \
      asb_log "config: could not atomically publish sustained_temp_user_override"
  fi

  # manual: the slider is the authority, full stop.
  #
  # This used to be the only guard, and the default mode is "smart" - so on every boot the
  # resolver rewrote sustained_temp_enter with the detected value and destroyed whatever the
  # user had set.
  # Reported exactly that way: "I set 55 and after a reboot it is 90 again".
  case "$_tm" in ''|manual) return 0 ;; esac
  # Smart resolves the device trip point, but not over a number the user chose.
  #
  # Reported as: set 55, reboot, it is 70. Both halves of this file rewrite
  # sustained_temp_enter on every boot - the sanity check raises it and this resolver
  # replaces it - so a deliberate choice survived exactly until the next restart. The
  # WebUI writes the slider and nothing recorded that it had been touched, so there
  # was no way to tell a user value from a leftover default.
  if [ -f /data/adb/asb/thermal_user_set ]; then
    asb_log "thermal mode=$_tm: user set the point by hand, leaving it alone"
    return 0
  fi
  _ts_source="$(grep -E '^SOURCE=' /data/adb/asb/thermal_stock 2>/dev/null \
               | head -1 | sed 's/.*=//' | tr -d ' \r')"
  if [ "$_ts_source" != "passive_trip_point" ]; then
    asb_log "thermal mode=$_tm: no passive stock trip (${_ts_source:-unknown}); leaving configured point unchanged"
    return 0
  fi
  _tsv="$(grep -E '^STOCK_THERMAL=' /data/adb/asb/thermal_stock 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_tsv" in ''|*[!0-9]*) return 0 ;; esac
  # Keep the written value inside the range the slider can express, or the card shows a
  # number its own control cannot reach - a slider capped at 70 displaying 90.
  [ "$_tsv" -lt 40 ] 2>/dev/null && _tsv=40
  [ "$_tsv" -gt 70 ] 2>/dev/null && _tsv=70
  _cur="$(grep -E '^[[:space:]]*sustained_temp_enter=' "$MODDIR/config/governor.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ "$_cur" = "$_tsv" ] && return 0
  if [ -x "$MODDIR/runtime/asb_config_safe.sh" ]; then
    sh "$MODDIR/runtime/asb_config_safe.sh" set sustained_temp_enter "$_tsv" >/dev/null 2>&1 || \
      { asb_log "config: rejected resolved sustained_temp_enter=$_tsv"; return 0; }
  fi
  # Smart lets the governor walk the point up from there; stock pins it.
  case "$_tm" in
    smart) _tceil=68 ;;
    *)     _tceil="$_tsv" ;;
  esac
  if [ -x "$MODDIR/runtime/asb_config_safe.sh" ]; then
    sh "$MODDIR/runtime/asb_config_safe.sh" set sustained_temp_ceiling "$_tceil" >/dev/null 2>&1 || \
      asb_log "config: could not atomically publish sustained_temp_ceiling=$_tceil"
  fi
  asb_log "thermal mode=$_tm -> enter=$_tsv ceiling=$_tceil (device trip point)"
}
asb_thermal_mode_apply
asb_thermal_sanity

asb_net_stock_capture() {
  _nsf="/data/adb/asb/net_stock.env"
  [ -f "$_nsf" ] && return 0
  mkdir -p /data/adb/asb 2>/dev/null
  {
    printf 'STOCK_TCP_CC=%s\n' "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    printf 'STOCK_QDISC=%s\n'  "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
  } > "$_nsf" 2>/dev/null
}
asb_net_stock_get() {
  # $1 = STOCK_TCP_CC | STOCK_QDISC
  grep -E "^$1=" /data/adb/asb/net_stock.env 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

apply_net() {
  asb_net_stock_capture

  # An explicit user choice wins, and "auto" means the captured stock value - not this
  # function's opinion. Only when neither exists does the old preference order apply.
  _u_cc="$(grep -E '^[[:space:]]*net_congestion=' "$MODDIR/config/governor.conf" 2>/dev/null \
           | head -1 | sed 's/.*=//' | tr -d ' \r')"
  _u_qd="$(grep -E '^[[:space:]]*net_qdisc=' "$MODDIR/config/governor.conf" 2>/dev/null \
           | head -1 | sed 's/.*=//' | tr -d ' \r')"

  case "$_u_qd" in
    ''|auto) _qd_want="$(asb_net_stock_get STOCK_QDISC)" ;;
    *)       _qd_want="$_u_qd" ;;
  esac
    # Same stand-down as congestion below: a per-link qdisc override is owned by
    # asb_net_apply.sh, which sets it per interface with tc.
    _pl_qd=0
    for _plk in net_qdisc_wifi net_qdisc_mobile; do
      _plv="$(grep -E "^[[:space:]]*$_plk=" "$MODDIR/config/governor.conf" 2>/dev/null \
              | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_plv" in ''|auto) : ;; *) _pl_qd=1 ;; esac
    done
    case "$_u_qd" in
      ''|auto)
        if [ "$_pl_qd" = "1" ]; then
          _qd_want=""
          asb_log "apply_net: per-link qdisc override present, global left alone"
        fi
        ;;
    esac
  if [ -n "$_qd_want" ]; then
    sysctlw net.core.default_qdisc "$_qd_want" 2>/dev/null \
      || sysctl_try net.core.default_qdisc fq_codel fq pfifo_fast
  else
    sysctl_try net.core.default_qdisc fq_codel fq pfifo_fast
  fi

  _cc_avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  case "$_u_cc" in
    ''|auto) _cc_want="$(asb_net_stock_get STOCK_TCP_CC)" ;;
    *)       _cc_want="$_u_cc" ;;
  esac
  # Stand down when a PER-LINK override exists.
  #
  # apply_net runs at boot and again on every reconcile, and it only knows the global key.
  _pl_set=0
  for _plk in net_congestion_wifi net_congestion_mobile; do
    _plv="$(grep -E "^[[:space:]]*$_plk=" "$MODDIR/config/governor.conf" 2>/dev/null \
            | head -1 | sed 's/.*=//' | tr -d ' \r')"
    case "$_plv" in ''|auto) : ;; *) _pl_set=1 ;; esac
  done
  case "$_u_cc" in
    ''|auto)
      if [ "$_pl_set" = "1" ]; then
        _cc_want=""
        asb_log "apply_net: per-link congestion override present, global left alone"
      fi
      ;;
  esac
  # Availability still decides: asking for bbr on a kernel without it would leave the
  # sysctl at whatever it was, and silently. Fall back in the documented order instead.
  if [ -n "$_cc_want" ] && { [ -z "$_cc_avail" ] || echo "$_cc_avail" | grep -qw "$_cc_want"; }; then
    sysctlw net.ipv4.tcp_congestion_control "$_cc_want"
    [ -e /proc/sys/net/ipv6/tcp_congestion_control ] \
      && sysctlw net.ipv6.tcp_congestion_control "$_cc_want"
  else
    sysctl_try net.ipv4.tcp_congestion_control cubic reno
    [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctl_try net.ipv6.tcp_congestion_control cubic reno
  fi
  case "$ASB_PROFILE" in
    performance) _pca=160; _pss=240 ;;
    battery)     _pca=80;  _pss=110 ;;
    *)           _pca=110; _pss=170 ;;
  esac
  sysctlw net.ipv4.tcp_pacing_ca_ratio $_pca
  sysctlw net.ipv4.tcp_pacing_ss_ratio $_pss
  [ -e /proc/sys/net/ipv6/tcp_ecn ] && sysctlw net.ipv6.tcp_ecn 0
  [ -e /proc/sys/net/ipv6/tcp_rmem ] && sysctlw net.ipv6.tcp_rmem "$_P_TCP_RMEM"
  [ -e /proc/sys/net/ipv6/tcp_wmem ] && sysctlw net.ipv6.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.ipv4.tcp_moderate_rcvbuf 1
  sysctlw net.ipv4.tcp_rmem "$_P_TCP_RMEM"
  sysctlw net.ipv4.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.core.rmem_max "$NET_RMEM_MAX"
  sysctlw net.core.wmem_max "$NET_WMEM_MAX"
  sysctlw net.core.optmem_max "$NET_OPTMEM_MAX"
  sysctlw net.ipv4.tcp_fastopen $_P_TCP_FASTOPEN
  sysctlw net.ipv4.tcp_sack 1
  sysctlw net.ipv4.tcp_dsack 1
  sysctlw net.ipv4.tcp_window_scaling 1
  sysctlw net.ipv4.tcp_timestamps 1
  sysctlw net.ipv4.tcp_ecn 0
  sysctlw net.ipv4.tcp_early_retrans 3
  [ -e /proc/sys/net/ipv4/tcp_notsent_lowat ] && sysctlw net.ipv4.tcp_notsent_lowat $_P_TCP_NOTSENT
  sysctlw net.ipv4.udp_rmem_min 65536
  sysctlw net.ipv4.udp_wmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_rmem_min ] && sysctlw net.ipv6.udp_rmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_wmem_min ] && sysctlw net.ipv6.udp_wmem_min 65536
  sysctlw net.ipv4.tcp_mtu_probing "$_P_TCP_MTU_PROBING"
  sysctlw net.ipv4.tcp_slow_start_after_idle 0
  sysctlw net.ipv4.tcp_recovery 1
  sysctlw net.ipv4.tcp_retrans_collapse 0
  sysctlw net.ipv4.tcp_max_orphans 8192
  sysctlw net.ipv4.tcp_rfc1337 1
  [ -n "$_P_UDP_MEM" ] && [ -e /proc/sys/net/ipv4/udp_mem ] && sysctlw net.ipv4.udp_mem "$_P_UDP_MEM"
  [ -n "$_P_HAPPY_EYEBALLS" ] && asb_settings_put system cloud_dns_happy_eyeballs_priority_enabled "$_P_HAPPY_EYEBALLS"
  sysctlw net.ipv4.tcp_keepalive_time   $_P_TCP_KEEPIDLE
  sysctlw net.ipv4.tcp_keepalive_intvl  75
  sysctlw net.ipv4.tcp_keepalive_probes 9
  sysctlw net.ipv4.tcp_fin_timeout          $_P_TCP_FIN
  sysctlw net.ipv4.tcp_no_metrics_save 1
  sysctlw net.core.somaxconn 512
  sysctlw net.ipv4.tcp_max_syn_backlog 2048
  sysctlw net.core.netdev_max_backlog $_P_NET_BACKLOG
  sysctlw net.core.netdev_budget $_P_NET_BUDGET
  sysctlw net.core.netdev_budget_usecs $_P_NET_BUDGET_US
  sysctlw net.core.dev_weight $_P_DEV_WEIGHT
  sysctlw net.core.bpf_jit_enable 1
  sysctlw net.core.bpf_jit_harden 0
  sysctlw net.core.bpf_jit_kallsyms 1
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_established 600
  [ -e /proc/sys/net/netfilter/nf_conntrack_buckets ] && \
  sysctlw net.netfilter.nf_conntrack_buckets 16384
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
  [ -e /proc/sys/net/netfilter/nf_conntrack_max ] && \
  sysctlw net.netfilter.nf_conntrack_max 65536
  [ -e /proc/sys/net/core/tstamp_allow_data ] && \
  sysctlw net.core.tstamp_allow_data 1
  sysctlw net.ipv4.ip_no_pmtu_disc 0
  sysctlw net.ipv4.tcp_syncookies 1
  sysctlw net.ipv4.tcp_rfc1337 1
  sysctlw net.ipv4.conf.all.rp_filter 0
  sysctlw net.ipv4.conf.default.rp_filter 0
  sysctlw net.ipv4.ip_nonlocal_bind 1
  [ -e /proc/sys/net/ipv6/ip_nonlocal_bind ] && sysctlw net.ipv6.ip_nonlocal_bind 1
  sysctlw net.ipv4.conf.all.accept_redirects 0
  sysctlw net.ipv4.conf.all.send_redirects 0
  sysctlw net.ipv4.conf.all.secure_redirects 0
  sysctlw net.ipv4.icmp_echo_ignore_broadcasts 1
  sysctlw net.ipv4.icmp_ignore_bogus_error_responses 1
  [ -e /proc/sys/net/ipv6/conf/all/accept_redirects ] && \
    sysctlw net.ipv6.conf.all.accept_redirects 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra ] && \
    sysctlw net.ipv6.conf.all.accept_ra 2
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.all.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/default/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.default.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/all/use_tempaddr ] && \
    sysctlw net.ipv6.conf.all.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/conf/default/use_tempaddr ] && \
    sysctlw net.ipv6.conf.default.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_anycast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_anycast 1
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_multicast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_multicast 1
  [ -e /proc/sys/net/ipv6/conf/all/proxy_ndp ] && \
    sysctlw net.ipv6.conf.all.proxy_ndp 1
  sysctlw net.ipv4.conf.all.accept_source_route 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_source_route ] && \
    sysctlw net.ipv6.conf.all.accept_source_route 0
  sysctlw net.ipv4.neigh.default.gc_thresh1 128
  sysctlw net.ipv4.neigh.default.gc_thresh2 512
  sysctlw net.ipv4.neigh.default.gc_thresh3 1024
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh1 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh1 128
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh2 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh2 512
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh3 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh3 1024
}
asb_feature_enabled NET && apply_net
asb_timeline_mark service_network_complete
# ASB:NET:END
apply_wifi_settings() {
  has settings || return 0
  asb_settings_put global nearby_scanning_enabled 0
  asb_settings_put global wifi_scan_throttle_enabled 1
  asb_settings_put global wifi_suspend_optimizations_enabled 1
  asb_settings_put global wifi_verbose_logging_enabled 0
}
# Deferred to post-boot: Settings/Wi-Fi service may not be ready during init.
asb_wifi_cc_heal() {
  # One-time heal: older versions ran `force-country-code enabled IT`, which
  if [ -f /data/adb/asb/wifi_cc_forced ]; then
    has cmd && cmd -w wifi force-country-code disabled >/dev/null 2>&1 || true
    rm -f /data/adb/asb/wifi_cc_forced 2>/dev/null || true
  fi
}
# Country heal is invoked by the post-boot connectivity stage below.

apply_wifi_country() {
  # Country from SIM then operator; only a confident 2-letter ISO code. We set
  _cc=""
  for _p in gsm.sim.operator.iso-country gsm.operator.iso-country; do
    _v="$(getprop "$_p" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    case "$_v" in [A-Z][A-Z]) _cc="$_v"; break ;; esac
  done
  [ -n "$WIFI_COUNTRY" ] && _cc="$WIFI_COUNTRY"   # explicit user override
  [ -n "$_cc" ] || return 0                        # none -> leave it to the modem

  has settings && {
    asb_settings_put global wifi_country_code "$_cc"
  }
}
# Deferred to post-boot: country policy belongs after framework readiness.
apply_wlan0_txqlen() {
  [ -e /sys/class/net/wlan0/tx_queue_len ] || return 0
  _want="${_P_WLAN_TXQLEN:-768}"
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  [ "$_txq" = "$_want" ] && return 0
  echo $_want > /sys/class/net/wlan0/tx_queue_len 2>/dev/null || true
  ip link set wlan0 txqueuelen $_want >/dev/null 2>&1 || true
}
# Deferred to post-boot: wlan0 may not be published yet.
netif_oper_upish() {
  _if="$1"
  [ -n "$_if" ] || return 1
  [ -r "/sys/class/net/$_if/operstate" ] || return 0
  _st="$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)"
  case "$_st" in
    up|dormant|unknown) return 0 ;;
  esac
  return 1
}
netif_carrier_upish() {
  _if="$1"
  [ -n "$_if" ] || return 0
  [ -r "/sys/class/net/$_if/carrier" ] || return 0
  [ "$(cat "/sys/class/net/$_if/carrier" 2>/dev/null)" = "1" ]
}
netif_qdisc_kind() {
  _if="$1"
  has tc || return 1
  [ -n "$_if" ] || return 1
  tc qdisc show dev "$_if" 2>/dev/null | awk 'NR==1{print $2}'
}
apply_netif_qdisc() {
  _if="$1"
  has tc || return 0
  [ -n "$_if" ] || return 0
  ip link show "$_if" >/dev/null 2>&1 || return 0
  netif_oper_upish "$_if" || return 0
  netif_carrier_upish "$_if" || return 0
  _qk="$(netif_qdisc_kind "$_if")"
  case "$_qk" in
    fq_codel|fq) return 0 ;;
    mq)
      tc qdisc show dev "$_if" 2>/dev/null | while read -r line; do
        _parent="$(echo "$line" | grep -oE 'parent [0-9a-f]+:[0-9a-f]+' | awk '{print $2}')"
        [ -n "$_parent" ] || continue
        tc qdisc replace dev "$_if" parent "$_parent" fq_codel >/dev/null 2>&1 || true
      done
      return 0
      ;;
  esac
  tc qdisc replace dev "$_if" root fq_codel >/dev/null 2>&1 || \
    tc qdisc replace dev "$_if" root fq >/dev/null 2>&1 || true
}
apply_wlan0_qdisc() {
  if has tc && ip link show wlan0 >/dev/null 2>&1; then
    if [ "$ASB_PROFILE" = "performance" ]; then
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    else
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    fi
  fi
}
apply_mobile_qdisc() {
  for _dev in /sys/class/net/*; do
    [ -e "$_dev" ] || continue
    _if="${_dev##*/}"
    case "$_if" in
      rmnet*|ccmni*)
        if has tc; then
          tc qdisc replace dev "$_if" root "$_P_QDISC" >/dev/null 2>&1 || apply_netif_qdisc "$_if"
        else
          apply_netif_qdisc "$_if"
        fi ;;

    esac
  done
}
# Qdisc setup is deferred to post-boot connectivity.
# ASB:WIFI:BEGIN
apply_wifi_pm() {
  wait_path /sys/class/net/wlan0 10 || return 0
  _wt=0
  while [ $_wt -lt 15 ]; do
    _wst="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$_wst" in up|dormant|unknown) break ;; esac
    sleep 1
    _wt=$((_wt+1))
  done
  case "$_P_WLAN_PM" in
    0)
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 0 2 0.06 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 0
      asb_persist_safe persist.vendor.wlan.powersave 0
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 0 2 0.06 || true
      ;;
    1)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 2 0.06 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 1
      asb_persist_safe persist.vendor.wlan.powersave 1
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 1 2 0.06 || true
      ;;
    *)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 2 0.06 || true
      asb_persist_safe persist.vendor.wlan.scan_throttle 1
      ;;
  esac
}
# Deferred to post-boot: this function waits for wlan0/operstate.
apply_wifi_dtim() {
  asb_has_risky_vendor_stack && return 0
  case "$ASB_PROFILE" in
    battery) iw dev wlan0 set listen-interval 10 >/dev/null 2>&1 || true ;;
    performance) iw dev wlan0 set listen-interval 2 >/dev/null 2>&1 || true ;;
    *) iw dev wlan0 set listen-interval 4 >/dev/null 2>&1 || true ;;
  esac
  writef_retry /sys/module/wlan/parameters/enable_connected_scan_result 0 2 0.06 || true
}
# Deferred to post-boot with the Wi-Fi power policy.
apply_net_steering() {
  for q in /sys/class/net/wlan0/queues/rx-* /sys/class/net/rmnet*/queues/rx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/rps_cpus" ] && echo fc > "$q/rps_cpus" 2>/dev/null || true
  done
  for q in /sys/class/net/wlan0/queues/tx-* /sys/class/net/rmnet*/queues/tx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/xps_cpus" ] && echo fc > "$q/xps_cpus" 2>/dev/null || true
  done
}
# Deferred to post-boot after network links exist.

# ASB:WIFI:END
# This retry can wait up to two minutes for a link. It is callable from the post-boot
# worker only, never launched during the init/service startup path.
asb_wifi_link_reassert() {
  # Only one post-boot reassert may own wlan0 at a time.  The old 120-second wait could leave
  # multiple delayed workers alive across profile/reconcile changes, each rewriting qdisc later.
  _lock="/data/adb/asb/wifi_reassert.lock"
  mkdir -p /data/adb/asb 2>/dev/null || return 0
  mkdir "$_lock" 2>/dev/null || { asb_log "wifi reassert: already running"; return 0; }
  trap 'rmdir "$_lock" 2>/dev/null || true' EXIT INT TERM

  _skip_wlan_wait=0
  if has settings; then
    _wifi_on="$(settings get global wifi_on 2>/dev/null)"
    case "$_wifi_on" in 0|disabled|false) _skip_wlan_wait=1 ;; esac
  fi
  [ "$_skip_wlan_wait" = "1" ] && return 0
  # No wlan0 after ten seconds means Wi-Fi is intentionally absent/down on this boot; do not
  # retain a two-minute sleeper solely to retry a non-critical queue policy.
  wait_path /sys/class/net/wlan0 10 || { asb_log "wifi reassert: wlan0 unavailable"; return 0; }
  t=0
  while [ "$t" -lt 30 ]; do
    st="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$st" in up|dormant) break ;; esac
    sleep 2
    t=$((t+2))
  done
  case "${st:-}" in up|dormant) ;; *) asb_log "wifi reassert: link not ready after ${t}s"; return 0 ;; esac
  asb_feature_enabled WIFI && apply_wlan0_txqlen
  asb_feature_enabled WIFI && apply_wlan0_qdisc
  q="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  [ "$q" = "${_P_WLAN_TXQLEN:-1024}" ] || asb_log "wifi reassert: queue policy not accepted"
}
# ASB:GPS:BEGIN
apply_gps_hygiene() {
  has settings || return 0
  asb_settings_put global assisted_gps_enabled 1
  asb_settings_put global gps_xtra_server "https://xtra3.gpsonextra.net/xtra3grc.bin"
  asb_settings_put global gps_xtra_server_1 "https://xtra2.gpsonextra.net/xtra2.bin"
  asb_settings_put global gps_xtra_server_2 "https://xtra1.gpsonextra.net/xtra.bin"
  asb_settings_put global ntp_server time.google.com
  asb_settings_put global ntp_server_2 ntp1.inrim.it
  asb_settings_put global ntp_server_3 0.it.pool.ntp.org
  asb_settings_put global ntp_server_4 1.it.pool.ntp.org
}
# GPS settings are applied with deferred connectivity after boot completion.
asb_timeline_mark service_connectivity_complete
# ASB:GPS:END
# ASB:AUDIO:BEGIN
apply_audio_runtime() {
  if [ "${AUDIO_EQ_COMPAT:-0}" = "1" ]; then
    setprop ro.audio.bt.connect.disable.mute true 2>/dev/null || true
    asb_persist_safe persist.audio.uhqa 0
    asb_persist_safe persist.vendor.audio.uhqa false
    setprop af.resampler.quality 0 2>/dev/null || true
    return
  fi
  asb_persist_safe persist.audio.hifi.int_codec true
  asb_persist_safe persist.vendor.audio.hifi.int_codec true
  setprop ro.audio.bt.connect.disable.mute true 2>/dev/null || true
  asb_persist_safe persist.vendor.audio.aec_ref.enable false
  setprop vendor.audio.feature.aec_ref.enable false 2>/dev/null || true

  if [ "${AUDIO_AGGRESSIVE:-0}" = "1" ]; then
    setprop ro.audio.hifi true 2>/dev/null || true
    setprop ro.vendor.audio.hifi true 2>/dev/null || true
    asb_persist_safe persist.audio.hifi true
    asb_persist_safe persist.vendor.audio.hifi true
    asb_persist_safe persist.audio.uhqa 1
    asb_persist_safe persist.vendor.audio.uhqa true
    asb_persist_safe persist.vendor.audio.power.save.setting 1
    # 255 is outside the platform enum and is silently rejected on current OPlus audio
    # stacks. Keep DEFAULT (0), which is the same validated policy as asb_audio_apply.sh.
    setprop af.resampler.quality 0 2>/dev/null || true
    setprop audio.offload.min.duration.secs 20 2>/dev/null || true
    setprop vendor.audio.offload.min.duration.secs 20 2>/dev/null || true
    setprop audio.offload.buffer.size.kb 256 2>/dev/null || true
    setprop vendor.audio.offload.buffer.size.kb 256 2>/dev/null || true
  fi
}
# AUDIO=1 exposes manual WebUI controls; it is not consent to rewrite the audio HAL on every
# boot.  A user action records audio_user_policy_enabled and is restored later, after Android is
# ready, through asb_audio_apply.sh in no-restart mode.
if asb_audio_boot_policy_enabled; then
  asb_log "audio runtime: explicit user policy deferred until boot_completed"
else
  asb_log "audio runtime: default ROM policy retained (no WebUI audio intent)"
fi
# ASB:AUDIO:END
# These legacy deletions alter audio HAL policy and therefore follow the same
# explicit AUDIO/device-pack gate as the runtime audio configuration.
# Do not delete HAL suspend policy automatically.  It affects power/call routing and must be
# left to the ROM unless a dedicated, reversible user action is implemented with a baseline.
# ASB:BG_TRIM:BEGIN

_BG_TRIM_NEVER="
com.android.systemui
com.android.bluetooth
com.google.android.bluetooth
com.android.server.telecom
com.android.launcher3
net.oneplus.launcher
com.oneplus.launcher
com.android.inputmethod.latin
com.google.android.inputmethod.latin
com.touchtype.swiftkey
com.android.dialer
com.google.android.dialer
com.oneplus.camera
com.oplus.camera
com.android.camera2
com.google.android.apps.maps
com.waze
"

_BG_TRIM_MESSENGER="
com.whatsapp
org.telegram.messenger
org.thunderdog.challegram
com.viber.voip
com.facebook.orca
com.facebook.mlite
com.discord
com.signal.android
org.thoughtcrime.securesms
com.skype.raider
com.tencent.mm
com.microsoft.teams
"

_BG_TRIM_RECENT_WORKSET="
com.adobe.lrmobile
com.adobe.photoshopmix
com.android.gallery3d
com.coloros.gallery3d
com.oneplus.gallery
com.google.android.apps.photos
com.spotify.music
com.aspiro.tidal
com.deezer.android.app
com.google.android.youtube.music
"

_BG_TRIM_HEAVY="
com.facebook.katana
com.instagram.android
com.snapchat.android
com.zhiliaoapp.musically
com.ss.android.ugc.trill
com.netflix.mediaclient
com.amazon.mShop.android.shopping
com.aliexpress.buyer
com.heytap.htms
com.heytap.pictorial
com.heytap.market
"

_BG_TRIM_DISABLE="
com.oplus.midas
com.oplus.olc
com.oplus.crashbox
com.oplus.logkit
"

asb_bg_trim_is_top() {
  local _pkg="$1"
  local _top
  _top=$(dumpsys activity activities 2>/dev/null \
    | grep -m1 'topResumedActivity\|mResumedActivity' \
    | grep -oE '[a-z][a-z0-9_.]+/[a-zA-Z0-9_.$]+' \
    | head -1 | cut -d/ -f1)
  [ "$_top" = "$_pkg" ]
}

asb_bg_trim_screen_off() {
  local _state
  _state=$(dumpsys power 2>/dev/null \
    | grep -m1 'mWakefulness=' | cut -d= -f2)
  case "$_state" in
    Asleep|Dozing) return 0 ;;
    *) return 1 ;;
  esac
}

asb_bg_trim_pkg() {
  local _pkg="$1" _level="$2"
  asb_bg_trim_is_top "$_pkg" && return 0
  local _pids
  _pids=$(pidof "$_pkg" 2>/dev/null)
  _pids="$_pids $(ps -A -o PID,NAME 2>/dev/null | awk -v p="$_pkg" \
    '$2==p || index($2, p":")==1 {print $1}' | tr '\n' ' ')"
  _pids=$(echo "$_pids" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
  [ -z "$_pids" ] && return 0
  local _pid
  for _pid in $_pids; do
    [ "$_pid" -gt 100 ] 2>/dev/null && \
      am send-trim-memory --user 0 "$_pid" "$_level" >/dev/null 2>&1
  done
}

asb_bg_trim_apply_buckets() {
  local _p
  for _p in $_BG_TRIM_MESSENGER; do
    am set-standby-bucket "$_p" active >/dev/null 2>&1 || true
  done
  for _p in $_BG_TRIM_RECENT_WORKSET; do
    am set-standby-bucket "$_p" working_set >/dev/null 2>&1 || true
  done
  for _p in $_BG_TRIM_HEAVY; do
    am set-standby-bucket "$_p" rare >/dev/null 2>&1 || true
  done
}

asb_bg_trim_apply_memcg() {
  [ -d /sys/fs/cgroup ] || return 0
  [ -e /sys/fs/cgroup/cgroup.controllers ] || return 0

  local _pkg _uid _path
  for _pkg in $_BG_TRIM_NEVER $_BG_TRIM_MESSENGER; do
    _uid=$(dumpsys package "$_pkg" 2>/dev/null \
      | grep -m1 'userId=' | cut -d= -f2 | tr -d ' ')
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    _path=/sys/fs/cgroup/uid_${_uid}
    [ -d "$_path" ] || continue
    [ -w "$_path/memory.low" ] && echo 67108864 > "$_path/memory.low" 2>/dev/null
  done

  for _pkg in $_BG_TRIM_HEAVY; do
    _uid=$(dumpsys package "$_pkg" 2>/dev/null \
      | grep -m1 'userId=' | cut -d= -f2 | tr -d ' ')
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    _path=/sys/fs/cgroup/uid_${_uid}
    [ -d "$_path" ] || continue
    [ -w "$_path/memory.high" ] && echo 268435456 > "$_path/memory.high" 2>/dev/null
  done
}

asb_bg_trim_oplus_tune() {
  :
}

asb_bg_trim_gms_wakelock_throttle() {
  has cmd || return 0
  # Stand aside when the user owns this decision.
  #
  # This function and runtime/asb_gms_trim.sh write the same appops. Today the ordering
  # saves us - the runtime script runs later in this file and wins - but that is a
  # coincidence of line numbers, not a design: moving either call would silently undo the
  # user's choice on every boot, and the symptom would be "strict works until I reboot".
  # An explicit check costs one line and cannot be broken by reordering.
  _gms_own="$(grep -E '^[[:space:]]*gms_trim=' "$MODDIR/config/governor.conf" 2>/dev/null \
              | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_gms_own" in
    lite|strict)
      asb_log "bg_trim: gms_trim=${_gms_own} owns the GMS appops, skipping the profile defaults"
      return 0 ;;
  esac
  cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set com.google.android.gms WAKE_LOCK allow             >/dev/null 2>&1 || true
  cmd appops set com.google.android.googlequicksearchbox RUN_IN_BACKGROUND ignore >/dev/null 2>&1 || true
  cmd appops set com.google.android.gms PSEUDO_LOCATION_REPORTING ignore >/dev/null 2>&1 || true
  am set-standby-bucket com.google.android.gms working_set >/dev/null 2>&1 || true
  am set-standby-bucket com.google.android.googlequicksearchbox rare >/dev/null 2>&1 || true
  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put global location_background_throttle_interval_ms 1800000
    asb_settings_put global location_background_throttle_proximity_alert_interval_ms 1800000
    # Full-day OP15 logs showed GMS activity-recognition (the ALARM_WAKEUP_ACTIVITY_DETECTION
    # alarm) as a top idle wakeup source — second only to AOD.
    asb_settings_put global activity_recognition_mode 0
    asb_settings_put global gms_activity_recognition_interval_ms 1800000
  fi
}

asb_bg_trim_reclaim_once() {
  local _p
  for _p in $_BG_TRIM_HEAVY; do
    asb_bg_trim_pkg "$_p" 40
  done
  if asb_bg_trim_screen_off; then
    for _p in $_BG_TRIM_RECENT_WORKSET; do
      asb_bg_trim_pkg "$_p" 20
    done
  fi
}

apply_bg_trim_runtime() {
  local _bg_level="${BG_TRIM_LEVEL:-safe}"

  # off means do nothing at all.
  #
  # The card offered safe and aggressive only, so the mildest choice available still
  # rewrote app standby buckets and memory.low/high - there was no way to say "leave my
  # background apps alone" short of turning off the whole BG_TRIM feature, which is not
  # in the WebUI. A user who wants ASB for its CPU and thermal work had no opt-out.
  if [ "$_bg_level" = "off" ]; then
    # Hand the buckets back before stepping away.
    #
    # Stopping here without undoing anything would leave every app ASB had moved to rare
    # or working_set sitting there, and Android does not promote a bucket on its own
    # schedule fast enough to notice. uninstall.sh already restores them to active for the
    # same reason, so this mirrors that path.
    #
    # active is where an unmanaged app sits; the scheduler demotes it again on its own if
    # the app really is idle.
    if command -v am >/dev/null 2>&1 && command -v pm >/dev/null 2>&1; then
      for _bgp in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
        [ -n "$_bgp" ] || continue
        am set-standby-bucket "$_bgp" active >/dev/null 2>&1 || true
      done
    fi
    asb_log "bg_trim: off - background apps left exactly as Android manages them"
    return 0
  fi

  # "safe" must be genuinely non-disruptive.  Before this guard, the same package disables,
  # vendor-service stops and Wi-Fi switches ran for *every* level; only the six-hour loop was
  # conditional.  That made a safe profile behave as aggressive and could provoke service
  # restarts precisely while Android was finishing a boot.
  if [ "$_bg_level" != "aggressive" ]; then
    asb_bg_trim_apply_buckets
    asb_bg_trim_apply_memcg
    asb_log "bg_trim: level=$_bg_level (non-disruptive)"
    return 0
  fi

  # Package disabling, service stops and forced Wi-Fi discovery changes are not a normal
  # battery optimisation: they can delay notifications, trigger vendor restart loops and make a
  # userspace reboot visibly slower.  Keep the legacy aggressive path available only after an
  # explicit local opt-in, never merely because an old preserved config says "aggressive".
  if [ ! -f /data/adb/asb/allow_disruptive_bg_trim ]; then
    asb_bg_trim_apply_buckets
    asb_bg_trim_apply_memcg
    asb_log "bg_trim: aggressive disruptive actions skipped (create /data/adb/asb/allow_disruptive_bg_trim to opt in)"
    return 0
  fi

  local _p
  for _p in $_BG_TRIM_DISABLE; do
    if command -v asb_pm_disable >/dev/null 2>&1; then
      asb_pm_disable "$_p"
    else
      pm disable-user --user 0 "$_p" >/dev/null 2>&1 || true
    fi
  done

  stop vendor.oplus.hardware.cammidasservice-V1-service >/dev/null 2>&1 || true
  stop vendor.oplus.hardware.olc2-V3-service           >/dev/null 2>&1 || true

  # Stop debug/crash-dump/telemetry daemons that run in the background but serve no purpose on
  # a user's daily driver.
  for _svc in minidump minidump32 minidump64 qseelogd wlanramdumpcollector \
              mqsasd bootstat poweroff_charger_log mtdoopslog ostatsd \
              charge_logger cnss_diag tcpdump; do
    stop "$_svc" >/dev/null 2>&1 || true
  done

  if command -v asb_settings_put >/dev/null 2>&1; then
    asb_settings_put global wifi_scan_always_enabled 0
    asb_settings_put global wifi_wakeup_enabled 0
  else
    asb_settings_put global wifi_scan_always_enabled 0
    asb_settings_put global wifi_wakeup_enabled 0
  fi

  asb_bg_trim_oplus_tune
  asb_bg_trim_gms_wakelock_throttle
  asb_bg_trim_apply_buckets
  asb_bg_trim_apply_memcg
  asb_log "bg_trim: level=$_bg_level (disruptive opt-in)"

  ( sleep 30; asb_bg_trim_reclaim_once ) >/dev/null 2>&1 &
  (
    while : ; do
      sleep 21600
      asb_bg_trim_apply_buckets >/dev/null 2>&1
      if asb_bg_trim_screen_off; then
        asb_bg_trim_reclaim_once >/dev/null 2>&1
      fi
    done
  ) >/dev/null 2>&1 &
}

# BG_TRIM contains package-manager, app-standby, cgroup lookup and vendor-service work.
# It must not run before Android reports boot complete: on the OP15 this entire synchronous
# service interval was 48 seconds after a restored aggressive configuration. The same function
# is invoked from the detached post-boot worker below, preserving every user-selected policy
# without making init/framework startup wait behind it.
asb_feature_enabled BG_TRIM && asb_log "bg_trim: deferred until boot_completed"
asb_timeline_mark service_bgtrim_deferred

# ASB:BG_TRIM:END
apply_bt_runtime() {
  asb_persist_safe persist.bluetooth.a2dp_offload.disabled false
  asb_persist_safe persist.vendor.bluetooth.a2dp_offload.disabled false
  asb_persist_safe persist.bluetooth.a2dp.optional_codecs_enabled 1
  asb_persist_safe persist.vendor.bt.enable.swb true
  asb_persist_safe persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled true
  # LE Audio is deliberately NOT forced on here, to stay consistent with system.prop (which had
  # the LE Audio / profile / class_of_device forces removed to fix classic-BLE watch pairing —
  # Amazfit / T-Rex Ultra 2 via Zepp).
  # It is dropped anyway so the module never re-forces LE Audio from any layer.
}
asb_bt_policy_enabled && apply_bt_runtime
apply_camera_props_static() {
  # Camera prop layer. IMPORTANT REVERSAL: the known-good debug module that has
  _cp_plat="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_cp_plat" ] && _cp_plat="$(getprop ro.hardware.chipname 2>/dev/null)"
  has resetprop || return 0
  resetprop -n persist.camera.tnr.preview 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.tnr.video 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.tnr_cds 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.preview 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr.video 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.tnr_cds 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.snapshot.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.preview.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.dual_camera_sat 1 >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.bt.record.support true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.loopback.support true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.audio.camera.videorecord.gain true >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n ro.camera.disableHeicUltraHDR false >/dev/null 2>&1 || true
  resetprop -n persist.camera.dcrf.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.isp.ltm_disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.jpeg.dumpqtable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.jpeg_burst 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.llnoise 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.ltmforseemore 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.max_prev.enable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.maxgain.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.llnoise 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.maxgain.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.ltmforseemore 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  resetprop -n persist.camera.tn.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.video.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.sys.camera.cameraservice.micompactmemory.enable true >/dev/null 2>&1 || true
  resetprop -n persist.sys.camera.ubwc.enabled 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.dual_camera_sat 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.preview.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.snapshot.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.video.ubwc 1 >/dev/null 2>&1 || true
  resetprop -n ro.camera.disableJpegR false >/dev/null 2>&1 || true
  resetprop -n ro.camera.enableCompositeAPI0JpegR true >/dev/null 2>&1 || true
  resetprop -n ro.vendor.camera.use_srgb_gamma true >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.hfr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.video.hdr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.camera.global.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mct.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.sensor.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.iface.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.isp.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.af.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.aec.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.awb.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.asd.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.afd.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.q3a.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.is.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.stats.haf.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.pproc.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.cpp.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.c2d.debug.mask 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.imglib.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.mmstill.logs 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.debug.enable 0 >/dev/null 2>&1 || true
  resetprop -n persist.camera.kpi.debug 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.cpp.duplicate_strip_dump 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.cpp.zoom.opt 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.disable 0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.fdvideo 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.opt_mode.video 2 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.smyuv.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.raw.zsl.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.zsl.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.multiframe.nr.enable 1 >/dev/null 2>&1 || true
  resetprop -n ro.camerax.extensions.enabled true >/dev/null 2>&1 || true
  resetprop -n vendor.camera.algo.jpeghwdecode 1 >/dev/null 2>&1 || true
  resetprop -n vendor.camera.algo.jpeghwencode 1 >/dev/null 2>&1 || true
  resetprop -n vendor.camera.picturesize.limit.enable false >/dev/null 2>&1 || true
  asb_log "camera props: applied static set (81 props)"
}
if asb_feature_enabled CAMERA && command -v asb_device_pack_allows >/dev/null 2>&1 && asb_device_pack_allows camera; then
  apply_camera_props_static
else
  asb_log "camera static: skipped on generic/unvalidated device pack"
fi

apply_camera_runtime() {
  # Base camera props — safe on every device. The proven-working OP12 build set
  asb_persist_safe persist.camera.tnr.preview 1
  asb_persist_safe persist.camera.tnr.video 1
  asb_persist_safe persist.vendor.camera.hdr.enable 1
  asb_persist_safe persist.vendor.camera.eis.enable 1
  # OP15 (canoe) ONLY: video HDR, 4K60 EIS, Hasselblad/Explorer are OnePlus 15
  _cam_soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_cam_soc" ] && _cam_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_cam_soc" in
    canoe|sm8850*)
      asb_persist_safe persist.vendor.camera.video.hdr.enable 1
      asb_persist_safe persist.vendor.camera.video.4k60.eis.enable 1
      if has resetprop; then
        resetprop -n ro.vendor.oplus.camera.isSupportExplorer 1 >/dev/null 2>&1 || true
        resetprop -n ro.vendor.oplus.camera.isHasselbladCamera 1 >/dev/null 2>&1 || true
      fi
      ;;
  esac
}
if asb_feature_enabled CAMERA && command -v asb_device_pack_allows >/dev/null 2>&1 && asb_device_pack_allows camera; then
  apply_camera_runtime
fi
tune_io_queues() {
  for _b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
    [ -d "$_b/queue" ] || continue
    [ -r "$_b/queue/rotational" ] && [ "$(cat "$_b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$_b/queue/iostats" 0
    writef "$_b/queue/add_random" 0
    writef "$_b/queue/rq_affinity" 2
    case "$ASB_PROFILE" in
      performance)
        writef "$_b/queue/read_ahead_kb" 512
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 256 || true ;;
      battery)
        writef "$_b/queue/read_ahead_kb" 64
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 64 || true ;;
      *)
        writef "$_b/queue/read_ahead_kb" 128
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 128 || true ;;
    esac
  done
}
# ASB:KERNEL:BEGIN
apply_kernel() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  sysctlw kernel.perf_cpu_time_max_percent 25
  sysctlw kernel.sched_schedstats 0
  sysctlw kernel.timer_migration 0
  sysctlw kernel.panic 0
  sysctlw kernel.panic_on_oops 0
  sysctlw vm.panic_on_oom 0
  [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  writef_retry /proc/sys/kernel/printk_devkmsg off 1 0 || true
  writef_retry /proc/sys/kernel/printk "3 4 1 7" 1 0 || true
  [ -e /proc/sys/kernel/printk_ratelimit ] && \
    sysctlw kernel.printk_ratelimit 1
  [ -e /proc/sys/kernel/printk_ratelimit_burst ] && \
    sysctlw kernel.printk_ratelimit_burst 5
  [ -e /proc/sys/vm/oom_dump_tasks ] && sysctlw vm.oom_dump_tasks 0
  [ -e /proc/sys/debug/exception-trace ] && \
    writef_retry /proc/sys/debug/exception-trace 0 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && \
    writef_retry /proc/sys/walt/sched_boost 0 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && \
    writef_retry /proc/sys/walt/sched_idle_enough $_P_IDLE 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && \
    writef_retry /proc/sys/walt/sched_idle_enough_clust "$_P_IDLEC" 1 0 || true
  # NOTE: per-cluster scaling_min_freq is now set inside apply_cpufreq_caps
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct $_P_CLUT 1 0 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$_P_CLUTC" 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation $_P_COLOC 1 0 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns $_P_BHYST 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost $_P_SBOOST 1 0 || true
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks $_P_RAVG 2 0.06 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres $_P_PIPE 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres $_P_PIPEN 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres $_P_PIPES 1 0 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost $_P_EDB 1 0 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct $_P_TOPW 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost $_P_MINTB 1 0 || true
  case "$ASB_PROFILE" in
    battery)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 2 || true
      [ -e /proc/sys/kernel/hrtimer_migration ] && writef_retry /proc/sys/kernel/hrtimer_migration 0 1 0 || true
      [ -e /proc/sys/kernel/timer_migration ] && sysctlw kernel.timer_migration 0 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 1 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 1 1 0 || true
      writef /sys/module/lpm_levels/parameters/sleep_disabled 0 || true
      [ -e /sys/module/lpm_levels/parameters/lpm_prediction ] &&         writef /sys/module/lpm_levels/parameters/lpm_prediction 1 || true
      [ -e /sys/module/printk/parameters/console_suspend ] && writef /sys/module/printk/parameters/console_suspend Y || true
      [ -e /proc/sys/kernel/printk_devkmsg ] && writef /proc/sys/kernel/printk_devkmsg ratelimit || true
      [ -e /proc/sys/vm/laptop_mode ] && writef /proc/sys/vm/laptop_mode 5 || true
      [ -e /sys/module/wakelock/parameters/debug ] && writef /sys/module/wakelock/parameters/debug 0 || true
      ;;
    performance)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 0 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 8 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 0 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 0 1 0 || true
      ;;
    *)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4 || true
      ;;
  esac
  tune_io_queues
}
asb_feature_enabled KERNEL && asb_log "boot: kernel/DSP policy deferred until boot_completed"
apply_dsp_compute_boost() {
  [ -e /sys/module/cdsp_loader/parameters/cdsp_load_state ] && \
    writef /sys/module/cdsp_loader/parameters/cdsp_load_state 1 || true
  [ -e /sys/module/adsprpc/parameters/perf_v2 ] && \
    writef /sys/module/adsprpc/parameters/perf_v2 1 || true
  for d in /sys/devices/platform/soc/*remoteproc-cdsp/power \
           /sys/devices/platform/soc/*remoteproc-adsp/power \
           /sys/devices/platform/soc/*cdsp*/power \
           /sys/devices/platform/soc/*adsp*/power; do
    [ -d "$d" ] || continue
    # "auto", not "on".
    #
    # control=on pins the runtime-PM state: the DSP never autosuspends, so an idle phone
    # keeps a compute island powered for nothing. That is the opposite of what a module
    # tuned for battery should leave behind, and nothing restores it - not the profile
    # switch, not uninstall.
    #
    # "auto" is the kernel default and still lets the DSP be woken instantly; the
    # autosuspend delay set below is what actually keeps it up across a burst of work,
    # which is the part worth having.
    [ -w "$d/control" ] && writef "$d/control" auto 2>/dev/null || true
    if [ -w "$d/autosuspend_delay_ms" ]; then
      writef "$d/autosuspend_delay_ms" 2000 2>/dev/null
    fi
  done
}
asb_feature_enabled KERNEL && asb_log "boot: DSP compute policy deferred until boot_completed"
asb_timeline_mark service_media_kernel_deferred
# ASB:KERNEL:END

asb_freq_pick_pct() {
  _dir="$1"; _pct="$2"
  [ -d "$_dir" ] || return 1
  _max="$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * _pct / 100 ))
  _avail="$_dir/scaling_available_frequencies"
    # NEAREST step, not the highest one at or below target.
    #
    # Taking only $1<=t lands the cap on whatever step sits below the target, and
    # frequency tables have gaps. On a OnePlus 13 prime cluster a requested 45%
    # (1944000) landed on 1689600 - 39%, a sixth harder than the number that was
    # actually tuned. Those percentages came from field feedback ("raised: UI stayed
    # janky at 50/44"), so shipping a harder cap than the tuned one is a different
    # setting wearing its name.
    #
    # It feeds back into heat too: a prime pinned below what the work needs pushes
    # that work onto the little cluster for longer, and a phone that stays busy
    # longer stays awake longer. The closer of the two neighbours keeps the error
    # symmetric and small instead of always undershooting.
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '
      $1<=t { lo=$1; next }
      !hi   { hi=$1 }
      END { if (lo=="") { print hi; exit }
            if (hi=="") { print lo; exit }
            print ((t-lo) <= (hi-t)) ? lo : hi }')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
asb_gpu_pick_pct() {
  _base="/sys/class/kgsl/kgsl-3d0/devfreq"
  [ -d "$_base" ] || return 1
  _max="$(cat "$_base/max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * $1 / 100 ))
  _avail="$_base/available_frequencies"
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '
      $1<=t { lo=$1; next }
      !hi   { hi=$1 }
      END { if (lo=="") { print hi; exit }
            if (hi=="") { print lo; exit }
            print ((t-lo) <= (hi-t)) ? lo : hi }')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
apply_gpu_caps() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  # Manual profile caps are a lower-priority lease. Do not silently overwrite
  # camera/safety/platform decisions, and keep desired/applied observable.
  command -v asb_arbiter_can_write >/dev/null 2>&1 && ! asb_arbiter_can_write gpu_cap profile && return 0
  command -v asb_arbiter_claim >/dev/null 2>&1 && asb_arbiter_claim gpu_cap profile 30 120 profile_apply || true
  _gbase="/sys/class/kgsl/kgsl-3d0/devfreq"
  # Primary path: devfreq frequency capping (OP13 Adreno 830 and any GPU that
  # populates devfreq/max_freq + available_frequencies).
  if [ -d "$_gbase" ] && [ -n "$(cat "$_gbase/max_freq" 2>/dev/null)" ] && [ -s "$_gbase/available_frequencies" ]; then
    _gmax="$(asb_gpu_pick_pct ${_P_GPU_MAX_PCT:-100})"
    if [ -n "$_gmax" ] && writef_retry "$_gbase/max_freq" "$_gmax" 2 0.06; then
      _gactual="$(cat "$_gbase/max_freq" 2>/dev/null)"
      command -v asb_arbiter_note >/dev/null 2>&1 && asb_arbiter_note gpu_cap profile profile_apply "$_gmax" "${_gactual:--}" applied || true
    fi
    if [ "${_P_GPU_MIN_PCT:-0}" -gt 0 ] 2>/dev/null; then
      _gmin="$(asb_gpu_pick_pct ${_P_GPU_MIN_PCT})"
    else
      _gmin="$(cat "$_gbase/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -n | head -1)"
      [ -n "$_gmin" ] || _gmin="$(cat "$_gbase/min_freq" 2>/dev/null)"
    fi
    [ -n "$_gmin" ] && writef_retry "$_gbase/min_freq" "$_gmin" 2 0.06 || true
    return 0
  fi
  # Fallback: pwrlevel capping. OP15 Adreno 840 leaves devfreq freq nodes empty
  _pmax_node="/sys/class/kgsl/kgsl-3d0/max_pwrlevel"
  _nlvl="$(cat /sys/class/kgsl/kgsl-3d0/num_pwrlevels 2>/dev/null)"
  if [ -w "$_pmax_node" ] && [ -n "$_nlvl" ] && [ "$_nlvl" -gt 1 ] 2>/dev/null; then
    _floor_file="/data/adb/asb/gpu_pwrlevel_floor"
    if [ ! -f "$_floor_file" ]; then
      mkdir -p /data/adb/asb 2>/dev/null
      cat "$_pmax_node" 2>/dev/null > "$_floor_file" 2>/dev/null || true
    fi
    _vfloor="$(cat "$_floor_file" 2>/dev/null)"
    case "$_vfloor" in ''|*[!0-9]*) _vfloor=0 ;; esac
    _pct="${_P_GPU_MAX_PCT:-100}"
    [ "$_pct" -gt 100 ] 2>/dev/null && _pct=100
    [ "$_pct" -lt 1 ] 2>/dev/null && _pct=1
    _last=$(( _nlvl - 1 ))
    _lvl=$(( (100 - _pct) * _last / 100 ))
    # Clamp into [vendor_floor .. slowest]: never faster than the vendor cap.
    [ "$_lvl" -lt "$_vfloor" ] 2>/dev/null && _lvl="$_vfloor"
    [ "$_lvl" -gt "$_last" ] 2>/dev/null && _lvl="$_last"
    if writef_retry "$_pmax_node" "$_lvl" 2 0.06; then
      _gactual="$(cat "$_pmax_node" 2>/dev/null)"
      command -v asb_arbiter_note >/dev/null 2>&1 && asb_arbiter_note gpu_cap profile profile_apply "$_lvl" "${_gactual:--}" applied || true
    fi
  fi
}
apply_cpufreq_caps() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  # Camera deadline and safety owners outrank a manual profile cap. Keep the
  # previous envelope intact rather than lowering it mid-recording.
  [ -f /dev/.asb/camera_guard ] && return 0
  command -v asb_arbiter_can_write >/dev/null 2>&1 && ! asb_arbiter_can_write cpu_cap profile && return 0
  command -v asb_arbiter_claim >/dev/null 2>&1 && asb_arbiter_claim cpu_cap profile 30 120 profile_apply || true
  # Topology-aware capping. 2-cluster SoCs (OP15 canoe, OP13 sun) map cleanly to
  _pol_list="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n)"
  _pol_count="$(echo "$_pol_list" | grep -c .)"
  _top_pol="$(echo "$_pol_list" | tail -1)"
  _top_rel=0
  if [ -n "$_top_pol" ]; then
    _top_rel="$(cat "$_top_pol/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_top_rel" in ''|*[!0-9]*) _top_rel=0 ;; esac
  fi
  for _pol_dir in $_pol_list; do
    [ -d "$_pol_dir" ] || continue
    _smax="$_pol_dir/scaling_max_freq"
    [ -w "$_smax" ] || continue
    _rel="$(cat "$_pol_dir/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) _rel=0 ;; esac
    _is_mid=0
    if [ "$_pol_count" -ge 3 ] && [ "$_rel" -gt "$little_end" ] && [ "$_rel" -lt "$_top_rel" ]; then
      _is_mid=1
    fi
    # _P_CPUCAP_* are PERCENTS of this cluster's cpuinfo_max_freq (empty = no cap).
    if [ "$_rel" -le "$little_end" ]; then
      _pct="$_P_CPUCAP_L"
    else
      _pct="$_P_CPUCAP_B"
    fi
    if [ "$_is_mid" = "1" ] && [ -n "$_P_CPUCAP_L" ] && [ -n "$_P_CPUCAP_B" ]; then
      # MID cluster (the OP12 policy2 workhorse): cap halfway between the LITTLE
      _hi="$_P_CPUCAP_L"; [ "$_P_CPUCAP_B" -gt "$_hi" ] 2>/dev/null && _hi="$_P_CPUCAP_B"
      _pct="$(( _hi + (100 - _hi) / 2 ))"
    fi
    if [ -z "$_pct" ]; then
      # no cap for this tier — restore the cluster's full hardware ceiling.
      _want="$(cat "$_pol_dir/cpuinfo_max_freq" 2>/dev/null)"
    elif [ "$_pct" -ge 100 ] 2>/dev/null; then
      _want="$(cat "$_pol_dir/cpuinfo_max_freq" 2>/dev/null)"
    else
      _want="$(asb_freq_pick_pct "$_pol_dir" "$_pct")"
    fi
    # In Smart mode the governor owns the ceiling - do not overwrite it here.
    #
    # This wrote the profile percentage unconditionally, so every reconcile pass stamped a
    # static per-profile number over whatever the FSM had just decided. Field traces across
    # four devices show the result: the governor owns the cap 11% of the time, 0% on one
    # phone, while "shell" owns 49-70%. All the thermal work - the SUSTAINED ladder, the
    # proportional clamp, the monotonic ratchet - was being overwritten seconds later by a
    # fixed percentage that knows nothing about temperature.
    #
    # The floor below is still written: it is a single-owner value the governor does not
    # REVERTED: handing the ceiling to the governor alone made things worse, not better.
    #
    # The theory was sound - the profile script was stamping a static percentage over the
    # FSM's thermal decisions, and ASB owned the cap only 11% of the time. Removing the
    # shell write should have handed control back.
    #
    # It did the opposite. A capture on the same phone afterwards: ASB ownership fell to 1%,
    # the prime cap sat below 1.2 GHz for 19% of the time, and the user reported stutter in
    # audio, animation, camera and the lock screen - with no improvement in heat or drain.
    # Whatever holds the cap when the shell stops writing, it is not this governor, and the
    # phone ends up slower AND no cooler.
    #
    # Restoring the unconditional write. The ownership problem is real and still unsolved,
    # but it needs to be understood before it is acted on - this was a guess, and it cost
    # the user a day of a stuttering phone.
    if [ -n "$_want" ] && writef_retry "$_smax" "$_want" 2 0.06; then
      _actual="$(cat "$_smax" 2>/dev/null)"
      command -v asb_arbiter_note >/dev/null 2>&1 && asb_arbiter_note cpu_cap profile profile_apply "$_want" "${_actual:--}" applied || true
    fi
    # Per-cluster min-freq floor (single owner, 4-cluster aware). little cluster
    _smin="$_pol_dir/scaling_min_freq"
    if [ -w "$_smin" ]; then
      # Smart owns a dynamic ceiling, but it must not keep the Balanced minimum as a
      # permanent floor. On 6+2 SoCs that pins six little cores at 787 MHz while the
      # user is merely scrolling a feed. Hardware min is topology-specific and lets
      # schedutil raise instantly; manual and Gaming paths retain their profile floor.
      if [ "${ASB_PROFILE:-$PROFILE}" = "smart" ]; then
        _minw="$(cat "$_pol_dir/cpuinfo_min_freq" 2>/dev/null)"
        case "$_minw" in ''|*[!0-9]*) _minw="" ;; esac
      elif [ "$_rel" -le "$little_end" ]; then
        _minw="$CPU_MIN_LITTLE"
      else
        _minw="$CPU_MIN_BIG"
      fi
      if [ -n "$_minw" ]; then
        _minpick="$(asb_pick_nearest_freq "$_pol_dir" "$_minw" 2>/dev/null)"
        [ -z "$_minpick" ] && _minpick="$_minw"
        _curmax_now="$(cat "$_smax" 2>/dev/null)"
        if [ -n "$_curmax_now" ] && [ -n "$_minpick" ] && [ "$_minpick" -gt "$_curmax_now" ] 2>/dev/null; then
          _minpick="$_curmax_now"
        fi
        [ -n "$_minpick" ] && writef_retry "$_smin" "$_minpick" 2 0.06 || true
      fi
    fi
  done
}
# apply_cpufreq_caps must run ONLY via apply_screen_aware_caps, which first sets

asb_screen_on() {
  for _dp in /sys/kernel/oplus_display/panel_power_status               /sys/kernel/oplus_display/disp_on_notify; do
    [ -r "$_dp" ] || continue
    _dpv="$(cat "$_dp" 2>/dev/null)"
    case "$_dpv" in 1|on|ON) return 0 ;; 0|off|OFF) return 1 ;; esac
  done
  for _df in /sys/class/drm/card0-DSI-1/status /sys/class/drm/card0-DSI-2/status; do
    [ -r "$_df" ] || continue
    [ "$(cat "$_df" 2>/dev/null)" = "connected" ] && return 0
    return 1
  done
  for _bl in /sys/class/backlight/panel0-backlight/brightness               /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$_bl" ] || continue
    _blv="$(cat "$_bl" 2>/dev/null)"
    [ "${_blv:-0}" -gt 0 ] 2>/dev/null && return 0
    return 1
  done
  dumpsys power 2>/dev/null | grep -q "mHoldingDisplaySuspendBlocker=true"
}
apply_screen_aware_caps() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  asb_feature_enabled CPU || return 0
  asb_load_profile
  _son=0
  asb_screen_on && _son=1
  # Caps are PERCENT of each cluster's own cpuinfo_max_freq (apply_cpufreq_caps
  _soc="$(getprop ro.board.platform 2>/dev/null)"
  [ -z "$_soc" ] && _soc="$(getprop ro.hardware.chipname 2>/dev/null)"
  case "$_soc" in
    canoe|sm8850*) _dev="op15" ;;
    sun|sm8750*)   _dev="op13" ;;
    pineapple|sm8650*) _dev="op12" ;;
    *)             _dev="generic" ;;
  esac

  _P_CPUCAP_L=""; _P_CPUCAP_B=""
  CPU_CAP_LITTLE=""; CPU_CAP_BIG=""
  case "$ASB_PROFILE" in
    performance)
      # never cap performance: full hardware range on every cluster, every SoC.
      _P_CPUCAP_L=""; _P_CPUCAP_B=""
      ;;
    balanced)
      if [ "$_son" -eq 1 ]; then
        # screen-on balanced: light touch; balance comes from WALT/uclamp. OP15
        case "$_dev" in
          op15) _P_CPUCAP_L=""; _P_CPUCAP_B="" ;;
          op13) _P_CPUCAP_L=72; _P_CPUCAP_B=58 ;;
          op12) _P_CPUCAP_L=78; _P_CPUCAP_B=58 ;;   # MID lifts to ~79%
          *)    _P_CPUCAP_L=72; _P_CPUCAP_B=55 ;;
        esac
      else
        _P_CPUCAP_L=55; _P_CPUCAP_B=45             # screen-off: cheap background
      fi
      ;;
    battery)
      if [ "$_son" -eq 1 ]; then
        # screen-on battery: MUST stay usable. Prime is capped for savings but
        case "$_dev" in
          op15) _P_CPUCAP_L=50; _P_CPUCAP_B=38 ;;
          op13) _P_CPUCAP_L=58; _P_CPUCAP_B=48 ;;   # raised: UI stayed janky at 50/44
          op12) _P_CPUCAP_L=60; _P_CPUCAP_B=45 ;;   # MID lifts to ~72%
          *)    _P_CPUCAP_L=52; _P_CPUCAP_B=40 ;;
        esac
      else
        _P_CPUCAP_L=35; _P_CPUCAP_B=25             # screen-off: aggressive
      fi
      ;;
    *)
      return 0
      ;;
  esac
  apply_cpufreq_caps
  asb_log "screen_aware_caps: dev=$_dev profile=$ASB_PROFILE screen_on=$_son cap_l=${_P_CPUCAP_L:-(none)} cap_b=${_P_CPUCAP_B:-(none)}"
}
asb_feature_enabled CPU && asb_log "boot: GPU cap policy deferred until boot_completed"
apply_walt_live() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  asb_feature_enabled CPU || return 0
  [ -d /proc/sys/walt ] || return 0
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks "$RAVG_TICKS" 2 0.06 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && writef_retry /proc/sys/walt/sched_idle_enough "$WALT_IDLE" 2 0.06 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && writef_retry /proc/sys/walt/sched_idle_enough_clust "$WALT_IDLE_CLUST" 2 0.06 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct "$WALT_CLUSTER" 2 0.06 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$WALT_CLUSTER_CLUST" 2 0.06 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation "$WALT_COLOC" 2 0.06 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres "$WALT_PIPE" 2 0.06 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres "$WALT_PIPE_NONSP" 2 0.06 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres "$WALT_PIPE_SP" 2 0.06 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns "$WALT_BUSY_HYST" 2 0.06 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost "$WALT_ED_BOOST" 2 0.06 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct "$WALT_TOPAPP_WEIGHT" 2 0.06 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost "$WALT_BOOST_MIN_UTIL" 2 0.06 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost "$WALT_SCHED_BOOST" 2 0.06 || true
}
apply_idle() {
  writef /sys/module/lpm_levels/parameters/sleep_disabled 0
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] &&     echo $_P_GTMR > /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_rail_on 0 2 0.06 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_clk_on  0 2 0.06 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_bus_on  0 2 0.06 || true
  [ -w /sys/class/kgsl/kgsl-3d0/force_no_nap ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/force_no_nap "${GPU_FORCE_NO_NAP:-0}" 2 0.06 || true
  [ -w /sys/class/kgsl/kgsl-3d0/bus_split ] && [ -n "$GPU_BUS_SPLIT" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/bus_split "$GPU_BUS_SPLIT" 2 0.06 || true
  [ -w /sys/class/kgsl/kgsl-3d0/throttling ] && [ -n "$GPU_THROTTLING" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/throttling "$GPU_THROTTLING" 2 0.06 || true
  [ -w /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel ] && [ -n "$GPU_THERMAL_PWRLEVEL" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "$GPU_THERMAL_PWRLEVEL" 2 0.06 || true
  [ -w /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor ] &&     echo msm-adreno-tz > /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor 2>/dev/null || true
}
asb_feature_enabled CPU && apply_idle

# ASB:CPU:BEGIN
apply_runtime_profile_now() {
  asb_load_profile
  PROFILE="$ASB_PROFILE"
  asb_log "apply_runtime_profile_now profile=$ASB_PROFILE"
  # Stock is an explicit terminal boundary for this runtime pass. Do not let any later
  # service helper reapply a CPU/GPU/VM/network profile after profile_core restored it.
  if [ "${ASB_STOCK_PROFILE:-0}" = "1" ]; then
    command -v asb_stock_enter >/dev/null 2>&1 && asb_stock_enter
    return 0
  fi
  ASB_PROFILE_BASELINE_CAPTURE=1
  export ASB_PROFILE_BASELINE_CAPTURE
  asb_feature_enabled CPU && asb_apply_profile_once
  if asb_feature_enabled CPU; then
    apply_walt_live
    apply_uclamp
    apply_cpuset_groups
    apply_cpuset_groups_all
    apply_idle
    apply_screen_aware_caps
    apply_gpu_caps
    # (min-freq now handled inside apply_cpufreq_caps; stray LITTLE/BIG writes removed)
    apply_cpugov_hints
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled NET && apply_net
  asb_feature_enabled WIFI && apply_wlan0_txqlen
  asb_feature_enabled WIFI && apply_wlan0_qdisc
  asb_feature_enabled WIFI && apply_wifi_pm
  asb_feature_enabled WIFI && apply_wifi_dtim

  asb_feature_enabled VM && apply_doze
  unset ASB_PROFILE_BASELINE_CAPTURE
  (
    sleep 10
    asb_load_profile
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
    asb_feature_enabled WIFI && apply_wifi_pm
    asb_feature_enabled WIFI && apply_wifi_dtim

  ) >/dev/null 2>&1 &
}
# ASB:CPU:END
apply_bt_settings() {
  if has settings; then
    asb_settings_put global bluetooth_btsnoop_default_mode 0
    asb_settings_put secure bluetooth_btsnoop_default_mode 0
    asb_settings_put global bluetooth_btsnoop_log_mode disabled
    settings delete global bluetooth_disabled_profiles >/dev/null 2>&1 || true
  fi
}
# Bluetooth Settings writes are re-applied by the post-boot framework stage.
apply_bt_codec_policy() {
  if has settings; then
    asb_settings_put global bluetooth_a2dp_optional_codecs_enabled 1
    asb_settings_put global bluetooth_a2dp_codec_priority_lhdc 1200
    asb_settings_put global bluetooth_a2dp_codec_priority_ldac 1100
    asb_settings_put global bluetooth_a2dp_codec_priority_aac 1000
    asb_settings_put global bluetooth_a2dp_ldac_quality_index 0
    asb_settings_put global bluetooth_a2dp_codec_ldac_quality_index 0
    asb_settings_put global bluetooth_a2dp_codec_ldac_playback_quality 990
  fi
  if has resetprop; then
    resetprop -n persist.vendor.qcom.bluetooth.aac_frm_ctl.enabled true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled true >/dev/null 2>&1 || true
    # LHDC quality/channelmode/version live in apply_bt_audio_hygiene, which sets the whole
    # codec picture together with samplerate and bitdepth.
    # Setting half of it here as well meant two owners for the same six properties and no way
    # to tell which one a future change should follow.
  fi
}
# Bluetooth Settings writes are re-applied by the post-boot framework stage.
apply_bt_volume_behavior() {
  # Respect the user's bt_absvol_mode (auto|on|off) from governor.conf — the
  _bt_mode="$(grep -E '^[[:space:]]*bt_absvol_mode=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [ -n "$_bt_mode" ] || _bt_mode="auto"
  # AUTO = truly hands-off: do NOT touch absolute-volume at all, so the stock
  if [ "$_bt_mode" = "auto" ]; then
    asb_log "bt absvol: mode=auto -> leaving stock absolute-volume untouched"
    return 0
  fi
  # Same vocabulary the WebUI writes and asb_audio_apply.sh reads.
  #
  # The card offers stock|disabled; this only knew auto|on|off, so "disabled" fell through to
  # the catch-all and boot re-enabled absolute volume.
  # The setting worked the moment it was tapped - asb_audio_apply.sh gets it right - and
  # silently reverted on the next reboot, which is the worst shape a bug can take: it looks
  # like it works.
  case "$_bt_mode" in
    disabled|on)  _bt_dav=1; _bt_prop="true"  ;;   # phone drives the gain
    stock|off)    _bt_dav=0; _bt_prop="false" ;;   # one shared scale with the headset
    *)            _bt_dav=0; _bt_prop="false" ;;
  esac
  if has settings; then
    asb_settings_put global bluetooth_disable_absolute_volume "$_bt_dav"
    asb_settings_put secure bluetooth_disable_absolute_volume "$_bt_dav"
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.disableabsvol "$_bt_prop" >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.disableabsvol "$_bt_prop" >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_disableabsvol >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_enableabsvol >/dev/null 2>&1 || true
  fi
}
# Bluetooth settings/props are re-applied by the post-boot framework stage.
apply_bt_audio_hygiene() {
  if has resetprop; then
    resetprop -p --delete persist.vendor.bt.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
    resetprop -p --delete persist.bluetooth.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.btstack.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bt.enable.lpa true >/dev/null 2>&1 || true
    # LE Audio (lc3_offload / leaudio.enable / leaudio.enabled) intentionally not
    # forced — see apply_bt_runtime note: it breaks classic-BLE watch pairing.
  fi
}
# Bluetooth audio props are re-applied by the post-boot framework stage.
if has resetprop; then
    for _k in media.resolution.limit.16bit media.resolution.limit.24bit media.resolution.limit.32bit \
             audio.resolution.limit.16bit audio.resolution.limit.24bit audio.resolution.limit.32bit; do
      resetprop -p --delete "$_k" >/dev/null 2>&1 || true
    done
  fi
apply_logd_props() {
  asb_persist_safe persist.logd.size 32K
  asb_persist_safe persist.logd.size.radio 32K
  asb_persist_safe persist.logd.size.system 32K
  asb_persist_safe persist.logd.size.crash 32K
  asb_persist_safe persist.logd.size.kernel 32K
  asb_persist_safe persist.logd.size.security 32K
  asb_persist_safe persist.logd.statistics false
  asb_persist_safe persist.logd.logpersistd stop
}
asb_feature_enabled LOG && apply_logd_props

# Runtime GMS/analytics tracking suppression via the settings DB. Props can't
apply_tracking_block() {
  _trk_log="/data/adb/asb/tracking_restore.log"
  # NOT truncated per boot any more.
  [ -f "$_trk_log" ] || : > "$_trk_log" 2>/dev/null
  _sp() {
    # _sp <key> <value> — save the old value the FIRST time only, then set the new one.
    if ! grep -q "^$1|" "$_trk_log" 2>/dev/null; then
      echo "$1|$(settings get global "$1" 2>/dev/null)" >> "$_trk_log" 2>/dev/null
    fi
    settings put global "$1" "$2" >/dev/null 2>&1
  }
  _sp clearcut_enabled 0
  _sp clearcut_events 0
  _sp clearcut_gcm 0
  _sp gmscorestat_enabled 0
  _sp ga_collection_enabled 0
  _sp analytics_enabled 0
  _sp uploading_enabled 0
  _sp usage_stats_enabled 0
  _sp usagestats_collection_enabled 0
  _sp network_watchlist_enabled 0
  _sp limit_ad_tracking 1
  _sp tron_enabled 0
  _sp play_store_panel_logging_enabled 0
  _sp phenotype_flags "disable_log_upload=1,disable_log_for_missing_debug_id=1"
  _sp binder_calls_stats "sampling_interval=600000000,detailed_tracking=disable,enabled=false,upload_data=false"
}
# Tracking Settings writes are re-applied by the post-boot framework stage.

apply_camera_experimental() {
  # The proven-working OP12 build ran this on pineapple too (it set MFNR/EIS/SAT/
  _orig="$MODDIR/config/camera_orig.conf"

  if [ ! -f "$_orig" ]; then
    mkdir -p "$MODDIR/config"
    echo "# ASB camera original values" > "$_orig"
    for _prop in \
      persist.vendor.camera.mfnr.enable \
      persist.vendor.camera.eis.enable \
      persist.vendor.camera.sat.fallback.dist \
      persist.vendor.camera.main.hfr \
      persist.vendor.camera.fast.af; do
      _v="$(getprop "$_prop" 2>/dev/null)"
      echo "${_prop}=${_v}" >> "$_orig"
    done
    asb_log "camera: saved originals to camera_orig.conf"
  fi

  has resetprop || return 0
  resetprop -n persist.vendor.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.sat.fallback.dist 2.0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.main.hfr 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.fast.af 1 >/dev/null 2>&1 || true
  asb_log "camera experimental: applied (MFNR+EIS+SAT+HFR+FastAF)"
}
if asb_feature_enabled CAMERA; then
  if command -v asb_device_pack_allows >/dev/null 2>&1 && asb_device_pack_allows camera; then
    apply_camera_experimental
  else
    asb_log "camera experimental: skipped on generic/unvalidated device pack"
  fi
fi

# Do not change the scheduler class or nice of the whole audioserver process.
# Process-level RR/52 can starve unrelated work and increase active drain even
# when no audio is playing. Route/DSP changes remain explicit WebUI actions.
apply_audio_boost() {
  asb_log "audio boost: process-level RT priority intentionally disabled"
  return 0
}

asb_check_perfhal_drift() {
  # DISABLED: caps are now a percent of each cluster's own max (see
  return 0
}
asb_check_perfhal_drift_legacy_unused() {
  asb_load_profile
  [ -z "$CPU_CAP_BIG" ] && return 0
  _want="$CPU_CAP_BIG"
  _drift_pol=""
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _rel="$(cat "$_pol/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) continue ;; esac
    [ "$_rel" -gt "$little_end" ] 2>/dev/null && { _drift_pol="$_pol"; break; }
  done
  [ -z "$_drift_pol" ] && return 0
  _cur="$(cat "$_drift_pol/scaling_max_freq" 2>/dev/null)"
  [ -z "$_cur" ] && return 0
  if [ "$_cur" != "$_want" ]; then
    asb_log "PERF-HAL DRIFT: $(basename $_drift_pol) max=${_cur} (expected ${_want}) — likely overridden by PowerHAL/thermal"
  fi
}

svc_state() { getprop "init.svc.$1" 2>/dev/null; }
svc_exists() { [ -n "$(svc_state "$1")" ]; }
svc_running() { [ "$(svc_state "$1")" = "running" ]; }
svc_busy() {
  st="$(svc_state "$1")"
  [ "$st" = "stopping" ] || [ "$st" = "restarting" ]
}
svc_stop() {
  s="$1"
  svc_exists "$s" || return 0
  svc_running "$s" || return 0
  svc_busy "$s" && return 0
  sleep 0.5
  svc_running "$s" && stop "$s" 2>/dev/null || true
  return 0
}
svc_stop_guarded() {
  s="$1"
  for i in 1 2 3; do
    svc_stop "$s"
    svc_running "$s" || return 0
    sleep 2
  done
  return 0
}
asb_stop_nonessential_services() {
  # Stopping an init service can trigger vendor restart/recovery work.  The old unconditional
  # post-boot sweep was therefore both a reboot-latency risk and a source of background churn.
  # Keep it as an explicit diagnostics opt-in for advanced users, not a default optimisation.
  if [ ! -f /data/adb/asb/allow_service_stops ]; then
    asb_log "service_stops: skipped (create /data/adb/asb/allow_service_stops to opt in)"
    return 0
  fi
  for s in \
    qseelogd wlanramdumpcollector mqsasd mtdoopslog debuggerd \
    minidump minidump32 minidump64 bootstat poweroff_charger_log \
    ostatsd charge_logger iorapd cnss_diag diag_mdlog diag_mdlog_start \
    mmi-diag qcom-diag tftp_server tcpdump modem_svc logcat-debug \
    midasd batterysecret \
    mdnsd \
    oplus_sensor_fb vendor.oplus.sensor.fb \
    oplus_crash_report \
    oplusdebuglogauto \
    vendor.oplus.logkit oplus_logctl \
    oplus_gaia oplus_theia theia_screen_monitor \
    qcom_diag_relay vendor.qti.diag \
    oplusd mlipay \
  ; do
    svc_stop_guarded "$s"
  done
}
apply_zram() {
  [ -e /sys/block/zram0 ] || return 0
  # A vendor-created zram device can contain gigabytes of live anonymous pages.  Resizing it
  # requires swapoff and a complete writeback into RAM, which is high I/O/CPU work and can take
  # tens of seconds after boot.  Preserve the vendor policy unless a power user explicitly
  # requests this destructive rebuild.
  if [ ! -f /data/adb/asb/allow_zram_rebuild ]; then
    asb_log "zram: preserving active vendor configuration (rebuild requires /data/adb/asb/allow_zram_rebuild)"
    return 0
  fi
  CPU_CORES=$(nproc 2>/dev/null || echo 8)
  ZRAM_SIZE_MB=8192
  _cur_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  _want_bytes=$((ZRAM_SIZE_MB * 1024 * 1024))
  if [ "$_cur_disksize" = "$_want_bytes" ] && \
     grep -q "/dev/block/zram0" /proc/swaps 2>/dev/null; then
    return 0
  fi
  swapoff /dev/block/zram0 >/dev/null 2>&1
  _t=0
  while grep -q "/dev/block/zram0" /proc/swaps 2>/dev/null && [ "$_t" -lt 5 ]; do
    sleep 1; swapoff /dev/block/zram0 >/dev/null 2>&1; _t=$((_t + 1))
  done
  echo 1 > /sys/block/zram0/reset 2>/dev/null || return 0
  sleep 2
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
  [ -f /sys/block/zram0/use_dedup ] && echo 1 > /sys/block/zram0/use_dedup 2>/dev/null || true
  echo "${ZRAM_SIZE_MB}M" > /sys/block/zram0/disksize 2>/dev/null || return 0
  echo 0 > /sys/block/zram0/queue/iostats 2>/dev/null || true
  echo 0 > /sys/block/zram0/queue/add_random 2>/dev/null || true
  mkswap /dev/block/zram0 >/dev/null 2>&1 && \
    swapon /dev/block/zram0 >/dev/null 2>&1 || true
}
apply_walt_boost() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  for _pol in 0 4 7; do
    _wp="/sys/devices/system/cpu/cpufreq/policy${_pol}/walt"
    [ -d "$_wp" ] || continue
    writef_retry "$_wp/input_boost_freq" 0  2 0.06 || true
    writef_retry "$_wp/input_boost_ms"   25 2 0.06 || true
  done
  [ -w /proc/sys/kernel/sched_boost ] && \
    writef_retry /proc/sys/kernel/sched_boost 0 2 0.06 || true
  writef_retry /proc/sys/kernel/sched_energy_aware 1 2 0.06 || true
}
# WALT boost and ZRAM reconciliation are performed by the deferred core worker.
# Starting them here previously contributed to the final four seconds of service startup.
asb_feature_enabled VM && asb_log "boot: ZRAM reconciliation deferred until boot_completed"

asb_apply_deferred_core_boot() {
  # The native governor is already alive before this worker and owns Smart CPU/GPU caps on
  # supported devices.  The boot trace from SM8850 shows that replaying the old shell policy
  # stack here still spends 14 seconds after boot_completed on cgroups, uclamp, WALT, sysctl
  # and GPU writes, without changing the governor-owned runtime result.  Those writes also
  # race vendor PowerHAL/thermal during the hottest part of a reboot.
  #
  # Keep the legacy shell convergence available for a device that demonstrably needs it, but
  # never make it the default.  A user can opt in with this marker after validating their ROM:
  #   /data/adb/asb/allow_boot_shell_policy
  # All normal ASB CPU decisions continue in the native governor.
  if [ ! -f /data/adb/asb/allow_boot_shell_policy ]; then
    asb_log "boot-core: native governor owns policy; legacy shell convergence skipped"
    asb_timeline_mark post_boot_core_policy_native_only
    return 0
  fi

  # Every call below is idempotent and was previously executed synchronously before
  # service_dispatched. Applying them after boot completion preserves the selected
  # profile while removing init/framework contention from the path to first UI.
  asb_load_profile
  # asb_apply_profile_once fan-outs into CPU, GPU, VM, network, Wi-Fi and UX writes.  Calling it
  # here and then applying the dedicated core policy below duplicated many cgroup/sysfs writes
  # and brought framework-facing Wi-Fi/UX work back onto the post-boot critical worker.
  # Initialise only the CPU topology required by this lean core path; network, Wi-Fi and UX are
  # handled in their own later, non-critical stages.
  asb_feature_enabled CPU && asb_cpu_cluster_init
  if asb_feature_enabled CPU; then
    apply_walt_boost
    apply_walt_live
    apply_uclamp
    apply_cpuset_groups
    apply_cpuset_groups_all
    apply_idle
    apply_screen_aware_caps
    apply_gpu_caps
    apply_cpugov_hints
  fi
  asb_feature_enabled VM && apply_vm
  if asb_feature_enabled KERNEL; then
    apply_kernel
    apply_dsp_compute_boost
  fi
  # zram rebuild runs in the background, not on the boot path.
  #
  # apply_zram calls swapoff, and swapoff does not return until every compressed page
  # has been faulted back into RAM. On a phone that has been up long enough to fill
  # zram that is tens of seconds of solid I/O, and it sits inside the stage a boot
  # timeline measured at 56 of 129 seconds. The loop below it then waits up to 5 more
  # seconds and sleeps another 2 unconditionally.
  #
  # Nothing depends on zram being resized before the phone is usable: it is a memory
  # tuning that pays off over hours, not a policy the rest of the module reads. It
  # also explains why a clean install with no tweaks boots fast - VM off, no rebuild.
  #
  # Backgrounded and delayed 60s so it lands after the launcher and the first apps
  # have settled, when swapoff has less to write back and nobody is waiting.
  if asb_feature_enabled VM; then
    ( sleep 60; apply_zram ) >/dev/null 2>&1 &
  fi
}

apply_doze() {
  # Defer to doze_level when the user has set one.
  #
  # This function writes device_idle_constants from the PROFILE, while
  # runtime/asb_doze_apply.sh writes the same key from the doze_level tweak - and at
  # doze_level=stock it DELETES the key outright. Two owners of one setting, and which
  # one wins depends on call order.
  #
  # The visible symptom is a tweak that does not stick: the user selects stock, the
  # helper clears the key, and the next profile pass writes the profile timings back.
  #
  # doze_level is the more specific statement - it is a choice about Doze, where the
  # profile is a choice about everything - so it takes precedence whenever it is set to
  # anything but its own default.
  _dz_lvl="$(grep -E '^[[:space:]]*doze_level=' "$MODDIR/config/governor.conf" 2>/dev/null \
             | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # stock is this tweak's default AND a deliberate choice, and both mean the same thing
  # here: Android's own timings, nothing written by the profile either. The helper clears
  # the key at stock, so returning early is what makes that clearing stick.
  #
  # An empty value means the config predates the key - only then does the profile decide.
  case "$_dz_lvl" in
    '') : ;;
    *) return 0 ;;
  esac

  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  has settings || return 0
  case "$ASB_PROFILE" in
    battery)
      _DIC="light_after_inactive_to=15000,light_pre_idle_to=2000,light_max_idle_to=86400000,light_idle_to=5000,light_idle_factor=3.0,light_idle_maintenance_min_budget=1000,light_idle_maintenance_max_budget=5000,inactive_to=30000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=3000,idle_pending_to=1500,max_idle_pending_to=3000,idle_pending_factor=3.0,idle_to=900000,max_idle_to=43200000,idle_factor=3.0,min_time_to_alarm=30000,max_temp_app_whitelist_duration=20000,mms_temp_app_whitelist_duration=10000,sms_temp_app_whitelist_duration=8000" ;;
    performance)
      _DIC="light_after_inactive_to=60000,light_pre_idle_to=10000,light_max_idle_to=86400000,light_idle_to=15000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=300000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=20000,idle_pending_to=10000,max_idle_pending_to=15000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=10800000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
    *)
      _DIC="light_after_inactive_to=30000,light_pre_idle_to=5000,light_max_idle_to=86400000,light_idle_to=10000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=180000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=10000,idle_pending_to=5000,max_idle_pending_to=10000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
  esac
  asb_settings_put global device_idle_constants "$_DIC"
}
# DeviceIdle framework write is deferred to post-boot.
# network_stats_poll_interval: how often the framework polls per-app network
apply_network_stats_poll() {
  [ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0
  has settings || return 0
  asb_feature_enabled LOG || return 0
  _eff_batt=0
  if [ "$ASB_PROFILE" = "battery" ]; then
    _eff_batt=1
  elif [ "$ASB_PROFILE" = "smart" ]; then
    _alpha="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | sed 's/^smart_alpha_battery=//')"
    case "$_alpha" in
      ''|*[!0-9]*) : ;;                                  # no/!num reading -> leave default
      *) [ "$_alpha" -ge 800 ] 2>/dev/null && _eff_batt=1 ;;
    esac
  fi
  if [ "$_eff_batt" = "1" ]; then
    asb_settings_put global network_stats_poll_interval 7200000
  else
    asb_settings_put global network_stats_poll_interval 1800000
  fi
}
# NetworkStats Settings write is deferred to post-boot.
apply_extra_settings() {
  has settings || return 0
  # Gated on audio_remove_volume_limit; see governor.conf. Re-asserting it every boot
  # would quietly undo a user who turned the limiter back on in Android settings.
  if [ "$(grep -E '^[[:space:]]*audio_remove_volume_limit=' "$MODDIR/config/governor.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')" = "1" ]; then
    asb_settings_put global audio_safe_volume_state 0
  fi
  settings delete global netstats_enabled >/dev/null 2>&1 || true
  settings delete global app_usage_enabled >/dev/null 2>&1 || true
  settings delete global package_usage_stats_enabled >/dev/null 2>&1 || true
  asb_settings_put global bluetooth_voip_support 1
  asb_settings_put global dropbox_max_files 5
  asb_settings_put global network_recommendations_enabled 0
  asb_settings_put global activity_starts_logging_enabled 0
  # Moved to runtime/asb_system_tweaks.sh, driven by phantom_procs. Setting it here as
  # well would mean the module overrides the user's choice on every boot - the exact
  # behaviour a per-user setting is supposed to end.
  asb_settings_put global send_action_app_error 0
  asb_settings_put global enhanced_connectivity_enabled 0
  asb_settings_put global adaptive_connectivity_enabled 0
  # Connectivity (captive-portal) check: point it at Cloudflare's generate_204 endpoint with a
  # gstatic fallback.
  asb_settings_put global captive_portal_mode 1
  asb_settings_put global captive_portal_detection_enabled 1
  asb_settings_put global captive_portal_use_https 1
  asb_settings_put global captive_portal_http_url "http://cp.cloudflare.com/generate_204"
  asb_settings_put global captive_portal_https_url "https://cp.cloudflare.com/generate_204"
  asb_settings_put global captive_portal_fallback_url "http://connectivitycheck.gstatic.com/generate_204"
  asb_settings_put global captive_portal_other_fallback_url "https://www.google.com/generate_204"
}
# Extra Settings writes are deferred to post-boot. Keep ZRAM and kernel-node work above here:
# they are memory/driver policy rather than framework IPC and may be needed before the first UI.
asb_timeline_mark service_runtime_kernel_memory_deferred
asb_timeline_mark service_runtime_framework_deferred
asb_timeline_mark service_runtime_core_deferred
asb_load_profile
# POSIX check, not "type -t".
# So this line silently skipped asb_apply_ux on EVERY boot, which is why "Manage UI speed" and
# "Force animation restart" appeared to do nothing - the animation scales and touch timeouts
# were only ever written when the user switched profiles by hand, and never at boot.
# Deferred until the framework is up: this makes seven settings calls.
#
# asb_apply_ux reads and writes animation scales and touch timeouts through the
# settings provider. Called here it runs while the boot animation is still on
# screen, and every one of those calls blocks until the provider is ready - a boot
# timeline shows 16 unaccounted seconds between service_runtime_core_deferred and
# service_dispatched, and the user reports the boot animation visibly stuttering on
# its third loop, which is exactly this window.
#
# The irony is that this line used to be broken - a bad command check meant it never
# ran at all. Fixing it was right; leaving it on the boot path was not.
#
# Animation scales are cosmetic and take effect the moment they are written, so
# waiting for boot_completed costs the user nothing and gives the animation back.
(
  _ux_w=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_ux_w" -lt 120 ]; do
    sleep 2; _ux_w=$((_ux_w + 2))
  done
  command -v asb_apply_ux >/dev/null 2>&1 && asb_apply_ux >/dev/null 2>&1
) &

# Re-assert haptic strength.
#
# sysctl values do not survive a reboot and the forced WiFi country code is released by some
# ROMs on boot, so without this the settings would apply once from the WebUI and quietly
# revert.
# Log level: resolve into log_verbosity every boot, and re-assert extreme if chosen.
# Undo the removed lockscreen tweak, once.
#
# lockscreen_skip_delayed is gone: it could only ever work below Android 11, and above that
# the keyguard ignores the key it wrote. Deleting the feature stops us SETTING the value,
# but anyone who switched it on still has secure lockscreen.disabled sitting in their
# settings - and with the script gone nothing would ever put it back. Restore the recorded
# original, or clear the key, then drop the state.
if [ -f /data/adb/asb/lockscreen_prev ]; then
  _lsp="$(grep -E '^PREV_LS_DISABLED=' /data/adb/asb/lockscreen_prev 2>/dev/null | head -1 | sed 's/[^=]*=//')"
  case "$_lsp" in
    ''|null) settings delete secure lockscreen.disabled >/dev/null 2>&1 ;;
    *)       settings put secure lockscreen.disabled "$_lsp" >/dev/null 2>&1 ;;
  esac
  rm -f /data/adb/asb/lockscreen_prev /data/adb/asb/lockscreen_result 2>/dev/null
  asb_log "lockscreen tweak removed - the setting it wrote has been put back"
fi

# Doze timings: re-assert at boot, the key does not survive one.
# Keep persist.asb.dsp.route honest while the phone is running.
#
# The route is written when audio settings change, but it also changes on its own -
# headphones in, Bluetooth connected, speaker again - and a stale value means the DSP
# output filter is deciding against last hour's route.  dumpsys audio is framework IPC, not a
# cheap local read; every 20 seconds created a permanent polling load even when no route was
# changing.  A 60-second fallback is sufficient because settings changes still signal the
# attacher immediately, while ordinary unplug/connect transitions remain corrected promptly.
(
  _prev_route=""
  while true; do
    # 5 s while the screen is on, 60 s otherwise.
    #
    # This loop now also has to notice playback starting, and a 60 s cadence would hand
    # the user the same delay the signal was meant to remove. Five seconds is a bounded
    # wait nobody will call broken.
    #
    # The screen-off branch keeps the slow interval and the guard below skips the pass
    # entirely, so a sleeping phone is not woken any more often than before - the whole
    # point of the earlier change to this loop.
    case "$(dumpsys deviceidle get screen 2>/dev/null)" in
      false|Asleep) sleep 60 ;;
      *) sleep 5 ;;
    esac
    # Skip the whole pass while the screen is off.
    #
    # This watches which output the DSP effect should follow, and it ran every 60 seconds
    # around the clock - 60 wakeups an hour, each one a dumpsys audio call, on a phone that
    # is supposed to be asleep. Unlike the governor, which waits on CLOCK_MONOTONIC and so
    # stops during suspend, a shell `sleep` runs on a timer that resumes the SoC.
    #
    # Nothing here is needed while the screen is off: the route only matters when audio is
    # actually being rendered to a user, and a route change with the screen off is picked up
    # on the first pass after it comes back on. Screen-off audio keeps working - this only
    # decides which output the effect attaches to, not whether sound plays.
    case "$(dumpsys deviceidle get screen 2>/dev/null)" in
      false|Asleep) continue ;;
    esac
    _f="$(grep -E '^[[:space:]]*dsp_outputs=' "$MODDIR/config/governor.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r')"
    case "$_f" in ''|all) continue ;; esac
    # Nothing to route while the effect is off.
    [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] || continue

    _now=""
    _d="$(dumpsys audio 2>/dev/null | grep -m1 -iE 'Device[s]?: *(speaker|bt|usb|wired|headset|headphone)')"
    case "$_d" in
      *bt_a2dp*|*BLUETOOTH_A2DP*|*bt_le*|*bt_sco*) _now="bt" ;;
      *usb*|*USB*|*wired_headset*|*wired_headphone*|*HEADSET*|*HEADPHONE*) _now="wired" ;;
      *speaker*|*SPEAKER*) _now="speaker" ;;
    esac
    [ -n "$_now" ] || continue
    # Also wake the attacher when playback STARTS, not only when the route changes.
    #
    # The attacher polls every 30 s while idle, so opening YouTube gives up to half a
    # minute of stock volume before the effect lands - audible, and it reads as the
    # feature being broken. The daemon already handles SIGUSR1 to cut its sleep short;
    # nothing was sending it on a playback transition, only on a route change.
    #
    # This needs no rebuild of the native binary, which matters: the fix inside
    # asb_dsp_attach.cpp is correct but cannot ship until that workflow can run.
    _play_now=0
    dumpsys audio 2>/dev/null | grep -qiE "state:started|player piid.*started" && _play_now=1
    if [ "$_play_now" = "1" ] && [ "${_prev_play:-0}" = "0" ]; then
      pkill -USR1 -f asb_dsp_attach 2>/dev/null \
        || killall -USR1 asb_dsp_attach 2>/dev/null || true
    fi
    _prev_play="$_play_now"
    [ "$_now" = "$_prev_route" ] && continue
    _prev_route="$_now"
    resetprop -n persist.asb.dsp.route "$_now" >/dev/null 2>&1 \
      || setprop persist.asb.dsp.route "$_now" >/dev/null 2>&1
    # Wake the attach daemon: it is what resolves the filter and pushes the gain, and its
    # own poll is 30 s. Without this the effect keeps boosting the old output for up to
    # half a minute after headphones come out, which is exactly when it is most audible.
    pkill -USR1 -f asb_dsp_attach 2>/dev/null \
      || killall -USR1 asb_dsp_attach 2>/dev/null || true
    asb_log "dsp route changed to $_now (outputs filter=$_f)"
  done
) >/dev/null 2>&1 &

# Put the OEM toggles back the way they were before this module arrived.
#
# Runs once, late, and then deletes its own record. Installing ASB changes the memory
# configuration enough that OxygenOS re-enables RAM expansion on the next boot; the
# user who had it off gets it back off, and a user who turns it on afterwards is never
# contradicted because the record is gone by then.
#
# Skipped entirely when the user asked ASB to manage these - then the profile owns them.
(
  sleep 120
  [ -s /data/adb/asb/oem_preinstall ] || exit 0
  _oemmg="$(grep -E '^[[:space:]]*UX_MANAGE_OEM_TOGGLES=' "$MODDIR/config/governor.conf" 2>/dev/null \
            | head -1 | sed 's/.*=//' | tr -d ' \r')"
  if [ "$_oemmg" = "1" ]; then
    rm -f /data/adb/asb/oem_preinstall 2>/dev/null
    exit 0
  fi
  command -v settings >/dev/null 2>&1 || exit 0
  while IFS="|" read -r _ok _ov; do
    [ -n "$_ok" ] || continue
    _now="$(settings get global "$_ok" 2>/dev/null)"
    case "$_now" in ''|null) _now=null ;; esac
    [ "$_now" = "$_ov" ] && continue
    if [ "$_ov" = "null" ]; then
      # It was unset before we arrived, so unset is what "as found" means. Writing a 0
      # is not the same: OxygenOS treats the key being absent as its own default and a
      # stored 0 as a deliberate choice.
      settings delete global "$_ok" >/dev/null 2>&1 \
        && asb_log "oem toggle $_ok was $_now, cleared (unset before install)"
    else
      settings put global "$_ok" "$_ov" >/dev/null 2>&1 \
        && asb_log "oem toggle $_ok was $_now, restored to $_ov (as found before install)"
    fi
  done < /data/adb/asb/oem_preinstall
  rm -f /data/adb/asb/oem_preinstall 2>/dev/null
) >/dev/null 2>&1 &

# Watch what holds the phone awake. This is a night-scale problem, so it must never turn
# into a periodic screen-on job or be the source of the wakeups it measures.
(
  _screenoff_pass=0
  while true; do
    sleep 1800
    # The helpers below collectively make many framework / PackageManager / app-ops calls.
    # Run only during a genuine screen-off window and only once per hour there.  A trial expiry
    # or GNSS cleanup does not justify waking the active user-facing system every 15 minutes.
    case "$(dumpsys deviceidle get screen 2>/dev/null)" in
      false|Asleep)
        _screenoff_pass=$((_screenoff_pass + 1))
        [ $((_screenoff_pass % 2)) -eq 0 ] || continue
        ;;
      *) continue ;;
    esac
    [ -f "$MODDIR/runtime/asb_wakelock_watch.sh" ] || continue
    sh "$MODDIR/runtime/asb_wakelock_watch.sh" >/dev/null 2>&1
    # Trial expiry and rejected-write detection ride the same cycle: a probation that is
    # only checked when the user opens the UI is not a probation.
    # Bluetooth link health rides the same cycle: the evidence accumulates over a session,
    # so checking it once an hour would miss the window it appears in.
    [ -f "$MODDIR/runtime/asb_bt_link_watch.sh" ] \
      && sh "$MODDIR/runtime/asb_bt_link_watch.sh" >/dev/null 2>&1
    [ -f "$MODDIR/runtime/asb_trial.sh" ] \
      && sh "$MODDIR/runtime/asb_trial.sh" check >/dev/null 2>&1
    # Classify the screen-off stretch alongside the wakelock snapshot: both answer
    # "what was actually happening", and running them together means the class and the
    # holder come from the same moment rather than from two different ones.
    [ -f "$MODDIR/runtime/asb_screenoff_class.sh" ] \
      && sh "$MODDIR/runtime/asb_screenoff_class.sh" >/dev/null 2>&1
    # Same cadence: both look for work that outlived the user's attention, and neither is
    # urgent enough to poll more often than the thing it is trying to save.
    [ -f "$MODDIR/runtime/asb_gnss_trim.sh" ] \
      && sh "$MODDIR/runtime/asb_gnss_trim.sh" >/dev/null 2>&1
  done
) >/dev/null 2>&1 &

# These helpers re-assert user choices, but several enter framework/package-manager code
# (`pm disable`, `cmd appops`, `cmd -w wifi`, DeviceIdle). Running them inline during a
# userspace reboot makes init wait behind service recovery and can turn a fast reboot into a
# visibly slow one. They are non-critical at the first frame: defer them until boot completed,
# then give framework services a short settle window. Every action remains enabled and is still
# applied on every boot; only its scheduling is changed.
(
  _asb_pb_wait=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_asb_pb_wait" -lt 180 ]; do
    sleep 1
    _asb_pb_wait=$((_asb_pb_wait + 1))
  done
  [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || {
    asb_log "post_boot_tweaks: skipped (boot completion timeout)"
    exit 0
  }
  # Two seconds, not eight - and the poll above is now 1s, not 3s.
  #
  # A timeline with an independent 1-second watcher shows boot_completed arriving at
  # 36s while post_boot_tweaks_begin was stamped at 44s. Those eight seconds were this
  # sleep plus up to three more lost in the polling interval: pure waiting, in the
  # window where the user is staring at a phone that has finished booting and is not
  # yet responsive.
  #
  # The pause exists to let the framework settle before the module starts writing, and
  # two seconds does that: boot_completed is itself the signal that the system is up,
  # so this is a courtesy margin rather than a real dependency.
  sleep 2
  asb_timeline_mark post_boot_tweaks_begin
  asb_log "post_boot_tweaks: begin"
  # Start the native Smart/profile governor only after Android's framework reports ready.
  # This is the material Stock/non-Stock difference: starting it during service init creates
  # metrics/sysfs traffic while zygote, PowerHAL and vendor services are still competing for
  # CPU.  Stock intentionally has no governor at all.
  if [ "${ASB_STOCK_PROFILE:-0}" != "1" ]; then
    asb_timeline_mark post_boot_governor_start_begin
    if command -v asb_governor_start >/dev/null 2>&1; then
      asb_governor_start || asb_log "post_boot: governor start deferred to watchdog"
    fi
    asb_timeline_mark post_boot_governor_start_complete
  else
    asb_timeline_mark post_boot_governor_stock_off
  fi

  # Fast boot counterpart to the existing deferred BG_TRIM/connectivity stages.
  # Do all optional profile CPU/VM/kernel/DSP/ZRAM work after Android reports completion.
  asb_timeline_mark post_boot_core_policy_begin
  asb_apply_deferred_core_boot
  asb_timeline_mark post_boot_core_policy_complete

  # Restore only a user-selected WebUI audio policy.  The `boot` mode applies properties without
  # restarting audioserver, so boot never gains an audio restart or Bluetooth reconnect side effect.
  if asb_audio_boot_policy_enabled && [ -f "$MODDIR/runtime/asb_audio_apply.sh" ]; then
    asb_timeline_mark post_boot_audio_user_policy_begin
    MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_audio_apply.sh" boot >/dev/null 2>&1 || \
      asb_log "audio runtime: explicit policy restore failed"
    asb_timeline_mark post_boot_audio_user_policy_complete
  fi

  [ -f "$MODDIR/runtime/asb_gms_freeze.sh" ] && \
    sh "$MODDIR/runtime/asb_gms_freeze.sh" >/dev/null 2>&1
  [ -f "$MODDIR/runtime/asb_gms_trim.sh" ] && \
    sh "$MODDIR/runtime/asb_gms_trim.sh" >/dev/null 2>&1
  [ -f "$MODDIR/runtime/asb_system_tweaks.sh" ] && \
    sh "$MODDIR/runtime/asb_system_tweaks.sh" >/dev/null 2>&1

  if asb_feature_enabled BG_TRIM; then
    asb_timeline_mark post_boot_bgtrim_begin
    apply_bg_trim_runtime
    asb_timeline_mark post_boot_bgtrim_complete
  fi

  # Wi-Fi readiness/operstate polling, country policy and interface qdisc writes are applied
  # after Android's framework and link manager settle. On the OP15 they accounted for the
  # measured 19-second service_network_complete -> service_connectivity_complete interval.
  # The whole connectivity block runs in the background.
  #
  # It took 16 of the 46 seconds the module spends after boot_completed, and none of it
  # is on anyone's critical path: Wi-Fi country, power-save, DTIM, queue lengths and GPS
  # hygiene all apply to a radio that is already up and working with platform defaults.
  # A few of these poke the Wi-Fi stack and wait for it to answer, which is exactly the
  # kind of thing that should not sit between the user and a usable phone.
  #
  # Marks are kept inside the subshell so the next timeline still measures the stage -
  # it will simply no longer be on the line the user waits behind.
  (
    asb_timeline_mark post_boot_connectivity_begin
    if asb_feature_enabled WIFI; then
      asb_wifi_cc_heal
      apply_wifi_settings
      apply_wifi_country
      apply_wlan0_txqlen
      apply_wlan0_qdisc
      apply_wifi_pm
      apply_wifi_dtim
      ( asb_wifi_link_reassert ) >/dev/null 2>&1 &
    fi
    if asb_feature_enabled NET; then
      apply_mobile_qdisc
      apply_net_steering
    fi
    asb_feature_enabled GPS && apply_gps_hygiene
    asb_timeline_mark post_boot_connectivity_complete
  ) &

  # These calls use Settings, DeviceIdle, package/service state or many framework IPCs. They
  # used to occupy the 11-second media/kernel -> runtime-core boot interval on the OP15.
  asb_timeline_mark post_boot_runtime_framework_begin
  # Framework Bluetooth policy is an explicit experimental opt-in.  Manual WebUI audio apply
  # remains available and does not route through this broad codec/offload/HFP policy block.
  if asb_bt_policy_enabled; then
    apply_bt_settings
    apply_bt_codec_policy
    apply_bt_volume_behavior
    apply_bt_audio_hygiene
  fi
  asb_feature_enabled LOG && apply_tracking_block
  asb_feature_enabled VM && apply_doze
  asb_feature_enabled VM && apply_network_stats_poll
  apply_extra_settings
  asb_stop_nonessential_services
  asb_timeline_mark post_boot_runtime_framework_complete

  # Athena: pm component state does not survive a reboot on every build, so re-assert it late.
  if [ -f "$MODDIR/runtime/asb_athena_apply.sh" ]; then
    case "$(grep -E '^[[:space:]]*athena_service=' "$MODDIR/config/governor.conf" 2>/dev/null \
            | head -1 | sed 's/.*=//' | tr -d ' \r')" in
      off) sh "$MODDIR/runtime/asb_athena_apply.sh" >/dev/null 2>&1 ;;
    esac
  fi

  # Network offload and route tuning do not need to delay initial UI or userspace reboot.
  [ -f "$MODDIR/runtime/asb_net_offload.sh" ] && \
    sh "$MODDIR/runtime/asb_net_offload.sh" >/dev/null 2>&1
  
  # Re-apply when new receive queues appear.
  #
  # This ran exactly once, at boot. But rmnet interfaces are created when the data call is
  # established and re-created on every network change - roaming, a SIM switch, airplane
  # mode, or the tower hopping this user sees on two SIMs in a weak-signal area. A queue
  # that appears after boot never gets its rps_cpus written, so packet processing lands on
  # whichever core the interrupt picked, typically a big one.
  #
  # That matters most for exactly the phone this was found on: 1.5 GB of mobile data in two
  # and a half hours. Steering that to the little cluster does not reduce the traffic, it
  # makes each packet cheaper - which is the only lever the module actually has here.
  #
  # Counting queues is a directory listing, not a write. When the count changes the script
  # re-runs and rewrites every queue, including the ones it already owned; that is cheap and
  # idempotent, and far simpler than tracking which interface came and went.
  (
    _no_prev=""
    while true; do
      sleep 120
      case "$(dumpsys deviceidle get screen 2>/dev/null)" in
        false|Asleep) continue ;;
      esac
      _no_now="$(ls -d /sys/class/net/*/queues/rx-* 2>/dev/null | wc -l)"
      [ "$_no_now" = "$_no_prev" ] && continue
      _no_prev="$_no_now"
      [ -f "$MODDIR/runtime/asb_net_offload.sh" ] && \
        sh "$MODDIR/runtime/asb_net_offload.sh" >/dev/null 2>&1
    done
  ) &
  if [ -f "$MODDIR/runtime/asb_doze_apply.sh" ]; then
    case "$(grep -E '^[[:space:]]*doze_level=' "$MODDIR/config/governor.conf" 2>/dev/null \
            | head -1 | sed 's/.*=//' | tr -d ' \r')" in
      moderate|aggressive|night) sh "$MODDIR/runtime/asb_doze_apply.sh" >/dev/null 2>&1 ;;
    esac
  fi
  [ -f "$MODDIR/runtime/asb_log_apply.sh" ] && \
    sh "$MODDIR/runtime/asb_log_apply.sh" >/dev/null 2>&1

  if [ -f "$MODDIR/runtime/asb_net_apply.sh" ]; then
    _asb_net_any=0
    for _nk in net_congestion net_qdisc wifi_country wifi_scan_throttle; do
      _nv="$(grep -E "^[[:space:]]*$_nk=" "$MODDIR/config/governor.conf" 2>/dev/null \
             | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_nv" in ''|auto) : ;; *) _asb_net_any=1 ;; esac
    done
    if [ "$_asb_net_any" = "1" ]; then
      sh "$MODDIR/runtime/asb_net_apply.sh" >/dev/null 2>&1
      asb_log "net settings re-asserted (post-boot)"
    fi

    # Route windows follow the link, so start their watcher only after framework networking settles.
    _asb_rt="$(grep -E '^[[:space:]]*net_route_tune=' "$MODDIR/config/governor.conf" 2>/dev/null \
               | head -1 | sed 's/.*=//' | tr -d ' \r')"
    case "$_asb_rt" in
      auto|conservative|aggressive)
        if [ -f "$MODDIR/runtime/asb_net_routes.sh" ] && command -v ip >/dev/null 2>&1; then
          if ! pgrep -f "asb_net_routes.sh watch" >/dev/null 2>&1; then
            ( MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_net_routes.sh" watch >/dev/null 2>&1 & ) &
            asb_log "net routes: link watcher started (post-boot)"
          fi
        fi
        ;;
    esac
  fi

  # The active poor-Wi-Fi fallback is an explicit opt-in. Start/reconcile it only after
  # Android reports boot completion and normal network settling; it owns no preferred
  # radio mode, carrier setting or roaming threshold.
  if [ -f "$MODDIR/runtime/asb_wifi_fallback.sh" ]; then
    MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wifi_fallback.sh" reconcile >/dev/null 2>&1
  fi
  asb_log "post_boot_tweaks: complete"
  asb_timeline_mark post_boot_tweaks_complete
) >/dev/null 2>&1 &

if [ -f "$MODDIR/runtime/asb_haptics_apply.sh" ]; then
  _asb_hap_conf="$MODDIR/config/governor.conf"
  _asb_hap_run=0
  _asb_hap="$(grep -E '^[[:space:]]*haptic_strength=' "$_asb_hap_conf" 2>/dev/null \
              | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_asb_hap" in
    [0-9]|10|off|light|medium|strong) _asb_hap_run=1 ;;
  esac
  # Touch has its own level and its own right to be re-asserted. Checking only
  # haptic_strength meant a "master stock + touch 8" config never ran at boot, so the
  # one setting the user had actually changed was the one OOS was free to overwrite.
  _asb_hap_t="$(grep -E '^[[:space:]]*haptic_touch_strength=' "$_asb_hap_conf" 2>/dev/null \
                | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_asb_hap_t" in
    [0-9]|10) _asb_hap_run=1 ;;
  esac
  if [ "$_asb_hap_run" = "1" ]; then
    sh "$MODDIR/runtime/asb_haptics_apply.sh" >/dev/null 2>&1
    asb_log "haptics re-asserted (alerts=$_asb_hap touch=$_asb_hap_t)"
  fi
fi

# Keep the blur block in system.prop honest.
_asb_blur_want="$(grep -E '^[[:space:]]*disable_blur=' "$MODDIR/config/governor.conf" 2>/dev/null \
                  | head -1 | sed 's/.*=//' | tr -d ' \r')"
# Same three-value vocabulary the card writes and asb_blur_apply.sh reads.
# Getting this wrong is how bt_absvol_mode used to revert on every boot.
case "$_asb_blur_want" in
  1|on|true|off|light|partial) _asb_blur_want=1 ;;
  *)                           _asb_blur_want=0 ;;
esac
_asb_blur_have=0
grep -q '^persist\.sys\.sf\.disable_blurs=1' "$MODDIR/system.prop" 2>/dev/null && _asb_blur_have=1
if [ -f "$MODDIR/runtime/asb_blur_apply.sh" ]; then
  if [ "$_asb_blur_want" != "$_asb_blur_have" ]; then
    # Rebuild only the managed property payload.  The helper receives --boot so default
    # `disable_blur=0` cannot issue a late WindowManager display transaction on OOS/ColorOS.
    sh "$MODDIR/runtime/asb_blur_apply.sh" --boot >/dev/null 2>&1
    asb_log "disable_blur=$_asb_blur_want: system.prop block rebuilt; default display state untouched"
  elif [ "$_asb_blur_want" = "1" ]; then
    # Re-assert only the explicit opt-in direction.  Stock blur is owned by Android/OEM and
    # must not be rewritten at boot, because some vendor WindowManager stacks re-resolve user
    # display scale/density after a blur configuration transaction.
    _blur_now="$(settings get global disable_window_blurs 2>/dev/null)"
    case "$_blur_now" in ""|null) _blur_now=0 ;; esac
    if [ "$_blur_now" != "1" ]; then
      settings put global disable_window_blurs 1 >/dev/null 2>&1
      asb_log "blur: disable_window_blurs $_blur_now -> 1 (explicit opt-in)"
    fi
  fi
fi
(
  sleep 30
  _fg="$(getprop persist.sys.power.fuel.gauge 2>/dev/null)"
  [ "$_fg" != "0" ] && asb_persist_safe persist.sys.power.fuel.gauge 0
) >/dev/null 2>&1 &
# Reconcile and the watchdog now run on the governor's clock.
#
# Starting them here as well would mean two schedulers for the same job, and the resident shell
# loop is the more expensive of the two - it exists only to hold a sleep.
(
  sleep 90
  if ! pgrep -f '/bin/asb$' >/dev/null 2>&1 && [ "${ASB_STOCK_PROFILE:-0}" != "1" ]; then
    asb_log "governor not running after 90s - starting reconcile/watchdog loops as fallback"
    [ -r "$MODDIR/runtime/asb_reconcile.sh" ] && . "$MODDIR/runtime/asb_reconcile.sh"
  fi
) >/dev/null 2>&1 &
(
  sleep 60
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  if asb_feature_enabled CPU; then
    if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
      apply_walt_live
    fi
  fi
  asb_log "light reinforce 60s profile=$ASB_PROFILE"
  has settings && asb_settings_put global network_recommendations_enabled 0
  # If the user opted to manage OEM toggles, OxygenOS often re-enables RAM
  if [ -r "$MODDIR/config/governor.conf" ]; then
    _oem="$(grep -E '^[[:space:]]*UX_MANAGE_OEM_TOGGLES=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    if [ "$_oem" = "1" ] || [ "$_oem" = "on" ]; then
      _rex="$(grep -E '^[[:space:]]*UX_RAM_EXPAND=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_rex" in ''|*[!0-9]*) _rex=0 ;; esac
      command -v asb_ram_expand_apply >/dev/null 2>&1 && asb_ram_expand_apply "$_rex"
    fi
  fi
  sleep 240
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  asb_log "full reinforce 5m profile=$ASB_PROFILE"
  if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled VM && apply_doze
) >/dev/null 2>&1 &
# Make the governor re-read the config once everything has settled.
#
# Boot order is: governor starts, then this script keeps editing governor.conf - device
# bounds, first-install neutralisation, per-model branches. The governor loads the file at
# startup and then only on command, so it spent the whole session running values that were
# replaced seconds after it read them. A OP13 diagnostic said so in plain text: "governor.conf
# was edited AFTER the governor started".
#
# One reload after the writes are done costs nothing and removes a whole class of "the
# setting is in the file and the governor is ignoring it".
(
  sleep 100
  if pgrep -f '/bin/asb$' >/dev/null 2>&1 && [ -x "$MODDIR/bin/asb" ]; then
    "$MODDIR/bin/asb" reload >/dev/null 2>&1 \
      && asb_log "governor reloaded after boot-time config writes"
  fi
) >/dev/null 2>&1 &

(
  sleep 95
  if ! pgrep -f '/bin/asb$' >/dev/null 2>&1 && [ "${ASB_STOCK_PROFILE:-0}" != "1" ]; then
    [ -r "$MODDIR/runtime/asb_watchdog.sh" ] && . "$MODDIR/runtime/asb_watchdog.sh"
  fi
) >/dev/null 2>&1 &

asb_timeline_mark service_dispatched
# Mark the wait for boot_completed separately from our own work.
#
# The timeline now shows the module finishing at 15s and post_boot starting at 44s - a
# 29-second gap in which nothing of ours is marked. That gap is either Android booting
# at its own pace, or Android booting more slowly because of something we did, and the
# current marks cannot tell those apart. Recording when we START waiting, plus what the
# module is holding at that moment, makes the next capture decide it: if the gap stays
# the same with the CPU caps left at stock, the module is not the cause.
asb_timeline_mark boot_wait_begin
(
  _bw=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_bw" -lt 180 ]; do
    sleep 1; _bw=$((_bw + 1))
  done
  asb_timeline_mark boot_completed_seen
) &
exit 0
