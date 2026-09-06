#!/system/bin/sh

MODID="AutoSystemBoost"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
resolve_moddir() {
  for d in \
    "$MODDIR" \
    "${SCRIPT_DIR%/tools}" \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID"; do
    [ -n "$d" ] || continue
    [ -f "$d/module.prop" ] && { echo "$d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(resolve_moddir)"

find_python() {
  for p in "${PYTHON3:-}" python3 /data/data/com.termux/files/usr/bin/python3; do
    [ -n "$p" ] || continue
    command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
PYTHON_BIN="$(find_python 2>/dev/null || true)"

ERRORS=0; WARNS=0
err()  { ERRORS=$((ERRORS+1)); echo "  ❌ $1"; }
warn() { WARNS=$((WARNS+1));   echo "  ⚠️  $1"; }
ok()   { echo "  ✅ $1"; }

get_kv() {
  _file="$1"; _key="$2"
  awk -F= -v k="$_key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      split(line, a, "=")
      key=a[1]
      gsub(/[[:space:]]+$/, "", key)
      if (key == k) {
        sub(/^[^=]*=/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        sub(/^"/, "", line)
        sub(/"$/, "", line)
        print line
        exit
      }
    }
  ' "$_file"
}

num_ge() { [ "$1" -ge "$2" ] 2>/dev/null; }
num_le() { [ "$1" -le "$2" ] 2>/dev/null; }
num_gt() { [ "$1" -gt "$2" ] 2>/dev/null; }

check_shell_syntax() {
  _f="$1"
  if sh -n "$_f" 2>/dev/null; then
    ok "$(basename "$_f") syntax ok"
  else
    err "$(basename "$_f") syntax error"
  fi
}

validate_json() {
  _f="$1"
  if [ -z "$PYTHON_BIN" ]; then
    warn "python3 not found, skipped JSON validation for $(basename "$_f")"
    return 0
  fi
  if "$PYTHON_BIN" -c "import json; json.load(open('$_f', encoding='utf-8'))" 2>/dev/null; then
    ok "$(basename "$_f"): valid JSON"
  else
    err "$(basename "$_f"): invalid JSON"
  fi
}

echo "═══════════════════════════════"
echo "  ASB Config Lint"
echo "═══════════════════════════════"
echo "  Module dir: $MODDIR"

echo
echo "🐚 Shell Syntax"
for f in \
  "$MODDIR/service.sh" \
  "$MODDIR/runtime/asb_watchdog.sh" \
  "$MODDIR/runtime/asb_reconcile.sh" \
  "$MODDIR/runtime/asb_tweaks.sh" \
  "$MODDIR/tools/asb_doctor.sh" \
  "$MODDIR/tools/asb_verify_device.sh" \
  "$MODDIR/tools/asb_release_pack.sh"; do
  [ -f "$f" ] && check_shell_syntax "$f"
done

echo
echo "⚙️  governor.conf"
CONF="$MODDIR/config/governor.conf"
if [ ! -f "$CONF" ]; then
  err "governor.conf not found"
else
  DUPES="$(awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != "") print key
    }' "$CONF" | sort | uniq -d)"
  [ -n "$DUPES" ] && err "duplicate keys: $DUPES" || ok "no duplicate keys"

  for need in sustained_temp_enter sustained_temp_exit auto_degrade_thermal_pct; do
    v="$(get_kv "$CONF" "$need")"
    [ -n "$v" ] && ok "$need present" || err "$need missing"
  done
  A_TIME="$(get_kv "$CONF" auto_degrade_time_gate)"
  [ -n "$A_TIME" ] && ok "auto_degrade_time_gate present" || warn "auto_degrade_time_gate not set (using built-in timing logic)"

  HEAVY_GPU="$(get_kv "$CONF" heavy_gpu_enter)"
  S_ENTER="$(get_kv "$CONF" sustained_temp_enter)"
  S_EXIT="$(get_kv "$CONF" sustained_temp_exit)"
  A_THERM="$(get_kv "$CONF" auto_degrade_thermal_pct)"

  [ -n "$HEAVY_GPU" ] && { num_ge "$HEAVY_GPU" 10 && num_le "$HEAVY_GPU" 90 && ok "heavy_gpu_enter in range" || warn "heavy_gpu_enter=$HEAVY_GPU outside 10-90"; }
  [ -n "$S_ENTER" ] && { num_ge "$S_ENTER" 50 && num_le "$S_ENTER" 95 && ok "sustained_temp_enter in range" || warn "sustained_temp_enter=$S_ENTER outside 50-95"; }
  [ -n "$S_EXIT" ]  && { num_ge "$S_EXIT" 35 && num_le "$S_EXIT" 90 && ok "sustained_temp_exit in range" || warn "sustained_temp_exit=$S_EXIT outside 35-90"; }
  [ -n "$A_THERM" ] && { num_ge "$A_THERM" 20 && num_le "$A_THERM" 95 && ok "auto_degrade_thermal_pct in range" || warn "auto_degrade_thermal_pct=$A_THERM outside 20-95"; }
  [ -n "$A_TIME" ]  && { num_ge "$A_TIME" 30 && num_le "$A_TIME" 600 && ok "auto_degrade_time_gate in range" || warn "auto_degrade_time_gate=$A_TIME outside 30-600"; }

  if [ -n "$S_ENTER" ] && [ -n "$S_EXIT" ]; then
    if num_ge "$S_EXIT" "$S_ENTER"; then
      err "sustained_temp_exit($S_EXIT) >= sustained_temp_enter($S_ENTER)"
    else
      ok "sustained temp enter/exit consistent"
    fi
  fi
fi

# Config ownership is deliberately a separate, machine-readable registry instead of inline
# comments. Inline comments are too easy to lose during generated/default-config updates; this
# guard makes every shipped key declare whether it is a normal user control, a sensitive advanced
# control, or an internal engine/derived setting.
echo
 echo "🧭 Config Key Ownership"
OWNERSHIP="$MODDIR/config/key_ownership.tsv"
if [ ! -f "$CONF" ]; then
  err "cannot validate config ownership without governor.conf"
elif [ ! -f "$OWNERSHIP" ]; then
  err "config/key_ownership.tsv missing"
else
  _own_bad="$(awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    NF != 3 {print "malformed:" NR; next}
    $1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print "invalid-key:" $1; next}
    $2 !~ /^(user|advanced|internal)$/ {print "invalid-class:" $1 "=" $2; next}
    $3 !~ /^[a-z_][a-z0-9_]*$/ {print "invalid-intent:" $1 "=" $3}
  ' "$OWNERSHIP")"
  _own_dupes="$(awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} NF==3 {print $1}' "$OWNERSHIP" | sort | uniq -d)"
  if [ -n "$_own_bad" ]; then
    err "key ownership registry invalid: $_own_bad"
  elif [ -n "$_own_dupes" ]; then
    err "duplicate keys in ownership registry: $_own_dupes"
  else
    _own_conf="${TMPDIR:-/tmp}/asb_own_conf.$$"
    _own_reg="${TMPDIR:-/tmp}/asb_own_reg.$$"
    awk -F= '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/{k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k); print k}' "$CONF" > "$_own_conf"
    awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} NF==3 {print $1}' "$OWNERSHIP" > "$_own_reg"
    _own_missing="$(while IFS= read -r _ok; do grep -Fqx "$_ok" "$_own_reg" || printf '%s ' "$_ok"; done < "$_own_conf")"
    _own_extra="$(while IFS= read -r _ok; do grep -Fqx "$_ok" "$_own_conf" || printf '%s ' "$_ok"; done < "$_own_reg")"
    rm -f "$_own_conf" "$_own_reg"
    if [ -n "$_own_missing" ] || [ -n "$_own_extra" ]; then
      err "config ownership key-set drift: missing=[${_own_missing:-}] extra=[${_own_extra:-}]"
    else
      _own_counts="$(awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} NF==3 {n[$2]++} END{printf "user=%d advanced=%d internal=%d", n["user"]+0, n["advanced"]+0, n["internal"]+0}' "$OWNERSHIP")"
      ok "config ownership registry exactly matches governor.conf ($_own_counts)"
    fi
  fi

  # A visible card must never be silently classified as internal; conversely an old public
  # registry row must be removed if its card disappears. This checks the ownership boundary,
  # not the user-facing translations (covered by the existing locale contracts below).
  if [ -f "$MODDIR/webroot/index.html" ] && [ -f "$OWNERSHIP" ]; then
    _own_ui="${TMPDIR:-/tmp}/asb_own_ui.$$"
    sed -n '/const CFG_ITEMS = \[/,/^\];/p' "$MODDIR/webroot/index.html" | grep -oE "key:'[A-Za-z_][A-Za-z0-9_]*'" | sed "s/key:'//;s/'//" | sort -u > "$_own_ui"
    _own_card_bad="$(while IFS= read -r _ok; do
      _oc="$(awk -F'|' -v k="$_ok" '$1==k {print $2; exit}' "$OWNERSHIP")"
      case "$_oc" in user|advanced) : ;; *) printf '%s ' "$_ok" ;; esac
    done < "$_own_ui")"
    _own_public_stale="$(awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} ($2=="user" || $2=="advanced") {print $1}' "$OWNERSHIP" | while IFS= read -r _ok; do grep -Fqx "$_ok" "$_own_ui" || printf '%s ' "$_ok"; done)"
    rm -f "$_own_ui"
    if [ -n "$_own_card_bad" ] || [ -n "$_own_public_stale" ]; then
      err "WebUI/ownership drift: internal-or-unregistered-cards=[${_own_card_bad:-}] stale-public-keys=[${_own_public_stale:-}]"
    else
      ok "every WebUI card is user/advanced and every public registry key has a card"
    fi
  fi
