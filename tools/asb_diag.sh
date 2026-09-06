#!/system/bin/sh
# ===================================================================== ASB GLOBAL DIAGNOSTIC —
# AutoSystemBoost full system audit
# ===================================================================== Easiest way to run
# (module installs a launcher on PATH): su -c asbdiag
#
#  Or run the script directly:
#       su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_diag.sh'
#
# Write probes are disabled by default. They temporarily change live CPU/GPU
# limits and can collide with a game, camera, thermal mitigation or PowerHAL.
# Run them only on an idle device with explicit consent:
#       su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_diag.sh --write-test'
#
# It inspects the LIVE system — the real mounted files and the real runtime properties/settings
# the OS is using right now — across every area ASB touches: module status, mounts, audio,
# bluetooth, GPS, Wi-Fi, network/TCP, camera, performance, display, props and the WebUI config.
#
# The full report is printed AND saved to: /sdcard/asb_diag_report.txt (storage root)
# /data/local/tmp/asb_diag_report.txt (fallback) The real filesystem root (/) is read-only, so
# "корень телефона" in practice means /sdcard — that's where the file lands.

# Read settings the way the module does.
# Without this the report showed "Failure calling service settings" for every value on a
# device where the module itself was already working through the content provider -
# the diagnostic was describing its own broken reads, not the module.
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh ] && \
  . /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh

WRITE_TEST=0
[ "${1:-}" = "--write-test" ] && WRITE_TEST=1
OUT1="/sdcard/asb_diag_report.txt"
OUT2="/data/local/tmp/asb_diag_report.txt"
: > "$OUT1" 2>/dev/null || OUT1=""
: > "$OUT2" 2>/dev/null || OUT2=""

P()  { printf '%s\n' "$1"; [ -n "$OUT1" ] && printf '%s\n' "$1" >> "$OUT1"; [ -n "$OUT2" ] && printf '%s\n' "$1" >> "$OUT2"; }
HR() { P "----------------------------------------------------------------"; }
SEC(){ P ""; P "================================================================"; P " $1"; P "================================================================"; }

PASS=0; FAIL=0; NA=0; INFO=0
# verdict: $1 label  $2 expected  $3 actual  $4 mode(eq|has|ge|present)
V() {
  _l="$1"; _e="$2"; _a="$3"; _m="${4:-eq}"; _st="FAIL"
  case "$_m" in
    eq)      [ "$_a" = "$_e" ] && _st="PASS" ;;
    has)     printf '%s' "$_a" | grep -q -- "$_e" && _st="PASS" ;;
    ge)      [ -n "$_a" ] && [ "$_a" -ge "$_e" ] 2>/dev/null && _st="PASS" ;;
    le)      [ -n "$_a" ] && [ "$_a" -le "$_e" ] 2>/dev/null && _st="PASS" ;;
    present) [ -n "$_a" ] && _st="PASS" ;;
  esac
  if [ -z "$_a" ] && [ "$_m" != "eq" ]; then _st="N/A "; NA=$((NA+1));
  elif [ "$_st" = "PASS" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); fi
  P "  [$_st] $_l"
  [ "$_m" != "info" ] && P "         want: $_e   live: ${_a:-<none>}"
}
NOTE(){ P "  (i) $1"; INFO=$((INFO+1)); }

gp() { getprop "$1" 2>/dev/null; }
firstf() { for _g in $@; do for _f in $_g; do [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }; done; done; return 1; }

# A vendor camera config may deliberately use JSON-with-comments. ASB strips leading
# comments from every payload it stages, but the live /odm file is not proof that ASB
# owns it: some root managers leave the vendor file visible, and unsupported camera
# domains have no ASB overlay at all. Report a real malformed ASB payload as FAIL;
# otherwise retain the observation as information rather than a false thermal/power alarm.
camera_json_comment_verdict() {
  _cj_file="$1"
  _cj_count="$(grep -cE '^[[:space:]]*//' "$_cj_file" 2>/dev/null)"
  if [ "${_cj_count:-0}" = "0" ]; then
    P "  [PASS] $_cj_file present, strict JSON (no // comments)"; PASS=$((PASS+1))
    return 0
  fi

  _cj_rel="${_cj_file#/odm}"
  _cj_asb_file=""
  _cj_asb_count=0
  # These are the exact destinations used by the installer and its deferred /odm bind.
  # A clean staged payload is intentionally not treated as ownership of a commented live
  # vendor file: the diagnostic must not turn a failed/unsupported mount into a false
  # claim that ASB wrote malformed JSON.
  for _cj_candidate in \
      "$MODDIR/system/odm$_cj_rel" \
      "$MODDIR/system/vendor/odm$_cj_rel" \
      "/data/adb/asb/odm_patched$_cj_file"; do
    [ -f "$_cj_candidate" ] || continue
    _cj_candidate_count="$(grep -cE '^[[:space:]]*//' "$_cj_candidate" 2>/dev/null)"
    if [ "${_cj_candidate_count:-0}" -gt 0 ] 2>/dev/null; then
      _cj_asb_file="$_cj_candidate"
      _cj_asb_count="$_cj_candidate_count"
      break
    fi
  done
  if [ -n "$_cj_asb_file" ]; then
    V "  ASB-managed camera payload has // comments (HAL JSON parser may reject)" "0" "$_cj_asb_count" eq
    NOTE "  staged payload: $_cj_asb_file"
  else
    NOTE "vendor JSON-with-comments: $_cj_file (${_cj_count}); ASB did not assert a JSON policy for this live vendor camera domain"
  fi
}

# ---- module discovery (KSU / APatch / Magisk) ----
MODDIR=""
for _root in /data/adb/modules /data/adb/ap/modules /data/adb/ksu/modules; do
  [ -d "$_root" ] || continue
  for _m in "$_root"/*; do
    [ -f "$_m/module.prop" ] || continue
    grep -q '^id=AutoSystemBoost$' "$_m/module.prop" 2>/dev/null && { MODDIR="$_m"; break; }
  done
  [ -n "$MODDIR" ] && break
done
[ -z "$MODDIR" ] && [ -d /data/adb/modules/AutoSystemBoost ] && MODDIR=/data/adb/modules/AutoSystemBoost
CONF="$MODDIR/config/governor.conf"
cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }

# =====================================================================
P "################################################################"
P "#         AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC            #"
P "################################################################"
P " date    : $(date 2>/dev/null)"
P " device  : $(gp ro.product.manufacturer) $(gp ro.product.model)  ($(gp ro.product.device))"
P " android : $(gp ro.build.version.release)  | build $(gp ro.build.id)"
P " platform: $(gp ro.board.platform)  | soc $(gp ro.soc.model)$(gp ro.hardware.chipname)"
P " kernel  : $(uname -r 2>/dev/null)"
_root_mgr="unknown"
[ -d /data/adb/ap ] && _root_mgr="APatch"
[ -d /data/adb/ksu ] && _root_mgr="KernelSU"
[ -f /data/adb/magisk/magisk ] && _root_mgr="Magisk"
P " root    : $_root_mgr"
P " module  : ${MODDIR:-NOT FOUND}"
[ -n "$MODDIR" ] && P " version : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)  ($(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"

if [ -z "$MODDIR" ]; then
  P ""; P "  !! AutoSystemBoost module not found — is it installed & enabled?"
  P ""; exit 0
fi

# =====================================================================
SEC "0. BOOT TIMELINE  (debug-only passive lifecycle evidence)"
_boot_timeline="/data/adb/asb/boot_timeline.tsv"
_boot_version="$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
# Keep this strict numeric debug-build rule in lockstep with runtime/asb_boot_timeline.sh
# and runtime/asb_debug_support.sh. A shell glob such as [1-9][0-9]* accidentally
# requires at least two digits, so it misclassified V64-debug4 as a release build.
_boot_debug=0
_boot_seq="${_boot_version##*-debug}"
case "$_boot_version:$_boot_seq" in
  *-debug[1-9]*:[1-9]*)
    case "$_boot_seq" in *[!0-9]*) ;; *) _boot_debug=1 ;; esac
    ;;
esac
if [ "$_boot_debug" = "1" ]; then
  if [ -r "$_boot_timeline" ]; then
    _boot_rows="$(grep -cv '^#' "$_boot_timeline" 2>/dev/null)"
    P "  recorder             : debug active · ${_boot_rows:-0} marker(s)"
    P "  boot reason           : $(grep '^# bootreason=' "$_boot_timeline" 2>/dev/null | head -1 | cut -d= -f2-)"
    P "  latest lifecycle rows:"
    tail -n 16 "$_boot_timeline" 2>/dev/null | while IFS= read -r _boot_row; do
      case "$_boot_row" in '#'*|'') continue ;; esac
      P "    $_boot_row"
    done
    NOTE "Rows use uptime_ms. A long gap before service_enter is pre-service; a long gap after service_dispatched is framework/vendor startup; a long post_boot_tweaks span identifies deferred helper work."
  else
    NOTE "No boot timeline yet. Reboot once, wait for the system to finish starting, then export asbdiag again."
  fi
else
  P "  recorder             : release build — disabled by design"
fi

# =====================================================================
SEC "0a. EXTERNAL KERNEL / UV COEXISTENCE  (read-only evidence; ASB owns no voltage policy)"
_uv_tool="$MODDIR/tools/asb_kernel_uv_coexist.sh"
_uv_tmp="/data/local/tmp/asb_uv_coexist.$$"
if [ -r "$_uv_tool" ]; then
  sh "$_uv_tool" > "$_uv_tmp" 2>/dev/null
  _uvget() { grep -E "^$1=" "$_uv_tmp" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
  _uv_status="$(_uvget status)"; _uv_conf="$(_uvget confidence)"; _uv_reason="$(_uvget reason)"
  P "  coexistence verdict  : ${_uv_status:-unavailable}  (confidence=${_uv_conf:-none})"
  P "  evidence             : ${_uv_reason:-unavailable}; $(_uvget evidence)"
  P "  ASB voltage owner    : $(_uvget asb_voltage_owner)"
  NOTE "$(_uvget warning)"
  NOTE "$(_uvget limit)"
  case "$_uv_status" in
    voltage_surface_observed|external_uv_hint)
      NOTE "External kernel/UV evidence is present. ASB keeps its CPU/GPU workload policy only; do not attribute voltage stability, reboot or thermal behavior to ASB alone." ;;
    *)
      NOTE "No explicit external UV evidence was observable. This is not proof that the current kernel uses stock voltage tables." ;;
  esac
  rm -f "$_uv_tmp" 2>/dev/null
else
  P "  coexistence verdict  : helper unavailable in this package"
fi

# ===================================================================== EFFECTIVE STATE — the
# computed source-of-truth summary.
SEC "0. EFFECTIVE STATE  (computed source-of-truth — read this first)"
# --- Smart enable: file-flag is truth, config is fallback ---
_sm_flag="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
_sm_cfg="$(cfg smart_mode_enabled)"
if [ -n "$_sm_flag" ]; then
  _sm_eff="$_sm_flag"; _sm_src="file-flag (/data/adb/asb/smart_mode_enabled)"
else
  _sm_eff="${_sm_cfg:-0}"; _sm_src="config-fallback (governor.conf, no file-flag yet)"
fi
[ "$_sm_eff" = "1" ] && _sm_word="ON" || _sm_word="OFF"
P "  smart_mode_effective : $_sm_word  ($_sm_eff)"
P "  smart_mode_source    : $_sm_src"
[ -n "$_sm_cfg" ] && [ -n "$_sm_flag" ] && [ "$_sm_cfg" != "$_sm_flag" ] && \
  NOTE "config says $_sm_cfg but the file-flag ($_sm_flag) wins — config value is just the shipped default."
# --- active profile + who owns the CPU caps right now ---
_prof="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prof="${_prof:-<unknown>}"
P "  active_profile       : $_prof"
if [ "$_sm_eff" = "1" ] || [ "$_prof" = "smart" ]; then
  _cap_owner="smart (governor/FSM synthesises caps from profile_bounds rails)"
  _fsm_active=1; _manual_active=0; _mode="smart"
else
  case "$_prof" in
    performance) _cap_owner="manual (service.sh — performance leaves clusters uncapped)" ;;
    *)           _cap_owner="manual (service.sh per-device % of cpuinfo_max — _P_CPUCAP_*)" ;;
  esac
  _fsm_active=0; _manual_active=1; _mode="manual"
fi
P "  cpu_cap_owner        : $_cap_owner"
P "  effective_profile_mode: $_mode    (fsm_bounds_active=$_fsm_active manual_caps_active=$_manual_active)"
NOTE "thermal override (writer/governor) can clamp on top of EITHER owner when the SoC runs hot."
# --- autonomy dial: smart_battery_bias resolves to an alpha lean ---
_bias="$(cfg smart_battery_bias)"; _bias="${_bias:-0}"
if [ "$_mode" = "smart" ] && [ "$_bias" -gt 0 ] 2>/dev/null; then
  P "  smart_battery_bias   : $_bias  (battery-lean nudge; scaled by learner confidence, hard-capped at pure-battery)"
  [ "$_bias" -ge 400 ] 2>/dev/null && NOTE "bias >= 400 can pin active-use alpha into battery-like behaviour — Smart then rides the BATTERY rail in profile_bounds.conf."
else
  P "  smart_battery_bias   : $_bias  (0 = no extra lean)"
fi
# --- canonical root manager (single detection, mirrors the module's own logic) ---
_rm="other"
[ -d /data/adb/ap ] && _rm="apatch"
[ -d /data/adb/ksu ] && _rm="ksu"
[ -f /data/adb/magisk/magisk ] && _rm="magisk-like"
P "  root_manager         : $_rm"
[ "$_rm" = "apatch" ] && NOTE "APatch path: OP12 camera handling is scoped specifically for APatch (real /odm mount)."

# =====================================================================
SEC "0b. CAMERA GRADE  (is the live tone table actually the graded one?)"
# Compare the marker against the file the camera really reads.
#
# The WebUI can say a camera tweak is saved, and it can say the value matches what was last
# baked - but neither answers "did the graded table reach the camera". The grader writes
# into the module tree, which is bind-mounted over /odm at boot; if that mount is missing or
# a later update replaced the file, the settings are correct and the picture is unchanged.
#
# So read the live path, pull one value the grader always rewrites, and print it next to
# the recorded one. Two numbers that agree is evidence; a status word is not.
_cg_mark=""
for _m in /data/adb/asb/grade_marks/*.mark; do
  [ -f "$_m" ] && { _cg_mark="$(cat "$_m" 2>/dev/null)"; break; }
done
if [ -n "$_cg_mark" ]; then
  NOTE "recorded grade: ${_cg_mark#*=}   (hash:level:grain:contrast:portrait:lowlight)"
else
  NOTE "recorded grade: none - the grader has not run on this install"
fi
_cg_live=""
for _f in /odm/etc/camera/config/video_beauty_default_config \
          /vendor/odm/etc/camera/config/video_beauty_default_config; do
  [ -r "$_f" ] || continue
  _cg_live="$_f"
  NOTE "live file: $_f"
  NOTE "  SatuColorScale in live file: $(grep -m1 -oE 'SatuColorScale[^,}]*' "$_f" 2>/dev/null)"
  NOTE "  sunsetSatScale in live file: $(grep -m1 -oE 'sunsetSatScale[^,}]*' "$_f" 2>/dev/null)"
  break
done
[ -n "$_cg_live" ] || NOTE "live file: not readable - camera config is not exposed here"
NOTE "(the module tree is bind-mounted over /odm at boot; a value here that never changes"
NOTE " between grade levels means the mount did not take, not that the tweak failed)"

SEC "0c. AUDIO CONFIG TREE  (which SKU the platform actually reads)"
# ColorOS keeps several SKU trees in one image and loads exactly one.
#
# A stock Ace 5 capture carries sku_pineapple, sku_cliffs and their _qssi variants side by
# side, plus audio_effects.xml at eleven separate paths. ASB's own path list has no SKU
# component, so on such a device it can find a file the framework never reads - and an
# effect registered in one config while audioserver loads another is how audioserver dies,
# taking SystemUI and the camera with it.
#
# Read-only. Printed so a mismatch is visible before it becomes a crash report.
NOTE "board platform: $(gp ro.board.platform)"
_ad_p="$(gp ro.board.platform)"
_ad_live=""
case "$_ad_p" in ''|*[!a-z0-9_]*) _ad_p="" ;; esac
if [ -n "$_ad_p" ]; then
  for _d in "/vendor/etc/audio/sku_$_ad_p" "/odm/etc/audio/sku_$_ad_p"; do
    [ -d "$_d" ] && { _ad_live="$_d"; break; }
  done
fi
NOTE "live audio SKU dir: ${_ad_live:-none (no SKU split on this platform)}"
_ad_n=0
for _f in /vendor/etc/audio_effects.xml /odm/etc/audio_effects.xml \
          /vendor/etc/audio/sku_*/audio_effects.xml /odm/etc/audio/sku_*/audio_effects.xml \
          /vendor/etc/audio_effects_config.xml /odm/etc/audio_effects_config.xml; do
  [ -f "$_f" ] && _ad_n=$(( _ad_n + 1 ))