fi

echo
 echo "📋 Profile Consistency"

for p in battery balanced performance; do
  f="$MODDIR/profiles/${p}.sh"
  [ ! -f "$f" ] && { err "$p.sh missing"; continue; }
  check_shell_syntax "$f"

  P="$(echo "$p" | tr '[:lower:]' '[:upper:]')"
  if [ -f "$MODDIR/config/profile_bounds.generated.sh" ]; then
    _src="$MODDIR/config/profile_bounds.generated.sh"
    CPU_MIN_L="$(get_kv "$_src" "${P}_CPU_MIN_LITTLE")"
    CPU_MIN_B="$(get_kv "$_src" "${P}_CPU_MIN_BIG")"
    CPU_MAX_L="$(get_kv "$_src" "${P}_CPU_MAX_LITTLE")"
    CPU_MAX_B="$(get_kv "$_src" "${P}_CPU_MAX_BIG")"
    CPU_CAP_L="$(get_kv "$_src" "${P}_CPU_CAP_LITTLE")"
    CPU_CAP_B="$(get_kv "$_src" "${P}_CPU_CAP_BIG")"
    GPU_MAX="$(get_kv "$_src" "${P}_GPU_MAX_PCT")"
  else
    CPU_MIN_L="$(get_kv "$f" CPU_MIN_LITTLE)"
    CPU_MIN_B="$(get_kv "$f" CPU_MIN_BIG)"
    CPU_MAX_L="$(get_kv "$f" CPU_MAX_LITTLE)"
    CPU_MAX_B="$(get_kv "$f" CPU_MAX_BIG)"
    CPU_CAP_L="$(get_kv "$f" CPU_CAP_LITTLE)"
    CPU_CAP_B="$(get_kv "$f" CPU_CAP_BIG)"
    GPU_MAX="$(get_kv "$f" GPU_MAX_PCT)"
  fi
  GPU_MIN="$(get_kv "$f" GPU_MIN_PCT)"
  SCHED_UP="$(get_kv "$f" SCHED_UP_RATE)"
  SCHED_DOWN="$(get_kv "$f" SCHED_DOWN_RATE)"

  [ -n "$CPU_MIN_L" ] && [ -n "$CPU_CAP_L" ] && num_gt "$CPU_MIN_L" "$CPU_CAP_L" && err "$p: CPU_MIN_LITTLE($CPU_MIN_L) > CPU_CAP_LITTLE($CPU_CAP_L)"
  [ -n "$CPU_MIN_B" ] && [ -n "$CPU_CAP_B" ] && num_gt "$CPU_MIN_B" "$CPU_CAP_B" && err "$p: CPU_MIN_BIG($CPU_MIN_B) > CPU_CAP_BIG($CPU_CAP_B)"
  [ -n "$CPU_CAP_L" ] && [ -n "$CPU_MAX_L" ] && num_gt "$CPU_CAP_L" "$CPU_MAX_L" && err "$p: CPU_CAP_LITTLE($CPU_CAP_L) > CPU_MAX_LITTLE($CPU_MAX_L)"
  [ -n "$CPU_CAP_B" ] && [ -n "$CPU_MAX_B" ] && num_gt "$CPU_CAP_B" "$CPU_MAX_B" && err "$p: CPU_CAP_BIG($CPU_CAP_B) > CPU_MAX_BIG($CPU_MAX_B)"
  [ -n "$GPU_MIN" ] && [ -n "$GPU_MAX" ] && num_gt "$GPU_MIN" "$GPU_MAX" && err "$p: GPU_MIN_PCT($GPU_MIN) > GPU_MAX_PCT($GPU_MAX)"
  [ -n "$SCHED_UP" ] && [ -n "$SCHED_DOWN" ] && num_gt "$SCHED_UP" "$SCHED_DOWN" && warn "$p: SCHED_UP_RATE($SCHED_UP) > SCHED_DOWN_RATE($SCHED_DOWN)"

  [ -n "$CPU_MAX_L" ] && [ -n "$CPU_MAX_B" ] && ok "$p.sh core ranges parsed"
done

echo
echo "📊 Profile Hierarchy"
_bsh="$MODDIR/config/profile_bounds.generated.sh"
_bcf="$MODDIR/config/profile_bounds.conf"
_hierarchy_src=""
if [ -f "$_bsh" ]; then
  _hierarchy_src="$_bsh"
elif [ -f "$_bcf" ]; then
  _hierarchy_src="$_bcf"