done
NOTE "audio effect configs present: $_ad_n"
NOTE "(ASB patches audio only where the DSP library exists - see dsp_soundfx in capabilities)"

SEC "0a. DEVICE CAPABILITIES  (discovered facts — from device_caps.env)"
_caps="/data/adb/asb/device_caps.env"
if [ -f "$_caps" ]; then
  _cget() { grep -E "^$1=" "$_caps" 2>/dev/null | head -1 | sed 's/^[^=]*=//'; }
  P "  soc / codename       : $(_cget soc_platform) / $(_cget codename)  ($(_cget model))"
  P "  android api / kernel : $(_cget android_api) / $(_cget kernel)"
  P "  cpu policies         : $(_cget cpu_policy_count) clusters [$(_cget cpu_policy_list)]"
  for _pid in $(_cget cpu_policy_list); do
    _hm="$(_cget cpu_policy${_pid}_hwmax)"; _nf="$(_cget cpu_policy${_pid}_nfreq)"
    _lo="$(_cget cpu_policy${_pid}_lowest_opp)"; _mw="$(_cget cpu_policy${_pid}_min_writable)"
    P "    - policy${_pid}: hw_max=${_hm} kHz, lowest_opp=${_lo:-unknown} kHz, min_write=${_mw:-unknown}, ${_nf} freq steps"
  done
  P "  gpu backend          : $(_cget gpu_backend)"
  P "  thermal zones        : $(_cget thermal_zone_count)"
  P "  paths: odm_camera=$(_cget has_odm_camera_dir) vendor_audio=$(_cget has_vendor_audio_dir) wlan_txqlen=$(_cget has_wlan_txqlen)"
  NOTE "Raw discovered facts. These feed the per-device bounds synthesis below."
else
  P "  (device_caps.env not present yet — run a reinstall, or it writes on next boot)"
fi

# =====================================================================
SEC "0b. RUNTIME ARBITRATION & WRITE HEALTH  (live owner / requested vs applied)"
_runtime_caps="/data/adb/asb/capabilities.env"
_state="/dev/.asb/state"
_rget() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
_stock_thermal="/data/adb/asb/thermal_stock"
_eff_env="/data/adb/asb/active_efficiency.env"
if [ -r "$_eff_env" ]; then
  P "  active-use envelope  : status=$(_rget status "$_eff_env") tier=$(_rget tier "$_eff_env") soc=$(_rget soc "$_eff_env") reason=$(_rget reason "$_eff_env")"
  P "    capability gate     : cpu_policies=$(_rget cpu_policy_count "$_eff_env") gpu=$(_rget gpu_backend "$_eff_env") thermal_zones=$(_rget thermal_zone_count "$_eff_env")"
  P "    policy deltas       : budget=$(_rget budget_light_bonus_pct "$_eff_env")/$(_rget budget_moderate_bonus_pct "$_eff_env")/$(_rget budget_severe_bonus_pct "$_eff_env")% gpu_idle+$(_rget gpu_idle_trim_bonus_pct "$_eff_env")% bg_uclamp-$(_rget bg_uclamp_moderate_delta "$_eff_env")/$(_rget bg_uclamp_severe_delta "$_eff_env")"
else
  P "  active-use envelope  : unavailable (generated at boot; generic ASB policy remains active)"
fi
if [ -r "$_stock_thermal" ]; then
  P "  stock thermal        : source=$(_rget SOURCE \"$_stock_thermal\") zone=$(_rget ZONE \"$_stock_thermal\") trip=$(_rget INDEX \"$_stock_thermal\") type=$(_rget TYPE \"$_stock_thermal\") raw=$(_rget RAW \"$_stock_thermal\") resolved=$(_rget RESOLVED \"$_stock_thermal\")C"
  [ "$(_rget SOURCE \"$_stock_thermal\")" = "passive_trip_point" ] || NOTE "No passive CPU trip was confirmed: stock/smart mode keeps the configured threshold unchanged."
else
  P "  stock thermal        : unavailable (captured on next boot)"
fi
if [ -r "$_runtime_caps" ]; then
  P "  boot manifest         : policies=$(_rget cpu_policy_count "$_runtime_caps") opp_complete=$(_rget cpu_opp_complete "$_runtime_caps") cgroup_v1=$(_rget cgroup_v1 "$_runtime_caps") cgroup_v2=$(_rget cgroup_v2 "$_runtime_caps")"
  P "  optional signals      : uclamp=$(_rget uclamp "$_runtime_caps") thermal=$(_rget thermal_sensors "$_runtime_caps") battery_current=$(_rget battery_current "$_runtime_caps") gpu_devfreq=$(_rget gpu_devfreq "$_runtime_caps")"
else
  P "  boot manifest         : unavailable (probe may not have completed)"
fi
_pack_state="/data/adb/asb/device_pack.state"
_props_state="/data/adb/asb/managed_props.state"
if [ -r "$_pack_state" ]; then
  P "  device-pack state     : status=$(_rget status "$_pack_state") reason=$(_rget reason "$_pack_state")"
else
  P "  device-pack state     : unavailable"
fi
if [ -r "$_props_state" ]; then
  P "  managed properties    : status=$(_rget status "$_props_state") reason=$(_rget reason "$_props_state") applied=$(_rget applied "$_props_state") skipped=$(_rget skipped "$_props_state")"
else
  P "  managed properties    : unavailable (applier has not run)"
fi
for _lease in /dev/.asb/arbiter/*.lease; do
  [ -r "$_lease" ] || continue
  _lo="$(_rget owner "$_lease")"; _lp="$(_rget priority "$_lease")"; _lr="$(_rget reason "$_lease")"; _le="$(_rget expires "$_lease")"
  _ld="$(_rget desired "$_lease")"; _la="$(_rget applied "$_lease")"; _lerr="$(_rget last_error "$_lease")"
  P "  lease ${_lease##*/} : owner=${_lo:-?} priority=${_lp:-?} reason=${_lr:-?} desired=${_ld:--} applied=${_la:--} error=${_lerr:-none} expires=${_le:-?}"
done
[ -f /dev/.asb/camera_guard ] && P "  camera lease          : ACTIVE (foreground/top-app/uclamp remain camera-owned)" || P "  camera lease          : inactive"
if [ -r "$_state" ]; then
  _wattempts="$(_rget writer_attempts "$_state")"; _wapplied="$(_rget writer_applied "$_state")"; _wfail="$(_rget writer_failures "$_state")"; _wskip="$(_rget writer_backoff_skips "$_state")"
  P "  writer health         : attempts=${_wattempts:-0} applied=${_wapplied:-0} failures=${_wfail:-0} backoff_skips=${_wskip:-0}"
  _w_vendor_ceiling="$(grep -E '^writer_node_cpu_max[0-2]=.*status:vendor_stricter_ceiling' "$_state" 2>/dev/null | cut -d= -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [ -n "$_w_vendor_ceiling" ] && NOTE "Vendor already holds a stricter CPU ceiling on ${_w_vendor_ceiling}; ASB accepts it and avoids a cap fight."
  P "  energy policy         : shadow=$(_rget shadow_mode "$_state") budget_enabled=$(_rget thermal_budget_enabled "$_state") trim=$(_rget thermal_budget_trim_pct "$_state")% (base=$(_rget thermal_budget_base_trim_pct "$_state")% + envelope=$(_rget thermal_budget_envelope_bonus_pct "$_state")%, stage=$(_rget thermal_budget_stage "$_state")) reason=$(_rget thermal_budget_reason "$_state") dwell=$(_rget thermal_budget_dwell_s "$_state")s"
  P "  active-use runtime    : loaded=$(_rget active_efficiency_active "$_state") tier=$(_rget active_efficiency_tier "$_state") reason=$(_rget active_efficiency_reason "$_state") gpu_idle_bonus=$(_rget active_efficiency_gpu_idle_bonus_pct "$_state")% bg_delta=$(_rget active_efficiency_bg_uclamp_moderate_delta "$_state")/$(_rget active_efficiency_bg_uclamp_severe_delta "$_state")"
  P "  ASB overhead          : events=$(_rget governor_event_wakeups "$_state") timer_wakeups=$(_rget governor_timer_wakeups "$_state") cpu_ms=$(_rget governor_cpu_ms "$_state")"
  if [ "${_wfail:-0}" = "0" ]; then
    NOTE "All observed native writes have read back successfully."
  else
    # Frequency-table size first: it decides how to read everything below.
    _ftn="$(grep -m1 "^freq_table_n=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d "\"")"
    case "${_ftn:-}" in
      ""|0,0,0) NOTE "OPP table not enumerable on this kernel - ceilings are written unrounded,"
                NOTE "  so observed>requested below is the kernel rounding up, not a vendor override." ;;
      *) NOTE "OPP steps per cluster: ${_ftn} (snapping active)" ;;
    esac
    NOTE "Writer failures are backoff-limited. Recent rejected writes:"
    # Show the rows instead of naming the file.
    #
    # This used to say "inspect /dev/.asb/write_errors" - which is exactly what nobody can
    # do from a pasted report, and what turned a one-line diagnosis into three rounds of
    # guessing at which node was failing and why. The rows carry the node, the value asked
    # for and the value read back; that triple is usually the whole answer.
    if [ -s /dev/.asb/write_errors ]; then
      tail -8 /dev/.asb/write_errors 2>/dev/null | while IFS= read -r _wl; do
        P "    $_wl"
      done
      NOTE "counts by node:"
      sed -n 's/.*node=\([A-Za-z_0-9]*\).*/\1/p' /dev/.asb/write_errors 2>/dev/null |
        sort | uniq -c | sort -rn | head -6 | while read -r _wn _wnode; do
          P "    ${_wnode}: ${_wn} rejected write(s)"
        done
    else
      NOTE "(no rows recorded yet - failures counted but nothing written to /dev/.asb/write_errors)"
    fi
  fi
else
  P "  (native state unavailable — start the governor before checking applied telemetry)"
fi