fi
if [ -n "$_hierarchy_src" ]; then
  BAT_CAP_L="$(get_kv "$_hierarchy_src" BATTERY_CPU_CAP_LITTLE)"
  BAL_CAP_L="$(get_kv "$_hierarchy_src" BALANCED_CPU_CAP_LITTLE)"
  PER_CAP_L="$(get_kv "$_hierarchy_src" PERFORMANCE_CPU_CAP_LITTLE)"
  BAT_CAP_B="$(get_kv "$_hierarchy_src" BATTERY_CPU_CAP_BIG)"
  BAL_CAP_B="$(get_kv "$_hierarchy_src" BALANCED_CPU_CAP_BIG)"
  PER_CAP_B="$(get_kv "$_hierarchy_src" PERFORMANCE_CPU_CAP_BIG)"
else
  BAT_CAP_L="$(get_kv "$MODDIR/profiles/battery.sh" CPU_CAP_LITTLE)"
  BAL_CAP_L="$(get_kv "$MODDIR/profiles/balanced.sh" CPU_CAP_LITTLE)"
  PER_CAP_L="$(get_kv "$MODDIR/profiles/performance.sh" CPU_CAP_LITTLE)"
  BAT_CAP_B="$(get_kv "$MODDIR/profiles/battery.sh" CPU_CAP_BIG)"
  BAL_CAP_B="$(get_kv "$MODDIR/profiles/balanced.sh" CPU_CAP_BIG)"
  PER_CAP_B="$(get_kv "$MODDIR/profiles/performance.sh" CPU_CAP_BIG)"
fi
if [ -n "$BAT_CAP_L" ] && [ -n "$BAL_CAP_L" ] && [ -n "$PER_CAP_L" ]; then
  if num_le "$BAT_CAP_L" "$BAL_CAP_L" && num_le "$BAL_CAP_L" "$PER_CAP_L"; then
    ok "little-cluster caps: battery ≤ balanced ≤ performance"
  else
    warn "little-cluster hierarchy broken: bat=$BAT_CAP_L bal=$BAL_CAP_L perf=$PER_CAP_L"
  fi
fi
if [ -n "$BAT_CAP_B" ] && [ -n "$BAL_CAP_B" ] && [ -n "$PER_CAP_B" ]; then
  if num_le "$BAT_CAP_B" "$BAL_CAP_B" && num_le "$BAL_CAP_B" "$PER_CAP_B"; then
    ok "big-cluster caps: battery ≤ balanced ≤ performance"
  else
    warn "big-cluster hierarchy broken: bat=$BAT_CAP_B bal=$BAL_CAP_B perf=$PER_CAP_B"
  fi
fi

echo
echo "💾 Runtime Files"
for pf in pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  fp="$MODDIR/runtime/$pf"
  [ -f "$fp" ] || continue
  case "$pf" in
    *.json)  validate_json "$fp" ;;
    *.jsonl)
      if [ -z "$PYTHON_BIN" ]; then
        warn "python3 not found, skipped JSONL validation for $pf"
      elif "$PYTHON_BIN" -c "import json,sys; [json.loads(l) for l in open('$fp', encoding='utf-8') if l.strip().startswith('{')]" 2>/dev/null; then
        ok "$pf: valid JSONL"
      else
        err "$pf: invalid JSONL"
      fi
      ;;
  esac
done