# =====================================================================
SEC "0a1. STOCK-FILE INVENTORY  (what was patchable at install — install_probe.txt)"
_probe="/data/adb/asb/install_probe.txt"
if [ -f "$_probe" ]; then
  # Echo the install-time per-subsystem summary (audio/wifi/perf/gps/camera/cpu)
  # plus the declared audio SKU, so a field report shows exactly what ASB found
  # it could tune on this specific model.
  _pl="$(grep -E '^[[:space:]]*declared_sku=' "$_probe" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')"
  [ -n "$_pl" ] && P "  $_pl"
  # Per-subsystem summary of what ASB actually tuned on THIS model (key-level).
  sed -n '/SUMMARY (what ASB/,/Inventory only/p' "$_probe" 2>/dev/null \
    | grep -E '^[[:space:]]+(audio|wifi|perf|gps|camera|cpu)[[:space:]]+:' \
    | while IFS= read -r _ln; do P "  $_ln"; done
  # Key-level tunability detail (which exact keys exist on this device's stock).
  _ct="$(grep -E '^[[:space:]]*camera_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _at="$(grep -E '^[[:space:]]*audio_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _wt="$(grep -E '^[[:space:]]*wifi_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _mt="$(grep -E '^[[:space:]]*media_codecs_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _pt="$(grep -E '^[[:space:]]*perf_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _gt="$(grep -E '^[[:space:]]*gps_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  if [ -n "$_ct$_at$_wt$_mt$_pt$_gt" ]; then
    P "  tunable: camera=${_ct:-?} audio=${_at:-?} wifi=${_wt:-?} media=${_mt:-?} perf=${_pt:-?} gps=${_gt:-?}"
  fi
  NOTE "Captured at install. Full inventory + key lists: $_probe"
else
  P "  (install_probe.txt not present — written on next install)"
fi

# =====================================================================
SEC "0a2. DEVICE-ADAPTIVE BOUNDS  (OP15-ratio synthesis — device_bounds.env)"
_dbounds="/data/adb/asb/device_bounds.env"
_ovr_flag="$(cfg device_bounds_override)"
P "  override active       : ${_ovr_flag:-0}  (governor consumes device_bounds.env only when =1)"
if [ -f "$_dbounds" ]; then
  _dconf="$(grep -E '^# confidence=' "$_dbounds" 2>/dev/null | head -1 | sed 's/^# confidence=//')"
  P "  synthesis confidence  : ${_dconf:-unknown}"
  _nvals="$(grep -cE '^[A-Z].*=' "$_dbounds" 2>/dev/null)"
  if [ "${_nvals:-0}" -gt 0 ] 2>/dev/null; then
    P "  synthesised bounds (scaled from OP15 ratios, snapped to this device):"
    grep -E '^[A-Z].*=' "$_dbounds" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
    if [ "${_ovr_flag:-0}" != "1" ]; then
      NOTE "These are a PREVIEW — not applied (override flag is off). The governor is using its compiled defaults. On OP15 the synthesised values equal those defaults anyway."
    else
      NOTE "ACTIVE: the governor loaded these over its compiled defaults at boot."
    fi
  else
    P "  (no overrides emitted — see confidence note above; compiled defaults stand)"
  fi
else
  P "  (device_bounds.env not present yet — writes at install or next boot)"
fi

# =====================================================================
SEC "0b. MODULE STATE  (running, mounts, governor)"
P "  module flags:"
for _fl in disable remove update skip_mount; do
  [ -f "$MODDIR/$_fl" ] && P "    - $_fl present (!!)" || P "    - $_fl absent (ok)"
done
# governor process
_gov_pid="$(pgrep -f 'asb_governor' 2>/dev/null | head -1)"
[ -z "$_gov_pid" ] && _gov_pid="$(pgrep -f '/asb' 2>/dev/null | head -1)"
V "ASB governor process alive" "running" "$([ -n "$_gov_pid" ] && echo running)" present
P "  current profile : $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# is module's system actually mounted?
_mounted="$(grep -c "AutoSystemBoost" /proc/mounts 2>/dev/null)"
NOTE "mount entries mentioning the module: ${_mounted:-0}"
# how the overlay arrived
P "  partitions handled by root mgr (from mounts):"
for _pp in vendor odm product system_ext; do
  grep -q " /$_pp " /proc/mounts 2>/dev/null && P "    - /$_pp is a mount point" || P "    - /$_pp not separately mounted"
done

# =====================================================================
SEC "1. AUDIO  (mixer files + runtime props)"
MIX="$(firstf '/vendor/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/odm/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/vendor/etc/audio/mixer_paths*.xml' '/odm/etc/audio/mixer_paths*.xml')"
if [ -n "$MIX" ]; then
  P "  mixer file: $MIX"
  _vpeak=$(grep -oE '(RX_RX[012]|WSA_RX[01]) Digital Volume" value="[0-9]+"' "$MIX" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
  _vclip=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="\(9[0-9]\|1[0-9][0-9]\)"' "$MIX" 2>/dev/null)
  _iir=$(grep -c 'IIR0 Enable Band[1-5]" value="1"' "$MIX" 2>/dev/null)
  _rdac=$(grep -c 'HPH[LR]_RDAC Switch" value="1"' "$MIX" 2>/dev/null)
  NOTE "RX/WSA Digital Volume peak: ${_vpeak:-n/a}  (84=0dB unity; SM8650/pineapple caps at 84, sun/canoe accept 88)"
  V "No out-of-range Digital Volume (>88 would break the speaker path)" "0" "$_vclip" eq
  V "IIR0 EQ bands flattened (engaged=0)" "0" "$_iir" eq
  V "Class-H headphone DAC armed (RDAC=1 present)" "1" "$_rdac" ge
  # aggressive (toggle)
  _aud_aggr="$(cfg audio_dac_hifi)"
  [ -n "$_aud_aggr" ] || _aud_aggr="$(cfg AUDIO_AGGRESSIVE)"
  NOTE "audio_dac_hifi toggle = ${_aud_aggr:-0}"
  if [ "${_aud_aggr:-0}" = "1" ]; then
    _comp=$(grep -c 'HPH[LR] Compander" value="1"' "$MIX" 2>/dev/null)
    _hifi=$(grep -c 'RX HPH Mode" value="CLS_H_HIFI"' "$MIX" 2>/dev/null)
    V "Aggressive: HPH companders OFF (engaged=0)" "0" "$_comp" eq
    V "Aggressive: RX HPH Mode = CLS_H_HIFI" "1" "$_hifi" ge
  fi
else
  NA=$((NA+1)); P "  [N/A ] no mixer_paths*.xml found on /vendor or /odm"
fi
# hi-res
APOL="$(firstf '/vendor/etc/audio_policy_configuration*.xml' '/odm/etc/audio_policy_configuration*.xml' '/vendor/etc/audio/audio_policy_configuration*.xml')"
[ -n "$APOL" ] && V "Hi-res 384000 present in audio policy" "1" "$(grep -c '384000' "$APOL" 2>/dev/null)" ge || NOTE "audio_policy_configuration not found"
# runtime audio props
P "  runtime audio props:"
for _p in persist.audio.hifi persist.audio.uhqa vendor.audio.hifi.dac \
          vendor.audio.feature.hifi_audio.enable \
          persist.vendor.audio.hifi.dac.enable \
          ro.vendor.audio.sdk.fluencetype \
          vendor.audio.offload.buffer.size.kb \
          persist.vendor.audio.ull.period.size; do
  P "    $_p = $(gp $_p)"
done

# HFP state, because that is where the field failures are.
#
# A capture from a CPH2769 recorded 35 hfp_audio disconnects in one session, median hold
# 27 seconds, 18 of them under 30 - the signature of SCO being opened, carrying nothing,
# and being torn down. A2DP was almost untouched, so this is the call profile, not music.
#
# ASB does not configure HFP and will not start: the read-only picture comes first. These
# are the knobs that decide whether the stack keeps an idle SCO link alive, and knowing
# their live values is what separates a fix from a guess.
P "  HFP / SCO state:"
for _p in persist.bluetooth.hfp_available_guard bt.max.hfpclient.connections \
          persist.vendor.btstack.enable.swb persist.vendor.qcom.bluetooth.enable.splita2dp \
          persist.bluetooth.sco_managed_by_audio; do
  P "    $_p = $(gp $_p)"
done
_hfp_sr="$(settings get global bluetooth_hfp_client_enabled 2>/dev/null)"
P "    setting bluetooth_hfp_client_enabled = ${_hfp_sr:-<unset>}"
_hfp_ev="/data/adb/asb/bt_lifecycle_events.tsv"
if [ -r "$_hfp_ev" ]; then
  P "    recorded hfp disconnects: $(grep -c 'hfp_audio_disconnect' "$_hfp_ev" 2>/dev/null)"
  P "    recorded a2dp disconnects: $(grep -c 'a2dp_profile_disconnect' "$_hfp_ev" 2>/dev/null)"
else
  P "    (no lifecycle recording - start a capture with ASB_BT_RECONNECT_TRACE=1)"
fi
# audio_profile (replaced AUDIO_EQ_COMPAT + the property half of AUDIO_AGGRESSIVE)
NOTE "audio_profile = $(cfg audio_profile)"

# =====================================================================
# media_loudness rewrites the volume curves rather than any property, so the check is
# whether the curve file carries our marker - a config value alone proves nothing here.
NOTE "media_loudness = $(cfg media_loudness)"
_vt="$(firstf '/vendor/etc/default_volume_tables.xml' '/odm/etc/default_volume_tables.xml')"
if [ -n "$_vt" ]; then
  V "  volume curves rebuilt by ASB" "present" "$(grep -m1 -o 'ASB:VOLCURVE' "$_vt" 2>/dev/null)" present
fi
_a2dp_req="$(cfg bt_a2dp_offload)"
_a2dp_set="$(settings get global bluetooth_a2dp_offload_enabled 2>/dev/null)"
NOTE "bt_a2dp_offload: requested=${_a2dp_req:-auto}  ·  setting=${_a2dp_set:-<unavailable>}  ·  platform_disabled=$(gp persist.bluetooth.a2dp_offload.disabled)  ·  vendor_disabled=$(gp persist.vendor.bluetooth.a2dp_offload.disabled)"

SEC "0e. UCLAMP TIERS  (what the scheduler is allowed to ask for, per tier)"
# Read the tiers, not the lease.
#
# The lease line reports whichever tier claimed it last, so a diag showed desired=24 - the
# background value - while top-app was a different number entirely. One figure standing in
# for four made it impossible to tell whether a change to the foreground tier had taken
# effect, which is exactly the question that mattered after top-app was exempted from
# perf_ceiling_pct.
#
# top-app is the one the user is waiting on. If it reads far below the profile rail, the
# scheduler will refuse to raise frequency for the app on screen no matter what the task
# asks for - and the work then finishes slowly, with the display and radio awake for all
# of it.
for _uc_root in /dev/cpuctl /sys/fs/cgroup/cpu; do
  [ -d "$_uc_root" ] || continue
  for _uc_t in top-app foreground background system-background; do
    _uc_v=""
    for _uc_f in "$_uc_root/$_uc_t/cpu.uclamp.max" "$_uc_root/$_uc_t/uclamp.max"; do
      [ -r "$_uc_f" ] && { _uc_v="$(cat "$_uc_f" 2>/dev/null)"; break; }
    done
    [ -n "$_uc_v" ] && NOTE "$_uc_t uclamp.max = $_uc_v"
  done
  _uc_ls=""
  for _uc_f in "$_uc_root/top-app/cpu.uclamp.latency_sensitive" "$_uc_root/top-app/uclamp.latency_sensitive"; do
    [ -r "$_uc_f" ] && { _uc_ls="$(cat "$_uc_f" 2>/dev/null)"; break; }
  done
  [ -n "$_uc_ls" ] && NOTE "top-app latency_sensitive = $_uc_ls"
  break
done
NOTE "(profile rails: top-app should track UCL_TOP_MAX; perf_ceiling_pct no longer scales it)"

SEC "0f. LSPOSED LOGGING  (read only — ASB never changes another module's settings)"
# Report it, do not touch it.
#
# A user asked ASB to switch LSPosed logging off, reasoning that the logging costs battery.
# ASB will not: LSPosed is a separate root module with its own configuration, and writing
# into another module's files makes ASB the kind of unannounced second writer this project
# has spent weeks untangling on the cap path. LSPosed does not know about us and would not
# put its settings back.
#
# What is useful is showing the state, so the answer is one glance instead of a guess. On
# the capture that prompted this, LSPosed had written zero lines - the noisy tags were
# ifw_intent_matched, FlagUtils and SmartTempDdsSwitchController, all OxygenOS components.
_lsp_dir=""
for _d in /data/adb/lspd /data/adb/lspd/log /data/misc/lspd; do
  [ -d "$_d" ] && { _lsp_dir="$_d"; break; }
done
if [ -z "$_lsp_dir" ]; then
  NOTE "LSPosed not present (no /data/adb/lspd) - nothing to report"
else
  NOTE "LSPosed directory: $_lsp_dir"
  _lsp_log_bytes=0
  for _f in /data/adb/lspd/log/*.log /data/adb/lspd/log/*/*.log; do
    [ -f "$_f" ] || continue
    _sz=$(wc -c < "$_f" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) continue ;; esac
    _lsp_log_bytes=$(( _lsp_log_bytes + _sz ))
  done
  NOTE "log files on disk: $(( _lsp_log_bytes / 1024 )) KiB"
  # A verbose_* file is the one LSPosed only writes when verbose logging is enabled, so its
  # presence answers the question directly.
  _lsp_verbose=0
  for _f in /data/adb/lspd/log/verbose_*.log; do [ -f "$_f" ] && _lsp_verbose=1; done
  if [ "$_lsp_verbose" = "1" ]; then
    NOTE "verbose logging: ON  -  turn it off in the LSPosed manager under Logs, not here"
  else
    NOTE "verbose logging: no verbose_*.log present (likely off)"
  fi
  NOTE "(ASB reports this and changes nothing: another module's settings are its own)"
fi

SEC "1a2. AUDIO ROUTE  (what the pipeline is doing right now — read only)"
# Measure the audio path instead of asserting properties at it.
#
# A comparative audit of two other Qualcomm modules concluded that their real value is not
# the property packs they ship - those fight whoever else owns the same files - but the
# fact that they force the question: which route is actually active, and is anything
# offloaded? ASB has never been able to answer it, and audio is the most expensive screen-on
# phase in every capture we have: 348 mA and 14.83 %/h for Bluetooth playback in the last
# one, against 152 for the same audio with the screen off.
#
# Everything below is a read. Nothing here changes a route, a codec or a property - if a
# node is absent the line says so and the report moves on.
_ap="$(dumpsys audio 2>/dev/null)"
if [ -n "$_ap" ]; then
  NOTE "active devices: $(echo "$_ap" | grep -m1 -iE 'Devices?:.*(SPEAKER|BLUETOOTH|USB|HEADSET|HEADPHONE)' | sed 's/^[[:space:]]*//' | cut -c1-90)"
  NOTE "audio mode: $(echo "$_ap" | grep -m1 -iE '^[[:space:]]*Mode:' | sed 's/^[[:space:]]*//' | cut -c1-60)"
else
  NOTE "dumpsys audio unavailable - route unknown"
fi
# Offload EVIDENCE, not an offload verdict.
#
# The first version of this block said hw_params and the PCM device count told us whether
# the DSP or the CPU was decoding. They do not: hw_params describes a stream's format, the
# device count is static platform topology, and a2dp_offload.cap is a capability list -
# what the platform CAN do, not what it IS doing. A review caught the overreach, and it
# mattered: the next step is an A/B experiment on A2DP offload, and starting that from a
# guess dressed as a measurement is how you get a result that means nothing.
#
# So: gather the signals, print them, and say "unknown" when they do not agree. A blank is
# more useful than a confident wrong answer.
_ev_req="$(cfg bt_a2dp_offload)"
_ev_set="$(settings get global bluetooth_a2dp_offload_enabled 2>/dev/null)"
_ev_pdis="$(gp persist.bluetooth.a2dp_offload.disabled)"
_ev_vdis="$(gp persist.vendor.bluetooth.a2dp_offload.disabled)"
_ev_cap="$(gp persist.bluetooth.a2dp_offload.cap)"
# AudioFlinger names an offloaded or compressed thread outright; that is the only line here
# that describes the running pipeline rather than its configuration.
_ev_af="$(dumpsys media.audio_flinger 2>/dev/null | grep -m1 -iE 'Offload|Compress' | sed 's/^[[:space:]]*//' | cut -c1-70)"
NOTE "a2dp evidence: requested=${_ev_req:-auto} setting=${_ev_set:-<none>} platform_disabled=${_ev_pdis:-<none>} vendor_disabled=${_ev_vdis:-<none>}"
NOTE "a2dp codecs advertised: ${_ev_cap:-<none>}   (capability, not proof of live offload)"
NOTE "audioflinger thread: ${_ev_af:-<no offload/compress thread reported>}"
# An offload thread is not evidence unless it belongs to THIS route, right now.
#
# The first version called any AudioFlinger Offload/Compress thread proof of A2DP
# offload. A review pointed out what that misses: the thread may serve a different
# output, or linger after playback stopped. Either way it produces a confident answer
# about Bluetooth from a signal that never mentioned Bluetooth - the same overreach
# this block was rewritten to remove once already.
#
# Three things must agree before the verdict firms up: a thread exists, the active
# route is Bluetooth, and something is actually playing. Short of that the honest
# answer is what is printed - the evidence, and "unknown".
_ev_route="$(echo "$_ap" | grep -m1 -icE 'Devices?:.*BLUETOOTH')"
_ev_play="$(dumpsys audio 2>/dev/null | grep -m1 -icE 'state:started|player piid.*started')"
# Conflict first, in the same order the shared logkit uses.
#
# The previous order set "off" from the properties and then let the thread branch
# overwrite it, so a phone whose vendor property blocks offload while AudioFlinger shows
# a thread on an active BT route was told "offload thread present" - a confident answer
# assembled from two signals that contradict each other. The shared logkit already calls
# that case "unknown (conflicting)", and two copies of one contract disagreeing is the
# defect this whole block was rewritten twice to remove.
_ev_blocked=0
case "$_ev_pdis$_ev_vdis" in *true*) _ev_blocked=1 ;; esac
if [ -n "$_ev_af" ] && [ "$_ev_blocked" = "1" ]; then
  _ev_verdict="unknown (conflicting AudioFlinger/property evidence)"
elif [ -n "$_ev_af" ] && [ "${_ev_route:-0}" -gt 0 ] && [ "${_ev_play:-0}" -gt 0 ]; then
  _ev_verdict="AudioFlinger offload/compress observed during BT playback (route association unverified)"
elif [ -n "$_ev_af" ]; then
  _ev_verdict="AudioFlinger offload/compress thread present (not tied to active BT playback)"
elif [ "$_ev_blocked" = "1" ]; then
  _ev_verdict="A2DP offload blocked by platform/vendor property"
else
  _ev_verdict="unknown"
fi
NOTE "offload state: $_ev_verdict"
NOTE "(read-only section: ASB changes nothing here, it only reports what the platform chose)"

SEC "1b. DSP ENGINE  (what the effect is actually doing)"
# The whole DSP block was missing from this report - six settings, none of them checked,
# on the subsystem most likely to be silently doing nothing. Config against live property
# is the only way to tell "configured" from "in force": the library reads the properties,
# not governor.conf.
_dsp_g="$(cfg dsp_loudness)"
case "$_dsp_g" in ''|0|off) NOTE "dsp_loudness = off - the effect is released from the audio path entirely" ;;
  *)
    _dsp_requested_mb=$((_dsp_g * 100))
    _dsp_expected_mb="$_dsp_requested_mb"
    [ "$_dsp_expected_mb" -gt 2500 ] && _dsp_expected_mb=2500
    V "  DSP gain applied (persist.asb.dsp.gain_mb)" "$_dsp_expected_mb" "$(gp persist.asb.dsp.gain_mb)" eq
    [ "$_dsp_requested_mb" -ne "$_dsp_expected_mb" ] && \
      NOTE "  requested ${_dsp_requested_mb}mB is safely capped to ${_dsp_expected_mb}mB (+25 dB compatibility limit)"
    V "  DSP enabled" "1" "$(gp persist.asb.dsp.enable)" eq
    ;;
esac
NOTE "dsp_bass = $(cfg dsp_bass)  ·  live: $(gp persist.asb.dsp.bass_db)"
NOTE "dsp_compressor = $(cfg dsp_compressor)  ·  live comp: $(gp persist.asb.dsp.comp)"
# Output routing needs the rebuilt library to take effect; a config that says bt with a
# library that predates the feature will process everything and look correct here.
_dsp_o="$(cfg dsp_outputs)"
# Only meaningful while the engine is running.
#
# This reported FAIL on three of six devices in a cross-device sweep, every one of them
# with dsp_loudness=off - the effect is released from the audio path entirely, so the
# routing property is unset by design. Flagging that as a failure trains people to skim
# past red lines, which costs more than the check is worth.
if [ "$(cfg dsp_loudness)" = "off" ] || [ "$(gp persist.asb.dsp.enable)" != "1" ]; then
  NOTE "  DSP outputs: not applicable - the engine is off, so routing is unset by design"