echo
echo "🔧 Features"
FEAT="$MODDIR/features.conf"
KNOWN_FEATURES="AUDIO BT NFC CAMERA MEDIA CPU VM NET WIFI GPS KERNEL LOG LPM RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY SOTER_REPAIR"
# Which features are actually wired is DERIVED, not hardcoded.
asb_feature_is_wired() {
  _fw="$1"
  grep -rqE "asb_feature_enabled[[:space:]]+${_fw}\b|_feat[[:space:]]+${_fw}\b" \
       "$MODDIR"/*.sh "$MODDIR"/runtime/*.sh "$MODDIR"/common/*.sh 2>/dev/null && return 0
  grep -qE "^# *ASB:${_fw}:BEGIN" "$MODDIR/system.prop" "$MODDIR/runtime/asb_managed.props" \
       "$MODDIR/service.sh" "$MODDIR/post-fs-data.sh" 2>/dev/null && return 0
  return 1
}
if [ -f "$FEAT" ]; then
  F_DUPES="$(awk -F= '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {k=$1; gsub(/[[:space:]]+$/, "", k); print k}' "$FEAT" | sort | uniq -d)"
  [ -n "$F_DUPES" ] && warn "duplicate feature keys: $F_DUPES" || ok "no duplicate feature keys"
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    case "$key" in ''|\#*) continue ;; esac
    key="$(echo "$key" | tr -d '[:space:]')"
    # strip inline # comments and surrounding whitespace from value
    val="$(echo "$val" | sed 's/#.*$//' | tr -d '[:space:]')"
    case " $KNOWN_FEATURES " in
      *" $key "*) : ;;
      *) warn "unknown feature key: $key" ;;
    esac
    case "$val" in 0|1) : ;; *) warn "features.conf: $key=$val (expected 0 or 1)" ;; esac
  done < "$FEAT"
  # Warn only about features that are genuinely inert.
  _feat_dead=""
  for _rf in $KNOWN_FEATURES; do
    grep -qE "^${_rf}=" "$FEAT" 2>/dev/null || continue
    asb_feature_is_wired "$_rf" || _feat_dead="${_feat_dead} ${_rf}"
  done
  if [ -n "$_feat_dead" ]; then
    warn "feature(s) declared but inert (no gate, no managed-property block):${_feat_dead}"
  else
    ok "every declared feature has a runtime path"
  fi
  ok "features.conf parsed"
else
  err "features.conf missing"
fi

echo
echo "🩺  — Operational Health"
# common/profile_core.sh must not exist (only runtime/ copy is canonical)
if [ -f "$MODDIR/common/profile_core.sh" ]; then
  err "common/profile_core.sh present —  expects only runtime/profile_core.sh (canonical-source guard)"
elif [ ! -f "$MODDIR/runtime/profile_core.sh" ]; then
  err "runtime/profile_core.sh missing"
else
  ok "profile_core.sh: only runtime/ copy"
fi

# Check 2: baseline helper must exist
if [ -f "$MODDIR/runtime/asb_baseline.sh" ]; then
  ok "runtime/asb_baseline.sh present (restore path enabled)"
else
  warn "runtime/asb_baseline.sh missing — persistent settings will not be restored on uninstall"
fi

# Check 3: BG_TRIM_LEVEL must be safe or aggressive
if [ -f "$MODDIR/config/governor.conf.shipped" ]; then
  _bgl="$(grep -E "^BG_TRIM_LEVEL=" "$MODDIR/config/governor.conf.shipped" 2>/dev/null | tail -1 | cut -d= -f2)"
  case "$_bgl" in
    safe|aggressive) ok "BG_TRIM_LEVEL=$_bgl (valid)" ;;
    "") warn "BG_TRIM_LEVEL not set in shipped config (will default to safe at runtime)" ;;
    *) err "BG_TRIM_LEVEL=$_bgl (must be safe or aggressive)" ;;
  esac
fi

# Check 4: KERNEL block must not contain audio props in the managed payload.
_PROP_PAYLOAD="$MODDIR/runtime/asb_managed.props"
[ -f "$_PROP_PAYLOAD" ] || _PROP_PAYLOAD="$MODDIR/system.prop"
if [ -f "$_PROP_PAYLOAD" ]; then
  _kern_audio="$(sed -n '/# ASB:KERNEL:BEGIN/,/# ASB:KERNEL:END/p' "$_PROP_PAYLOAD" | grep -cE "^(persist\.|ro\.|vendor\.).*audio|^(persist\.|ro\.|vendor\.).*dts|^(persist\.|ro\.|vendor\.).*dolby")"
  if [ "$_kern_audio" -gt 0 ]; then
    err "managed property KERNEL block contains $_kern_audio audio props"
  else
    ok "managed property KERNEL block free of audio overrides"
  fi
fi

# Check 5: Soter loop must be opt-in (SOTER_REPAIR=0 default)
if grep -qE "^SOTER_REPAIR=" "$MODDIR/features.conf" 2>/dev/null; then
  _sv="$(grep -E "^SOTER_REPAIR=" "$MODDIR/features.conf" | tail -1 | sed 's/SOTER_REPAIR=//;s/#.*//;s/[[:space:]]//g')"
  if [ "$_sv" = "0" ]; then
    ok "SOTER_REPAIR=0 (opt-in, default off)"
  elif [ "$_sv" = "1" ]; then
    warn "SOTER_REPAIR=1 — Soter repair runs on every boot"
  fi
fi

# Check 6: pm clear in Soter loop must NOT be present (destructive — removed)
if [ -f "$MODDIR/service.sh" ]; then
  # Exclude comments — grep for pm clear NOT preceded by '#'
  if grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -qE "pm clear com\.tencent\.soter\.soterserver"; then
    err "service.sh contains destructive 'pm clear com.tencent.soter.soterserver'"
  else
    ok "Soter loop free of pm clear"
  fi
fi

#  check: Athena/COSA persist setprops must not be in service.sh non-comment lines
# Reason: setting persist.sys.oplus.athena.reclaim_enable=1 on OnePlus Ace 5
# (SM8635, OxygenOS 16) caused system_server deadlock with CachedAppOptimizer.
if [ -f "$MODDIR/service.sh" ]; then
  _athena_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "(asb_persist_safe|setprop)[[:space:]]+persist\\.sys\\.oplus\\.(athena|deepthinker)" 2>/dev/null)"
  if [ "$_athena_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh writes $_athena_writes Athena/deepthinker persist props"
  else
    ok "Athena/COSA persist props not written"
  fi
fi

#  check: matrix.limiter.enable=false and ro.audio.audiozoom=true must
# not be in service.sh or the managed property payload non-comment lines.
# Reason: both cause stereo widening / center channel weakness (user-reported).
if [ -f "$MODDIR/service.sh" ]; then
  _widening_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "(matrix\\.limiter\\.enable[[:space:]]+false|audiozoom[[:space:]]+true)" 2>/dev/null)"
  if [ "$_widening_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh writes $_widening_writes stereo-widening props"
  else
    ok "Stereo-widening props not written"
  fi
fi
_PROP_PAYLOAD="$MODDIR/runtime/asb_managed.props"
[ -f "$_PROP_PAYLOAD" ] || _PROP_PAYLOAD="$MODDIR/system.prop"
if [ -f "$_PROP_PAYLOAD" ]; then
  _widening_sysprop="$(grep -vE "^[[:space:]]*#" "$_PROP_PAYLOAD" | grep -cE "^(audio\\.matrix\\.limiter\\.enable=false|vendor\\.audio\\.matrix\\.limiter\\.enable=false|ro\\.audio\\.audiozoom=true)" 2>/dev/null)"
  if [ "$_widening_sysprop" -gt 0 ] 2>/dev/null; then
    err "managed property payload has $_widening_sysprop stereo-widening defaults"
  else
    ok "managed property payload free of stereo-widening defaults"
  fi
fi

# check: vm.oom_kill_allocating_task=1 must not be written anywhere in service.sh.
# This setting caused false-positive OOM kills of legitimately allocating apps (App Market,
# WhatsApp) under battery profile memory pressure (swappiness=200 + minfree=112MB).
if [ -f "$MODDIR/service.sh" ]; then
  _oom_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "sysctlw[[:space:]]+vm\\.oom_kill_allocating_task[[:space:]]+1|echo[[:space:]]+1[[:space:]]*>.*oom_kill_allocating_task" 2>/dev/null)"
  if [ "$_oom_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh sets vm.oom_kill_allocating_task=1 ($_oom_writes occurrences) —  regression, causes false-positive OOM kills"
  else
    ok "vm.oom_kill_allocating_task not forced to 1"
  fi
fi

#  check: battery profile VM_SWAPPINESS must not exceed 175. had
# 200 (kernel default is 60) which combined with oom_kill_allocating_task=1
# caused app kills under normal memory pressure. 175 is the safe ceiling.
if [ -f "$MODDIR/profiles/battery.sh" ]; then
  _swap_bat="$(grep -E "^VM_SWAPPINESS=" "$MODDIR/profiles/battery.sh" | cut -d= -f2)"
  if [ -n "$_swap_bat" ] && [ "$_swap_bat" -gt 175 ] 2>/dev/null; then
    err "battery profile VM_SWAPPINESS=$_swap_bat exceeds safe ceiling 175"
  else
    ok "battery profile VM_SWAPPINESS=$_swap_bat within safe range"
  fi
fi

if [ -f "$MODDIR/src/asb_governor.c" ]; then
  if grep -qE "^#define BAT_TRUST_NOISY[[:space:]]" "$MODDIR/src/asb_governor.c"; then
    ok "BAT_TRUST_NOISY constant present"
  else
    err "BAT_TRUST_NOISY constant missing from asb_governor.c"
  fi
  _intent_names_count="$(grep -E "^static const char \*intent_names\[\]" "$MODDIR/src/asb_governor.c" | grep -oE '"[^"]+"' | wc -l)"
  if [ "$_intent_names_count" = "7" ]; then
    ok "intent_names[] has 7 entries (IDLE_WARM present)"
  else
    err "intent_names[] has $_intent_names_count entries"
  fi
  if grep -qE "asb_log_critical|asb_log_persist" "$MODDIR/src/asb_governor.c"; then
    ok "persistent log mirror present"
  else
    err "persistent log mirror missing"
  fi
fi

echo
echo "🏗  Bounds Source-of-Truth"
_bc="$MODDIR/config/profile_bounds.conf"
_bsh="$MODDIR/config/profile_bounds.generated.sh"
_bh="$MODDIR/src/asb_fsm_bounds.generated.h"
_gen="$MODDIR/tools/gen_bounds.sh"
if [ -f "$_bc" ] && [ -f "$_bsh" ] && [ -f "$_bh" ] && [ -f "$_gen" ]; then
  if [ "$_bc" -nt "$_bsh" ] || [ "$_bc" -nt "$_bh" ]; then
    warn "profile_bounds.conf newer than generated files — run tools/gen_bounds.sh"
  else
    ok "generated bounds files newer than source"
  fi
  if [ -x "$_gen" ] || [ -r "$_gen" ]; then
    _tmp_sh="$(mktemp 2>/dev/null || echo "/tmp/asb_lint_sh.$$")"
    _tmp_h="$(mktemp 2>/dev/null || echo "/tmp/asb_lint_h.$$")"
    _cur_sh_md5="$(md5sum "$_bsh" 2>/dev/null | awk '{print $1}')"
    _cur_h_md5="$(md5sum "$_bh"  2>/dev/null | awk '{print $1}')"
    _backup_sh="$(cat "$_bsh" 2>/dev/null)"
    _backup_h="$(cat "$_bh"  2>/dev/null)"
    if bash "$_gen" >/dev/null 2>&1; then
      _new_sh_md5="$(md5sum "$_bsh" 2>/dev/null | awk '{print $1}')"
      _new_h_md5="$(md5sum "$_bh"  2>/dev/null | awk '{print $1}')"
      if [ "$_cur_sh_md5" = "$_new_sh_md5" ] && [ "$_cur_h_md5" = "$_new_h_md5" ]; then
        ok "regeneration produces identical output (no drift)"
      else
        err "regeneration would change files — generated bounds are STALE"
        printf '%s\n' "$_backup_sh" > "$_bsh" 2>/dev/null
        printf '%s\n' "$_backup_h"  > "$_bh"  2>/dev/null
      fi
    else
      err "gen_bounds.sh exited non-zero (invariant violation in profile_bounds.conf)"
    fi
    rm -f "$_tmp_sh" "$_tmp_h" 2>/dev/null
  fi

  for P in BATTERY BALANCED PERFORMANCE; do
    _shc_min_l="$(grep -E "^${P}_CPU_MIN_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _shc_max_l="$(grep -E "^${P}_CPU_MAX_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _shc_cap_l="$(grep -E "^${P}_CPU_CAP_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _chc_floor_max_l="$(grep -E "^#define ASB_${P}_FLOOR_CPU_MAX_LITTLE" "$_bh" 2>/dev/null | awk '{print $3}')"
    _chc_ceil_max_l="$(grep -E "^#define ASB_${P}_CEIL_CPU_MAX_LITTLE"  "$_bh" 2>/dev/null | awk '{print $3}')"
    _chc_floor_min_l="$(grep -E "^#define ASB_${P}_FLOOR_CPU_MIN_LITTLE" "$_bh" 2>/dev/null | awk '{print $3}')"
    if [ -n "$_shc_cap_l" ] && [ -n "$_chc_floor_max_l" ] && [ "$_shc_cap_l" = "$_chc_floor_max_l" ]; then
      :
    else
      err "${P}: CPU_CAP_LITTLE shell=$_shc_cap_l vs C FLOOR_CPU_MAX_LITTLE=$_chc_floor_max_l (must match)"
    fi
    if [ -n "$_shc_max_l" ] && [ -n "$_chc_ceil_max_l" ] && [ "$_shc_max_l" = "$_chc_ceil_max_l" ]; then
      :
    else
      err "${P}: CPU_MAX_LITTLE shell=$_shc_max_l vs C CEIL_CPU_MAX_LITTLE=$_chc_ceil_max_l (must match)"
    fi
    if [ -n "$_shc_min_l" ] && [ -n "$_chc_floor_min_l" ] && [ "$_shc_min_l" = "$_chc_floor_min_l" ]; then
      :
    else
      err "${P}: CPU_MIN_LITTLE shell=$_shc_min_l vs C FLOOR_CPU_MIN_LITTLE=$_chc_floor_min_l (must match)"
    fi
  done
  ok "shell↔C bounds parity checked (BATTERY/BALANCED/PERFORMANCE)"
elif [ -f "$_bsh" ] && [ ! -f "$_bc" ] && [ ! -f "$_gen" ]; then
  if grep -qE "^BATTERY_CPU_MIN_LITTLE=[0-9]+" "$_bsh" && \
     grep -qE "^BALANCED_CPU_MIN_LITTLE=[0-9]+" "$_bsh" && \
     grep -qE "^PERFORMANCE_CPU_MIN_LITTLE=[0-9]+" "$_bsh"; then
    ok "profile_bounds.generated.sh present and well-formed (release deployment)"
  else
    err "profile_bounds.generated.sh malformed (missing per-profile keys)"
  fi
else
  if [ ! -f "$_bc" ] && [ ! -f "$_bsh" ]; then
    warn "no bounds source-of-truth files found — older module version?"
  elif [ ! -f "$_bsh" ] || [ ! -f "$_bh" ]; then
    err "generated bounds files missing — run tools/gen_bounds.sh"
  fi
fi

echo
# asbdiag ships twice: tools/asb_diag.sh is the source, system/bin/asbdiag is what the
# user runs. Nothing kept them in step, and they had drifted by 83 lines - so a report
# from a user was describing an older build than the one they installed.
if [ -f tools/asb_diag.sh ] && [ -f system/bin/asbdiag ]; then
  if cmp -s tools/asb_diag.sh system/bin/asbdiag; then
    ok "asbdiag copies are identical"
  else
    warn "system/bin/asbdiag differs from tools/asb_diag.sh - copy it before release"
  fi
fi

# Config schema: does the stored number still match what the UI writes?
#
# Three regressions in a row came from the same place - a value whose meaning changed
# while old configs kept the old number. anim_speed is the one that got caught; the next
# one will not announce itself either. So: pin the schema to the shape of the settings it
# describes, and fail when the shape moves without the number moving.
#
# Each shape is bound to its key BEFORE sorting.
#
# The first version hashed the bare option lists and slider ranges, then sorted them -
# which turns the input into a set and loses which card each shape belongs to. Swapping
# the opts of two cards left the fingerprint identical, verified on this file: every
# stored value for both settings then meant something else while the lint said "matches".
# Tying key to shape first makes the sort safe, because each line now carries its own
# identity and a swap changes two lines rather than reordering the same two.
#
# [a-zA-Z0-9_] and not [a-zA-Z_]: bt_a2dp_offload has a digit in its name, and the
# narrower class silently dropped it - 33 matches instead of 34, with no error anywhere.
_schema_now="$(grep -oE "key:'[a-zA-Z0-9_]+'[^}]*(opts:\[[^]]*\]|min:-?[0-9]+, max:[0-9]+)" webroot/index.html \
               | sed -E "s/.*key:'([a-zA-Z0-9_]+)'.*(opts:\[[^]]*\]|min:-?[0-9]+, max:[0-9]+)/\1=\2/" \
               | sort | md5sum | cut -c1-12)"