else
  V "  DSP outputs live (persist.asb.dsp.outputs)" "${_dsp_o:-all}" "$(gp persist.asb.dsp.outputs)" eq
fi
NOTE "  DSP requested/applied gain: requested=$(gp persist.asb.dsp.gain_requested_mb)mB  ·  applied=$(gp persist.asb.dsp.gain_applied_mb)mB  ·  published_route=$(gp persist.asb.dsp.route)"
case "$(gp persist.asb.dsp.outputs)" in
  '') NOTE "outputs property unset - library may predate per-output routing (rebuild libasbdsp)" ;;
esac
_sfx64="$(ls -l /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null | awk '{print $5}')"
NOTE "installed library: ${_sfx64:-<absent>} bytes 64-bit  ·  ABI $(cat /data/adb/modules/AutoSystemBoost/dsp_abi_installed 2>/dev/null)"
_dsp_pid="$(pidof audiohalservice.qti 2>/dev/null)"
if [ -n "$_dsp_pid" ]; then
  V "  library mapped into the audio HAL" "present" \
    "$(grep -c asbdsp /proc/$_dsp_pid/maps 2>/dev/null | grep -v '^0$')" present
fi
V "  effect registered with audioflinger" "present" \
  "$(dumpsys media.audio_flinger 2>/dev/null | grep -m1 -o 'ASB Loudness')" present

# =====================================================================
SEC "2. BLUETOOTH"
# Automatic link-drop mitigation, when it engaged.
#
# Shown because the phone quietly changed a Wi-Fi setting on the user's behalf, and that
# should never be invisible - even when it is the right call.
if [ -f "${ASB_CONFIG_STATE:-/data/adb/asb}/bt_link_auto" ]; then
  NOTE "repeated audio-link drops were detected - Wi-Fi scanning is throttled to keep the link"
  _btl="${ASB_CONFIG_STATE:-/data/adb/asb}/bt_link_watch.log"
  [ -s "$_btl" ] && tail -2 "$_btl" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
fi
_btmode="$(cfg bt_absvol_mode)"
NOTE "bt_absvol_mode toggle = ${_btmode:-auto}"
P "  live bluetooth props:"
for _p in persist.bluetooth.disableabsvol persist.bluetooth.leaudio.enabled \
          persist.bluetooth.spatial_audio_support persist.bluetooth.enablenewavrcp \
          persist.bluetooth.a2dp_offload.cap; do
  P "    $_p = $(gp $_p)"
done
# global absolute-volume setting
_absvol="$(settings get global bluetooth_disable_absolute_volume 2>/dev/null)"
NOTE "settings global bluetooth_disable_absolute_volume = ${_absvol:-<unset>}"
case "${_btmode:-auto}" in
  on)  V "BT absolute volume disabled (mode=on)" "1" "$_absvol" eq ;;
  off) V "BT absolute volume kept (mode=off)" "0" "$_absvol" eq ;;
  *)   NOTE "BT mode auto — no forced expectation" ;;
esac

# =====================================================================
SEC "3. GPS / LOCATION"
_gfound=0
for GP in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf /system/etc/gps.conf; do
  [ -f "$GP" ] || continue
  _gfound=1
  _cap=$(grep -E '^CAPABILITIES=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  _ntp=$(grep -E '^(NTP_SERVER|XTRA_SERVER_1)=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  P "  file: $GP"
  # CAPABILITIES is a hardware capability bitmask that legitimately differs per SoC (OP15
  # canoe=0x3F, OP12 pineapple=0x17).
  # It must NOT be forced to a fixed value — doing so could advertise GNSS features the chip
  # lacks.
  [ -n "$_cap" ] && NOTE "GNSS $_cap (device-native bitmask; not forced)"
  [ -n "$_ntp" ] && NOTE "NTP/XTRA: $_ntp"
done
[ "$_gfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no gps.conf found in live system"; }

# =====================================================================
SEC "4. WI-FI"
_wfound=0
for WF in /vendor/etc/wifi/*/WCNSS_qcom_cfg.ini /vendor/etc/wifi/WCNSS_qcom_cfg.ini /odm/etc/wifi/*/WCNSS_qcom_cfg.ini; do
  [ -f "$WF" ] || continue
  _wfound=1
  P "  file: $WF"
  _pmd=$(grep -E '^gRuntimePMDelay=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  _amc=$(grep -E '^gActiveMaxChannelTime=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  _bbw=$(grep -E '^gBusBandwidthVeryHighThreshold=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  # Device-safe clamp semantics: the patch only LOWERS these toward a ceiling and never raises
  # a device that already ships a better (lower) value.
  [ -n "$_pmd" ] && V "  gRuntimePMDelay<=2000 (lower=quicker idle)" "2000" "$_pmd" le
  [ -n "$_amc" ] && V "  gActiveMaxChannelTime<=40 (lower=shorter dwell)" "40" "$_amc" le
  [ -n "$_bbw" ] && V "  gBusBandwidthVeryHighThreshold<=12000" "12000" "$_bbw" le
done
[ "$_wfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no WCNSS_qcom_cfg.ini found"; }
# supplicant safety
SUP="$(firstf '/vendor/etc/wifi/wpa_supplicant_overlay.conf' '/odm/etc/wifi/wpa_supplicant_overlay.conf')"
[ -n "$SUP" ] && V "supplicant keeps p2p_disabled=1 (Wi-Fi-safe)" "1" "$(grep -c 'p2p_disabled=1' "$SUP" 2>/dev/null)" ge
P "  live wifi link: $(dumpsys wifi 2>/dev/null | grep -m1 -iE 'mWifiInfo|SSID' | sed 's/^[[:space:]]*//' | cut -c1-70)"

# =====================================================================
# Can Settings be reached at all? Ask once, loudly, before anything that depends on it.
#
# A OnePlus 15R report had ten separate lines reading "cmd: Failure calling service
# settings" scattered through Bluetooth, RAM expand, adaptive battery and the lockscreen -
# each looking like its own small problem. They were one problem: the settings command
# cannot bind to the service on that device, and it exits 0 while failing, so every caller
# believed it had worked. One line at the top is worth ten buried ones.
_set_probe="$(settings get system screen_off_timeout 2>/dev/null)"
case "$_set_probe" in
  *'Failure calling service'*|*'Exception'*|'')
    _set_alt="$(content query --uri content://settings/system --where "name='screen_off_timeout'" 2>/dev/null \
                | sed -n 's/.*value=\(.*\)$/\1/p' | head -1)"
    if [ -n "$_set_alt" ]; then
      V "  Settings service" "reachable" "settings-cmd-broken-provider-ok" eq
      NOTE "the settings command fails on this device; ASB falls back to the content provider"
      NOTE "  any tweak that writes a setting works, but only through the fallback"
    else
      V "  Settings service" "reachable" "UNREACHABLE" eq
      NOTE "NEITHER the settings command NOR the content provider answers."
      NOTE "  Every setting-based tweak is inert on this device: Bluetooth absolute volume,"
      NOTE "  scan rate, blur, haptics, the OEM toggles. This is a device"
      NOTE "  or root-manager condition, not something ASB can work around."
    fi
    ;;
  *)
    NOTE "settings service: reachable (screen_off_timeout=$_set_probe)"
    ;;
esac

SEC "5. NETWORK / TCP"
P "  net.tcp buffer sizes (live props):"
for _p in net.tcp.buffersize.wifi net.tcp.buffersize.lte net.tcp.buffersize.5g \
          net.tcp.buffersize.default; do
  P "    $_p = $(gp $_p)"
done
P "  kernel tcp:"
P "    rmem_max = $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
P "    wmem_max = $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
P "    rmem_default = $(cat /proc/sys/net/core/rmem_default 2>/dev/null)"
P "    congestion = $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
P "    available_congestion = $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
P "    tcp_fastopen = $(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)"
P "    default_qdisc = $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
# DNS / connectivity props ASB may touch
P "  connectivity props:"
for _p in net.dns1 net.dns2 persist.sys.use_dingtalk_dns ro.ril.disable.power.collapse; do
  P "    $_p = $(gp $_p)"
done

# =====================================================================
SEC "5a. THERMAL / NETWORK CHOICES"
NOTE "sustained_temp_enter = $(cfg sustained_temp_enter)°C (ASB's own throttle point; vendor limits sit below and are not raised)"
# auto now means "the value the device shipped with", so the captured stock is worth
# printing - without it there is no way to tell an auto that resolved correctly from an
# auto that silently fell through.
if [ -f /data/adb/asb/net_stock.env ]; then
  NOTE "captured stock: $(tr '\n' ' ' < /data/adb/asb/net_stock.env)"
else
  NOTE "net_stock.env missing - auto has no stock value to resolve to yet (captured on next boot)"
fi
V "  tcp congestion in force" "$(cfg net_congestion | sed 's/^auto$//')" \
  "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" present
NOTE "available congestion algorithms: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
NOTE "qdisc in force: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"


# Requested vs accepted, per key.
#
# The live sysctl alone cannot separate "the kernel refused this" from "nobody asked" - both
# look like the previous value.
# asb_net_apply.sh records a verdict per key, and pairing the two is the whole point of a
# diagnostic: a report stating bbr is configured while cubic runs, with no reason given, sends
# someone hunting a bug that is really a missing kernel module.
_nvf="/data/adb/asb/net_apply_result"
if [ -f "$_nvf" ]; then
  for _nk in net_congestion net_qdisc net_congestion_wifi net_congestion_mobile \
             net_qdisc_wifi net_qdisc_mobile wifi_country wifi_scan_throttle; do
    _nw="$(cfg "$_nk")"
    case "$_nw" in ''|auto) continue ;; esac
    _nv="$(grep -E "^$_nk=" "$_nvf" 2>/dev/null | head -1 | sed 's/.*=//')"
    case "$_nv" in
      ok)          V "  $_nk" "$_nw" "$_nw" eq ;;
      unavailable) V "  $_nk (kernel lacks it)" "$_nw" "unavailable" eq ;;
      failed)      V "  $_nk (write refused)"   "$_nw" "failed" eq ;;
      pending)     NOTE "$_nk = $_nw - stored, waiting for a link to apply it to" ;;
      *)           NOTE "$_nk = $_nw - no verdict recorded yet (apply has not run)" ;;
    esac
  done
else
  NOTE "net_apply_result missing - no network key applied through the WebUI yet"
fi

# Radio policy is deliberately independent of the power profile. Report the master first, so a
# device log distinguishes a stored handover preference from an allowed active modem policy.
_radio_policy="$(cfg radio_policy_enable)"
case "$_radio_policy" in
  1) NOTE "Cellular/radio controls: enabled by explicit user choice; LPM state: $(cat /dev/.asb/lpm_mode 2>/dev/null || echo not-written)" ;;
  *) NOTE "Cellular/radio controls: off — profiles leave Android mobile-data context and TCP keepalives untouched" ;;
esac
# Fast handover is owned by modem LPM rather than the route-tuning script. Report both the
# stored request and the master gate; save/night correctly defer it until the screen is awake.
case "$(cfg net_handover_fast):$_radio_policy" in
  1:1) NOTE "Wi-Fi → mobile handover: fast requested; LPM state: $(cat /dev/.asb/lpm_mode 2>/dev/null || echo not-written)" ;;
  1:*) NOTE "Wi-Fi → mobile handover: stored but inactive (cellular/radio controls off)" ;;
  *) NOTE "Wi-Fi → mobile handover: stock/off" ;;
esac
case "$(cfg net_handover_active):$_radio_policy" in
  1:1) NOTE "Wi-Fi fallback: active opt-in; $(MODDIR=\"${MODDIR:-/data/adb/modules/AutoSystemBoost}\" sh \"${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_wifi_fallback.sh\" status 2>/dev/null || echo status-unavailable)" ;;
  1:*) NOTE "Wi-Fi fallback: stored but inactive (cellular/radio controls off)" ;;
  *) NOTE "Wi-Fi fallback: off" ;;
esac
# Why it fired, not just whether it is armed.
#
# A user reported the phone leaving a good Wi-Fi network and rejoining a minute later. The
# status line says "armed" either way, so there was nothing to look at - the watcher writes
# its reasoning to its own log and the report never showed it.
if [ -s "${ASB_CONFIG_STATE:-/data/adb/asb}/wifi_fallback.log" ]; then
  NOTE "recent Wi-Fi fallback decisions:"
  tail -6 "${ASB_CONFIG_STATE:-/data/adb/asb}/wifi_fallback.log" 2>/dev/null |
    while IFS= read -r _wfl; do P "    $_wfl"; done
fi

# A strongly battery-lean Smart session must not negate its own economy choice by holding
# mobile_data_always_on during a feed/media HEAVY burst.  This is read-only explanation of the
# native policy; confirmed games and camera sessions retain fast LPM.
_smart_lpm_bias="$(cfg smart_battery_bias)"
case "$_smart_lpm_bias" in
  ''|*[!0-9]*) ;;
  *) if [ "$_prof" = "smart" ] && [ "$_smart_lpm_bias" -ge 400 ]; then
       NOTE "Smart battery-lean: HEAVY media uses normal LPM; gaming/camera retain fast"
     fi ;;
esac

# Per-interface reality. The global sysctls say nothing about what each link is doing, and
# here they can legitimately differ: congestion is set per route, the queue per interface.
if command -v ip >/dev/null 2>&1; then
  ip route show 2>/dev/null | grep '^default' | while IFS= read -r _dr; do
    _di="$(printf '%s' "$_dr" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    [ -n "$_di" ] || continue
    _dcc="$(printf '%s' "$_dr" | grep -oE 'congctl [a-z_]+' | cut -d' ' -f2)"
    _dw="$(printf '%s' "$_dr" | grep -oE 'initcwnd [0-9]+ initrwnd [0-9]+')"
    _dq="$(tc qdisc show dev "$_di" 2>/dev/null | head -1 | awk '{print $2}')"
    NOTE "link $_di: qdisc=${_dq:-?} congctl=${_dcc:-<global>} ${_dw:-no-window-tuning}"
  done
fi

# Route-window support is a kernel capability, not a setting, and it decides whether the
# per-link congestion choice is genuinely simultaneous or a global switch in disguise.
if command -v ip >/dev/null 2>&1 && ip route show 2>/dev/null | grep -q 'congctl'; then
  NOTE "per-route congctl: SUPPORTED (Wi-Fi and mobile can differ at the same time)"
else
  NOTE "per-route congctl: not in use (per-link choice falls back to the global switch)"
fi

# The link watcher re-applies route windows when the network changes. Without it the
# tuning survives only until the next reconnect, and does so silently.
if pgrep -f "asb_net_routes.sh watch" >/dev/null 2>&1; then
  NOTE "route link watcher: running (re-applies on network change)"
else
  case "$(cfg net_route_tune)" in
    ''|off) : ;;
    *) NOTE "route link watcher: NOT running - windows will not survive a network change" ;;
  esac
fi

SEC "5a2. SMART LEARNING  (what the current bucket knows)"
_sb_t="$(grep -m1 '^smart_bucket_temp_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_sb_d="$(grep -m1 '^smart_bucket_drain_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
NOTE "bucket avg temp = ${_sb_t:-0} (tenths C)  ·  avg drain = ${_sb_d:-0} (tenths %/h)"
_tw="$(grep -m1 '^smart_therm_warm_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tc="$(grep -m1 '^smart_therm_cool_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
# Learned from this device's own median, not hardcoded - a OnePlus 12 and a 15 idle at
# different temperatures, so an absolute threshold would be right for one and wrong for
# the other. 420/380 showing here means not enough buckets have history yet.
NOTE "thresholds in force: warm above ${_tw:-?}, cool below ${_tc:-?} (tenths C, learned from this device)"
case "${_tw:-0}" in
  420) NOTE "still using fallback thresholds - fewer than 4 buckets have enough history" ;;
esac
# These two drive the thermal lean added in V62. A bucket with zero here has not reached
# the observation floor yet, which is not a fault - it means the lean is not applied.
case "${_sb_t:-0}" in
  0) NOTE "no learned thermal history for this bucket yet - lean inactive" ;;
  *) if [ "${_sb_t:-0}" -gt 420 ] 2>/dev/null; then
       NOTE "-> leaning toward battery (this bucket historically runs warm)"
     elif [ "${_sb_t:-0}" -lt 380 ] 2>/dev/null; then
       NOTE "-> allowing more headroom (this bucket historically runs cool)"
     else
       NOTE "-> neutral (between the warm and cool marks)"
     fi ;;
esac
NOTE "sessions learned = $(grep -m1 '^smart_sessions_total=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"

SEC "5a3. BATTERY BEHAVIOUR  (the governor-owned switches)"
# Is the governor actually quiet while the screen is off?
#
# The awake share is the number that matters and it is not visible anywhere else. Two field
# captures on BALANCED showed idle at 83% awake and charging-idle at 100%, against a <5%
# target - the profile ran full sensor polling with the anti-clamp armed because its plan
# branch never looked at the screen. Print the plan so the next report answers this on its
# own instead of needing a full-day capture.
_pl_cls="$(grep -E '^plan_class=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
_pl_deep="$(grep -E '^plan_deep=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
_pl_ac="$(grep -E '^plan_ac=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
# screen_on is not in the state file; read the display the way metrics does.
_pl_scr="$(cat /sys/kernel/oplus_display/panel_power_status 2>/dev/null | head -1)"
case "$_pl_scr" in 1|2) _pl_scr=1 ;; 0) _pl_scr=0 ;; *) _pl_scr="" ;; esac
if [ -n "$_pl_cls" ]; then
  # Compare the configured point with actual live CPU sensors, not with hardware
  # trip/setpoint zones. On this OP15, `cpu-hw-trip-*` is a constant 95C shutdown
  # threshold, not a measurement; treating it as idle temperature created a false FAIL.
  _tp_set="$(cfg sustained_temp_enter)"
  _tp_now=0
  _tp_n=0
  for _tz in /sys/class/thermal/thermal_zone*; do
    _tt="$(cat "$_tz/type" 2>/dev/null)"
    case "$_tt" in *cpu*|*CPU*) : ;; *) continue ;; esac
    case "$_tt" in *trip*|*limit*|*shutdown*|*crit*|*alarm*) continue ;; esac
    _tv="$(cat "$_tz/temp" 2>/dev/null)"
    case "$_tv" in ''|*[!0-9]*) continue ;; esac
    [ "$_tv" -gt 1000 ] && _tv=$(( _tv / 1000 ))
    # Values outside plausible live CPU sensor range are setpoints/faults, not
    # evidence that a 40..70C throttle slider is permanently active.
    [ "$_tv" -lt 20 ] && continue
    [ "$_tv" -gt 85 ] && continue
    _tp_n=$((_tp_n + 1))
    [ "$_tv" -gt "$_tp_now" ] && _tp_now="$_tv"
  done
case "$_tp_set" in
  ''|*[!0-9]*) : ;;
  *)
    if [ "$_tp_now" -gt 0 ] && [ "$_tp_set" -lt "$_tp_now" ]; then
      V "  throttle point below live CPU sensor" "< ${_tp_now}C" "${_tp_set}C" eq
      NOTE "  a real CPU sensor is already above the selected point; sustained policy may engage."
      NOTE "  Check workload/cooling before raising the threshold."
    elif [ "$_tp_now" -gt 0 ] && [ "$_tp_set" -eq "$_tp_now" ]; then
      NOTE "throttle point ${_tp_set}C equals live CPU max ${_tp_now}C across ${_tp_n} sensor(s) - boundary observed, not a failure"
      NOTE "  Equality is a transition edge; the operational policy remains strict-above to avoid threshold chatter."
    else
      NOTE "throttle point ${_tp_set}C vs live CPU max ${_tp_now}C across ${_tp_n} sensor(s) - headroom ok"
    fi
    ;;
esac
NOTE "governor plan: class=$_pl_cls deep_sleep=${_pl_deep:-?} anti_clamp=${_pl_ac:-?} screen_on=${_pl_scr:-?}"
  if [ "$_pl_scr" = "0" ] && [ "$_pl_deep" = "0" ]; then
    NOTE "  screen is OFF but the plan is not the quiet one - expect a 5s tick and full polling"
  fi
fi
# These live in governor.conf and are read by the native governor, which reloads only on
# command. A value here that the governor has not picked up looks applied and is not -
# the single most common way a setting appears to do nothing.
NOTE "auto_battery = $(cfg auto_battery_enable)  ·  charge_aware = $(cfg charge_aware_enable)"
NOTE "cool_gaming = $(cfg cool_gaming)  ·  suppress_gaming_on_battery = $(cfg bat_suppress_gaming)"
NOTE "night_quiet = $(cfg night_quiet_enable)  ·  bg_trim = $(cfg BG_TRIM_LEVEL)"
NOTE "throttle mode = $(cfg sustained_temp_mode) at $(cfg sustained_temp_enter)°C"
# The governor does not publish this key in its state file, so there is nothing to compare
# against - checked rather than assumed. What CAN be verified is that the governor read
# the config at all: it logs the reload, and a config newer than the last reload means the
# value on screen is not the one in force.
_conf_mtime="$(stat -c %Y /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null)"
_gov_start="$(stat -c %Y /dev/.asb/governor.pid 2>/dev/null)"
if [ -n "$_conf_mtime" ] && [ -n "$_gov_start" ]; then
  if [ "$_conf_mtime" -gt "$_gov_start" ] 2>/dev/null; then
    NOTE "governor.conf was edited AFTER the governor started - run 'asb reload' or reboot for governor-owned keys to take effect"
  else
    NOTE "governor started after the last config edit - its values are current"
  fi
fi
[ -f /data/adb/asb/auto_battery_origin ] \
  && NOTE "auto-battery is currently active - will return to $(cat /data/adb/asb/auto_battery_origin 2>/dev/null) when charged"

SEC "5a3b. THERMAL SOURCE PROVENANCE  (which sensor controls the governor)"
_tcs="$(_rget thermal_control_source /dev/.asb/state | tr -d '\"')"
_tcz="$(_rget thermal_control_zone /dev/.asb/state)"
_tconf="$(_rget thermal_source_confidence /dev/.asb/state)"
_trej="$(_rget thermal_rejected_type /dev/.asb/state | tr -d '\"')"
_traw="$(_rget thermal_rejected_raw /dev/.asb/state)"
_sq="$(_rget startup_quarantined /dev/.asb/state)"
NOTE "control source: ${_tcs:-unknown}  zone: ${_tcz:--1}  confidence: ${_tconf:-0}/2"
case "${_tconf:-0}" in
  2) NOTE "-> cross-checked against CPU peers" ;;
  1) NOTE "-> LOW confidence: derived fallback or source not peer-validated" ;;
  *) NOTE "-> uninitialized or unavailable" ;;
esac
if [ -n "$_trej" ]; then
  NOTE "rejected source: $_trej (raw=${_traw:-?}; raw is not displayed as degrees because scale may differ)"
fi
if [ "${_sq:-0}" -gt 0 ] 2>/dev/null; then
  NOTE "startup quarantine: $_sq sample(s) excluded from Smart learning during boot settle"
fi
_txn=/data/adb/asb/config_last_txn
if [ -r "$_txn" ]; then
  NOTE "last config transaction: class=$(_rget result_class "$_txn") key=$(_rget key "$_txn") pre_epoch=$(_rget pre_epoch "$_txn") post_epoch=$(_rget post_epoch "$_txn") reload=$(_rget reload_accepted "$_txn") recovery=$(_rget recovery "$_txn") lock_owner=$(_rget lock_owner "$_txn") lock_owner_state=$(_rget lock_owner_state "$_txn") lock_age=$(_rget lock_age "$_txn") lock_recovered=$(_rget lock_recovered "$_txn")"
else
  NOTE "last config transaction: none recorded yet"
fi
_install_state=/data/adb/asb/last_install_state
if [ -r "$_install_state" ]; then
  NOTE "last install: config=$(_rget config_mode "$_install_state") source=$(_rget config_source "$_install_state") keys=$(_rget config_keys "$_install_state") module=$(_rget module_version "$_install_state") profiles=$(_rget named_profiles "$_install_state") learning=$(_rget smart_learning "$_install_state") snapshot=$(_rget snapshot_state "$_install_state")"
else
  NOTE "last install: no migration record (older installation or first boot not completed)"
fi

SEC "5a4. SUSPEND  (is the phone actually sleeping?)"
# The single most useful overnight number, and the one nothing used to show.
# CLOCK_MONOTONIC stops during suspend, CLOCK_BOOTTIME does not - their ratio over a
# screen-off stretch is the share of it the CPU stayed awake. A capture showed 73% across
# nine hours where the target is under 5%, with drain to match, and no part of the module
# could say so.
_awk_pct="$(grep -m1 '^awake_pct_screenoff=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_awk_win="$(grep -m1 '^awake_window_min=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
case "${_awk_pct:--1}" in
  -1|'') NOTE "not measured yet - needs 10 minutes of continuous screen-off" ;;
  *)
    NOTE "awake ${_awk_pct}% of the last ${_awk_win:-0} min of screen-off  (target: under 5%)"
    if [ "${_awk_pct:-0}" -gt 15 ] 2>/dev/null; then
      NOTE "-> the phone is NOT suspending properly. This costs more than any tuning here can save."
      NOTE "   Something holds a wakelock: check 'dumpsys batterystats' for the holder,"
      NOTE "   or run tools/logkit/asb_log_full_day.sh for an attributed report."
      NOTE "   Common causes: a connected Bluetooth device, a sync-heavy app, a bad alarm."
    elif [ "${_awk_pct:-0}" -gt 5 ] 2>/dev/null; then
      NOTE "-> higher than ideal but not alarming; one chatty app can account for this."
    else
      NOTE "-> suspending normally."
    fi ;;
esac

SEC "5a6. SCREEN-OFF CLASS  (what the last screen-off stretch actually was)"
# Two identical-looking idle hours can be deep sleep or Bluetooth playback. Naming which
# one it was is the difference between a usable night reference and a conclusion drawn
# from a media session.
if [ -r /dev/.asb/screenoff_class ]; then
  _sc="$(grep -m1 '^class=' /dev/.asb/screenoff_class 2>/dev/null | cut -d= -f2)"
  _sr="$(grep -m1 '^reason=' /dev/.asb/screenoff_class 2>/dev/null | cut -d= -f2-)"
  NOTE "class: ${_sc:-unknown} - ${_sr:-no reason recorded}"
  case "$_sc" in
    quiet)    NOTE "-> usable as a night reference" ;;
    media|network)
              NOTE "-> current here reflects audio or the radio, not CPU policy" ;;
    charging) NOTE "-> excluded from drain adaptation" ;;
    noisy)    NOTE "-> unexplained wakefulness; see the wakelock section below" ;;
  esac
else
  NOTE "not classified yet - runs on the screen-off sampling cycle"
fi
# Battery measurement confidence sits here too: a %/h figure is only as good as the
# window behind it, and both are read together or not at all.
_bwc="$(grep -m1 '^battery_window_confidence=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_bwr="$(grep -m1 '^battery_window_reason=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
case "${_bwc:-}" in
  3) NOTE "battery window: high confidence - ${_bwr}" ;;
  2) NOTE "battery window: medium - ${_bwr}" ;;
  1) NOTE "battery window: LOW - ${_bwr} (treat any %/h as an estimate)" ;;
  0) NOTE "battery window: no valid window - ${_bwr}" ;;
esac

SEC "5a9. THERMAL CONSENSUS  (is the control sensor believable?)"
# One temperature with no provenance is a claim, not a measurement. This shows what it was
# cross-checked against and whether the sources agreed.
_tct="$(grep -m1 '^thermal_control_source=' /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '\"')"
_tsc="$(grep -m1 '^thermal_source_confidence=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tph="$(grep -m1 '^thermal_peer_hi=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tpl="$(grep -m1 '^thermal_peer_lo=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tpn="$(grep -m1 '^thermal_peer_n=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tcn="$(grep -m1 '^thermal_consensus=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '\"')"
_trt="$(grep -m1 '^thermal_rejected_type=' /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '\"')"
NOTE "control source: ${_tct:-unknown}"
case "${_tsc:-0}" in
  3) NOTE "confidence: HIGH - cross-checked and agrees with independent sensors" ;;
  2) NOTE "confidence: good - validated against peer CPU zones" ;;
  1) NOTE "confidence: LOW - derived or disputed; see the note below" ;;
  *) NOTE "confidence: not established yet" ;;
esac
[ -n "$_tpn" ] && [ "${_tpn:-0}" -gt 0 ] 2>/dev/null && \
  NOTE "checked against ${_tpn} non-CPU peer sensor(s), range ${_tpl:-?}..${_tph:-?}C"
[ -n "$_tcn" ] && NOTE "consensus: ${_tcn}"
if [ -n "$_trt" ]; then
  # Raw, never with a degree sign: the whole point is that it is not degrees.
  _trr="$(grep -m1 '^thermal_rejected_raw=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  NOTE "rejected candidate: ${_trt} (raw ${_trr}, not a temperature)"
fi

SEC "5a8. TRIALS  (settings on probation)"
# A risky tweak that is being evaluated rather than trusted. Shown separately because
# "active" and "on trial until tonight" are different states and the user chose one.
_trd="${ASB_CONFIG_STATE:-/data/adb/asb}/trial"
if [ -d "$_trd" ] && ls "$_trd"/*.trial >/dev/null 2>&1; then
  for _t in "$_trd"/*.trial; do
    _tk="$(grep -m1 '^key=' "$_t" 2>/dev/null | cut -d= -f2)"
    _tv="$(grep -m1 '^trial_value=' "$_t" 2>/dev/null | cut -d= -f2)"
    _tp="$(grep -m1 '^previous_value=' "$_t" 2>/dev/null | cut -d= -f2)"
    _te="$(grep -m1 '^expires=' "$_t" 2>/dev/null | cut -d= -f2)"
    _left=$(( ${_te:-0} - $(date +%s 2>/dev/null || echo 0) ))
    [ "$_left" -lt 0 ] 2>/dev/null && _left=0
    NOTE "${_tk} = ${_tv} (was ${_tp:-stock}) - reverts in $(( _left / 3600 ))h unless confirmed"
  done
else
  NOTE "no settings on trial"
fi
if [ -d "$_trd" ] && ls "$_trd"/*.kept >/dev/null 2>&1; then
  NOTE "confirmed after trial: $(ls "$_trd"/*.kept 2>/dev/null | sed 's|.*/||;s|\.kept$||' | tr '\n' ' ')"
fi

SEC "5a7. APPLY LEDGER  (what the device actually accepted)"
# Scheduler ceilings that drifted and were put back.
#
# Recorded separately because the module CORRECTS them: a live reading always looks right,
  # What was ASKED for, beside what the node holds.
  _uw="$(grep -m1 "^uclamp_want=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [ -n "$_uw" ] && NOTE "requested by governor (top,bg): $_uw"
# so this is the only trace that anything was wrong. top-app uclamp.max at 0 means the
# scheduler was forbidden from asking for performance for the app on screen - expensive,
# and invisible without this line.
_led_r="${ASB_CONFIG_STATE:-/data/adb/asb}/apply_ledger"
if [ -s "$_led_r" ]; then
  _rc=$(grep -c '^[0-9]*|reconcile|' "$_led_r" 2>/dev/null)
  case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
  if [ "$_rc" -gt 0 ]; then
    NOTE "scheduler ceilings restored ${_rc} time(s) since boot:"
    grep '^[0-9]*|reconcile|' "$_led_r" 2>/dev/null | cut -d'|' -f3,5 | sort | uniq -c |
      while read -r _n _kv; do
        P "    $(printf '%s' "$_kv" | cut -d'|' -f1) was $(printf '%s' "$_kv" | cut -d'|' -f2) (${_n}x)"
      done
    NOTE "-> all were corrected; frequent entries mean the ROM keeps overwriting ASB"
  else
    NOTE "no scheduler ceiling drift recorded"
  fi