_schema_rec="$(grep -m1 '^# CONFIG_SHAPE=' config/governor.conf 2>/dev/null | sed 's/.*=//')"
_schema_ver="$(grep -m1 'echo [0-9]* > /data/adb/asb/config_schema' common/install.sh \
               | grep -oE 'echo [0-9]+' | grep -oE '[0-9]+')"
if [ -z "$_schema_rec" ]; then
  warn "config shape fingerprint missing - add '# CONFIG_SHAPE=$_schema_now' to governor.conf"
elif [ "$_schema_rec" != "$_schema_now" ]; then
  err "config shape changed ($_schema_rec -> $_schema_now) but nothing says the schema moved."
  # Continuation lines use P, not err: one problem is one error. Counting the explanation
  # as five more made a single finding read as six and would hide a second real one.
  echo "     If a stored value now means something different, bump the number written to"
  echo "     /data/adb/asb/config_schema (currently $_schema_ver) and add a migration."
  echo "     Only if no stored value changed meaning, update CONFIG_SHAPE in governor.conf -"
  echo "     and say in the commit which values you checked. That line is the cheapest way"
  echo "     to make this red go away, which is exactly why it must not be the reflex."
else
  ok "config shape matches the recorded fingerprint (schema $_schema_ver)"
fi

# Translation files: present, parseable, and matching the language list.
#
# Moving these out of index.html removed 58 KB from a 4700-line file and made a translation
# a self-contained contribution - but it also turned a missing language from a syntax error
# into a silent fallback to English. That is the right runtime behaviour and the wrong
# build behaviour: shipping without a language nobody notices until a user reports it.
_i18n_langs="$(grep -oE "const ASB_LANGS = \[[^]]*\]" webroot/index.html \
               | grep -oE "'[a-z]{2}'" | tr -d \' )"
for _l in en $_i18n_langs; do
  if [ ! -f "webroot/i18n/$_l.json" ]; then
    err "webroot/i18n/$_l.json missing - ASB_LANGS offers '$_l' with no strings behind it"
  elif ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "webroot/i18n/$_l.json" 2>/dev/null; then
    err "webroot/i18n/$_l.json is not valid JSON - the UI would fall back to English silently"
  fi
done
ok "translation files present and parseable"

# Every locale must carry every global WebUI string from en.json.
#
# Card names/descriptions have their own nested checks below. This covers the root-level UI
# copy such as the named profile manager, export locations and two-step destructive reset
# dialogs. English fallback keeps the UI usable, but a mixed-language confirmation is not a
# release-quality result and used to hide thirty-six missing strings across eleven locales.
if command -v python3 >/dev/null 2>&1 && [ -f webroot/i18n/en.json ]; then
  _root_i18n_miss="$(python3 - <<'PYEOF_ROOT_I18N'
import glob, json, os
with open('webroot/i18n/en.json', encoding='utf-8') as f:
    reference = set(json.load(f))
out = []
for path in sorted(glob.glob('webroot/i18n/*.json')):
    if path.endswith('/en.json'):
        continue
    with open(path, encoding='utf-8') as f:
        missing = sorted(reference - set(json.load(f)))
    if missing:
        out.append('%s: %s' % (os.path.basename(path), ', '.join(missing[:6])))
print('; '.join(out))
PYEOF_ROOT_I18N
)"
  if [ -n "$_root_i18n_miss" ]; then
    err "locales missing global WebUI strings - $_root_i18n_miss"
  else
    ok "every locale contains all global WebUI strings"
  fi
fi