fi

# "Enabled" in the UI and "the ROM took it" are different claims. Every writer records a
# read-back result here, so a tweak that reads back wrong is visible instead of silently
# looking fine.
_led="${ASB_CONFIG_STATE:-/data/adb/asb}/apply_ledger"
if [ -s "$_led" ]; then
  NOTE "last 8 write results:"
  tail -8 "$_led" 2>/dev/null | while IFS='|' read -r _t _dom _k _req _prev _now _res _why _ttl; do
    P "    ${_dom}/${_k}: ${_res}${_why:+  (${_why})}"
  done
  # A count by class is what tells you whether this device is fighting the module.
  NOTE "totals: $(awk -F'|' '{c[$7]++} END{for(k in c) printf "%s=%d ", k, c[k]}' "$_led" 2>/dev/null)"
  _bad="$(awk -F'|' '$7=="readback_mismatch"||$7=="not_writable"{n++} END{print n+0}' "$_led" 2>/dev/null)"
  if [ "${_bad:-0}" -gt 0 ] 2>/dev/null; then
    NOTE "-> ${_bad} write(s) the device did not accept - those tweaks are not in effect"
  fi
else
  NOTE "no writes recorded yet"
fi

SEC "5a5. WAKELOCKS  (what is keeping the phone awake)"
# The suspend figure above says the phone is not sleeping; this says who is doing it.
# Without the name, "awake 73%" is a fact the user can do nothing with.
if [ -s /data/adb/asb/wakelock_top ]; then
  NOTE "top sources holding the CPU (name | ms held | times taken):"
  while IFS='|' read -r _wn _wa _wc; do
    [ -n "$_wn" ] || continue
    # Arithmetic only on digits.
    #
    # The batterystats fallback writes human durations - "11m 2s 985ms" - while the
    # debugfs path writes plain microseconds. $(( )) on the first form aborts the whole
    # shell, which is why the report stopped dead at this section and nothing after it was
    # produced. One unparsed field silently truncated the entire diagnostic.
    case "${_wa:-}" in
      ''|*[!0-9]*) P "    $_wn  ·  ${_wa:-?}  ·  ${_wc:-0}x" ;;
      *)           P "    $_wn  ·  $(( _wa / 1000 ))s  ·  ${_wc:-0}x" ;;
    esac
  done < /data/adb/asb/wakelock_top
  NOTE "kernel sources (qup_uart, alarmtimer, wlan) are the hardware asking, not an app"
  NOTE "a package name here is an app you can restrict, uninstall or exempt yourself"
else
  NOTE "no snapshot yet - taken every 15 min, needs /sys/kernel/debug to be readable"
fi
NOTE "wakelock_action = $(cfg wakelock_action)  (0 = report only)"
if [ -s /data/adb/asb/wakelock_restricted ]; then
  NOTE "$(wc -l < /data/adb/asb/wakelock_restricted) app(s) moved to restricted by ASB - undone on uninstall"
fi

SEC "5b. HAPTICS"
_h_lvl="$(cfg haptic_strength)"
case "$_h_lvl" in
  ''|-1|auto|stock) NOTE "haptic_strength = stock (not managed by ASB)" ;;
  *)
    NOTE "haptic_strength = ${_h_lvl}/10, touch = $(cfg haptic_touch_strength)"
    # The coarse Android keys are a gate, not a level: they were already at 3 on the
    # devices this was built for, which is why setting them alone did nothing. What is
    # felt is the OEM stepless value, so that is what gets verified.
    _h_want=$(( ${_h_lvl:-0} * 2400 / 10 ))
    V "  notification stepless amplitude" "$_h_want" \
      "$(settings get system notification_stepless_vibration_intensity 2>/dev/null)" eq
    V "  ring stepless amplitude" "$_h_want" \
      "$(settings get system ring_stepless_vibration_intensity 2>/dev/null)" eq
    V "  coarse gate open (notification_vibration_intensity)" "3" \
      "$(settings get system notification_vibration_intensity 2>/dev/null)" eq
    NOTE "a live value BELOW the wanted one means the vibrator service rejected it and the script stepped down"
    ;;
esac

SEC "6. CAMERA"
_cam_plat="$(gp ro.board.platform)"
[ -z "$_cam_plat" ] && _cam_plat="$(gp ro.hardware.chipname)"
_is_pineapple=0
case "$_cam_plat" in pineapple|sm8650*) _is_pineapple=1 ;; esac

# --- 6a. Multicamera HAL props (the crash is in ChiMcxRoiTranslator) ---
P "  multicamera / HAL props:"
for _p in \
    ro.vendor.oplus.camera.isHasselbladCamera \
    ro.vendor.oplus.camera.isSupportExplorer \
    persist.vendor.camera.video.4k60.eis.enable \
    persist.vendor.camera.mfnr.enable \
    persist.vendor.camera.multiframe.nr.enable \
    persist.vendor.camera.dual_camera_sat \
    persist.vendor.camera.sat.fallback.dist \
    vendor.camera.aux.packagelist \
    ro.vendor.oplus.camera.backCamSize; do
  P "    $_p = $(gp $_p)"
done
# camera provider service health (the process that SIGABRTs on OP12)
P "  camera provider service: init.svc=$(gp init.svc.vendor.camera-provider) cameraserver=$(gp init.svc.cameraserver)"

# --- 6b. OP12 camera env: must MATCH the proven-working module, and /odm must
#     stay in sync with /vendor/odm (a desync between the two is the prime
#     multicamera-HAL crash suspect on APatch). ---
if [ "$_is_pineapple" = "1" ]; then
  NOTE "platform=$_cam_plat -> OP12: camera overlay should match the known-good module; /odm and /vendor/odm must agree"
  # CRITICAL: compare media_profiles on the real /odm partition vs /vendor/odm.
  _mp_odm="/odm/etc/camera/media_profiles.xml"
  _mp_vodm="/vendor/odm/etc/camera/media_profiles.xml"
  _sz_odm="$( [ -f "$_mp_odm" ] && wc -c < "$_mp_odm" 2>/dev/null | tr -d ' ' )"
  _sz_vodm="$( [ -f "$_mp_vodm" ] && wc -c < "$_mp_vodm" 2>/dev/null | tr -d ' ' )"
  P "  media_profiles sizes: /odm=${_sz_odm:-absent}  /vendor/odm=${_sz_vodm:-absent}"
  if [ -n "$_sz_odm" ] && [ -n "$_sz_vodm" ]; then
    if [ "$_sz_odm" = "$_sz_vodm" ]; then
      P "  [PASS] /odm and /vendor/odm media_profiles agree (no desync)"; PASS=$((PASS+1))
    else
      V "  /odm vs /vendor/odm media_profiles DESYNC (HAL crash suspect)" "in-sync" "odm=${_sz_odm}/vodm=${_sz_vodm}" eq
    fi
  fi
  # Owner/timestamp tell us whether the module wrote /vendor/odm directly (group
  # shell + recent date) vs a clean magic-mount. Informational, helps debugging.
  if [ -f "$_mp_vodm" ]; then
    _own="$(ls -l "$_mp_vodm" 2>/dev/null | awk '{print $3":"$4}')"
    P "  /vendor/odm media_profiles owner = ${_own:-?} (root:root = stock/mount, *:shell = module wrote it)"
  fi
  # conf_tuning / video_beauty presence (these SHOULD be present now — we apply
  # the same overlay as the working module, no longer a camera-off).
  for VB in /odm/etc/camera/config/video_beauty_default_config \
            /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    # A comment starts a line. "//" anywhere else is data.
    #
    # grep -c '//' counted every double slash in the file, including the ones inside string
    # values - a URL, a path, an escaped separator. That made this check fail on all six
    # devices in a cross-device sweep, including ones whose file ASB never touched, and a
    # red line that is always red tells you nothing.
    camera_json_comment_verdict "$VB"
  done
  # multicamera/HAL props that must be live for configure_streams to succeed.
  P "  multicamera props live:"
  for _p in persist.vendor.camera.mfnr.enable ro.vendor.oplus.camera.isSupportExplorer \
            persist.camera.dual_camera_sat persist.vendor.camera.sat.fallback.dist; do
    P "    $_p = $(gp $_p)"
  done
else
  # --- 6c. OP13/OP15: camera overlays SHOULD be applied ---
  for VB in /odm/etc/camera/config/video_beauty_default_config /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    P "  file: $VB"
    _ct_present="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
    if [ -n "$_ct_present" ]; then
      V "  retouch app count >= 7" "7" "$(grep -c packageName "$VB" 2>/dev/null)" ge
      V "  Telegram present" "1" "$(grep -c org.telegram.messenger "$VB" 2>/dev/null)" ge
    else
      NA=$((NA+2))
      P "  [N/A ] retouch/Telegram content is OP15 camera-tone specific (no conf_tuning on this model)"
    fi
    camera_json_comment_verdict "$VB"
  done
  CT="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
  if [ -n "$CT" ]; then
    P "  file: $CT"
    # sunsetBrightScale is deliberately NOT written any more.
    #
    # The old sed grader pinned it to 0.9 so boosted warm skies would not clip.
    # The current grader is purely relative - it multiplies what the firmware ships and writes
    # no absolute tone values at all - so this check asserted behaviour that was removed on
    # purpose, and reported FAIL on a device where nothing was wrong.
    NOTE "sunsetBrightScale = $(grep -o '"sunsetBrightScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$') (informational: the relative grader does not set this)"
    # Camera grade is driven by CAMERA_LEVEL (0..4 slider).
    # Mirror the runtime value table (runtime/asb_tweaks.sh) so the expected
    # sunsetSatScale/blueSatParam match the user's actual level instead of false-FAILing
    # against the old fixed aggressive numbers.
    _clvl="$(cfg CAMERA_LEVEL)"
    _caggr="$(cfg CAMERA_AGGRESSIVE)"
    if [ -z "$_clvl" ] || [ "$_clvl" = "0" ]; then
      [ "${_caggr:-0}" = "1" ] && _clvl=3 || _clvl=0
    fi
    NOTE "CAMERA_LEVEL = ${_clvl} (legacy CAMERA_AGGRESSIVE=${_caggr:-0} maps to level 3)"
    if [ "${_clvl:-0}" -ge 1 ] 2>/dev/null; then
      _cam_soc="$(getprop ro.board.platform 2>/dev/null)"
      [ -z "$_cam_soc" ] && _cam_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
      # Grading is a RATIO now, so there is no single expected number to compare against - the
      # result depends on what the device shipped.
      # Checking "does it differ from the stock file" is the honest test, and it is also the
      # one that would have caught the two ways this silently did nothing: rules that matched
      # no value, and a hook that graded a file something else overwrote.
      _cam_stock_bw="0.35, 0.5, 0.7"
      _cam_live_bw="$(grep -m1 -o '"BlendWeight"[^]]*]' "$CT" 2>/dev/null | sed 's/.*\[//;s/\]//')"
      V "  grade(lvl$_clvl) live file differs from stock" "not [$_cam_stock_bw]" \
        "$(if [ "$_cam_live_bw" = "$_cam_stock_bw" ]; then printf '[%s]' "$_cam_live_bw"; \
           else printf 'not [%s]' "$_cam_stock_bw"; fi)" eq
      NOTE "grain=$(cfg CAMERA_GRAIN) contrast=$(cfg CAMERA_CONTRAST) portrait=$(cfg CAMERA_PORTRAIT) lowlight=$(cfg CAMERA_LOWLIGHT)  (3/3/0/0 = stock)"
      # Portrait weights ship at zero and cannot be scaled, so they are set absolutely -
      # worth checking separately because a zero here means the setting did nothing.
      if [ "$(cfg CAMERA_PORTRAIT)" != "0" ] && [ -n "$(cfg CAMERA_PORTRAIT)" ]; then
        # Read FaceBlendWeight from a PORTRAIT block, and test for zero numerically.
        #
        # Face, not Skin: Skin already ships non-zero in two of the three portrait blocks
        # (0.15), so a check built on it passes on a completely untouched device and can never
        # tell you the setting did nothing.
        #
        # It also used to grep the whole file and take the first weight it saw - which lives in
        # a non-portrait block, where zero is correct and expected.
        # The all-zero filter matched the literal text "0.0, 0.0, 0.0" only, so once the grader
        # rewrote those zeros as "0, 0, 0" the filter stopped catching them, the zero row
        # survived, and the check reported PASS while printing "0, 0, 0" as its own evidence.
        _cam_skin="$(sed -n '/EnhanceNet[A-Za-z]*PortraitParams/,/}/p' "$CT" 2>/dev/null \
                     | grep -o '"FaceBlendWeight"[^]]*]' \
                     | sed 's/.*\[//;s/\]//' \
                     | awk -F, '{ for (i=1;i<=NF;i++) { gsub(/ /,"",$i); if ($i+0 != 0) { print; break } } }' \
                     | head -1)"
        V "  portrait AI weights are non-zero" "present" "${_cam_skin:-0, 0, 0}" present
      fi
      _row="$_clvl"
      case "$_cam_soc" in sun|sm8750*) _row=$((_clvl - 1)); [ "$_row" -lt 1 ] && _row=1 ;; esac
      _exp_sss=""; _exp_bsat=""
      if [ -n "$_exp_sss" ]; then
        V "  grade(lvl$_clvl) sunsetSatScale=$_exp_sss" "$_exp_sss" "$(grep -o '"sunsetSatScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        _inj="$(cfg CAMERA_AGGRESSIVE_INJECT)"; NOTE "inject mode = ${_inj:-safe}"
        if [ "${_inj:-safe}" = "aggressive" ]; then
          V "  grade(lvl$_clvl) blueSatParam=$_exp_bsat" "$_exp_bsat" "$(grep -o '"blueSatParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        fi
      fi
    fi
  else
    NOTE "conf_tuning_params.json absent"
  fi
  # Read the bitrate from the file the recording pipeline actually uses AND that the module can
  # overlay.
  # On OP15 the camera's own /odm/etc/camera/media_profiles sits on a read-only opex partition
  # the module can't touch, so checking it reports stock and falsely fails — the media
  # framework reads the bitrate from /vendor/etc/media_profiles*.xml, which ASB DOES overlay
  # and lift.
  CMP="$(firstf '/vendor/etc/media_profiles.xml' '/vendor/etc/media_profiles_V1_0.xml' '/odm/etc/camera/media_profiles.xml' '/vendor/odm/etc/camera/media_profiles.xml')"
  if [ -n "$CMP" ]; then
    _br=$(awk '/quality="1080p"/{f=1} f&&/bitRate=/{match($0,/bitRate="[0-9]+"/);print substr($0,RSTART+9,RLENGTH-10);exit}' "$CMP" 2>/dev/null)
    case "$_cam_plat" in canoe|sm8850*) _bexp=40000000 ;; *) _bexp=37300000 ;; esac
    V "  1080p video bitrate raised" "$_bexp" "$_br" eq
  fi
fi

# =====================================================================
SEC "7. PERFORMANCE / CPU / GPU"
P "  CPU policies (scaling max vs hardware max — shows how hard each cluster is capped):"
# Work out the topology so we can label little / mid / prime, matching the
# governor's own classification (first policy = little, last = prime, anything
# between on a 3+ cluster part = mid workhorse).
_pol_dirs="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n)"
_npol="$(echo "$_pol_dirs" | grep -c .)"
_first_pol="$(echo "$_pol_dirs" | head -1)"
_last_pol="$(echo "$_pol_dirs" | tail -1)"
for _pol in $_pol_dirs; do
  [ -d "$_pol" ] || continue
  _cl=$(basename "$_pol")
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _hmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  _pctmax="?"
  if [ -n "$_smax" ] && [ -n "$_hmax" ] && [ "$_hmax" -gt 0 ] 2>/dev/null; then
    _pctmax=$(( _smax * 100 / _hmax ))
  fi
  _tier="big/prime"
  if [ "$_pol" = "$_first_pol" ]; then
    _tier="little"
  elif [ "$_pol" = "$_last_pol" ]; then
    _tier="prime"
  elif [ "$_npol" -ge 3 ]; then
    _tier="mid"
  fi
  P "    $_cl ($_tier): max=${_smax}/${_hmax} kHz (${_pctmax}% of hw) gov=$_gov"
done
_gpu_gov="$(cat /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>/dev/null)"
_gpu_pwr="$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null)"
_gpu_floor="$(cat /data/adb/asb/gpu_pwrlevel_floor 2>/dev/null)"
if [ -n "$_gpu_gov" ]; then
  P "  GPU: $_gpu_gov  max_pwrlevel=$_gpu_pwr (devfreq-capped)"
else
  # devfreq freq nodes empty (e.g. OP15 Adreno 840) -> ASB caps via pwrlevel.
  P "  GPU: pwrlevel-controlled  max_pwrlevel=$_gpu_pwr${_gpu_floor:+ (vendor floor=$_gpu_floor)}"
fi
NOTE "tier shows the governor's cluster role; %-of-hw shows the active cap. In"
NOTE "performance every cluster should read ~100%; in battery the prime cluster"
NOTE "is capped low while little/mid keep enough headroom to stay smooth."
# Profile-aware sanity.
_prof_now="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prime_smax=$(cat "$_last_pol/scaling_max_freq" 2>/dev/null)
_prime_hmax=$(cat "$_last_pol/cpuinfo_max_freq" 2>/dev/null)
_prime_pct="?"
if [ -n "$_prime_smax" ] && [ -n "$_prime_hmax" ] && [ "$_prime_hmax" -gt 0 ] 2>/dev/null; then
  _prime_pct=$(( _prime_smax * 100 / _prime_hmax ))
fi
case "$_prof_now" in
  performance)
    NOTE "performance: prime live scaling_max=${_prime_pct}% of hw (the OEM governor varies this under load; ASB applies NO cap in performance)"
    ;;
  battery)
    # battery SHOULD cap prime. If the live value is already <=70% that confirms
    # ASB's cap; if higher, it may just be the governor sitting high momentarily,
    # so this is a soft check rather than a hard fail.
    if [ "$_prime_pct" != "?" ] && [ "$_prime_pct" -le 70 ] 2>/dev/null; then
      P "  [PASS] battery: prime cluster capped (${_prime_pct}% of hw)"; PASS=$((PASS+1))
    else
      NOTE "battery: prime live scaling_max=${_prime_pct}% of hw (expected <=70%; if this persists under idle, ASB's cap may not be sticking — check the write-test above)"
    fi ;;
  *)
    NOTE "profile=$_prof_now -> prime cluster at ${_prime_pct}% of hw (balanced/smart vary by load)" ;;
esac
# cool gaming
_cool="$(cfg cool_gaming)"; NOTE "cool_gaming toggle = ${_cool:-0}"
QAPE="$(firstf '/vendor/etc/perf/qapegameconfig.txt' '/odm/etc/perf/qapegameconfig.txt')"
[ -n "$QAPE" ] && NOTE "qapegameconfig present: $QAPE" || NOTE "qapegameconfig absent (normal on OP12)"
# thermal
P "  thermal: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) (zone0 raw)"

# =====================================================================
SEC "7b. MEMORY / LMKD / ZRAM"
# RAM overview
if [ -r /proc/meminfo ]; then
  _memtot=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')
  _memfree=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2}')
  P "  RAM: total=$((${_memtot:-0}/1024))MB available=$((${_memfree:-0}/1024))MB"
  # Detailed breakdown so we can see WHAT occupies RAM (the headline "available" number swings
  # with whatever apps are open at snapshot time, which makes cross-profile comparisons
  # misleading).
  _mi() { grep -m1 "^$1:" /proc/meminfo 2>/dev/null | awk '{print $2}'; }
  _mb() { echo "$(( ${1:-0} / 1024 ))MB"; }
  _free=$(_mi MemFree); _cached=$(_mi Cached); _buffers=$(_mi Buffers)
  _srecl=$(_mi SReclaimable); _sunrecl=$(_mi SUnreclaim); _shmem=$(_mi Shmem)
  _aanon=$(_mi 'Active(anon)'); _ianon=$(_mi 'Inactive(anon)')
  _afile=$(_mi 'Active(file)'); _ifile=$(_mi 'Inactive(file)')
  _swcached=$(_mi SwapCached); _mapped=$(_mi Mapped); _kreclaim=$(_mi KReclaimable)
  P "    MemFree=$(_mb $_free)  Cached=$(_mb $_cached)  Buffers=$(_mb $_buffers)  SwapCached=$(_mb $_swcached)"
  P "    Active(anon)=$(_mb $_aanon)  Inactive(anon)=$(_mb $_ianon)   <- real app (anon) memory"
  P "    Active(file)=$(_mb $_afile)  Inactive(file)=$(_mb $_ifile)   <- file cache (reclaimable)"
  P "    SReclaimable=$(_mb $_srecl)  SUnreclaim=$(_mb $_sunrecl)  KReclaimable=$(_mb $_kreclaim)  Shmem=$(_mb $_shmem)  Mapped=$(_mb $_mapped)"
  # Derived: reclaimable cache that the kernel can hand back under pressure, vs
  # genuinely committed memory. This is the apples-to-apples figure to compare
  # across profiles, not the raw "available".
  _reclaimable=$(( ${_cached:-0} + ${_buffers:-0} + ${_srecl:-0} ))
  _anon=$(( ${_aanon:-0} + ${_ianon:-0} ))
  P "    => reclaimable cache ~$(_mb $_reclaimable), committed app(anon) ~$(_mb $_anon)"
  NOTE "compare app(anon) across profiles, NOT 'available' — 'available' swings with whatever is open at snapshot time"
fi
# swap / zram
if [ -r /proc/swaps ]; then
  P "  swap devices:"
  tail -n +2 /proc/swaps 2>/dev/null | while read _sn _st _ssz _su _sp; do
    P "    $_sn ($_st) size=$((${_ssz:-0}/1024))MB used=$((${_su:-0}/1024))MB"
  done
fi
for _zr in /sys/block/zram0/comp_algorithm /sys/block/zram0/disksize /sys/block/zram0/mem_limit /sys/block/zram0/mm_stat /sys/block/zram0/io_stat; do
  [ -r "$_zr" ] && P "    zram $(basename $_zr): $(cat $_zr 2>/dev/null | tr '\n' ' ')"
done
if [ -r /proc/pressure/memory ]; then
  P "  memory PSI (read-only):"
  sed 's/^/    /' /proc/pressure/memory 2>/dev/null
else
  NOTE "memory PSI unavailable on this kernel (no policy is changed)"
fi
# LMKD tunables ASB may touch
P "  LMKD / vmpressure props:"
# OEM system toggles ASB can optionally manage (only when UX_MANAGE_OEM_TOGGLES=1).
P "  OEM toggles (managed only if UX_MANAGE_OEM_TOGGLES=1):"
for _ot in ram_expand_size adaptive_battery_management_enabled sem_low_heat_mode; do
  P "    settings global $_ot = $(settings get global $_ot 2>/dev/null)"
done
for _p in ro.lmk.use_psi ro.lmk.thrashing_limit ro.lmk.swap_util_max \
          persist.device_config.lmkd_native.thrashing_limit \
          persist.sys.lmkd.camera_adaptive_lmk.enable; do
  P "    $_p = $(gp $_p)"
done
# kernel VM tunables
P "  kernel VM:"
for _vm in swappiness vfs_cache_pressure watermark_scale_factor; do
  [ -r "/proc/sys/vm/$_vm" ] && P "    vm.$_vm = $(cat /proc/sys/vm/$_vm 2>/dev/null)"
done
# memory cgroup presence (ASB BG_TRIM depends on memcg)
_memcg="$(firstf '/dev/memcg' '/sys/fs/cgroup/memory')"
# Say which half is missing, not that the whole tweak is limited.
#
# BG_TRIM has two mechanisms: memory cgroups, and standby buckets via am set-standby-bucket.
# Only the first needs memcg. The old wording - "BG_TRIM limited" - read as "this does not
# work here", and that is how a CPH2769 owner took it, on a device logging 2744 timer
# wakeups a session: exactly what buckets are for, and buckets were running the whole time.
if [ -n "$_memcg" ]; then
  NOTE "memcg present: $_memcg (BG_TRIM: memory limits + standby buckets)"
else
  NOTE "no memcg path (BG_TRIM: standby buckets only - memory limits unavailable here)"
fi
_bgtrim="$(cfg BG_TRIM_LEVEL)"; NOTE "BG_TRIM_LEVEL = ${_bgtrim:-safe}"
# Athena state. ASB never disables com.oplus.athena, but older builds did and did not
# record it, so uninstall could not restore it either. Surfacing it here means a tester
# who sees it disabled can tell at a glance whether the module is responsible.
if pm list packages -d 2>/dev/null | grep -q '^package:com.oplus.athena$'; then
  if grep -q "^pm|com.oplus.athena|" /data/adb/asb/baseline.txt 2>/dev/null; then
    NOTE "com.oplus.athena DISABLED by ASB (recorded in baseline; uninstall will restore it)"
  else
    NOTE "com.oplus.athena DISABLED, but NOT by this build - no baseline record. Likely a"
    NOTE "  leftover from an older ASB. Restore with: pm enable com.oplus.athena"
  fi
else
  NOTE "com.oplus.athena enabled (ASB does not disable it)"
fi

# =====================================================================
SEC "8. DISPLAY / UX"
for _p in vendor.display.enable_dpps_dynamic_fps debug.hwui.use_partial_updates persist.sys.hwui.enable_texture_optimize; do
  P "    $_p = $(gp $_p)"
done
P "  animation scales (settings):"
for _s in window_animation_scale transition_animation_scale animator_duration_scale; do
  P "    $_s = $(settings get global $_s 2>/dev/null)"
done

# =====================================================================
NOTE "log_level = $(cfg log_level)  ·  camera_hold = $(cfg camera_hold_enable)"

SEC "7c. UI SPEED / ANIMATION"
# anim_speed overrides the profile's own scale. Both write the same three settings, so
# the live value is the only way to tell which one won.
NOTE "anim_speed = $(cfg anim_speed)  ·  UX_MANAGE_TIMEOUTS = $(cfg UX_MANAGE_TIMEOUTS)"
for _as in window_animation_scale transition_animation_scale animator_duration_scale; do
  P "    live $_as = $(settings get global $_as 2>/dev/null)"
done
NOTE "force animation restart = $(cfg UX_ANIM_FORCE_RESTART) (SystemUI is never restarted on a profile switch since V62)"

SEC "8a. SLEEP / DOZE  (the subsystem nobody can observe directly)"
_dz="$(cfg doze_level)"
NOTE "doze_level = ${_dz:-stock}"
V "  device_idle_constants in force" "present" \
  "$(settings get global device_idle_constants 2>/dev/null)" present
if [ -r /data/adb/asb/night_window.conf ]; then
  _ns="$(grep -E '^sleep_min=' /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  _nw="$(grep -E '^wake_min='  /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  _nn="$(grep -E '^samples='   /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  # Printed as clock times: minutes-since-midnight is what the file stores and what
  # nobody can read at a glance.
  NOTE "learned sleep window: $(printf '%02d:%02d' $((_ns/60)) $((_ns%60)))-$(printf '%02d:%02d' $((_nw/60)) $((_nw%60))) from ${_nn} night(s)"
  _minsmp="$(cfg night_quiet_auto_min_samples)"; : "${_minsmp:=3}"
  if [ "${_nn:-0}" -lt "$_minsmp" ] 2>/dev/null; then
    NOTE "below ${_minsmp} samples - the configured hours are still being used instead"
  fi
else
  NOTE "no learned window yet (night_window.conf absent) - static hours in use"
fi
# AOD is borrowed, not disabled: the baseline file existing means it is currently paused,
# and its absence means either the window is closed or the user never had AOD on.
[ -f /data/adb/asb/aod_baseline ] \
  && NOTE "AOD currently paused by ASB (original: $(cat /data/adb/asb/aod_baseline 2>/dev/null))" \
  || NOTE "AOD not currently held by ASB (doze_always_on = $(settings get secure doze_always_on 2>/dev/null))"

# =====================================================================
SEC "8b. INTERFACE / SYSTEM TWEAKS"
V "  window blur disabled" "$(cfg disable_blur)" \
  "$(settings get global disable_window_blurs 2>/dev/null)" present
NOTE "ui_effects_level = $(cfg ui_effects_level)  ·  anim_level prop = $(gp persist.sys.oplus.anim_level)"
NOTE "phantom_procs = $(cfg phantom_procs)  ·  live: $(settings get global settings_enable_monitor_phantom_procs 2>/dev/null)"
NOTE "lockscreen_shortcuts = $(cfg lockscreen_shortcuts)"
# The property that caused a bootloop. Worth naming explicitly in every report: if it is
# ever back in system.prop, that is the first thing to look at.
_vdb="$(gp vendor.display.supports_background_blur)"
case "$_vdb" in
  0) BAD_NOTE="  vendor.display.supports_background_blur = 0 - this value bootloops the display stack"; P "$BAD_NOTE" ;;
  *) NOTE "vendor.display.supports_background_blur = ${_vdb:-<unset>} (0 would be a problem)" ;;
esac
[ -f /data/adb/asb/prop_blocks_disabled ] \
  && NOTE "BOOT SAFETY FIRED: $(cat /data/adb/asb/prop_blocks_disabled 2>/dev/null | tr '\n' ' ')"

# =====================================================================
SEC "9. WEBUI CONFIG  (governor.conf — what the user selected)"
if [ -f "$CONF" ]; then
  P "  $CONF :"
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$CONF" 2>/dev/null | while IFS= read -r _line; do P "    $_line"; done
else
  P "  governor.conf not found"
fi

# =====================================================================
SEC "10. HARDWARE PROFILE  (for per-SoC governor / profile tuning)"
P "  This section captures the full CPU/GPU/thermal topology so the governor,"
P "  profiles and Smart mode can be tuned individually per SoC (canoe/sun/"
P "  pineapple). The clusters and frequency tables differ per chip, which is why"
P "  one set of battery caps can feel sluggish on OP12 but fine on OP15."
P ""

# --- 10a. CPU cluster topology + full frequency tables ---
P "  CPU CLUSTERS (policy = a cluster; lists every available frequency):"
for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pol" ] || continue
  _pn=$(basename "$_pol")
  _cpus=$(cat "$_pol/affected_cpus" 2>/dev/null)
  _cmin=$(cat "$_pol/cpuinfo_min_freq" 2>/dev/null)
  _cmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _smin=$(cat "$_pol/scaling_min_freq" 2>/dev/null)
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _cur=$(cat "$_pol/scaling_cur_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  # Writability of both cap nodes: a device can expose a frequency table while
  # rejecting writes, in which case ASB must report an OEM/kernel owner rather than claim control.
  if [ -w "$_pol/scaling_max_freq" ]; then _wf="writable"; else _wf="NOT-writable"; fi
  if [ -w "$_pol/scaling_min_freq" ]; then _minwf="writable"; else _minwf="NOT-writable"; fi
  _lowest="$(tr ' ' '\n' < "$_pol/scaling_available_frequencies" 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {print}' | sort -n | awk 'NF{print; exit}')"
  _prof_live="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
  _state_live="$(grep '^state=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
  P "  [$_pn] cpus={$_cpus} gov=$_gov scaling_max=$_wf scaling_min=$_minwf"
  P "        hw_range : $_cmin .. $_cmax"
  P "        scaling  : min=$_smin max=$_smax cur=$_cur"
  P "        lowest_opp: ${_lowest:-unknown}"
  case "$_state_live" in DEEP_IDLE|LIGHT_IDLE|MODERATE|SUSTAINED) _smart_low_floor_state=1 ;; *) _smart_low_floor_state=0 ;; esac
  if [ "$_prof_live" = "smart" ] && [ "$_smart_low_floor_state" = "1" ] && [ -n "$_lowest" ]; then
    if [ "$_smin" = "$_lowest" ]; then
      P "        smart minimum: [PASS] Smart requested hardware lowest OPP"
    else
      P "        smart minimum: [WARN] want=$_lowest live=${_smin:-unknown} (vendor/kernel override or write failure)"
    fi
  else
    P "        smart minimum: not expected (profile=${_prof_live:-none} state=${_state_live:-unknown})"
  fi
  P "        available: $(cat "$_pol/scaling_available_frequencies" 2>/dev/null)"
  # governor tunables that shape responsiveness (schedutil / walt)
  for _t in schedutil/rate_limit_us schedutil/up_rate_limit_us \
            schedutil/down_rate_limit_us schedutil/hispeed_freq \
            walt/target_loads walt/up_rate_limit_us walt/down_rate_limit_us; do
    [ -r "$_pol/$_t" ] && P "        tunable $_t = $(cat "$_pol/$_t" 2>/dev/null)"
  done
  # boost / scaling driver
  [ -r "$_pol/scaling_driver" ] && P "        driver   = $(cat "$_pol/scaling_driver" 2>/dev/null)"