# Every runtime script must be in the workflow's required-files list.
#
# Adding a script means touching the script itself, install.sh for its chmod, service.sh to
# call it - and the two workflows, which is the one nobody remembers because nothing breaks
# locally when you forget. asb_wakelock_watch.sh shipped without it and was caught by a
# reviewer asking, not by anything here.
#
# The list is what makes the build fail loudly if a file goes missing from the tree; a
# script absent from it can vanish from a release with no warning at all.
_wf=".github/workflows/build-release.yml"
if [ -f "$_wf" ]; then
  _missing_rt=""
  for _rs in runtime/*.sh; do
    [ -f "$_rs" ] || continue
    grep -q "\"$_rs\"" "$_wf" 2>/dev/null || _missing_rt="$_missing_rt $(basename "$_rs")"
  done
  if [ -n "$_missing_rt" ]; then
    err "runtime scripts missing from the workflow required-files list:$_missing_rt"
  else
    ok "every runtime script is listed in the release workflow"
  fi
fi

# Every card must be in SNAP_KEYS, or its value never leaves the phone.
#
# SNAP_KEYS is what export writes and what an upgrade restores. A card missing from it
# looks fine in the UI and is silently absent from every backup - the user changes a
# setting, exports, and the value is not in the file. Found that way for two cards added
# in this release.
if [ -f webroot/index.html ] && command -v python3 >/dev/null 2>&1; then
  _snap_miss="$(python3 - <<'PYEOF_SNAP'
import re
s = open('webroot/index.html', encoding='utf-8').read()
m = re.search(r"SNAP_KEYS\s*=\s*\[(.*?)\]", s, re.S)
snap = set(re.findall(r"'([a-zA-Z_0-9]+)'", m.group(1))) if m else set()
i = s.index('const CFG_ITEMS = [');  j = s.index('\n];', i)
keys = re.findall(r"\{ key:'([A-Za-z_][A-Za-z_0-9]*)'", s[i:j])
print(' '.join(k for k in keys if k not in snap))
PYEOF_SNAP
)"
  if [ -n "$_snap_miss" ]; then
    err "cards missing from SNAP_KEYS (never exported, never restored):$_snap_miss"
  else
    ok "every card is in SNAP_KEYS"
  fi
fi

# Every card must declare its application semantics.
#
# Missing keys silently fall through applyModeOf() to APPLY_REBOOT. That is safe but can be
# false: night_modem_idle is read by the governor after a reload and previously told users to
# reboot for no reason. Keeping this explicit makes product copy match the actual save path.
if [ -f webroot/index.html ] && command -v python3 >/dev/null 2>&1; then
  _apply_miss="$(python3 - <<'PYEOF_APPLY'
import re
s = open('webroot/index.html', encoding='utf-8').read()
i = s.index('const CFG_ITEMS = ['); j = s.index('\n];', i)
items = set(re.findall(r"\{ key:'([A-Za-z_][A-Za-z_0-9]*)'", s[i:j]))
m = re.search(r'const APPLY_MODE\s*=\s*\{(.*?)\n\};', s, re.S)
apply = set(re.findall(r'([A-Za-z_][A-Za-z_0-9]*)\s*:\s*APPLY_(?:LIVE|NEXT|REBOOT)', m.group(1))) if m else set()
print(' '.join(sorted(items - apply)))
PYEOF_APPLY
)"
  if [ -n "$_apply_miss" ]; then
    err "cards missing APPLY_MODE (would silently claim reboot):$_apply_miss"
  else
    ok "every card has an explicit APPLY_MODE"
  fi
fi

# Every card must have a name in every language.
#
# Adding a card means touching CFG_ITEMS, the icon map, the group map, the apply map and
# eleven translation files. The first four are checked; the translations were not, and a
# card added after the strings moved out of index.html shipped English-only in ten
# languages without anything noticing. Caught by a user looking at the screen, which is
# the wrong last line of defence.
if command -v python3 >/dev/null 2>&1; then
  _i18n_miss="$(python3 - <<'PYEOF_I18N'
import json, re, glob, sys
s = open('webroot/index.html', encoding='utf-8').read()
i = s.index('const CFG_ITEMS = [');  j = s.index('\n];', i)
keys = re.findall(r"\{ key:'([A-Za-z_][A-Za-z_0-9]*)'", s[i:j])
out = []
for f in sorted(glob.glob('webroot/i18n/*.json')):
    # en.json holds interface strings only - card names live in CFG_ITEMS itself.
    if f.endswith('en.json'):
        continue
    try:
        d = json.load(open(f, encoding='utf-8'))
    except Exception:
        continue
    miss = [k for k in keys if k not in d.get('cfg', {})]
    if miss:
        out.append('%s: %s' % (f.split('/')[-1], ', '.join(miss[:4])))
print('; '.join(out))
PYEOF_I18N
)"
  if [ -n "$_i18n_miss" ]; then
    err "cards missing translations - $_i18n_miss"
  else
    ok "every card has a name in every language"
  fi
fi

# Terms that must not be translated by their everyday sense.
#
# H_GOV shipped as ГУБЕРНАТОР, GOBERNADOR, GOVERNADOR, المنظّم and 调度器 - five languages
# where "governor" was rendered as a public official or a task scheduler rather than the
# CPU frequency governor. Caught by a reviewer, not by anything here, and the only reason
# it was one term rather than several is luck.
#
# This is a blacklist of renderings known to be wrong, not a translation checker. It
# cannot judge a translation it has not seen before; it can stop a known-bad one coming
# back, which is the part that was purely manual until now.
# المنظّم was named in the comment above and missing from the list - a regression guard
# that covers four of the five cases it documents. Safe to add: the correct rendering is
# منظّم التردد, which has no definite article, so the bare form cannot match it.
_bad_terms="ГУБЕРНАТОР GOBERNADOR GOVERNADOR 调度器 المنظّم"
for _bt in $_bad_terms; do
  if grep -q "$_bt" action.sh 2>/dev/null; then
    err "action.sh contains '$_bt' - 'governor' here is the CPU frequency governor,"
    err "  not a public official or a task scheduler. See H_GOV."
  fi
done
ok "no known term mistranslations in action.sh"

# A schema number with no migration branch is worse than no schema at all: install.sh
# would compare against a version nothing handles, and everyone on the previous one stops
# being migrated silently. Check that the number written matches the highest one branched on.
# [^;]* and not [^0-9]*: the second migration branch is written as
# "${_asb_anim_schema:-1}" -lt 2, and a class excluding digits cannot cross the :-1 in the
# default. The old pattern found one branch of two. That was harmless while both were -lt
# 2, but a branch written only in the default form would have emptied _mig_max - and the
# guard below then skipped the whole check without printing anything. Silently doing
# nothing is the failure mode this file exists to prevent.
#
# Verified on this file: the pattern finds both branches; on a file containing only the
# default form it finds it too, where the previous two attempts returned nothing.
_mig_max="$(grep -oE 'schema[^;]*-lt[[:space:]]+[0-9]+' common/install.sh \
            | grep -oE '[0-9]+$' | sort -n | tail -1)"
# An empty result is an error, not a reason to stay quiet: either the pattern broke or
# there are no migrations at all, and both deserve red.
if [ -z "$_mig_max" ]; then
  err "no migration branch found in common/install.sh"
  err "  Either the schema has no migrations, or this check's pattern stopped matching."
  err "  Both are worth stopping for - a schema nobody migrates is a silent data change."
elif [ -n "$_schema_ver" ]; then
  if [ "$_schema_ver" != "$_mig_max" ]; then
    err "schema $_schema_ver is written but migrations only branch up to $_mig_max"
    err "  Add the missing 'schema -lt $_schema_ver' branch, or nobody on $_mig_max gets migrated."
  else
    ok "schema $_schema_ver has a matching migration branch"
  fi
fi


echo "🌐 Card descriptions per language"
# Names without descriptions is the failure mode users actually hit.
#
# A locale file with every NAME translated passes the old check and still shows English
# paragraphs under Italian titles - which is what an Italian user reported. Descriptions
# are the long texts, so they are the ones left behind when a language is added in a hurry.
# Counting them here means the gap is visible before release rather than after.
_desc_bad=0
for _lf in webroot/i18n/*.json; do
  _ln="$(basename "$_lf" .json)"
  [ "$_ln" = "en" ] && continue
  _miss="$(python3 - "$_lf" <<'PYEOF' 2>/dev/null
import json,sys,re
h=open('webroot/index.html').read()
items=set(re.findall(r"\{ key:'([\w]+)'", h))
c=json.load(open(sys.argv[1])).get('cfg',{})
print(len([k for k in items if k in c and 'desc' not in c[k]]))
PYEOF
)"
  case "$_miss" in ''|0) : ;; *) warn "$_ln.json: $_miss cards have a name but no description"; _desc_bad=1 ;; esac
done
[ "$_desc_bad" = "0" ] && ok "every language describes every card"
echo ""

echo "🖼  Card icons"
# Icons must be a real escape, not the text of one.
#
# CFG_ICONS entries look like '\uD83D\uDCF4'. Written with a doubled backslash the browser
# stops seeing an escape and renders twenty literal characters, which overflow the 44px
# icon box and shove the card title across the screen. This has now happened three times -
# Athena, net_rps and night_modem_idle - because nothing checked for it and the mistake
# looks identical to the correct form at a glance.
_ico_bad="$(python3 - <<'PYEOF' 2>/dev/null
import re
h=open('webroot/index.html').read()
blk=re.search(r'const CFG_ICONS = \{(.*?)\};', h, re.S)
if not blk: print(''); raise SystemExit
bad=[k for k,v in re.findall(r"(\w+)\s*:\s*'([^']*)'", blk.group(1)) if v.startswith('\\\\')]
print(' '.join(bad))
PYEOF
)"
if [ -n "$_ico_bad" ]; then
  err "icons written as literal text, not escapes: $_ico_bad"
else
  ok "every card icon is a real escape sequence"
fi
echo ""

echo "📁 Installer layout"
# There must be exactly ONE install.sh, and it lives in common/.
#
# functions.sh sources $MODPATH/common/install.sh and nothing else - a copy at the root is
# never executed by the installer, but rsync packaged it anyway and it overwrote the real
# one inside the zip. The stale root copy still had an unguarded
# `. "$MODPATH/common/englishtext.sh"`, so every CI build failed with
# "can't open .../common/englishtext.sh" while the fixed copy sat right next to it.
#
# Note the line number in that error is misleading: functions.sh strips comments from every
# .sh before running it, so reported lines do not match the file on disk.
if [ ! -f common/install.sh ]; then
  err "common/install.sh missing - this is the file functions.sh actually sources"
elif [ -f install.sh ]; then
  err "install.sh exists at the ROOT - delete it, only common/install.sh is executed"
else
  ok "single installer at common/install.sh"
fi
echo ""

echo "📋 Release identity"
# update.json is an OTA manifest. Its future release asset cannot exist before this
# workflow builds the first release ZIP, so the manifest is deliberately not a CI gate.
# module.prop is the authoritative artifact identity.
_mp="$MODDIR/module.prop"
_cl="$MODDIR/CHANGELOG.md"
if [ -f "$_mp" ]; then
  _mp_ver="$(grep '^version=' "$_mp" | head -1 | cut -d= -f2)"
  _mp_code="$(grep '^versionCode=' "$_mp" | head -1 | cut -d= -f2)"
  if [ -n "$_mp_ver" ] && [ -n "$_mp_code" ]; then
    ok "module identity present: version=$_mp_ver versionCode=$_mp_code"
    # update.json is what the manager reads to offer an update, so a stale copy tells
    # every installed user there is nothing new. It was two releases behind - V63/630
    # against a V64/640 module - and nothing in the build checked.
    if [ -f "$MODDIR/update.json" ]; then
      _uj_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MODDIR/update.json" | head -1)"
      _uj_code="$(sed -n 's/.*"versionCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MODDIR/update.json" | head -1)"
      if [ "$_uj_ver" = "$_mp_ver" ] && [ "$_uj_code" = "$_mp_code" ]; then
        ok "update.json matches module.prop"
      else
        err "update.json says $_uj_ver/$_uj_code but module.prop says $_mp_ver/$_mp_code"
      fi
    fi
  else
    err "module.prop missing version or versionCode"
  fi
  if [ -f "$_cl" ] && [ -n "$_mp_ver" ]; then
    if grep -qE "^# .*${_mp_ver}|^## .*${_mp_ver}" "$_cl" 2>/dev/null; then
      ok "CHANGELOG.md mentions $_mp_ver"
    else
      warn "CHANGELOG.md has no section heading for $_mp_ver"
    fi
  fi
  _ws="$MODDIR/webroot/index.html"
  if [ -f "$_ws" ] && [ -n "$_mp_ver" ]; then
    if grep -q "verBadge\"[^>]*>${_mp_ver}<" "$_ws" 2>/dev/null; then
      ok "WebUI badge matches $_mp_ver"
    else
      warn "WebUI verBadge does not match module.prop:version=$_mp_ver"
    fi
  fi
  _ac="$MODDIR/action.sh"
  if [ -f "$_ac" ] && [ -n "$_mp_ver" ]; then
    if grep -qE "(AutoSystemBoost|ASB)\s+${_mp_ver}\b" "$_ac" 2>/dev/null; then
      ok "action.sh banner matches $_mp_ver"
    else
      warn "action.sh banner does not match module.prop:version=$_mp_ver"
    fi
  fi
else
  err "module.prop missing"
fi

_ss="$MODDIR/service.sh"
_is="$MODDIR/common/install.sh"
if [ -f "$_ss" ]; then
  _exp_schema="$(grep -oE '_expected_schema=[0-9]+' "$_ss" | head -1 | grep -oE '[0-9]+')"
  _bm_schema=""
  if [ -f "$_is" ]; then
    _bm_schema="$(grep -A1 'build_manifest.json' "$_is" 2>/dev/null | grep -oE 'schema_version"?:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')"
    [ -z "$_bm_schema" ] && _bm_schema="$(grep -oE 'schema_version":[[:space:]]*[0-9]+' "$_is" | head -1 | grep -oE '[0-9]+')"
  fi
  if [ -n "$_exp_schema" ] && [ -n "$_bm_schema" ] && [ "$_exp_schema" = "$_bm_schema" ]; then
    ok "service.sh:_expected_schema == install.sh:build_manifest schema_version ($_exp_schema)"
  elif [ -n "$_exp_schema" ] && [ -n "$_bm_schema" ]; then
    err "schema mismatch: service.sh=$_exp_schema build_manifest=$_bm_schema"
  fi
fi

#  Smart Mode consistency checks
echo
echo "──  Smart Mode checks ──"
_sm_h="$MODDIR/src/asb_smart.h"
_sm_defs="$MODDIR/src/asb_smart_defs.h"
_cfg="$MODDIR/src/asb_config.h"
_gconf="$MODDIR/config/governor.conf.shipped"

if [ -f "$_sm_h" ] && [ -f "$_sm_defs" ]; then
  ok "asb_smart.h + asb_smart_defs.h present"
else
  err "asb_smart.h or asb_smart_defs.h missing"
fi

if [ -f "$_cfg" ] && [ -f "$_gconf" ]; then
  # Verify every smart_ key in shipped config has a parser branch in asb_config.h
  _missing=""
  for _k in $(grep "^smart_" "$_gconf" | cut -d= -f1); do
    if ! grep -q "\"$_k\"" "$_cfg"; then
      _missing="$_missing $_k"
    fi
  done
  if [ -n "$_missing" ]; then
    err "Smart Mode keys in governor.conf.shipped not parsed by asb_config.h:$_missing"
  else
    ok "all smart_ keys in shipped config have parser branches"
  fi

  # Verify Smart Mode struct field count matches parser count
  _struct_fields=$(grep "smart_" "$_cfg" | grep -c "int\s*smart_" || echo 0)
  _parser_brs=$(grep -c "\"smart_" "$_cfg" || echo 0)
  if [ "$_struct_fields" -gt 0 ] && [ "$_parser_brs" -gt 0 ]; then
    if [ "$_struct_fields" = "$_parser_brs" ]; then
      ok "Smart Mode: $_struct_fields struct fields == $_parser_brs parser branches"
    else
      warn "Smart Mode: struct fields ($_struct_fields) != parser branches ($_parser_brs)"
    fi
  fi
fi

# PROFILE_SMART enum should be defined
if [ -f "$MODDIR/src/asb_fsm.h" ]; then
  if grep -q "^#define PROFILE_SMART" "$MODDIR/src/asb_fsm.h"; then
    ok "PROFILE_SMART enum defined in asb_fsm.h"
  else
    err "PROFILE_SMART enum missing from asb_fsm.h"
  fi
fi

# Smart Mode CLI tool should exist and be executable
_smcli="$MODDIR/tools/asb_smart_mode.sh"
if [ -f "$_smcli" ]; then
  if bash -n "$_smcli" 2>/dev/null; then
    ok "tools/asb_smart_mode.sh syntax OK"
  else
    err "tools/asb_smart_mode.sh has syntax errors"
  fi
fi

# Check: smart_pkg_plaintext defaults to 0 (privacy by default)
if [ -f "$_gconf" ]; then
  _pkg_plain=$(grep "^smart_pkg_plaintext=" "$_gconf" | cut -d= -f2)
  if [ "$_pkg_plain" = "0" ]; then
    ok "smart_pkg_plaintext=0 (privacy by default)"
  else
    err "smart_pkg_plaintext=$_pkg_plain in shipped config (must be 0 for privacy)"
  fi
fi

# Check: smart_mode_enabled defaults to 0 in shipped config (per migration design)
if [ -f "$_gconf" ]; then
  _sm_en=$(grep "^smart_mode_enabled=" "$_gconf" | cut -d= -f2)
  if [ "$_sm_en" = "0" ]; then
    ok "smart_mode_enabled=0 in shipped config (controlled by file flag at boot)"
  else
    warn "smart_mode_enabled=$_sm_en in shipped config (should be 0; flag governs runtime)"
  fi
fi

echo
echo "──  Smart Mode unit tests ──"
_lc=""
command -v gcc >/dev/null 2>&1 && _lc=gcc
[ -z "$_lc" ] && { command -v cc >/dev/null 2>&1 && _lc=cc; }
[ -n "${CC:-}" ] && _lc="$CC"
if [ -z "$_lc" ]; then
  echo "  (no C compiler on this host — test build skipped; runs in CI/dev)"
elif [ ! -f "$MODDIR/tests/test_smart_session3.c" ]; then
  echo "  (tests/ not present — skipped)"
else
  for _t in test_smart_session2 test_smart_session3; do
    if "$_lc" -I"$MODDIR/src" -D_GNU_SOURCE -Wno-unused-parameter -Wno-sign-compare \
        -Wno-unused-function "$MODDIR/tests/$_t.c" -o "/tmp/asb_lint_$_t" 2>/dev/null; then
      ok "$_t compiles"
    else
      err "$_t does NOT compile — Smart Mode test barrier is broken"
    fi
    rm -f "/tmp/asb_lint_$_t"
  done
fi

echo
echo "═══════════════════════════════"
echo "  Lint: ❌ $ERRORS errors  ⚠️  $WARNS warnings"
[ $ERRORS -eq 0 ] && echo "  Config: CLEAN" || echo "  Config: FIX REQUIRED"
echo "═══════════════════════════════"