done
P ""
# how many distinct clusters -> tells us the topology class
_ncl=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | wc -l)
NOTE "cluster count = $_ncl  (canoe/sun usually 2 policies for a 6+2; pineapple 4: 1+3+2+1)"
# Show how ASB's governor maps physical policies -> logical slots (little/big/
# prime). On a 4-cluster OP12 the governor now assigns first->little, last->
# prime, all middles->big, and applies the big cap to BOTH middle clusters.
_pol_ids=""
for _pp in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pp" ] && _pol_ids="$_pol_ids $(basename "$_pp" | sed 's/policy//')"
done
_pol_ids="$(echo $_pol_ids | tr ' ' '\n' | sort -n | tr '\n' ' ')"
P "  governor slot mapping (physical policy -> slot):"
_first=""; _last=""
for _id in $_pol_ids; do [ -z "$_first" ] && _first="$_id"; _last="$_id"; done
for _id in $_pol_ids; do
  if [ "$_id" = "$_first" ]; then P "    policy$_id -> slot0 (little)"
  elif [ "$_id" = "$_last" ]; then P "    policy$_id -> slot2 (prime)"
  else P "    policy$_id -> slot1 (big) [gets BATTERY/BALANCED_CPU_MAX_BIG cap]"; fi
done
# per-core: which cluster + online state
P "  PER-CORE map:"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpufreq/scaling_cur_freq" ] || continue
  P "    $_cn: online=$(cat "$_c/online" 2>/dev/null || echo 1) cur=$(cat "$_c/cpufreq/scaling_cur_freq" 2>/dev/null)"
done

# --- 10b. CPU capacity / EAS energy model (key for Smart scheduling) ---
P ""
P "  CPU CAPACITY (EAS energy model — relative core strength):"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpu_capacity" ] && P "    $_cn capacity = $(cat "$_c/cpu_capacity" 2>/dev/null)"
done

# --- 10c. sched / walt knobs ASB's governor reasons about ---
P ""
P "  SCHED / WALT globals:"
for _s in /proc/sys/kernel/sched_util_clamp_min /proc/sys/kernel/sched_util_clamp_max \
          /proc/sys/kernel/sched_schedstats; do
  [ -r "$_s" ] && P "    $(basename $_s) = $(cat $_s 2>/dev/null)"
done
for _wp in /sys/devices/system/cpu/walt/sched_boost \
           /proc/sys/walt/sched_boost; do
  [ -r "$_wp" ] && P "    $(echo $_wp|sed 's#.*/##') = $(cat $_wp 2>/dev/null)"
done
# msm_performance (governor writes cpu_max_freq here)
[ -r /sys/kernel/msm_performance/parameters/cpu_max_freq ] && \
  P "    msm_performance cpu_max_freq = $(cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)"

# --- 10d. GPU full profile ---
P ""
P "  GPU (Adreno):"
_kg=/sys/class/kgsl/kgsl-3d0
if [ -d "$_kg" ]; then
  P "    model          = $(cat $_kg/gpu_model 2>/dev/null)"
  P "    governor       = $(cat $_kg/devfreq/governor 2>/dev/null)"
  P "    cur_freq       = $(cat $_kg/devfreq/cur_freq 2>/dev/null)"
  P "    min/max_freq   = $(cat $_kg/devfreq/min_freq 2>/dev/null) / $(cat $_kg/devfreq/max_freq 2>/dev/null)"
  P "    available_freq = $(cat $_kg/devfreq/available_frequencies 2>/dev/null)"
  P "    max_pwrlevel   = $(cat $_kg/max_pwrlevel 2>/dev/null)  (num_pwrlevels=$(cat $_kg/num_pwrlevels 2>/dev/null))"
  P "    min_pwrlevel   = $(cat $_kg/min_pwrlevel 2>/dev/null)"
  P "    default_pwr    = $(cat $_kg/default_pwrlevel 2>/dev/null)"
  P "    busy_pct       = $(cat $_kg/gpubusy 2>/dev/null)"
  P "    throttling     = $(cat $_kg/throttling 2>/dev/null)"
  # GPU write-test: does ASB actually control the GPU ceiling, or does the vendor governor
  # (msm-adreno-tz) override it like walt does for CPU?
  _gdv="$_kg/devfreq"
  if [ "$WRITE_TEST" != "1" ]; then
    NOTE "GPU write-test skipped in safe read-only mode (rerun with --write-test while idle)"
  elif [ -w "$_gdv/max_freq" ] && [ -s "$_gdv/available_frequencies" ]; then
    _g_orig="$(cat "$_gdv/max_freq" 2>/dev/null)"
    _g_try="$(tr ' ' '\n' < "$_gdv/available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
    if [ -n "$_g_try" ] && [ "$_g_try" != "$_g_orig" ]; then
      echo "$_g_try" > "$_gdv/max_freq" 2>/dev/null
      _g_read="$(cat "$_gdv/max_freq" 2>/dev/null)"
      if [ "$_g_read" = "$_g_try" ]; then
        P "    [PASS] GPU max_freq write-test: wrote $_g_try, read back $_g_read (ASB CAN cap the GPU)"
      else
        P "    [FAIL] GPU max_freq write-test: wrote $_g_try but read back $_g_read (vendor governor OVERRIDES the GPU cap)"
      fi
      [ -n "$_g_orig" ] && echo "$_g_orig" > "$_gdv/max_freq" 2>/dev/null
    else
      P "    GPU write-test skipped (no distinct available freq)"
    fi
  elif [ -w "$_kg/max_pwrlevel" ]; then
    _p_orig="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    _p_try=$(( ${_p_orig:-0} + 1 ))
    echo "$_p_try" > "$_kg/max_pwrlevel" 2>/dev/null
    _p_read="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    if [ "$_p_read" = "$_p_try" ]; then
      P "    [PASS] GPU max_pwrlevel write-test: wrote $_p_try, read back $_p_read (ASB CAN cap via pwrlevel)"
    else
      P "    [FAIL] GPU max_pwrlevel write-test: wrote $_p_try but read back $_p_read (vendor OVERRIDES pwrlevel)"
    fi
    [ -n "$_p_orig" ] && echo "$_p_orig" > "$_kg/max_pwrlevel" 2>/dev/null
  fi
else
  _gdev=""
  for _gd in /sys/class/devfreq/*gpu* /sys/class/devfreq/*mali* /sys/class/devfreq/*powervr* \
             /sys/class/devfreq/*xclipse* /sys/class/devfreq/*adreno* /sys/class/devfreq/*kgsl*; do
    [ -r "$_gd/max_freq" ] && { _gdev="$_gd"; break; }
  done
  if [ -n "$_gdev" ]; then
    P "    generic devfreq  = ${_gdev##*/}"
    P "    governor        = $(cat "$_gdev/governor" 2>/dev/null)"
    P "    cur_freq        = $(cat "$_gdev/cur_freq" 2>/dev/null)"
    P "    min/max_freq    = $(cat "$_gdev/min_freq" 2>/dev/null) / $(cat "$_gdev/max_freq" 2>/dev/null)"
    P "    available_freq  = $(cat "$_gdev/available_frequencies" 2>/dev/null)"
    [ -r "$_gdev/load" ] && P "    load             = $(cat "$_gdev/load" 2>/dev/null)"
    NOTE "generic GPU telemetry is capability-gated; no KGSL pwrlevel assumptions are made"
  else
    NOTE "no recognised GPU devfreq backend (CPU/thermal policy remains active; GPU telemetry is unavailable)"
  fi
fi

# --- 10e. Thermal zones + cooling (why OP12 throttles differently) ---
P ""
P "  THERMAL zones (live temps; governor reads these to back off):"
for _tz in /sys/class/thermal/thermal_zone*; do
  [ -d "$_tz" ] || continue
  _ty=$(cat "$_tz/type" 2>/dev/null)
  _tp=$(cat "$_tz/temp" 2>/dev/null)
  case "$_ty" in
    *cpu*|*gpu*|*skin*|*shell*|*soc*|*battery*|*modem*|*ddr*)
      P "    $(basename $_tz) [$_ty] = $_tp" ;;
  esac
done
# thermal config / mitigation
[ -d /sys/class/thermal/cooling_device0 ] && \
  P "  cooling devices present: $(ls -d /sys/class/thermal/cooling_device* 2>/dev/null | wc -l)"

# --- 10f. Battery state (affects what the battery profile should target) ---
P ""
P "  BATTERY:"
_bp=/sys/class/power_supply/battery
if [ -d "$_bp" ]; then
  P "    capacity   = $(cat $_bp/capacity 2>/dev/null)%"
  P "    status     = $(cat $_bp/status 2>/dev/null)"
  P "    temp       = $(cat $_bp/temp 2>/dev/null)"
  P "    current_now= $(cat $_bp/current_now 2>/dev/null)"
  P "    health     = $(cat $_bp/health 2>/dev/null)"
fi

# --- 10g. ASB governor live state (what it actually decided) ---
P ""
P "  ASB GOVERNOR live state:"
# WRITE-TEST: prove whether ASB can actually set scaling_max_freq on this device.
# If readback != what we wrote, the OEM/kernel is rejecting or overriding ASB's caps — which
# fully explains caps that never match ASB's intended per-device percentages (and battery-mode
# jank if caps don't apply).
_wt_pol="/sys/devices/system/cpu/cpufreq/policy0"
if [ "$WRITE_TEST" != "1" ]; then
  NOTE "CPU scaling_max write-test skipped in safe read-only mode (rerun with --write-test while idle)"
elif [ -w "$_wt_pol/scaling_max_freq" ]; then
  _wt_orig="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
  # pick a mid available freq distinct from current
  _wt_try="$(tr ' ' '\n' < "$_wt_pol/scaling_available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
  if [ -n "$_wt_try" ] && [ "$_wt_try" != "$_wt_orig" ]; then
    echo "$_wt_try" > "$_wt_pol/scaling_max_freq" 2>/dev/null
    sleep 1
    _wt_read="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
    if [ "$_wt_read" = "$_wt_try" ]; then
      P "    [PASS] scaling_max write-test: wrote $_wt_try, read back $_wt_read (ASB CAN control caps)"
    else
      P "    [FAIL] scaling_max write-test: wrote $_wt_try but read back $_wt_read (OEM/kernel OVERRIDES ASB caps!)"
    fi
    # restore
    echo "$_wt_orig" > "$_wt_pol/scaling_max_freq" 2>/dev/null
  else
    P "    write-test skipped (no distinct available freq)"
  fi
else
  P "    [FAIL] scaling_max_freq is NOT writable on policy0 (ASB cannot cap CPU here!)"
fi
P "    current_profile = $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# smart_mode flag decides whether the governor owns caps (smart) or the shell does (manual).
# If this is 1 while a manual profile is selected, the governor may be fighting
# apply_screen_aware_caps for the cap — the #1 thing to check when the live caps don't match
# the per-device percentages.
_smf="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
P "    smart_mode_enabled flag = ${_smf:-<absent>}"
P "    smart_prev_profile = $(cat /data/adb/asb/smart_prev_profile 2>/dev/null || echo '<absent>')"
for _gp in persist.asb.profile persist.asb.smart.alpha persist.asb.last_plan \
           persist.asb.battery.session persist.asb.smart.state; do
  _gv="$(gp $_gp)"; [ -n "$_gv" ] && P "    $_gp = $_gv"
done
# governor's own log tail (decisions, throttle events). The persistent log is
# the authoritative one; check it plus the volatile copies.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" \
           /data/adb/asb/asb.log /data/local/tmp/asb.log; do
  [ -f "$_lg" ] && { P "    log tail ($_lg):"; tail -12 "$_lg" 2>/dev/null | while IFS= read -r _l; do P "      $_l"; done; break; }
done
# Pull the most recent screen_aware_caps decision (what the shell INTENDED to
# write) so it can be compared against the live %-of-hw readout above. A
# mismatch means something overwrote the shell caps after they were applied.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" /data/adb/asb/asb.log; do
  [ -f "$_lg" ] || continue
  _sac="$(grep "screen_aware_caps:" "$_lg" 2>/dev/null | tail -1)"
  [ -n "$_sac" ] && P "    last screen_aware_caps: $_sac"
  break
done

# --- 10h. profile_bounds the module shipped (compare vs hardware above) ---
P ""
P "  SHIPPED battery rails (compare against hw freqs above):"
# The source profile_bounds.conf is intentionally NOT shipped in the installed module (it's a
# dev/source artifact); what ships is the generated .sh (and the values baked into the governor
# binary).
_pb=""
for _cand in "$MODDIR/config/profile_bounds.generated.sh" "$MODDIR/config/profile_bounds.conf"; do
  [ -f "$_cand" ] && { _pb="$_cand"; break; }
done
if [ -n "$_pb" ]; then
  P "    (source: $(basename "$_pb"))"
  grep -E '^(BATTERY|BALANCED|PERFORMANCE)_CPU_(MIN|MAX|CAP)_' "$_pb" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
else
  NOTE "no shipped bounds file found (generated.sh expected in module/config)"
fi
P ""
P "  >>> TUNING HINT: compare BATTERY_CPU_MAX_* above with each cluster's real"
P "      'available' table. If a battery cap doesn't line up with an actual"
P "      frequency step for THIS SoC's clusters, the governor may be pinning the"
P "      wrong cluster low (the likely cause of OP12 battery-mode sluggishness)."

P "  PASS=$PASS   FAIL=$FAIL   N/A=$NA   info=$INFO"
# Normalized score so devices are comparable. Raw PASS counts mislead (a device
# with more applicable checks, e.g. bt_absvol=on + aggressive toggles, racks up
# more PASS without being "better optimized"). pass_ratio = PASS / applicable.
_applicable=$((PASS + FAIL))
if [ "$_applicable" -gt 0 ]; then
  _ratio=$(( PASS * 100 / _applicable ))
  P "  applicable=$_applicable   pass_ratio=${_ratio}%   (PASS/(PASS+FAIL); N/A & info excluded)"
  P "  >>> Compare devices by pass_ratio, NOT raw PASS — a higher PASS count"
  P "      usually just means more checks applied on that model."
fi
P ""
P "  How to read this:"
P "   - PASS  = ASB's change is live in the system."
P "   - FAIL  = a file exists but the value isn't what ASB intended"
P "             (or the camera reads a partition ASB can't overlay, e.g."
P "              /odm on OP12 — see notes by each item)."
P "   - N/A   = that file/feature doesn't exist on this model (often"
P "             expected: conf_tuning/qape are absent on OP12/Gen3)."
P "   - (i)   = informational (toggle states, live props, link info)."
P ""
P "  Report saved to:"
[ -n "$OUT1" ] && P "    $OUT1"
[ -n "$OUT2" ] && P "    $OUT2"
P "################################################################"
