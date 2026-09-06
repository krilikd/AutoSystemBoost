# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service (a OnePlus 15R returned "Failure calling service settings"
# for every call while exiting 0). Sourced here so installer-time writes get it too.
[ -f "$MODPATH/runtime/asb_settings.sh" ] && . "$MODPATH/runtime/asb_settings.sh"

set +x 2>/dev/null
set +v 2>/dev/null

asb_push_old_output() {
  local i=0
  while [ $i -lt 3 ]; do
    # Make sure the module has a config before anything else runs.
#
# The release workflow deliberately excludes config/governor.conf and ships
# config/governor.conf.shipped instead, so the flashable ZIP has no working config until
# the installer creates one. Nothing did. A user on release V63 could not change a single
# setting - every WebUI write answered "missing governor.conf" - and reinstalling did not
# help, because reinstalling ran the same installer that never created the file.
#
# This has to happen before any code that READS the config, which is most of this script,
# so it goes at the very top rather than wherever it was convenient to add.
if [ ! -f "$MODPATH/config/governor.conf" ] && [ -f "$MODPATH/config/governor.conf.shipped" ]; then
  cp -f "$MODPATH/config/governor.conf.shipped" "$MODPATH/config/governor.conf" 2>/dev/null || true
  chmod 644 "$MODPATH/config/governor.conf" 2>/dev/null || true
fi
if [ ! -f "$MODPATH/config/governor.conf" ]; then
  ui_print " "
  ui_print "  config/governor.conf is missing and cannot be restored."
  ui_print "  Every setting change will fail. Re-download the module ZIP."
  ui_print " "
fi

ui_print " "
    i=$((i+1))
  done
}

asb_big_banner() {
  asb_push_old_output
ui_print " "
ui_print "    █████╗    ███████╗██████╗ "
ui_print "  ██╔══██╗██╔════╝██╔══██╗"
ui_print "  ███████║███████╗██████╔╝"
ui_print "  ██╔══██║╚════██║██╔══██╗"
ui_print "  ██║      ██║███████║██████╔╝"
ui_print "  ╚═╝      ╚═╝╚══════╝╚═════╝ "
ui_print " "
  ui_print "${SEPARATOR}"
}

asb_normalize_module_layout() {
  # Kill a stray $MODPATH/system/system before anything else.
  #
  # A build of the volume-curve code prefixed "system" onto a live path that already began with
  # /system, producing system/system/vendor/odm/etc/audio/...
  # The mount layer then tries to place that at /system/system, which does not exist, and the
  # device bootloops.
  #
  # The source of it is fixed, but a device already carrying one cannot boot to install the fix
  # - the user disables the module in recovery, boots, and installs over it.
  if [ -d "$MODPATH/system/system" ]; then
    rm -rf "$MODPATH/system/system" 2>/dev/null
    ui_print "      ! ${ASB_L_FIX_SYSSYS:-removed a stray system/system overlay path from an earlier build}"
  fi
  for _mroot in /data/adb/modules/AutoSystemBoost /data/adb/modules_update/AutoSystemBoost; do
    [ -d "$_mroot/system/system" ] && rm -rf "$_mroot/system/system" 2>/dev/null
  done

  # Remove ODM-side volume tables placed as overlays by the build that bootlooped.
  #
  # media_loudness briefly wrote default_volume_tables.xml into system/odm/etc/audio and
  # system/vendor/odm/etc/audio as magic-mount overlays.
  # Every other /odm audio file in this module goes through the runtime bind precisely because
  # /odm must not be overlaid here, and these two did not - the device stopped booting the
  # moment the tweak was set to anything but stock.
  for _mroot in "$MODPATH" /data/adb/modules/AutoSystemBoost /data/adb/modules_update/AutoSystemBoost; do
    [ -d "$_mroot" ] || continue
    rm -f "$_mroot/system/odm/etc/audio/default_volume_tables.xml" \
          "$_mroot/system/vendor/odm/etc/audio/default_volume_tables.xml" 2>/dev/null
  done

  for _part in vendor odm product system_ext my_product mi_ext; do
    _root="$MODPATH/$_part"
    [ -e "$_root" ] || continue
    if [ -L "$_root" ]; then continue; fi
    [ -d "$_root" ] || continue

    for _f in $(cd "$_root" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _target="$MODPATH/system/$_part/$_f"
      if [ ! -f "$_target" ]; then
        mkdir -p "$(dirname "$_target")" 2>/dev/null
        cp -f "$_root/$_f" "$_target" 2>/dev/null || true
      fi
    done
    rm -rf "$_root" 2>/dev/null || true
  done

  if [ -f "$INFO" ]; then
    for _part in vendor odm product system_ext my_product mi_ext; do
      sed -i "\|^$MODPATH/$_part/|d" "$INFO" 2>/dev/null || true
    done
  fi

  for _part in vendor odm product system_ext my_product mi_ext; do
    [ -L "$MODPATH/$_part" ] && continue
    [ -d "$MODPATH/$_part" ] && rmdir "$MODPATH/$_part" 2>/dev/null || true
  done

}

asb_end_banner() {
  # A one-glance summary of what ended up enabled - the sections above show the work, this
  # shows the final category picture so the install closes like the action screen.
  # Sections that had no output at all, because nothing on their path prints during install -
  # vibration and background trimming are applied by the runtime scripts, and auto-battery by
  # the governor.
  _sg() {
    grep -E "^[[:space:]]*$1=" "$MODPATH/config/governor.conf" 2>/dev/null \
      | head -1 | sed 's/.*=//' | tr -d ' \r'
  }
  _hap_l="$(_sg haptic_strength)"
  case "$_hap_l" in
    ''|-1|auto|stock) : ;;
    *)
      ui_print " "
      ui_print "  📳  ${ASB_SEC_HAPTICS:-VIBRATION}"
      if [ "$_hap_l" = "0" ]; then
        ui_print "      + ${ASB_L_TW_VIB_OFF:-Vibration: off}"
      else
        ui_print "      + $(printf "${ASB_L_VIB_SET:-strength %s/10 on the OEM scale, applied immediately}" "$_hap_l")"
      fi
      case "$(_sg haptic_touch_strength)" in
        ''|-1|auto) : ;;
        *) ui_print "      + $(printf "${ASB_L_VIB_TOUCH:-touch feedback %s/10, set separately}" "$(_sg haptic_touch_strength)")" ;;
      esac ;;
  esac

  _bat_any=0
  case "$(_sg auto_battery_enable)" in 1) _bat_any=1 ;; esac
  case "$(_sg charge_aware_enable)" in 1) _bat_any=1 ;; esac
  case "$(_sg cool_gaming)" in 1) _bat_any=1 ;; esac
  if [ "$_bat_any" = "1" ]; then
    ui_print " "
    ui_print "  🔋  ${ASB_SEC_BATTERY:-BATTERY}"
    case "$(_sg auto_battery_enable)" in
      1) ui_print "      + ${ASB_L_BAT_AUTO:-switches to Battery when low, and back when charged}" ;;
    esac
    case "$(_sg charge_aware_enable)" in
      1) ui_print "      + ${ASB_L_BAT_CHARGE:-more headroom while charging and cool, less as it warms}" ;;
    esac
    case "$(_sg cool_gaming)" in
      1) ui_print "      + ${ASB_L_BAT_COOL:-games lean thermal earlier, for a cooler phone}" ;;
    esac
  fi

  case "$(_sg BG_TRIM_LEVEL)" in
    ''|off) : ;;
    *)
      ui_print " "
      ui_print "  🧠  ${ASB_SEC_MEMORY:-MEMORY}"
      ui_print "      + $(printf "${ASB_L_MEM_TRIM:-background trimming: %s}" "$(_sg BG_TRIM_LEVEL)")" ;;
  esac


  # Categories last, not first.
  #
  # The per-topic sections above (display, vibration, battery, memory) each describe something
  # that was actually done, and they read as a continuation of the install log right above
  # them.
  _en=""; _en_n=0; _en_line=""
  for _c in CPU VM AUDIO BT NFC CAMERA MEDIA NET WIFI GPS KERNEL LOG LPM \
            RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY; do
    eval "_cv=\"\$ASB_${_c}\""
    [ "$_cv" = "true" ] || continue
    _en_line="${_en_line}${_en_line:+ · }${_c}"
    _en_n=$((_en_n + 1))
    if [ "$_en_n" -ge 5 ]; then
      _en="${_en}${_en:+
}      ${_en_line}"; _en_line=""; _en_n=0
    fi
  done
  [ -n "$_en_line" ] && _en="${_en}${_en:+
}      ${_en_line}"
  if [ -n "$_en" ]; then
    ui_print " "
    ui_print "  📋  ${ASB_SEC_CATEGORIES:-ENABLED CATEGORIES}"
    printf '%s\n' "$_en" | while IFS= read -r _l; do ui_print "$_l"; done
  fi
  # Scroll the detail off screen, leaving the summary alone at the end.
  #
  # The installer view does not scroll back on most managers, so whatever sits at the
  # bottom when it finishes is what the user reads. The per-section detail - WI-FI,
  # BATTERY, MEMORY, PREPARED COMPONENTS - is useful while it streams past and noise once
  # the summary is there to replace it.
  #
  # 60 lines. The tail after this gap - summary, banner, the manager's own output - is
  # 17 lines, so a window taller than 77 lines would still show BATTERY and MEMORY at 26.
  # A tablet or a landscape phone is easily that tall, and the report was still visible
  # there.
  #
  # Sizing this by counting is the wrong instinct anyway: there is no height to count
  # against, and a blank line costs nothing. Enough to clear any plausible window beats
  # exactly enough for the one that was measured.
  #
  # It used to sit ABOVE the component list, which put the hole in the middle of the
  # report instead of at its end.
  _i=0
  while [ "$_i" -lt 60 ]; do
    ui_print " "
    _i=$((_i + 1))
  done

  if [ -n "$INFO" ] && [ -f "$INFO" ] && [ ! -s "$INFO" ]; then
    rm -f "$INFO" 2>/dev/null || true
  fi
  [ -f "$NVBASE/modules/.$MODID-files" ] && [ ! -s "$NVBASE/modules/.$MODID-files" ] \
    && rm -f "$NVBASE/modules/.$MODID-files" 2>/dev/null || true

  ui_print " "
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "  ${ASB_DONE_TITLE:-✓ AutoSystemBoost installed}"
  ui_print "  ${ASB_DONE_MSG:-Reboot to activate.}"
  ui_print "${SEPARATOR}"
ui_print " "
ui_print "    █████╗    ███████╗██████╗ "
ui_print "  ██╔══██╗██╔════╝██╔══██╗"
ui_print "  ███████║███████╗██████╔╝"
ui_print "  ██╔══██║╚════██║██╔══██╗"
ui_print "  ██║      ██║███████║██████╔╝"
ui_print "  ╚═╝      ╚═╝╚══════╝╚═════╝ "
ui_print " "
}

asb_install_prebuilt_governor() {
  local abi src dst
  dst="$MODPATH/bin/asb"
  abi="arm64-v8a"
  src="$MODPATH/bin/$abi/asb"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst" 2>/dev/null || cat "$src" > "$dst"
    chmod 0755 "$dst" 2>/dev/null || true
    ASB_GOV_ABI="$abi"
    return 0
  fi
  return 1
}
sedi() {
  local expr="$1"; shift
  [ -z "$expr" ] && return 0
  local f tmp
  for f in "$@"; do
    [ -f "$f" ] || continue
    tmp="${f}.asbtmp.$$"
    sed "$expr" "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    cat "$tmp" > "$f" 2>/dev/null || true
    rm -f "$tmp"
  done
}
set +x
set +v

SEPARATOR="────────────────────────────────────────────"

LANG="$(settings get system system_locales 2>/dev/null)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop persist.sys.locale)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop ro.product.locale)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop ro.product.locale.language)-$(getprop ro.product.locale.region)"

# Pick the installer language from the device locale.
#
# The old form knew exactly one language plus English, so adding a third meant editing
# this branch. Now it maps a locale prefix to a file and falls back to English when the
# file is missing - which also means a half-finished translation can be dropped in and
# tested without touching install logic.
_asb_lang_file=""
case "$(printf '%s' "$LANG" | tr '[:upper:]' '[:lower:]')" in
  *ru-*|*ru_*|ru)  _asb_lang_file=russiantext.sh    ;;
  *uk-*|*uk_*|uk)  _asb_lang_file=ukrainiantext.sh  ;;
  *de-*|*de_*|de)  _asb_lang_file=germantext.sh     ;;
  *es-*|*es_*|es)  _asb_lang_file=spanishtext.sh    ;;
  *pt-*|*pt_*|pt)  _asb_lang_file=portuguesetext.sh ;;
  *tr-*|*tr_*|tr)  _asb_lang_file=turkishtext.sh    ;;
  *in-*|*id-*|*id_*|id) _asb_lang_file=indonesiantext.sh ;;
  *it-*|*it_*|it)  _asb_lang_file=italiantext.sh   ;;
  *fr-*|*fr_*|fr)  _asb_lang_file=frenchtext.sh    ;;
  *hy-*|*hy_*|hy)  _asb_lang_file=armeniantext.sh  ;;
  *ar-*|*ar_*|ar)  _asb_lang_file=arabictext.sh    ;;
  # zh covers Simplified; zh-TW/zh-HK fall through to English rather than being shown
  # Simplified text, which is a different language rather than a dialect of the same one.
  zh-cn*|zh_cn*|*zh-hans*|zh) _asb_lang_file=chinesetext.sh ;;
esac
# English is loaded first in every case: a translation that covers only part of the keys
# then overrides what it has, and anything it misses stays readable instead of blank.
#
# Both sources are guarded, and English is no exception.
#
# This ran as an unconditional `. "$MODPATH/common/englishtext.sh"` and aborted the
# whole install with "can't open ... No such file or directory" when the file was not
# there yet. customize.sh sets SKIPUNZIP=1 and unpacks by hand, so at this point in the
# script MODPATH/common may not be populated - the old code happened to work because
# nothing was sourced this early. A missing translation must degrade to untranslated
# text, never to a failed install: the strings are labels, and no label is worth
# bricking an installation over.
#
# TMPDIR is checked first: customize.sh extracts there, and on the path where common/
# has not reached MODPATH yet that is where the file actually is.
for _asb_lang_dir in "$TMPDIR" "$MODPATH/common" "$TMPDIR/common"; do
  [ -n "$_asb_lang_dir" ] || continue
  if [ -f "$_asb_lang_dir/englishtext.sh" ]; then
    . "$_asb_lang_dir/englishtext.sh"
    [ -n "$_asb_lang_file" ] && [ -f "$_asb_lang_dir/$_asb_lang_file" ] \
      && . "$_asb_lang_dir/$_asb_lang_file"
    break
  fi
done

ASB_SED_INPLACE_MODE=''
_asb_sed_do() {
  local mode="$1"; shift
  if [ "$mode" = "gnu" ]; then
    asb_sed "$@"
  else
    asb_sed "" "$@"
  fi
}
asb_sed() {
  if [ -z "$ASB_SED_INPLACE_MODE" ]; then
    local td="${TMPDIR:-/dev/tmp}"
    [ -d "$td" ] || mkdir -p "$td" 2>/dev/null
    local t="$td/.asb_sedtest.$$"
    echo x > "$t" 2>/dev/null
    if _asb_sed_do gnu 's/x/x/' "$t" >/dev/null 2>&1; then
      ASB_SED_INPLACE_MODE='gnu'
    elif _asb_sed_do bsd 's/x/x/' "$t" >/dev/null 2>&1; then
      ASB_SED_INPLACE_MODE='bsd'
    else
      ASB_SED_INPLACE_MODE='none'
    fi
    rm -f "$t" 2>/dev/null
  fi
  if [ "$ASB_SED_INPLACE_MODE" = 'gnu' ]; then
    _asb_sed_do gnu "$@"
  elif [ "$ASB_SED_INPLACE_MODE" = 'bsd' ]; then
    _asb_sed_do bsd "$@"
  else
    sed "$@"
  fi
}

map_files() {
  local module="$1"
  local dir="$2"
  [ -d "$module/$dir" ] || return 0
  find "$module/$dir" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r abs_path; do
    local rel="${abs_path#$module/}"
    local target="/$rel"
    if [ -e "$target" ]; then
      mount --bind "$abs_path" "$target" 2>/dev/null
    fi
  done
}

asb_has_xmlstarlet() { command -v xmlstarlet >/dev/null 2>&1; }
asb_poll_key() {
  local ev
  exec 7>&2
  exec 2>/dev/null
  ev="$(timeout 0.01 getevent -lqc 1)"
  exec 2>&7
  exec 7>&-

  case "$ev" in
    *KEY_VOLUMEUP*DOWN*)   echo "up" ;;
    *KEY_VOLUMEDOWN*DOWN*) echo "down" ;;
    *) echo "none" ;;
  esac
}

asb_wait_key_timed() {
  local timeout_sec="$1"
  local start now elapsed k
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      echo "none"
      return 0
    fi
    k="$(asb_poll_key)"
    if [ "$k" != "none" ]; then
      echo "$k"
      return 0
    fi
  done
}

asb_show_menu_timed() {
  local timeout_sec="$1"; shift
  local selected=1
  local total=$#
  local start now elapsed current
  start=$(date +%s)

  while true; do
    eval "current=\${$selected}"
    ui_print "➔ $current"
    ui_print " "

    while true; do
      now=$(date +%s)
      elapsed=$((now - start))
      if [ "$elapsed" -ge "$timeout_sec" ]; then
        return 0
      fi

      case "$(asb_poll_key)" in
        up)
          selected=$((selected % total + 1))
          break
          ;;
        down)
          ui_print "[*] Выбрано: $current"
          return "$selected"
          ;;
        *)
          ;;
      esac
    done
  done
}

asb_abort_timeout() {
  ui_print " "
  ui_print "$SEPARATOR"
  ui_print "$ASB_TIMEOUT"
  ui_print "$SEPARATOR"
  abort
}

asb_choose_cat() {
  local cat="$1" title="$2"
  ui_print " "
  ui_print "$SEPARATOR"
  ui_print "$title"
  ui_print " "
  ui_print "$ASB_HINT"
  ui_print " "

  local k
  k="$(asb_wait_key_timed 10)"
  case "$k" in
    up)   eval "ASB_${cat}=true" ;;
    down) eval "ASB_${cat}=false" ;;
    *)    asb_abort_timeout ;;
  esac
}

asb_drop_block_if_off() {
  local cat="$1" file="$2"
  eval "local on=\${ASB_${cat}}"
  [ "$on" = "true" ] && return 0
  [ -f "$file" ] || return 0
  sedi "/^# *ASB:${cat}:BEGIN\$/,/^# *ASB:${cat}:END\$/d" "$file" 2>/dev/null || true
}

asb_prop_first() {
  local v
  for k in "$@"; do
    v="$(getprop "$k" 2>/dev/null)"
    [ -n "$v" ] && [ "$v" != "null" ] && { echo "$v"; return 0; }
  done
  echo ""
}

asb_prop_file_first() {
  local _key _v _f
  for _key in "$@"; do
    for _f in       "$ORIGDIR/system/build.prop" "$ORIGDIR/system/system/build.prop"       "$ORIGDIR/vendor/build.prop" "$ORIGDIR/odm/build.prop"       "$ORIGDIR/product/build.prop" "$ORIGDIR/system_ext/build.prop"       /system/build.prop /system/system/build.prop /vendor/build.prop /odm/build.prop /product/build.prop /system_ext/build.prop; do
      [ -f "$_f" ] || continue
      _v="$(sed -n "s/^${_key}=//p" "$_f" 2>/dev/null | head -n 1)"
      [ -n "$_v" ] && [ "$_v" != "null" ] && { echo "$_v"; return 0; }
    done
  done
  echo ""
}

asb_norm_l() { echo "$*" | tr '[:upper:]' '[:lower:]'; }

asb_detect_compat() {
  ASB_MODEL_RAW="$(asb_prop_file_first ro.product.model ro.product.vendor.model ro.product.system.model ro.product.odm.model ro.product.product.model ro.build.product ro.product.name ro.product.vendor.name)"
  [ -n "$ASB_MODEL_RAW" ] || ASB_MODEL_RAW="$(asb_prop_first ro.product.model ro.product.vendor.model ro.product.system.model ro.product.odm.model ro.product.product.model)"
  ASB_DEVICE_RAW="$(asb_prop_file_first ro.product.device ro.product.vendor.device ro.vendor.product.device ro.product.system.device ro.product.odm.device ro.product.product.device ro.build.product ro.vendor.product.name ro.product.name)"
  [ -n "$ASB_DEVICE_RAW" ] || ASB_DEVICE_RAW="$(asb_prop_first ro.product.device ro.product.vendor.device ro.vendor.product.device ro.product.system.device ro.product.odm.device ro.product.product.device ro.build.product)"
  ASB_MANUFACTURER_RAW="$(asb_prop_file_first ro.product.manufacturer ro.product.vendor.manufacturer ro.vendor.product.manufacturer ro.product.brand ro.product.vendor.brand ro.product.system.brand ro.product.odm.brand)"
  [ -n "$ASB_MANUFACTURER_RAW" ] || ASB_MANUFACTURER_RAW="$(asb_prop_first ro.product.manufacturer ro.product.vendor.manufacturer ro.vendor.product.manufacturer ro.product.brand ro.product.vendor.brand ro.product.system.brand)"
  ASB_PRJ_RAW="$(asb_prop_file_first ro.boot.prjname ro.boot.project)"
  [ -n "$ASB_PRJ_RAW" ] || ASB_PRJ_RAW="$(asb_prop_first ro.boot.prjname ro.boot.project)"
  ASB_FP_RAW="$(asb_prop_file_first ro.build.fingerprint ro.vendor.build.fingerprint ro.system.build.fingerprint ro.bootimage.build.fingerprint)"
  [ -n "$ASB_FP_RAW" ] || ASB_FP_RAW="$(asb_prop_first ro.build.fingerprint ro.vendor.build.fingerprint ro.system.build.fingerprint)"
  ASB_MODEL_L="$(asb_norm_l "$ASB_MODEL_RAW")"
  ASB_DEVICE_L="$(asb_norm_l "$ASB_DEVICE_RAW")"
  ASB_MANUFACTURER_L="$(asb_norm_l "$ASB_MANUFACTURER_RAW")"
  ASB_PRJ_L="$(asb_norm_l "$ASB_PRJ_RAW")"
  ASB_FP_L="$(asb_norm_l "$ASB_FP_RAW")"

  ASB_IS_ONEPLUS=false
  ASB_IS_OP15=false
  ASB_IS_OP13=false
  ASB_IS_OP12=false

  echo "$ASB_MANUFACTURER_L $ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_ONEPLUS=true

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 15"*|*"oneplus15"*|*"op15"*|*"cph274"*|*"cph275"*|*"op611fl1"*|*"plk110"*|*"pjz110"*|*"pkz110"*)
      ASB_IS_OP15=true ;;
  esac
  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 13"*|*"oneplus13"*|*"op13"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
      ASB_IS_OP13=true ;;
  esac
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8750"*|*"sun"*)
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"ktm"*|*"plq110"*|*"op6113"*|*"ace 6"*|*"ace6"*)
            ui_print "[*] OnePlus Ace 6 (ktm) on the shared SM8750/sun firmware — generic-safe tuning (no OP13 overlay; its live audio/media sit on /odm and are handled by runtime binds)" ;;
          *"sun"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
            echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP13=true ;;
          *)
            ui_print "[*] SM8750 device, non-OP13 codename — generic-safe tuning (no OP13 overlay, boots on any SM8750 sibling)" ;;
        esac ;;
    esac
  fi

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 12"*|*"oneplus12"*|*"op12"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*)
      ASB_IS_OP12=true ;;
  esac
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ] && [ "$ASB_IS_OP12" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8650"*|*"pineapple"*)
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"pineapple"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*|*"ossi"*|*"22877"*)
            echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP12=true ;;
          *)
            ui_print "[*] SM8650 device, non-OP12 codename — generic-safe tuning (no OP12 overlay, boots on any SM8650 sibling)" ;;
        esac ;;
    esac
  fi

  echo "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(^|[[:space:]/._-])(cph27[45][0-9a-z]*|op611fl1|op611|plk110|pjz110|pkz110|oplus/cph27[45]|oneplus/cph27[45])([[:space:]/._-]|$)' && ASB_IS_OP15=true
  echo "$ASB_PRJ_L" | grep -Eqi '^(24831|24833|24863)$' && ASB_IS_OP15=true

  if [ "$ASB_IS_OP15" != "true" ] && [ -r /proc/cmdline ]; then
    _cmdline_prj="$(cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -i 'prjname=' | cut -d= -f2 | head -1)"
    echo "$_cmdline_prj" | grep -Eqi '^(24831|24833|24863)$' && ASB_IS_OP15=true
    _cmdline_model="$(cat /proc/cmdline 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    echo "$_cmdline_model" | grep -Eqi '(cph274|cph275|op611fl1|plk110|pjz110|pkz110)' && ASB_IS_OP15=true
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    _dt_compat=""
    for _dt_f in /proc/device-tree/compatible \
                 /proc/device-tree/chosen/prj_name \
                 /proc/device-tree/chosen/prjname \
                 /sys/firmware/devicetree/base/compatible; do
      [ -r "$_dt_f" ] || continue
      _dt_val="$(cat "$_dt_f" 2>/dev/null | tr '\0' '\n' | tr '[:upper:]' '[:lower:]')"
      [ -n "$_dt_val" ] && _dt_compat="$_dt_compat $_dt_val"
    done
    echo "$_dt_compat" | grep -Eqi '(cph274|cph275|op611|plk110|pjz110|pkz110|24831|24833|24863|oneplus15|oneplus-15)' && ASB_IS_OP15=true
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    if [ -d /sys/devices/system/cpu/cpufreq/policy6 ]; then
      _max6="$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)"
      if echo "$_max6" | grep -q '^4[56][0-9][0-9][0-9][0-9][0-9]$'; then
        _sm8850_foreign=0
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"macan"*|*"fairlady"*|*"15r"*|*"ace 6t"*|*"ace6t"*|*"15t"*|*"plr110"*|*"plz110"*|*"pmb110"*|*"cph276"*|*"cph277"*)
            _sm8850_foreign=1 ;;
        esac
        if [ "$_sm8850_foreign" != "1" ]; then
          echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP15=true
        else
          ui_print "[*] SM8850 device, non-OP15 codename — generic-safe tuning (no OP15 overlay)"
        fi
      fi
    fi
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    ui_print "[*] Detect debug: manufacturer=$ASB_MANUFACTURER_RAW | model=$ASB_MODEL_RAW | device=$ASB_DEVICE_RAW | prj=$ASB_PRJ_RAW"
  fi
  [ "$ASB_IS_OP15" = "true" ] && ASB_IS_OP13=false && ASB_IS_OP12=false
  [ "$ASB_IS_OP13" = "true" ] && ASB_IS_OP12=false
  # Digital-gain ceiling for asb_patch_one_mixer. SM8650/pineapple (cliffs) WCD/WSA
  # "Digital Volume" controls top out at 0 dB = 84; writing 88 clips and breaks the
  # speaker volume path there. Every other SoC keeps the original +boost to 88.
  _asb_dv_max=88
  case "$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")" in
    *"sm8650"*|*"pineapple"*) _asb_dv_max=84 ;;
  esac
  asb_identify_device
}

# Resolve a human-readable device name for the install log so users of OP13 / OP12 /
# Ace 6 / Ace 5 / etc. no longer see "OnePlus (generic)" or bare "OP15" wording.
asb_identify_device() {
  # 1) OnePlus/OPPO expose the retail marketing name directly — no lookup needed.
  ASB_DEVICE_NAME="$(asb_prop_first \
      ro.vendor.oplus.market.enname ro.oplus.market.enname \
      ro.vendor.oplus.market.name ro.oplus.market.name \
      ro.config.marketing_name ro.product.marketname)"
  ASB_DEVICE_NAME="$(printf '%s' "$ASB_DEVICE_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # 2) Known-model fallback keyed off model / device / project / fingerprint.
  if [ -z "$ASB_DEVICE_NAME" ]; then
    case " $ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L " in
      *" ktm "*|*plq110*|*op6113*|*24851*|*ossi*)   ASB_DEVICE_NAME="OnePlus Ace 6" ;;
      *cph2691*|*op5d3b*)                            ASB_DEVICE_NAME="OnePlus Ace 5" ;;
      *canoe*|*pjz110*|*cph2747*|*cph2749*)          ASB_DEVICE_NAME="OnePlus 15" ;;
      *cph2649*|*cph2653*|*cph2655*|*pjz120*|*sun*)  ASB_DEVICE_NAME="OnePlus 13" ;;
      *cph2661*|*cph2663*|*aston*)                   ASB_DEVICE_NAME="OnePlus 13R" ;;
      *cph2573*|*cph2583*|*cph2581*|*pjd110*)        ASB_DEVICE_NAME="OnePlus 12" ;;
      *cph2609*|*cph2611*|*cph2607*|*waffle*)        ASB_DEVICE_NAME="OnePlus 12R" ;;
    esac
  fi
  # 3) Generic OnePlus by SoC family, then bare model code, then a safe default.
  if [ -z "$ASB_DEVICE_NAME" ]; then
    case "$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")" in
      *sm8850*|*canoe*)     ASB_DEVICE_NAME="OnePlus (SM8850)" ;;
      *sm8750*|*sun*)       ASB_DEVICE_NAME="OnePlus (SM8750)" ;;
      *sm8650*|*pineapple*) ASB_DEVICE_NAME="OnePlus (SM8650)" ;;
    esac
  fi
  [ -z "$ASB_DEVICE_NAME" ] && [ -n "$ASB_MODEL_RAW" ] && ASB_DEVICE_NAME="$ASB_MANUFACTURER_RAW $ASB_MODEL_RAW"
  [ -z "$ASB_DEVICE_NAME" ] && ASB_DEVICE_NAME="OnePlus device"
  ui_print "[*] Device identified: ${ASB_DEVICE_NAME}"
}

ASB_IS_APATCH=false
asb_detect_manager() {
  if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ] || [ -f /data/adb/apd ]; then
    if [ "${KSU:-}" = "true" ] || [ -f /data/adb/ksud ]; then
      [ "${APATCH:-}" = "true" ] && ASB_IS_APATCH=true || ASB_IS_APATCH=false
    else
      ASB_IS_APATCH=true
    fi
  fi
  if [ "$ASB_IS_APATCH" = "true" ]; then
    ui_print "[*] Root manager: APatch (OP12 camera engine exclusion will apply)"
  fi
}

asb_apply_device_overlay() {
  _ov="$1"; _label="$2"
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] $_label detected"
  ui_print "${SEPARATOR}"

  rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/audio" 2>/dev/null || true
  # Safety sweep: a previous build (before the configs-only clone) could have staged multi-MB
  # ML models and calibration blobs into the audio tree, ballooning the module to ~32MB.
  find "$MODPATH/system" -type f \( -name '*.mnn' -o -name '*.onnx' -o -name '*.bin' \
       -o -name '*.dlc' -o -name '*.tflite' \) -delete 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true   # OP12/OP13: strip OP15 multicam set from /odm copy too (ChiMcx crash fix)
  rm -f  "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/izat.conf" 2>/dev/null || true

  if [ -d "$MODPATH/$_ov" ]; then
    _odm_dups() {
      case "$1" in
        vendor/odm/*)
          _sub="${1#vendor/odm/}"
          echo "system/vendor/odm/$_sub"
          ;;
        vendor/*)
          echo "system/$1"
          ;;
        *)
          echo "system/$1"
          ;;
      esac
    }
    if [ "$ASB_GPS" = "true" ]; then
      for _f in vendor/etc/gps.conf vendor/odm/etc/gps.conf \
                vendor/etc/izat.conf vendor/odm/etc/izat.conf; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "      + GPS: $_dst"
          done
        fi
      done
    fi
    if [ "$ASB_CAMERA" = "true" ]; then
      for _cf_rel in vendor/odm/etc/camera/conf_tuning_params.json \
                     vendor/odm/etc/camera/config/video_beauty_default_config; do
        _cf_base="${_cf_rel#vendor/odm/etc/camera/}"
        for _live in "/odm/etc/camera/$_cf_base" \
                     "/vendor/odm/etc/camera/$_cf_base" \
                     "/system/vendor/odm/etc/camera/$_cf_base"; do
          if [ -f "$_live" ] && [ ! -f "$MODPATH/$_ov/$_cf_rel" ]; then
            mkdir -p "$MODPATH/$_ov/$(dirname "$_cf_rel")" 2>/dev/null
            cp -f "$_live" "$MODPATH/$_ov/$_cf_rel" 2>/dev/null \
              && ui_print "      + $(printf "${ASB_L_CAM_PREPARED:-Camera: %s prepared from device stock}" "$_cf_base")"
            break
          fi
        done
      done
      for _f in vendor/etc/media_profiles.xml \
                vendor/odm/etc/camera/media_profiles.xml \
                vendor/odm/etc/camera/conf_tuning_params.json \
                vendor/odm/etc/camera/config/video_beauty_default_config; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "      + Camera/media: $_dst"
          done
        fi
      done
      _ctf="$MODPATH/system/vendor/odm/etc/camera/conf_tuning_params.json"
      _skip_cam_engine=false
      [ "$ASB_IS_OP12" = "true" ] && [ "$ASB_IS_APATCH" = "true" ] && _skip_cam_engine=true
      if [ "$_skip_cam_engine" != "true" ] && [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
        . "$MODPATH/runtime/asb_tweaks.sh"
        asb_tw_save_base "$_ctf" force
        asb_apply_dynamic_tweaks "$MODPATH"
        asb_camera_aggr_flag
        # Grading is NOT done here any more. asb_clone_device_camera_tone owns these
        # files: it clones them from the live partition into both destinations and runs
        # after this branch, so anything graded here was overwritten a moment later.
        if [ "$_ASB_CAMERA_AGGR" = "1" ] && [ -f "$_ctf" ]; then
          if [ "$_ASB_CAMERA_INJECT" = "1" ]; then
            ui_print "      + ${ASB_D_CAM_AGGR_INJ:-Camera aggressive tone applied (incl. injected keys)}"
          else
            ui_print "      + ${ASB_D_CAM_AGGR_EXIST:-Camera aggressive tone applied (existing keys only)}"
          fi
        fi
      elif [ "$_skip_cam_engine" = "true" ]; then
        ui_print "      + OP12/APatch: ${ASB_D_CAM_STOCK:-camera kept stock (tweak engine skipped)}"
      fi
    fi
  fi

  rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true
  ui_print "      + ${ASB_D_OVERLAY:-overlay patched in place (EQ / volume / hi-res / codecs)}"
}

asb_perf_patch_configstore() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/\(Name="vendor.debug.enable.lm" Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="vendor.debug.enable.memperfd"[^V]*Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.enable.prekill"[^V]*Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="vendor.perf.topAppRenderThreadBoost.enable" Value="\)false/\1true/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.qape.boost_duration" Value="\)10"/\13"/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.qape.max_boost_count" Value="\)3"/\11"/g' "$_f"
  sedi 's/\(Name="vendor.perf.fps_switch_hyst_time_secs" Value="\)10"/\112"/g' "$_f"
  sedi 's/\(Name="ro.vendor.wlc.exit.timeout" Value="\)120000"/\130000"/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.active_reqs_max" Value="\)30"/\128"/g' "$_f"
}

asb_perf_patch_gameconfig() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([0-9][0-9]*[ 	][ 	]*[^ 	][^ 	]*[ 	][ 	]*\)48000\([ 	][ 	]*\)1150\([ 	][ 	]*\)1000/\144000\2900\3800/' "$_f"
}

asb_clamp_down_key() {
  _ck_f="$1"; _ck_k="$2"; _ck_ceil="$3"
  [ -f "$_ck_f" ] || return 0
  _ck_cur=$(grep -E "^${_ck_k}=" "$_ck_f" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  case "$_ck_cur" in
    ''|*[!0-9]*) return 0 ;;   # absent or non-numeric -> leave stock
  esac
  if [ "$_ck_cur" -gt "$_ck_ceil" ] 2>/dev/null; then
    sed -i "s/^${_ck_k}=.*/${_ck_k}=${_ck_ceil}/" "$_ck_f" 2>/dev/null || true
  fi
}

asb_patch_one_wcnss() {
  _f="$1"; [ -f "$_f" ] || return 0
  asb_clamp_down_key "$_f" gRuntimePMDelay 2000
  asb_clamp_down_key "$_f" gActiveMaxChannelTime 40
  asb_clamp_down_key "$_f" gBusBandwidthVeryHighThreshold 12000
}

asb_patch_wifi_inplace() {
  _label="$1"
  [ "$ASB_WIFI" = "true" ] || return 0

  _wifi_hit=0
  for _ws in /vendor/etc/wifi /odm/etc/wifi /odm/vendor/etc/wifi /vendor/odm/etc/wifi /system/vendor/etc/wifi; do
    [ -d "$_ws" ] || continue
    # Enumerate the WCNSS config files with BOUNDED SHELL GLOBS — top-level plus up to two
    # nested sku folders (e.g.
    # Globs only stat the paths they match — exactly the traversal the old `ls` guard did
    # (which never hung) — while still catching the nested-only layouts the old guard skipped.
    _dst_root="$MODPATH/system${_ws#/system}"
    for _wf in "$_ws"/WCNSS_qcom_cfg*.ini \
               "$_ws"/*/WCNSS_qcom_cfg*.ini \
               "$_ws"/*/*/WCNSS_qcom_cfg*.ini; do
      [ -f "$_wf" ] || continue
      _rel="${_wf#"$_ws"/}"
      _dst="$_dst_root/$_rel"
      mkdir -p "$(dirname "$_dst")" 2>/dev/null
      cp -f "$_wf" "$_dst" 2>/dev/null || continue
      asb_patch_one_wcnss "$_dst"
      _wifi_hit=1
    done
  done
  [ "$_wifi_hit" = "1" ] || { ui_print "      + ${ASB_D_WIFI_NONE:-no device WCNSS config found — Wi-Fi left stock}"; return 0; }
  ui_print "      + ${ASB_D_WIFI_OK:-WCNSS Wi-Fi config patched (device-native)}"
}

asb_patch_perf_inplace() {
  _label="$1"
  [ "$ASB_CPU" = "true" ] || { ui_print "[*] CPU/perf category off — skipping perf tuning"; return 0; }

  _perfsrc=""
  for _d in /vendor/etc/perf /odm/etc/perf /system/vendor/etc/perf /system_ext/etc/perf; do
    if [ -f "$_d/perfconfigstore.xml" ] || [ -f "$_d/qapegameconfig.txt" ]; then
      _perfsrc="$_d"; break
    fi
  done
  if [ -z "$_perfsrc" ]; then
    ui_print "[*] No stock perf dir found — skipping perf tuning"
    return 0
  fi

  _dst="$MODPATH/system/vendor/etc/perf"
  rm -rf "$_dst" 2>/dev/null || true
  mkdir -p "$_dst" 2>/dev/null

  for _pf in perfconfigstore.xml qapegameconfig.txt perfboostsconfig.xml; do
    if [ -f "$_perfsrc/$_pf" ]; then
      cp -f "$_perfsrc/$_pf" "$_dst/$_pf" 2>/dev/null || continue
      chmod 0644 "$_dst/$_pf" 2>/dev/null || true
    fi
  done

  asb_perf_patch_configstore "$_dst/perfconfigstore.xml"
  if [ -f "$_dst/qapegameconfig.txt" ]; then
    asb_perf_patch_gameconfig "$_dst/qapegameconfig.txt"
  fi
  if [ -f "$_dst/perfboostsconfig.xml" ]; then
    sedi 's/\(Id="0x000010A7"[^>]*Timeout="\)2000"/\11600"/g' "$_dst/perfboostsconfig.xml"
  fi
  _pf_n="$(find "$_dst" -type f 2>/dev/null | wc -l)"
  [ "${_pf_n:-0}" -gt 0 ] && ui_print "      + ${ASB_D_PERF:-perf configs tuned} (${_pf_n} file(s): ${ASB_D_PERF_TAIL:-boost timeouts, game config})"
}

asb_loc_patch_xtwifi() {
  _f="$1"; _model="$2"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*SIZE_BYTE_TOTAL_CACHE[[:space:]]*=[[:space:]]*\)5000000/\132000000/' "$_f"
  sedi 's/^\([[:space:]]*DEBUG_GLOBAL_LOG_LEVEL[[:space:]]*=[[:space:]]*\)2/\10/' "$_f"
  sedi "s/^\([[:space:]]*MODEL_ID_IN_REQUEST_TO_SERVER[[:space:]]*=[[:space:]]*\)\"UNKNOWN\"/\1\"$_model\"/" "$_f"
}
asb_loc_patch_lowi() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*LOWI_LOG_LEVEL[[:space:]]*=[[:space:]]*\)4/\10/' "$_f"
  sedi 's/^\([[:space:]]*LOWI_USE_LOWI_LP[[:space:]]*=[[:space:]]*\)0/\11/' "$_f"
}

asb_loc_patch_gps() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*DEBUG_LEVEL[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\10/'                 "$_f"
  sedi 's/^\([[:space:]]*INTERMEDIATE_POS[[:space:]]*=[[:space:]]*\)0/\11/'                       "$_f"
  sedi 's/^\([[:space:]]*AP_CLOCK_PPM[[:space:]]*=[[:space:]]*\)100/\150/'                        "$_f"
  sedi 's/^\([[:space:]]*AP_TIMESTAMP_UNCERTAINTY[[:space:]]*=[[:space:]]*\)10/\13/'              "$_f"
  sedi 's/^\([[:space:]]*BUFFER_DIAG_LOGGING[[:space:]]*=[[:space:]]*\)1/\10/'                    "$_f"
  sedi 's/^\([[:space:]]*LOC_DIAGIFACE_ENABLED[[:space:]]*=[[:space:]]*\)1/\10/'                  "$_f"
  sedi 's/^\([[:space:]]*LPP_PROFILE[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\115/'                 "$_f"
  sedi 's/^\([[:space:]]*SUPL_VER[[:space:]]*=[[:space:]]*\)0x10000/\10x20000/'                   "$_f"
  sedi 's/^\([[:space:]]*NMEA_REPORT_RATE[[:space:]]*=[[:space:]]*\)NHZ/\11HZ/'                   "$_f"
}

asb_loc_patch_izat() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*IZAT_DEBUG_LEVEL[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\10/'             "$_f"
}

asb_media_lift_file() {
  awk -v is_canoe="$2" '
    function lift_sized(b, w, h,   t) {
      t = b
      if (w == 1920 && h == 1080) t = (is_canoe ? 40000000 : 37300000)
      else if (w == 3840 && h == 2160) t = 100000000
      else if (w == 1280 && h == 720)  t = (b < 20000000 ? 20000000 : b)
      if (t < b) t = b
      return t
    }
    # Buffer a whole <Video ...> element (its attributes are split across lines in the stock
    # media_profiles), then lift bitRate by the width/height found ANYWHERE in that element.
    # The old per-line matcher required width, height and bitRate on the same line, which never
    # happens in the OP15 stock format - so 1080p fell through to the unsized bracket bump and
    # landed at 37.3M instead of 40M (a diag FAIL).
    {
      line = $0
      if (in_video) {
        vbuf = vbuf "\n" line
        if (line ~ /\/>/ || line ~ /<\/Video>/) {
          # element complete - lift it
          w = vbuf; h = vbuf
          if (match(vbuf, /width="[0-9]+"/))  { w = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", w); w = w + 0 } else w = 0
          if (match(vbuf, /height="[0-9]+"/)) { h = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", h); h = h + 0 } else h = 0
          if (w > 0 && h > 0 && match(vbuf, /bitRate="[0-9]+"/)) {
            b = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", b); b = b + 0
            nb = lift_sized(b, w, h)
            sub(/bitRate="[0-9]+"/, "bitRate=\"" nb "\"", vbuf)
          }
          printf "%s\n", vbuf
          in_video = 0; vbuf = ""
        }
        next
      }
      if (line ~ /<Video([ \t]|$)/ && line !~ /\/>/) {
        in_video = 1; vbuf = line; next
      }
      # single-line <Video .../> (rare) - handle inline
      if (line ~ /<Video/ && match(line, /width="[0-9]+"/) && match(line, /height="[0-9]+"/)) {
        w = line; sub(/.*width="/, "", w); sub(/".*/, "", w); w = w + 0
        h = line; sub(/.*height="/, "", h); sub(/".*/, "", h); h = h + 0
        if (match(line, /bitRate="[0-9]+"/)) {
          b = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", b); b = b + 0
          nb = lift_sized(b, w, h)
          sub(/bitRate="[0-9]+"/, "bitRate=\"" nb "\"", line)
        }
        print line; next
      }
      print line
    }
    END { if (in_video && vbuf != "") printf "%s\n", vbuf }' "$1" > "$1.asbtmp" 2>/dev/null \
      && mv -f "$1.asbtmp" "$1" 2>/dev/null
}

# Format-agnostic hi-res sampling-rate lifter for audio_policy_configuration.xml.
# Idempotent: never appends a rate that is already present.
asb_lift_hires_policy() {
  [ -f "$1" ] || return 0
  awk '
  {
    line=$0; out=""
    while (match(line, /samplingRates="[^"]*"/)) {
      pre=substr(line,1,RSTART-1); m=substr(line,RSTART,RLENGTH)
      val=m; sub(/^samplingRates="/,"",val); sub(/"$/,"",val)
      sep=(val ~ /,/)?",":" "
      if (val ~ /(^|[, ])96000([, ]|$)/ && val !~ /(^|[, ])384000([, ]|$)/) {
        nn=split("176400 192000 352800 384000",hr," ")
        for(i=1;i<=nn;i++){ if(val !~ ("(^|[, ])" hr[i] "([, ]|$)")) val=val sep hr[i] }
        m="samplingRates=\"" val "\""
      }
      out=out pre m; line=substr(line,RSTART+RLENGTH)
    }
    print out line
  }' "$1" > "$1.hrtmp" 2>/dev/null \
    && mv -f "$1.hrtmp" "$1" 2>/dev/null
}

asb_patch_media_profiles_inplace() {
  [ "$ASB_MEDIA" = "true" ] || { ui_print "[*] Media category off - skipping media_profiles lift"; return 0; }
  _mpp_done=0
  _ASB_MP_CANOE=0
  case "$(getprop ro.board.platform 2>/dev/null)$(getprop ro.product.device 2>/dev/null)" in
    *canoe*|*sm8850*|*SM8850*) _ASB_MP_CANOE=1 ;;
  esac
  [ "$ASB_IS_OP15" = "true" ] && _ASB_MP_CANOE=1
  _mp_roots="/vendor /system/vendor /system_ext /product"
  if [ "$ASB_IS_OP15" = "true" ] || [ "$ASB_IS_OP13" = "true" ]; then
    _mp_roots="$_mp_roots /odm /system/odm"
  fi
  for _mp_live in $(find $_mp_roots \
                      -type f -name 'media_profiles*.xml' 2>/dev/null \
                      | grep -vE '/vintf/|/manifest' | sort -u); do
    # Strip a leading /system before prefixing, or the two stack into
    # $MODPATH/system/system/...
    # - the mount layer then aims at /system/system, which does not exist, and the device
    # bootloops.
    _mp_rel="system${_mp_live#/system}"
    mkdir -p "$MODPATH/$(dirname "$_mp_rel")" 2>/dev/null
    cp -f "$_mp_live" "$MODPATH/$_mp_rel" 2>/dev/null || continue
    chmod 0644 "$MODPATH/$_mp_rel" 2>/dev/null
    asb_media_lift_file "$MODPATH/$_mp_rel" "$_ASB_MP_CANOE"
    _mpp_done=$((_mpp_done + 1))
  done
  [ "$_mpp_done" -gt 0 ] && ui_print "      + media_profiles: ${ASB_D_MEDIA_LIFT:-video bitrate lifted in} $_mpp_done ${ASB_D_MEDIA_TAIL:-device-native file(s)}"
  return 0
}

# Does this conf_tuning_params.json still carry the untouched BT.601 chroma matrix?
asb_cam_chroma_ok() {
  [ -f "$1" ] || return 0
  grep -m1 -o '"Main1x_Rgb2YuvParams"[^]]*]' "$1" 2>/dev/null \
    | grep -o -- '-0\.1687[0-9]*'
}

asb_clone_device_camera_tone() {
  [ "$ASB_CAMERA" = "true" ] || return 0
  # Needed here for asb_tw_base_path / asb_tw_save_base: this function is the first
  # thing that touches the camera files, and it must know where their baselines live
  # before it decides what to copy from. Sourcing is idempotent.
  if ! command -v asb_tw_base_path >/dev/null 2>&1; then
    [ -r "$MODPATH/runtime/asb_tweaks.sh" ] && . "$MODPATH/runtime/asb_tweaks.sh"
  fi
  for _ct_base in conf_tuning_params.json config/video_beauty_default_config; do
    for _ct_live in "/odm/etc/camera/$_ct_base" \
                    "/vendor/odm/etc/camera/$_ct_base" \
                    "/system/vendor/odm/etc/camera/$_ct_base"; do
      [ -f "$_ct_live" ] || continue
      if [ "$ASB_IS_OP15" = "true" ] || [ "$ASB_IS_OP13" = "true" ]; then
        _ct_dsts="system/vendor/odm/etc/camera/$_ct_base system/odm/etc/camera/$_ct_base"
      else
        _ct_dsts="system/vendor/odm/etc/camera/$_ct_base"
      fi
      for _ct_dst in $_ct_dsts; do
        if [ ! -f "$MODPATH/$_ct_dst" ]; then
          mkdir -p "$MODPATH/$(dirname "$_ct_dst")" 2>/dev/null
          # SOURCE OF TRUTH: the pristine baseline, not the live path.
          #
          # "$_ct_live" is a MOUNTED path.
          #
          # asb_tw_base_path gives the .asbbase for this destination.
          _ct_src="$_ct_live"
          # The chroma test below only means anything for conf_tuning_params.json: it looks for
          # the BT.601 matrix, which video_beauty_default_config simply does not contain.
          # Running it there made the grep come back empty, which the code reads as "graded" -
          # so a perfectly good video_beauty baseline would be deleted and the user shown a
          # corruption warning about a file that was never graded in the first place.
          _ct_checkable=0
          [ "$_ct_base" = "conf_tuning_params.json" ] && _ct_checkable=1
          if [ "$_ct_checkable" = "1" ] && command -v asb_tw_base_path >/dev/null 2>&1; then
            _ct_bp="$(asb_tw_base_path "$MODPATH/$_ct_dst" 2>/dev/null)"
            if [ -n "$_ct_bp" ] && [ -f "$_ct_bp" ]; then
              # Trust the baseline only if it still looks like stock.
              #
              # Devices updated from a build with the compounding bug carry a baseline that is
              # already graded, and using it as "the pristine original" is what made the damage
              # permanent across reinstalls.
              if [ -n "$(asb_cam_chroma_ok "$_ct_bp")" ]; then
                _ct_src="$_ct_bp"
              else
                rm -f "$_ct_bp" 2>/dev/null
                ASB_CAM_BASE_REPAIRED=1
              fi
            fi
          fi
          # The live path needs the same test, and this is the case that actually bit.
          #
          # Discarding a bad baseline falls back to "$_ct_live" on the assumption that a
          # missing baseline means a first install, where the live file really is stock.
          # That assumption breaks on an update installed over a RUNNING module: /odm/etc is
          # still the old module's overlay at that moment, so the fallback copied the previous
          # install's graded output - the exact file we had just refused to trust.
          #
          # So: if the live file fails the same test, do not clone anything. Leaving the
          # destination absent means the boot pass has no file to grade and the next
          # install - after the reboot the user is about to do anyway - finds real stock.
          if [ "$_ct_checkable" = "1" ] && [ "$_ct_src" = "$_ct_live" ]; then
            if [ -z "$(asb_cam_chroma_ok "$_ct_live")" ]; then
              ASB_CAM_LIVE_DIRTY=1
              continue
            fi
          fi
          cp -f "$_ct_src" "$MODPATH/$_ct_dst" 2>/dev/null \
            && chmod 0644 "$MODPATH/$_ct_dst" 2>/dev/null
          # Capture the baseline NOW, from the pristine copy, before anything grades it.
          command -v asb_tw_save_base >/dev/null 2>&1 && \
            asb_tw_save_base "$MODPATH/$_ct_dst" force
        fi
      done
      if [ "${ASB_CAM_LIVE_DIRTY:-0}" = "1" ] && [ "${_ASB_CAM_WARNED:-0}" != "1" ]; then
        # This one needs the user to act, so say so plainly rather than reassuring them.
        _ASB_CAM_WARNED=1
        ui_print "      ! ${ASB_L_CAM_LIVE_DIRTY1:-camera tuning on this device is still graded from an older build}"
        ui_print "        ${ASB_L_CAM_LIVE_DIRTY2:-camera left untouched. To restore it: remove ASB, reboot, install again}"
      elif [ "${ASB_CAM_BASE_REPAIRED:-0}" = "1" ] && [ "${_ASB_CAM_WARNED:-0}" != "1" ]; then
        _ASB_CAM_WARNED=1
        ui_print "      ! ${ASB_L_CAM_BASE_FIX1:-camera baseline from an older build was already graded - discarded}"
        ui_print "        ${ASB_L_CAM_BASE_FIX2:-it will be re-captured from stock after this reboot}"
      fi
      # Grade here, on every copy that was just made.
      #
      # This is where the camera files actually come from on an OP13/OP15 - cloned from the
      # live partition into TWO destinations, system/vendor/odm and system/odm.
      # Doing it at the point of creation means there is one place that owns these files
      # instead of two.
      if [ "$_ct_base" = "conf_tuning_params.json" ] \
         && [ -f "$MODPATH/runtime/asb_camera_grade.sh" ]; then
        asb_camera_aggr_flag
        # Independent sliders used to be inside the CAMERA_LEVEL > 0 gate, so a user could
        # save max Contrast/Grain/Portrait/Low-light values and still receive a stock file.
        # Resolve each once and build a grade whenever any one differs from its stock value.
        _cam_get() {
          for _cg in /data/adb/modules/AutoSystemBoost/config/governor.conf \
                     "$MODPATH/config/governor.conf"; do
            [ -f "$_cg" ] || continue
            _cv="$(grep -E "^[[:space:]]*$1=" "$_cg" 2>/dev/null | head -1 \
                   | sed 's/.*=//' | tr -d ' \r')"
            case "$_cv" in ''|*[!0-9]*) : ;; *) echo "$_cv"; return 0 ;; esac
          done
          echo ""
        }
        _asb_cam_grain="$(_cam_get CAMERA_GRAIN)";    [ -n "$_asb_cam_grain" ] || _asb_cam_grain=3
        _asb_cam_contrast="$(_cam_get CAMERA_CONTRAST)"; [ -n "$_asb_cam_contrast" ] || _asb_cam_contrast=3
        _asb_cam_portrait="$(_cam_get CAMERA_PORTRAIT)"; [ -n "$_asb_cam_portrait" ] || _asb_cam_portrait=0
        _asb_cam_lowlight="$(_cam_get CAMERA_LOWLIGHT)"; [ -n "$_asb_cam_lowlight" ] || _asb_cam_lowlight=0
        if [ "${_ASB_CAMERA_LEVEL:-0}" -gt 0 ] 2>/dev/null \
           || [ "$_asb_cam_grain" != 3 ] || [ "$_asb_cam_contrast" != 3 ] \
           || [ "$_asb_cam_portrait" != 0 ] || [ "$_asb_cam_lowlight" != 0 ]; then
          _ct_done=0
          for _ct_dst in $_ct_dsts; do
            [ -f "$MODPATH/$_ct_dst" ] || continue
            # Sweep markers whose destination no longer exists. Before the names were
            # normalised these piled up one per install; an old device carries a directory
            # of them, and they are not worth keeping - a marker for a path that is gone
            # guards nothing.
            for _gm in /data/adb/asb/grade_marks/*.mark; do
              [ -f "$_gm" ] || continue
              case "$_gm" in *.asbdes*|*.graded.mark|*modules_update*) rm -f "$_gm" 2>/dev/null ;; esac
            done
            MODDIR="$MODPATH" ASB_CAMERA_LEVEL_IN="$_ASB_CAMERA_LEVEL" \
              ASB_CAM_GRAIN_IN="$_asb_cam_grain" \
              ASB_CAM_CONTRAST_IN="$_asb_cam_contrast" \
              ASB_CAM_PORTRAIT_IN="$_asb_cam_portrait" \
              ASB_CAM_LOWLIGHT_IN="$_asb_cam_lowlight" \
              sh "$MODPATH/runtime/asb_camera_grade.sh" \
                 "$MODPATH/$_ct_dst" "$MODPATH/$_ct_dst.graded" >/dev/null 2>&1
            if [ -s "$MODPATH/$_ct_dst.graded" ]; then
              mv -f "$MODPATH/$_ct_dst.graded" "$MODPATH/$_ct_dst" 2>/dev/null
              chmod 0644 "$MODPATH/$_ct_dst" 2>/dev/null
              _ct_done=$((_ct_done + 1))
            else
              rm -f "$MODPATH/$_ct_dst.graded" 2>/dev/null
            fi
          done
          [ "$_ct_done" -gt 0 ] && ui_print "      + Camera tuning: level ${_ASB_CAMERA_LEVEL:-0} / independent controls applied to ${_ct_done} file(s)"
        fi
      fi
      case "$_ct_base" in
        conf_tuning_params.json)
          ui_print "      + ${ASB_L_CAM_TUNING:-Camera: image tuning ready (colour, detail, sharpening)}" ;;
        *video_beauty*)
          ui_print "      + ${ASB_L_CAM_BEAUTY:-Camera: retouch profile ready (per-app beauty settings)}" ;;
        *)
          ui_print "      + $(printf "${ASB_L_CAM_OTHER:-Camera: %s ready}" "$_ct_base")" ;;
      esac
      break
    done
  done
}

asb_patch_location_inplace() {
  _model="$1"
  [ "$ASB_GPS" = "true" ] || { ui_print "[*] GPS category off — skipping location tuning"; return 0; }

  rm -f "$MODPATH/system/vendor/etc/xtwifi.conf" \
        "$MODPATH/system/vendor/odm/etc/xtwifi.conf" \
        "$MODPATH/system/odm/etc/xtwifi.conf" \
        "$MODPATH/system/vendor/etc/lowi.conf" \
        "$MODPATH/system/odm/etc/lowi.conf" 2>/dev/null || true

  for _src in /vendor/etc/xtwifi.conf /odm/etc/xtwifi.conf /vendor/odm/etc/xtwifi.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_xtwifi "$MODPATH/$_rel" "$_model"
      }
    fi
  done
  for _src in /vendor/etc/lowi.conf /odm/etc/lowi.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_lowi "$MODPATH/$_rel"
      }
    fi
  done

  for _src in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_gps "$MODPATH/$_rel"
      }
    fi
  done
  _loc_izat=0
  for _src in /vendor/etc/izat.conf /odm/etc/izat.conf /vendor/odm/etc/izat.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_izat "$MODPATH/$_rel"
        _loc_izat=1
      }
    fi
  done
  ui_print "      + GPS/A-GPS tuned (gps.conf$([ "$_loc_izat" = "1" ] && echo " + izat.conf"))"
}

asb_clone_dir_from_live() {
  _src="$1"
  [ -d "$_src" ] || return 1
  _canon="$_src"
  case "$_canon" in
    /system/*) _canon="${_canon#/system}" ;;
  esac
  _dest="$MODPATH/system${_canon}"
  rm -rf "$_dest" 2>/dev/null
  mkdir -p "$_dest" 2>/dev/null
  # Copy ONLY the text config files ASB actually patches.
  # The audio dir also holds huge binary blobs - noise-suppression ML models
  # (dcunet_nbf.onnx.mnn ~3.5M, oprec_nn_ve.mnn ~1.5M) and mic/camera calibration (.bin,
  # several MB each) - which ASB never touches.
  _clone_n=0
  ( cd "$_src" && find . -maxdepth 6 -type f \
        \( -name '*.xml' -o -name '*.conf' -o -name '*.json' -o -name '*.txt' \
           -o -name '*.ini' -o -name '*.cfg' -o -name 'video_beauty_default_config' \) 2>/dev/null | while IFS= read -r _f; do
      _f="${_f#./}"
      mkdir -p "$_dest/$(dirname "$_f")" 2>/dev/null
      cp -f "$_src/$_f" "$_dest/$_f" 2>/dev/null || true
    done )
  # Prune any now-empty dirs the find above created nothing in.
  find "$_dest" -type d -empty -delete 2>/dev/null || true
  [ -d "$_dest" ] || return 1
  # Say what was mirrored, not where it came from.
  #
  # "vendor/etc/audio -> system/vendor/etc/audio (configs only)" is a line for whoever wrote
  # the installer.
  # Count the files and name the area instead; the paths are still in the log for anyone
  # debugging, one line above.
  _clone_cnt="$(find "$_dest" -type f 2>/dev/null | wc -l | tr -d ' ')"
  # Localised: the module ships English and Russian text files and the user picked one
  # at the top of the install. Hardcoding English here would have made this the only
  # untranslated part of the output.
  case "$_canon" in
    */audio*)
      # Audio is assembled from several valid vendor/ODM/system paths on modern OnePlus ROMs.
      # Report their combined result once from the Audio stage; three indistinguishable counters
      # made a successful merge look like an accidental repeated copy in the install log.
      if [ "${ASB_AUDIO_CLONE_DEFER:-0}" = "1" ]; then
        ASB_AUDIO_CLONE_TOTAL=$(( ${ASB_AUDIO_CLONE_TOTAL:-0} + _clone_cnt ))
        ASB_AUDIO_CLONE_PATHS=$(( ${ASB_AUDIO_CLONE_PATHS:-0} + 1 ))
        return 0
      fi
      _clone_fmt="${ASB_L_MIRROR_AUDIO:-mirrored %s audio settings file(s) so ASB can edit them safely}"
      ;;
    */camera*) _clone_fmt="${ASB_L_MIRROR_CAMERA:-mirrored %s camera settings file(s) so ASB can edit them safely}" ;;
    *)         _clone_fmt="${ASB_L_MIRROR_SYSTEM:-mirrored %s system settings file(s) so ASB can edit them safely}" ;;
  esac
  ui_print "      + $(printf "$_clone_fmt" "$_clone_cnt")"
  return 0
}

asb_clone_device_audio_wifi() {
  _label="$1"

  if [ "$ASB_AUDIO" = "true" ]; then
    ASB_AUDIO_CLONE_DEFER=1
    ASB_AUDIO_CLONE_TOTAL=0
    ASB_AUDIO_CLONE_PATHS=0
    for _af in mixer_paths.xml ftm_mixer_paths.xml resourcemanager.xml \
               audio_module_config_primary.xml; do
      rm -f "$MODPATH/system/vendor/etc/$_af" 2>/dev/null || true
      rm -f "$MODPATH/system/vendor/odm/etc/$_af" 2>/dev/null || true
    done
    _audio_done=0
    # Merge ALL audio dirs, do not stop at the first that exists.
    # Breaking after the first dir copied /vendor but never reached /odm, so mixer_paths was
    # never cloned and the whole aggressive/EQ/Class-H mixer tune silently did nothing (device
    # diag: 46% pass).
    for _asrc in /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
      if [ -d "$_asrc" ]; then
        asb_clone_dir_from_live "$_asrc" && _audio_done=1
      fi
    done
    if [ "${ASB_AUDIO_CLONE_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
      ui_print "      + $(printf "${ASB_L_MIRROR_AUDIO_TOTAL:-mirrored %s audio settings file(s) from %s device path(s) so ASB can edit them safely}" "${ASB_AUDIO_CLONE_TOTAL}" "${ASB_AUDIO_CLONE_PATHS}")"
    fi
    unset ASB_AUDIO_CLONE_DEFER ASB_AUDIO_CLONE_TOTAL ASB_AUDIO_CLONE_PATHS

    # If we still have no mixer_paths anywhere, look wider: some revisions keep it under
    # sku_* subdirs the loop above already covers, but a few stage it beside the codecs.
    if [ -z "$(find "$MODPATH/system/vendor/etc/audio" "$MODPATH/system/odm/etc/audio" \
                    -name 'mixer_paths*.xml' 2>/dev/null | head -1)" ]; then
      for _mxsrc in $(find /vendor /odm /system/vendor -maxdepth 4 -name 'mixer_paths*.xml' 2>/dev/null | head -8); do
        _mxrel="system${_mxsrc#/system}"
        case "$_mxsrc" in /system/*) _mxrel="system${_mxsrc#/system}" ;; *) _mxrel="system${_mxsrc}" ;; esac
        mkdir -p "$MODPATH/$(dirname "$_mxrel")" 2>/dev/null
        cp -f "$_mxsrc" "$MODPATH/$_mxrel" 2>/dev/null && { _audio_done=1; ui_print "      + recovered mixer: ${_mxsrc}"; }
      done
    fi
    [ "$_audio_done" = "1" ] || ui_print "      - no device audio dir found"
  fi

}

asb_patch_one_mixer() {
  _f="$1"; [ -f "$_f" ] || return 0
  # Digital-gain ceiling is device-gated.
  _dvmax="${_asb_dv_max:-88}"
  for _v in 80 81 82 83 84 85 86 87; do
    [ "$_v" -ge "$_dvmax" ] 2>/dev/null && continue
    sedi "s/\\(name=\"RX_RX[012] Digital Volume\" value=\"\\)${_v}\"/\\1${_dvmax}\"/g" "$_f"
    sedi "s/\\(name=\"WSA_RX[01] Digital Volume\" value=\"\\)${_v}\"/\\1${_dvmax}\"/g" "$_f"
  done
  sedi 's/\(name="IIR0 Enable Band[1-5]" value="\)1"/\10"/g' "$_f"
  sedi 's/\(name="HPH[LR]_RDAC Switch" value="\)0"/\11"/g' "$_f"
  # Promote the Class-H headphone modes to HIFI.
  for _hphm in CLS_H_ULP CLS_H_LOHIFI CLS_H_LP CLS_H_NORMAL; do
    sedi "s/\\(name=\"RX HPH Mode\" value=\"\\)${_hphm}\"/\\1CLS_H_HIFI\"/g" "$_f"
  done
}

asb_patch_audio_inplace_aggr_flag() {
  _ASB_AUDIO_AGGR="$(grep -E '^[[:space:]]*audio_dac_hifi=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # legacy fallback: AUDIO_AGGRESSIVE was the old name of the mixer/DAC half
  [ -n "$_ASB_AUDIO_AGGR" ] || _ASB_AUDIO_AGGR="$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_AUDIO_AGGR" ] || _ASB_AUDIO_AGGR=0
}

asb_camera_aggr_flag() {
  _ASB_CAMERA_LEVEL="$(grep -E '^[[:space:]]*CAMERA_LEVEL=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_ASB_CAMERA_LEVEL" in ''|*[!0-9]*) _ASB_CAMERA_LEVEL="" ;; esac
  _ASB_CAMERA_AGGR="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_CAMERA_AGGR" ] || _ASB_CAMERA_AGGR=0
  if [ -z "$_ASB_CAMERA_LEVEL" ]; then
    [ "$_ASB_CAMERA_AGGR" = "1" ] && _ASB_CAMERA_LEVEL=3 || _ASB_CAMERA_LEVEL=0
  fi
  [ "$_ASB_CAMERA_LEVEL" -gt 0 ] 2>/dev/null && _ASB_CAMERA_AGGR=1 || _ASB_CAMERA_AGGR=0
  _inj_raw="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE_INJECT=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_inj_raw" in
    aggressive|1) _ASB_CAMERA_INJECT=1 ;;
    *)            _ASB_CAMERA_INJECT=0 ;;
  esac
}

asb_guard_v4a_effects() {
  _v4a_ok=0
  for _sd in /odm/etc /vendor/etc /vendor/odm/etc /system/vendor/etc \
             /system/vendor/odm/etc /system/etc; do
    for _sf in "$_sd"/audio_effects.xml "$_sd"/audio_effects_config.xml; do
      if [ -f "$_sf" ] && grep -q 'v4a_re' "$_sf" 2>/dev/null; then
        _v4a_ok=1; break
      fi
    done
    [ "$_v4a_ok" = "1" ] && break
  done
  if [ "$_v4a_ok" = "0" ]; then
    for _sf in $(find /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio -maxdepth 4 \
                      -type f -name "audio_effects*.xml" 2>/dev/null); do
      if grep -q 'v4a_re' "$_sf" 2>/dev/null; then _v4a_ok=1; break; fi
    done
  fi

  if [ "$_v4a_ok" = "1" ]; then
    ui_print "[*] V4A kept — device stock already wires ViPER (libv4a_re.so present)"
    return 0
  fi

  _stripped=0
  for _ef in $(find "$MODPATH/system" -type f -name "audio_effects*.xml" 2>/dev/null); do
    if grep -q 'v4a_re' "$_ef" 2>/dev/null; then
      sedi 's#<effect name="v4a_standard_re"[^/]*/>##g' "$_ef"
      sedi 's#<library name="v4a_re"[^/]*/>##g' "$_ef"
      _stripped=$((_stripped + 1))
    fi
  done
  return 0
}

# Media loudness: reshape the audio-policy volume CURVES (index -> attenuation in millibels).
# Stock OxygenOS attenuates brutally across the usable range — media sits at -40 dB at 20% and
# -17 dB at 60% — which is why "one step too quiet, one step too loud" happens and why the
# phone feels short of volume.
#
# ONLY two curves are touched, chosen from the real stream->curve map:
# DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE -> MUSIC + ASSISTANT on speaker
# DEFAULT_MEDIA_VOLUME_CURVE -> MUSIC on headset / BT / earpiece Deliberately NOT touched:
# NON_MUTABLE_* (alarms), HEADSET/EXT_MEDIA curves (ringtone + notifications),
# SILENT/FULL_SCALE.
#
# The 100%/0 dB point is never raised above unity, so nothing can clip.
# They used to exist only here, which is why changing media_loudness after install did nothing
# no matter how many times the phone was rebooted.
if [ -r "$MODPATH/runtime/asb_volume_curves.sh" ]; then
  . "$MODPATH/runtime/asb_volume_curves.sh"
fi

# Media loudness needs to be patched from a PRISTINE stock copy, because scaling is not
# idempotent and the previous install's overlay may already be shadowing /vendor/etc.

# --- ASB DSP effect ----------------------------------------------------------- Installs
# libasbdsp.so into the /vendor overlay and registers it in the device's
# audio_effects_config.xml.
ASB_DSP_UUID="a5b10001-7e55-4c60-9f21-415342445350"
ASB_DSP_TYPE="fe3199be-aed0-413f-87bb-11260eb63cf1"

# Stage the effect library into the overlay UNCONDITIONALLY, the way ViperFX and friends ship
# theirs.
# It used to be installed only when dsp_loudness was already 3/6/9 at install time - but the
# audio stage runs long before the user's config is carried over from the previous install, so
# it always read the shipped default (off) and the library was never staged.
#
# Shipping it always costs nothing: an effect that is not listed in audio_effects_config.xml is
# never dlopen'd, so an unregistered .so is inert bytes on disk (~20 KB).
#
# 64-bit only on purpose: this platform has no /vendor/lib at all (no 32-bit audio processes),
# and the CI builds arm64-v8a only - an arm64 .so in a 32-bit soundfx dir would just fail to
# load.
#
# The module ships both.
# A OnePlus 13 reported dsp_loudness silent with the attach daemon logging set=-19
# initCheck=-19 on every attempt: NO_INIT, the factory refusing to create the effect, because
# the AIDL-only library exported no AELI symbol for a factory that wanted one.
#
# VINTF is the authority: the device manifest declares the effect HAL and its format.
# dsp_effect_abi=aidl|legacy in governor.conf overrides the probe, so a tester can
# settle the question on a device without waiting for a new build.
asb_pick_dsp_abi() {
  # Read the LIVE config first, then the one in the zip.
  # The carry-over that copies user keys into $MODPATH runs ~560 lines after the DSP library is
  # staged, so at this point $MODPATH/config/governor.conf is still the pristine shipped file -
  # a user override would have been read as "auto" and silently ignored, which makes "just set
  # it and reinstall" advice that cannot work.
  _abi_force=""
  for _abi_cf in /data/adb/modules/AutoSystemBoost/config/governor.conf \
                 /data/adb/asb/governor.conf.snapshot \
                 "$MODPATH/config/governor.conf"; do
    [ -f "$_abi_cf" ] || continue
    _abi_force="$(grep -E '^[[:space:]]*dsp_effect_abi=' "$_abi_cf" 2>/dev/null \
                  | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
    case "$_abi_force" in aidl|legacy|aidl_v[0-9]*) break ;; *) _abi_force="" ;; esac
  done
  case "$_abi_force" in
    aidl|legacy|aidl_v[0-9]*) printf '%s' "$_abi_force"; return 0 ;;
  esac

  _vintf_hit=""
  for _vd in /vendor/etc/vintf /odm/etc/vintf /system/etc/vintf; do
    [ -d "$_vd" ] || continue
    for _vf in "$_vd"/manifest.xml "$_vd"/manifest/*.xml "$_vd"/manifest_*.xml; do
      [ -f "$_vf" ] || continue
      grep -q 'android\.hardware\.audio\.effect' "$_vf" 2>/dev/null || continue
      _vintf_hit="$_vf"
      # An aidl-format entry anywhere for this HAL means the AIDL factory is live.
      if tr -d '\n' < "$_vf" 2>/dev/null \
         | grep -qE 'format="aidl"[^>]*>[^<]*<name>android\.hardware\.audio\.effect|android\.hardware\.audio\.effect[^<]*</name>[^<]*<fqname'; then
        # ...and the INTERFACE VERSION decides which build of it can load.
        #
        # A OnePlus 13 and a OnePlus 15 running the same module, byte-identical library (362392
        # bytes on both), with the effects config patched and visible to audiohalservice.qti in
        # its own mount namespace on both - and the library in the service's memory on only one
        # of them.
        # Nothing in the config or the filesystem could have shown that - it took comparing a
        # working device against a broken one.
        _av="$(tr -d '\n' < "$_vf" 2>/dev/null \
               | sed 's/.*android\.hardware\.audio\.effect<\/name>//' \
               | sed 's/.*<version>\([0-9]*\)<\/version>.*/\1/' \
               | head -c 4 | tr -d ' ')"
        case "$_av" in
          [0-9]*) printf 'aidl_v%s' "$_av" ;;
          *)      printf 'aidl' ;;
        esac
        return 0
      fi
    done
  done

  # The HAL is declared but not as AIDL -> HIDL factory, so legacy is genuinely usable.
  [ -n "$_vintf_hit" ] && { printf 'legacy'; return 0; }

  # Nothing declared it at all. Fall back on the API level, where AIDL effects are the
  # norm from 35 up, and say so in the log rather than guessing quietly.
  _abi_sdk="$(getprop ro.build.version.sdk 2>/dev/null)"
  case "$_abi_sdk" in
    ''|*[!0-9]*) printf 'aidl'; return 0 ;;
  esac
  [ "$_abi_sdk" -ge 35 ] && printf 'aidl' || printf 'legacy'
  return 0
}

asb_install_dsp_lib() {
  _dsp_any=0
  # 64-bit and 32-bit soundfx dirs both exist on the target, and an effect library has to match
  # the bitness of the process that dlopens it - so each gets the .so built for its own ABI.
  ASB_DSP_ABI="$(asb_pick_dsp_abi)"
  # Whether a HIDL factory exists at all decides if legacy is a real option or only a
  # library that will sit in memory doing nothing.
  case "$ASB_DSP_ABI" in
    aidl*) _vintf_aidl_only=1 ;;
    *)     _vintf_aidl_only=0 ;;
  esac
  case "$ASB_DSP_ABI" in
    legacy)
      if [ -f "$MODPATH/bin/libasbdsp_legacy.so" ]; then
        _dsp_s64="$MODPATH/bin/libasbdsp_legacy.so"
        _dsp_s32="$MODPATH/bin/libasbdsp_legacy_32.so"
      else
        ASB_DSP_ABI="aidl"
      fi
      ;;
    aidl_v*)
      # A version-specific build if we ship one, otherwise the generic AIDL library.
      # Saying which happened matters: falling back silently is how a device ends up
      # with an effect its factory cannot load and no clue why.
      _dsp_v="${ASB_DSP_ABI#aidl_}"
      if [ -f "$MODPATH/bin/libasbdsp_${_dsp_v}.so" ]; then
        _dsp_s64="$MODPATH/bin/libasbdsp_${_dsp_v}.so"
        _dsp_s32="$MODPATH/bin/libasbdsp_${_dsp_v}_32.so"
      elif [ "$_vintf_aidl_only" = "1" ]; then
        # Do NOT quietly stage the legacy library here.
        #
        # Tested on a OnePlus 15 forced to legacy: the library loads - four mappings in
        # audiohalservice.qti - and no effect is ever created.
        # The client path goes through the AIDL factory, which dlopens whatever the config
        # names and then looks for createEffect; the legacy library exports only AELI, so the
        # effect is never instantiated.
        #
        # So on an AIDL-only device a missing version means the DSP genuinely cannot run.
        # Say that, rather than installing something that will fail silently.
        ui_print "    ! ASB DSP: this device needs the AIDL effect ${_dsp_v}, which is not"
        ui_print "      in this build. The legacy effect cannot substitute: its client-facing"
        ui_print "      factory is AIDL-only, so a legacy library loads but never registers."
        ui_print "      DSP will stay off until a matching build ships."
        ASB_DSP_ABI="none"
        _dsp_s64=""
        _dsp_s32=""
      elif [ -f "$MODPATH/bin/libasbdsp_legacy.so" ]; then
        # Fall back to LEGACY, not to the generic AIDL library.
        #
        # The generic build is compiled against whichever interface version the build tree
        # froze last.
        #
        # The legacy effect ABI (audio_effect_library_t / AUDIO_EFFECT_LIBRARY_INFO_SYM) is NOT
        # versioned - it has been frozen for years, which is how ViPER ships one library for
        # every device and Android release.
        _dsp_s64="$MODPATH/bin/libasbdsp_legacy.so"
        _dsp_s32="$MODPATH/bin/libasbdsp_legacy_32.so"
        ASB_DSP_ABI="legacy"
        ui_print "      + ASB DSP: device wants AIDL effect ${_dsp_v}, which is not shipped"
        ui_print "        using the legacy effect instead - that ABI is not versioned"
      else
        ui_print "    ! ASB DSP: device declares AIDL effect ${_dsp_v}, no matching build shipped"
        ui_print "      and no legacy library either - the DSP will not load"
        ASB_DSP_ABI="aidl"
      fi
      ;;
  esac
  case "$ASB_DSP_ABI" in
    legacy|aidl_v*) : ;;
    *) ASB_DSP_ABI="aidl"
       # Prefer the newest VERSIONED build over the generic name.
       #
       # bin/libasbdsp.so is a third copy that predates the versioned ones and is not the same
       # bytes as either - 362392 against v3's 378760 - so on a device whose version the probe
       # could not read, the generic slot was handing out an older build than the module
       # already carries.
       _dsp_s64=""
       _dsp_s32=""
       if [ -f "$MODPATH/bin/libasbdsp.so" ]; then
         _dsp_s64="$MODPATH/bin/libasbdsp.so"
         _dsp_s32="$MODPATH/bin/libasbdsp_32.so"
       fi
       for _vg in "$MODPATH"/bin/libasbdsp_v*.so; do
         case "$_vg" in *_32.so) continue ;; esac
         [ -f "$_vg" ] || continue
         _dsp_s64="$_vg"
         _dsp_s32="${_vg%.so}_32.so"
       done ;;
  esac
  # Record what the probe chose.
  # "auto" has to mean something concrete at boot: without this, post-fs-data has no target to
  # restore and a user who tries legacy once is stuck with it forever - the switch was one-way,
  # and setting the card back to auto left the legacy library staged while the config claimed
  # otherwise.
  echo "$ASB_DSP_ABI" > "$MODPATH/dsp_abi_installed" 2>/dev/null
  ui_print "      + ASB DSP: ${ASB_DSP_ABI} effect selected for this device"

  [ -n "$_dsp_s64" ] || return 1
  for _dsp_pair in \
    "$_dsp_s64|$MODPATH/system/vendor/lib64/soundfx|/vendor/lib64/soundfx" \
    "$_dsp_s32|$MODPATH/system/vendor/lib/soundfx|/vendor/lib/soundfx"; do
    _dsp_src="${_dsp_pair%%|*}"
    _dsp_rest="${_dsp_pair#*|}"
    _dsp_dir="${_dsp_rest%%|*}"
    _dsp_live="${_dsp_rest##*|}"
    [ -f "$_dsp_src" ] || continue
    mkdir -p "$_dsp_dir" 2>/dev/null || continue
    cp -f "$_dsp_src" "$_dsp_dir/libasbdsp.so" 2>/dev/null || continue
    chmod 0644 "$_dsp_dir/libasbdsp.so" 2>/dev/null
    # Borrow the SELinux label from a real library in the matching live soundfx dir.
    # Without a vendor_file-ish context audioserver is not allowed to dlopen it and the
    # effect silently never loads.
    _dsp_ref=""
    for _c in "$_dsp_live"/*.so; do [ -f "$_c" ] && { _dsp_ref="$_c"; break; }; done
    if [ -n "$_dsp_ref" ]; then
      _dsp_ctx="$(ls -Zd "$_dsp_ref" 2>/dev/null | awk '{print $1}')"
      case "$_dsp_ctx" in
        ?*:?*:?*:?*) chcon "$_dsp_ctx" "$_dsp_dir/libasbdsp.so" 2>/dev/null || true ;;
      esac
    fi
    _dsp_any=1
  done
  [ "$_dsp_any" = "1" ] || return 1
  return 0
}

asb_register_dsp_effect() {
  [ -f "$1" ] || return 0
  # Strip any earlier ASB registration first.
  if grep -qE 'asb_loudness|asbdsp' "$1" 2>/dev/null; then
    _clean_ae="${1}.asbclean"
    awk '
      /<library[^>]*name="asbdsp"/            { next }
      /<effect[^>]*name="asb_loudness"/       { next }
      /<apply[^>]*effect="asb_loudness"/      { next }
      { print }
    ' "$1" > "$_clean_ae" 2>/dev/null || { rm -f "$_clean_ae" 2>/dev/null; }
    if [ -s "$_clean_ae" ]; then
      # Drop a <stream type="..."> block that our removal left with no <apply> inside.
      awk '
        /<stream[[:space:]]+type=/ { buf = $0; hold = 1; has = 0; next }
        hold && /<\/stream>/ {
          if (has) { print buf; print body; print }
          hold = 0; body = ""; next
        }
        hold { if ($0 ~ /<apply/) has = 1; body = (body == "" ? $0 : body "\n" $0); next }
        { print }
      ' "$_clean_ae" > "${_clean_ae}2" 2>/dev/null
      [ -s "${_clean_ae}2" ] && cat "${_clean_ae}2" > "$1"
      rm -f "${_clean_ae}2" 2>/dev/null
    fi
    rm -f "$_clean_ae" 2>/dev/null
  fi
  # Either ABI is enough to justify registering the effect: audio_effects_config.xml
  # names the library by filename, and each process picks the soundfx dir matching its
  # own bitness.
  [ -f "$MODPATH/system/vendor/lib64/soundfx/libasbdsp.so" ] \
    || [ -f "$MODPATH/system/vendor/lib/soundfx/libasbdsp.so" ] || return 0
  grep -q '<libraries>' "$1" 2>/dev/null || return 0
  grep -q '<effects>' "$1" 2>/dev/null || return 0
  sedi "s#<libraries>#<libraries>\n        <library name=\"asbdsp\" path=\"libasbdsp.so\"/>#" "$1"
  sedi "s#<effects>#<effects>\n        <effect name=\"asb_loudness\" library=\"asbdsp\" uuid=\"${ASB_DSP_UUID}\" type=\"${ASB_DSP_TYPE}\"/>#" "$1"
  # Attach to the music stream.
  # On OP15 our block was inserted before the stock music_helper block and was silently dropped
  # - the effect loaded into the factory (9 effects) yet audiopolicy logged
  # "addOutputSessionEffects(): no output processing needed for this stream".
  #
  # Registering the effect in a stream's post-processing chain CRASHES audioserver on this
  # platform.
  #
  # The entry is not needed anyway.
  # OxygenOS never applies config-declared post-processing - AudioPolicyEffects logs "no output
  # processing needed for this stream" even for the stock music_helper - so effects here are
  # attached programmatically instead.
}

asb_audio_ensure_volume_libs() {
  _aed="$1"
  [ -d "$_aed" ] || return 0
  for _vd in /vendor/lib64/soundfx /vendor/lib/soundfx \
             /odm/lib64/soundfx /odm/lib/soundfx \
             /system/lib64/soundfx /system/lib/soundfx \
             /system/vendor/lib64/soundfx /system/vendor/lib/soundfx; do
    [ -f "$_vd/libv4a_re.so" ] && return 0
  done
  _fixed=0
  for _ef in $(find "$_aed" -type f -name "audio_effects*.xml" 2>/dev/null); do
    grep -q "<libraries>" "$_ef" 2>/dev/null || continue
    if ! grep -q 'name="volume_listener"' "$_ef" 2>/dev/null; then
      sedi '/<libraries>/ a\        <library name="volume_listener" path="libvolumelistener.so"/>' "$_ef"
      _fixed=1
    fi
    if ! grep -q 'name="audio_pre_processing"' "$_ef" 2>/dev/null; then
      sedi '/<libraries>/ a\        <library name="audio_pre_processing" path="libqcomvoiceprocessing.so"/>' "$_ef"
      _fixed=1
    fi
  done
  [ "$_fixed" = "1" ] && ui_print "      + audio_effects: ensured stock volume libs present (device-native)"
  return 0
}

asb_patch_audio_inplace() {
  [ "$ASB_AUDIO" = "true" ] || { ui_print "[*] Audio category off — skipping mixer tune"; return 0; }
  _adir="$MODPATH/system/vendor/etc/audio"
  [ -d "$_adir" ] || { ui_print "[*] No cloned audio dir — skipping mixer tune"; return 0; }

  _n=0
  for _mx in $(find "$_adir" -type f -name "mixer_paths*.xml" 2>/dev/null); do
    asb_patch_one_mixer "$_mx"
    _n=$((_n + 1))
  done

  # Hi-res sampling rates for audio_policy_configuration.xml (what the diag reads for "384000
  # present").
  for _apc in $(find "$_adir" -type f -name "audio_policy_configuration.xml" 2>/dev/null); do
    asb_lift_hires_policy "$_apc"
  done
  if [ -f /vendor/etc/audio_policy_configuration.xml ]; then
    _apd="$MODPATH/system/vendor/etc/audio_policy_configuration.xml"
    [ -f "$_apd" ] || { mkdir -p "$MODPATH/system/vendor/etc" 2>/dev/null; cp -f /vendor/etc/audio_policy_configuration.xml "$_apd" 2>/dev/null; }
    asb_lift_hires_policy "$_apd"
  fi

  # ASB DSP effect: install the library first; the odm-bind stage registers it.
  # Always stage the library; only the registration below is gated on the setting.
  if asb_install_dsp_lib; then
    # The attacher daemon lives in the module dir, not /vendor: it links libaudioclient, which
    # is a system library and not available to vendor processes.
    # Without it the effect is registered and loaded by the factory but never instantiated,
    # because OxygenOS does not apply the config's <postprocess> section.
    if [ -f "$MODPATH/bin/asb_dsp_attach" ]; then
      chmod 0755 "$MODPATH/bin/asb_dsp_attach" 2>/dev/null
      ui_print "      + ASB DSP attacher staged (creates the effect on the global mix)"
    else
      ui_print "    ! ASB DSP attacher missing - effect will register but not attach"
    fi
    _dspg="$(grep -E '^[[:space:]]*dsp_loudness=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
    case "$_dspg" in
      ''|off|0|*[!0-9]*) _dspg_ok=0 ;;
      *) [ "$_dspg" -ge 1 ] 2>/dev/null && [ "$_dspg" -le 25 ] 2>/dev/null && _dspg_ok=1 || _dspg_ok=0 ;;
    esac
    if [ "$_dspg_ok" = "1" ]; then
        ui_print "      + ASB ${ASB_D_DSP_ENGINE:-DSP engine}: +${_dspg} dB ${ASB_D_DSP_GAIN:-gain}"
        ui_print "        ${ASB_D_DSP_CHAIN:-soft-knee compressor -> makeup gain -> peak limiter (no clip)}"
        _dsp_abis=""
        [ -f "$MODPATH/system/vendor/lib64/soundfx/libasbdsp.so" ] && _dsp_abis="64-bit"
        [ -f "$MODPATH/system/vendor/lib/soundfx/libasbdsp.so" ] && _dsp_abis="${_dsp_abis:+$_dsp_abis + }32-bit"
        ui_print "        ${ASB_D_DSP_STAGED:-library staged for}: ${_dsp_abis:-none}"
    else
        ui_print "      + ASB DSP: ${ASB_D_DSP_OFF:-library staged, effect off} (dsp_loudness=off)"
    fi
  else
    ui_print "    ! ASB DSP: libasbdsp.so missing from build - skipped"
  fi

  # Media loudness: reshape the MUSIC volume curves from a pristine stock copy.
  _ml="$(grep -E '^[[:space:]]*media_loudness=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  case "$_ml" in
    mild)   _mlpct=80 ;;
    strong) _mlpct=65 ;;
    max)    _mlpct=40 ;;
    *)      _mlpct=100 ;;
  esac
  if [ "$_mlpct" != "100" ]; then
    asb_volume_odm_bind_cleanup >/dev/null 2>&1
    if asb_volume_curves_build "$MODPATH" "$_mlpct"; then
      case "$_ml" in
        mild)   ui_print "      + ${ASB_D_LOUD:-media loudness}: mild (~+3 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
        strong) ui_print "      + ${ASB_D_LOUD:-media loudness}: strong (~+6 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
        max)    ui_print "      + ${ASB_D_LOUD:-media loudness}: max (~+10 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
      esac
      ui_print "        ${ASB_D_LOUD_NOTE:-music curves only; alarms/ringtones untouched; 100% never raised}"
    else
      ui_print "    ! media loudness: stock volume table unavailable - skipped"
    fi
  fi

  asb_audio_ensure_volume_libs "$_adir"

  if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
    . "$MODPATH/runtime/asb_tweaks.sh"
    asb_save_dynamic_baselines "$MODPATH"
    asb_apply_dynamic_tweaks "$MODPATH"
  fi
  asb_patch_audio_inplace_aggr_flag
  if [ "$_ASB_AUDIO_AGGR" = "1" ]; then
    ui_print "      + ${ASB_D_MIXER:-mixer}: $_n ${ASB_D_MIXER_TAIL:-file(s) tuned — digital vol 84->88}, flat EQ"
    ui_print "        ${ASB_D_MIXER_AGGR:-Class-H DAC, HPH HIFI mode, compander off (aggressive)}"
  else
    ui_print "      + ${ASB_D_MIXER:-mixer}: $_n ${ASB_D_MIXER_TAIL:-file(s) tuned — digital vol 84->88} (RX+speaker)"
    ui_print "        ${ASB_D_MIXER_STD:-flat EQ, Class-H DAC}"
  fi
}

asb_strip_shipped_static_vendor() {
  rm -rf "$MODPATH/system/vendor/etc/audio" \
         "$MODPATH/system/vendor/odm/etc/audio" \
         "$MODPATH/system/odm/etc/audio" 2>/dev/null || true
  for _af in mixer_paths.xml ftm_mixer_paths.xml resourcemanager.xml \
             audio_module_config_primary.xml; do
    rm -f "$MODPATH/system/vendor/etc/$_af" \
          "$MODPATH/system/vendor/odm/etc/$_af" 2>/dev/null || true
  done
  rm -f "$MODPATH/system/vendor/etc/media_profiles"*.xml \
        "$MODPATH/system/vendor/odm/etc/media_profiles"*.xml \
        "$MODPATH/system/odm/etc/media_profiles"*.xml 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" \
         "$MODPATH/system/odm/etc/camera" \
         "$MODPATH/system/vendor/etc/camera" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/gps.conf" \
        "$MODPATH/system/vendor/etc/izat.conf" \
        "$MODPATH/system/vendor/odm/etc/gps.conf" \
        "$MODPATH/system/vendor/odm/etc/izat.conf" \
        "$MODPATH/system/odm/etc/gps.conf" \
        "$MODPATH/system/odm/etc/izat.conf" 2>/dev/null || true
}

# Write the device-pack manifest for the running build.
#
# Domains are granted from what the installer actually did, not from a wish list:
#   properties - always, when the model was recognised. These are the managed props in
#                runtime/asb_managed.props, and they are the reason the gate exists.
#   camera     - only if a camera overlay was produced for this device.
#   audio      - only if an audio overlay was produced.
#
# An unrecognised device gets no manifest at all and stays generic, which is the whole
# point of the tier system.
asb_write_device_pack_manifest() {
  _dpm_pack="${1:-}"
  [ -n "$_dpm_pack" ] || return 0

  _dpm_fp="$(getprop ro.build.fingerprint 2>/dev/null)"
  [ -n "$_dpm_fp" ] || {
    ui_print "      + device pack: no build fingerprint - staying generic"
    return 0
  }

  mkdir -p /data/adb/asb 2>/dev/null || return 0
  _dpm_tmp="/data/adb/asb/device_pack_verified.tmp.$$"
  {
    printf 'tier=validated\n'
    printf 'fingerprint=%s\n' "$_dpm_fp"
    printf 'pack=%s\n' "$_dpm_pack"
    printf 'certified_by=installer\n'
    printf 'certified_at=%s\n' "$(date +%s 2>/dev/null || echo 0)"
    printf 'domain=properties\n'
    # Camera and audio are claimed only when their overlay exists on disk: a domain
    # granted without the files behind it would authorise writes with nothing to write.
    if [ -d "$MODPATH/system/odm/etc/camera" ] || [ -d "$MODPATH/system/vendor/odm/etc/camera" ]; then
      printf 'domain=camera\n'
    fi
    if [ -d "$MODPATH/system/vendor/etc/audio" ] || [ -d "$MODPATH/system/odm/etc/audio" ]; then
      printf 'domain=audio\n'
    fi
  } > "$_dpm_tmp" 2>/dev/null && mv -f "$_dpm_tmp" /data/adb/asb/device_pack_verified 2>/dev/null

  if [ -r /data/adb/asb/device_pack_verified ]; then
    ui_print "      + device pack certified for this build ($_dpm_pack)"
  fi
}

asb_apply_device_native_tuning() {
  _label="$1"
  # Certify the pack for THIS build, where the evidence exists: the model was matched,
  # the stock files were read, and an overlay was produced from them. Nothing else in the
  # module knows that much, which is why the manifest was never written and 823 managed
  # properties stayed blocked on every device.
  asb_write_device_pack_manifest "${2:-}"
  ui_print " "
  ui_print "  🚀  AutoSystemBoost — ${ASB_SEC_INSTALLING:-installing for} ${_label}"
  ui_print "      ${ASB_SEC_BUILDING:-building a device-native overlay from this phone stock files}"
  ui_print " "

  asb_strip_shipped_static_vendor

  # Each stage prints ONE section with an emoji header and a few "+" detail lines, the same
  # shape as the action screen.
  ui_print "  🎵  ${ASB_SEC_AUDIO:-AUDIO}"
  asb_clone_device_audio_wifi   "$_label"
  asb_patch_audio_inplace       "$_label"
  # DSP belongs to Audio in both the WebUI and the installer report. Register it here,
  # after the audio overlay exists but before the next category headline, so users do not
  # read a second unrelated DSP section later in the log.
  asb_register_dsp_all_configs

  # Clear any ODM volume-table copy an earlier build left in the overlay.
  #
  # It never reached /odm (proven: marker present in the module, absent on the live path), so
  # it was inert - but on a non-reference device it creates a system/odm directory that then
  # has to be pruned, and dead files in an overlay are exactly what turns into a mystery later.
  # The post-clone re-reshape that used to sit here went with it: it existed only to survive
  # the clone wiping system/odm/etc/audio, and nothing is written there any more.
  rm -f "$MODPATH/system/odm/etc/audio/default_volume_tables.xml" \
        "$MODPATH/system/vendor/odm/etc/audio/default_volume_tables.xml" 2>/dev/null

  ui_print " "
  ui_print "  📷  ${ASB_SEC_CAMERA:-CAMERA}"
  asb_clone_device_camera_tone

  ui_print " "
  ui_print "  🎬  ${ASB_SEC_MEDIA:-MEDIA}"
  asb_patch_media_profiles_inplace

  ui_print " "
  ui_print "  ⚡  ${ASB_SEC_PERF:-PERFORMANCE}"
  asb_patch_perf_inplace        "$_label"

  ui_print " "
  ui_print "  🛰  ${ASB_SEC_LOCATION:-LOCATION}"
  asb_patch_location_inplace    "$2"

  ui_print " "
  ui_print "  📶  ${ASB_SEC_WIFI:-WI-FI}"
  asb_patch_wifi_inplace        "$_label"
  ui_print " "

  if [ "$ASB_AUDIO" = "true" ] || [ "$ASB_CAMERA" = "true" ]; then
    if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
      . "$MODPATH/runtime/asb_tweaks.sh"
      asb_save_dynamic_baselines "$MODPATH" 2>/dev/null || true
      asb_apply_dynamic_tweaks "$MODPATH" 2>/dev/null || true
    fi
  fi

  _man="$MODPATH/generated_overlay_manifest.txt"
  _asb_overlay_built_at="$(date +'%F %T' 2>/dev/null || printf unknown)"
  {
    printf '%s\n' "# ASB device-native overlay — $_asb_overlay_built_at"
    printf '%s\n' "# device: $_label"
    printf '%s\n' '# built by cloning + key-patching device stock files'
    find "$MODPATH/system" -type f \( -path '*/etc/audio/*' -o -path '*/camera/*' \
      -o -name 'media_profiles*.xml' -o -name 'gps.conf' -o -name 'izat.conf' \
      -o -path '*/etc/perf/*' -o -name 'WCNSS_qcom_cfg*.ini' \) 2>/dev/null \
      | sed "s|$MODPATH/||"
  } > "$_man" 2>/dev/null
  cp -f "$_man" /data/adb/asb/generated_overlay_manifest.txt 2>/dev/null || true
  echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null || true
    # The SYSTEM header is not printed here.
    #
    # It sat at the end of the manifest builder and nothing was ever printed under it, so
    # the install report showed an empty heading - and because DSP ENGINE follows straight
    # after, DSP looked like it belonged to SYSTEM. The sections that follow carry their
    # own headings; this one headed nothing.
}

asb_prune_non_op15_vendor_overlays() {
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Compatibility mode enabled"
  ui_print "[*] ${ASB_DEVICE_NAME} — not the OP15 reference model"
  ui_print "[*] Keeping script/prop tweaks, pruning reference (OP15) vendor overlays that do not fit this model"

  # Start conservative on hardware nobody has measured.
  #
  # A field report from a OnePlus Ace 5 had 4K60 recording stuttering until the CPU,
  # memory, scheduler and Doze tweaks were removed - and the Action screen on that phone
  # showed three NOT APPLIED entries, so the device-native pipeline was not covering it
  # either. The defaults are tuned against devices the author owns; on anything else they
  # are an assumption, and the cost of a wrong assumption is a phone that behaves worse
  # than stock while the user has no idea which of 44 settings did it.
  #
  # Only the aggressive ones are stood down, and only on a first install - a returning
  # user keeps whatever they chose. Everything remains switchable in the WebUI; this
  # changes where the phone starts, not what it can do.
  if [ ! -f /data/adb/asb/nonref_defaults_applied ] \
     && [ -f "$MODPATH/config/governor.conf" ]; then
    for _nr in "BG_TRIM_LEVEL=off" "phantom_procs=stock" "doze_level=stock" "night_modem_idle=0" "athena_service=stock" \
               "media_loudness=stock" "sustained_temp_mode=stock"; do
      _nrk="${_nr%%=*}"; _nrv="${_nr#*=}"
      if grep -qE "^[[:space:]]*${_nrk}=" "$MODPATH/config/governor.conf" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${_nrk}=.*|${_nrk}=${_nrv}|" "$MODPATH/config/governor.conf" 2>/dev/null
      fi
    done
    mkdir -p /data/adb/asb 2>/dev/null
    date +%s > /data/adb/asb/nonref_defaults_applied 2>/dev/null
    ui_print "[*] Conservative defaults applied for this model - enable extras in the WebUI"
  fi
  ui_print "${SEPARATOR}"

  rm -f "$MODPATH/system/etc/permissions/Bluetooth.xml" 2>/dev/null || true
  rm -f "$MODPATH/system/etc/compatconfig/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*a2dp*"xml" 2>/dev/null || true

  rm -f "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true   # OP12/OP13: strip OP15 multicam set from /odm copy too (ChiMcx crash fix)

  rm -f "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true
  for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml usb_audio_policy_configuration.xml virtual_audio_policy_configuration.xml; do
    rm -f "$MODPATH/system/vendor/etc/${_f}" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/${_f}" 2>/dev/null || true
  done
  rm -f "$MODPATH/system/vendor/etc/"media_codecs_*_audio.xml 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true

  rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/xtwifi.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/xtwifi.conf" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/lowi.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/gps" 2>/dev/null || true

  find "$MODPATH/system" -type d -empty -print -delete 2>/dev/null || true
}

asb_generate_odm_binds() {
  _ob_root="/data/adb/asb/odm_patched"
  _ob_man="/data/adb/asb/odm_bind_manifest.txt"
  rm -rf "$_ob_root" 2>/dev/null
  rm -f "$_ob_man" 2>/dev/null
  [ -f /data/adb/asb/vendor_overlay_blocked ] && return 0
  [ "$ASB_AUDIO" = "true" ] || [ "$ASB_MEDIA" = "true" ] || return 0
  _ob_canoe=0
  # Every access below touches LIVE /odm paths.
  _ob_to=""
  command -v timeout >/dev/null 2>&1 && _ob_to="timeout 20"
  for _ob_t in \
      /odm/etc/audio/audio_policy_configuration.xml \
      /odm/etc/mixer_paths.xml \
      /odm/etc/audio_effects_config.xml \
      /odm/etc/media_profiles_V1_0.xml \
      /odm/etc/camera/media_profiles.xml; do
    ui_print "    . odm-bind check: ${_ob_t}"
    _ob_p="$_ob_root$_ob_t"
    mkdir -p "$(dirname "$_ob_p")" 2>/dev/null
    # guarded cp covers existence, read AND a stalled-mount timeout in one step
    $_ob_to cp -f "$_ob_t" "$_ob_p" 2>/dev/null || continue
    case "$_ob_t" in
      *audio_policy_configuration.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_lift_hires_policy "$_ob_p"
        ;;
      *mixer_paths*.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_patch_one_mixer "$_ob_p"
        ;;
      *media_profiles*.xml)
        [ "$ASB_MEDIA" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_media_lift_file "$_ob_p" "$_ob_canoe"
        ;;
      *audio_effects_config.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_register_dsp_effect "$_ob_p"
        ;;
    esac
  done
  ui_print "    . odm-bind: volume libs"
  [ "$ASB_AUDIO" = "true" ] && asb_audio_ensure_volume_libs "$_ob_root/odm/etc"
  ui_print "    . odm-bind: building manifest"
  : > "$_ob_man"
  for _ob_p in $(find "$_ob_root" -type f 2>/dev/null); do
    _ob_t="${_ob_p#$_ob_root}"
    if $_ob_to cmp -s "$_ob_p" "$_ob_t" 2>/dev/null; then
      rm -f "$_ob_p" 2>/dev/null
      continue
    fi
    chmod 0644 "$_ob_p" 2>/dev/null
    _ob_ctx="$($_ob_to ls -Zd "$_ob_t" 2>/dev/null | awk '{print $1}')"
    case "$_ob_ctx" in
      ?*:?*:?*:?*) chcon "$_ob_ctx" "$_ob_p" 2>/dev/null || true ;;
    esac
    echo "$_ob_t|$_ob_p" >> "$_ob_man"
  done
  if [ -s "$_ob_man" ]; then
    ui_print "[*] odm-side audio/media: $(wc -l < "$_ob_man") file(s) patched for runtime bind (the /odm partition itself is never modified)"
  else
    rm -f "$_ob_man" 2>/dev/null
    rm -rf "$_ob_root" 2>/dev/null
  fi
}

# Register the ASB DSP effect on ANY device, not just the reference model.
#
# The registration used to live in two places and neither covered the whole fleet: the OP15
# branch patched its own sku_* configs plus the /odm runtime bind, and asb_generate_odm_binds
# patched /odm/etc/audio_effects_config.xml - and that generator is only ever called on
# non-reference OnePlus models.
# On those devices the library was staged and the properties were published, so everything
# reported success, while no audio_effects_config.xml anywhere listed the effect: audioserver
# never dlopen'd it, the attach daemon had nothing to attach, and the action screen showed
# "effect not registered by install" next to a DSP that had been switched on for weeks.
#
# There is nothing device-specific about registering an effect, so this is one function that
# every branch calls.
# It patches every effects config the module overlay carries - at any depth, which is what
# picks up the per-SKU layout (sku_cliffs, sku_pineapple, ...) that newer devices use - and
# then delivers a patched /odm/etc/audio_effects_config.xml through the same fuse-guarded
# runtime bind, because AOSP resolves /odm before /vendor and /system, so on a device that
# ships one, that file is the only one the framework actually reads.
#
# asb_register_dsp_effect strips its own lines before re-adding them, so every
# path here is idempotent across reinstalls and upgrades.
# Deliver the patched camera configs through the /odm runtime bind.
#
# The camera tone and the retouch app list are staged into the module overlay at BOTH
# system/vendor/odm/etc/camera and system/odm/etc/camera, and the second of those only ever
# becomes live if the root manager happens to magic-mount the odm tree.
# The audio side of exactly this problem was already solved with the fuse-guarded runtime bind;
# the camera files were simply never added to it.
#
# Only files the module actually changed are bound, the manifest entry is
# deduplicated, and the whole thing is skipped when the bootloop fuse is set - so
# this cannot make a device that already refuses the overlay any worse.
asb_generate_odm_camera_binds() {
  [ "$ASB_CAMERA" = "true" ] || return 0
  [ -f /data/adb/asb/vendor_overlay_blocked ] && return 0

  _obc_man="/data/adb/asb/odm_bind_manifest.txt"
  _obc_any=0
  for _obc_rel in conf_tuning_params.json config/video_beauty_default_config; do
    _obc_live="/odm/etc/camera/$_obc_rel"
    [ -f "$_obc_live" ] || continue
    _obc_src="$MODPATH/system/odm/etc/camera/$_obc_rel"
    [ -f "$_obc_src" ] || _obc_src="$MODPATH/system/vendor/odm/etc/camera/$_obc_rel"
    [ -f "$_obc_src" ] || continue
    cmp -s "$_obc_src" "$_obc_live" 2>/dev/null && continue

    _obc_dst="/data/adb/asb/odm_patched$_obc_live"
    mkdir -p "$(dirname "$_obc_dst")" 2>/dev/null
    cp -f "$_obc_src" "$_obc_dst" 2>/dev/null || continue
    chmod 0644 "$_obc_dst" 2>/dev/null
    _obc_ctx="$(ls -Zd "$_obc_live" 2>/dev/null | awk '{print $1}')"
    case "$_obc_ctx" in
      ?*:?*:?*:?*) chcon "$_obc_ctx" "$_obc_dst" 2>/dev/null || true ;;
    esac
    touch "$_obc_man" 2>/dev/null
    grep -q "^${_obc_live}|" "$_obc_man" 2>/dev/null \
      || echo "${_obc_live}|${_obc_dst}" >> "$_obc_man"
    _obc_any=$((_obc_any + 1))
  done
  [ "$_obc_any" -gt 0 ] && \
    ui_print "      + $(printf "${ASB_L_CAM_QUEUED:-Camera: %s config(s) will be linked in at boot}" "$_obc_any")"
  return 0
}

asb_register_dsp_all_configs() {
  # Device-native paths call this from their Audio stage. The later fallback call remains
  # for compatibility paths that do not build an overlay, so it must be idempotent.
  [ "${ASB_DSP_REGISTRATION_DONE:-0}" = "1" ] && return 0
  ASB_DSP_REGISTRATION_DONE=1
  [ "$ASB_AUDIO" = "true" ] || return 0

  for _d in "$MODPATH" /data/adb/modules/AutoSystemBoost; do
    [ -d "$_d" ] || continue
    find "$_d/system" -name 'audio_effects_config.xml.asbbak' -type f -delete 2>/dev/null || true
    rm -f "$_d"/system/vendor/odm/etc/audio_effects_config.xml.asbbak \
          "$_d"/system/odm/etc/audio_effects_config.xml.asbbak 2>/dev/null
  done

  if [ ! -f "$MODPATH/system/vendor/lib64/soundfx/libasbdsp.so" ] \
     && [ ! -f "$MODPATH/system/vendor/lib/soundfx/libasbdsp.so" ]; then
    ui_print "    ! ASB DSP: library not staged - nothing to register"
    return 0
  fi

  # Materialise the effects config the framework will actually read.
  #
  # The overlay only ever contains what asb_clone_device_audio_wifi cloned, and that clones the
  # audio DIRECTORIES (/vendor/etc/audio, /odm/etc/audio).
  # A device that keeps its effects config one level up - /vendor/etc/audio_effects_config.xml
  # - therefore had nothing in the overlay to register into, so the search below found zero
  # files and the effect stayed unregistered while everything else reported success.
  #
  # AOSP resolves this file as /odm/etc -> /vendor/etc -> /system/etc and the first hit wins,
  # so patching a lower-priority copy is wasted work.
  # Anything under an odm path goes through the runtime bind below instead - not just because
  # grafting /odm into the magic-mount tree is what bootlooped the Ace 6, but because a later
  # install stage hard-removes every odm graft from the module tree, so a clone placed there
  # would be deleted before it ever reached a boot.
  _dsp_cloned=""
  for _ecl in /vendor/etc/audio_effects_config.xml \
              /vendor/etc/audio_effects.xml \
              /system/etc/audio_effects_config.xml; do
    [ -f "$_ecl" ] || continue
    case "$_ecl" in
      /system/*) _ecd="$MODPATH/system${_ecl#/system}" ;;
      *)         _ecd="$MODPATH/system${_ecl}" ;;
    esac
    [ -f "$_ecd" ] && continue
    mkdir -p "$(dirname "$_ecd")" 2>/dev/null || continue
    cp -f "$_ecl" "$_ecd" 2>/dev/null || continue
    chmod 0644 "$_ecd" 2>/dev/null
    _ecc="$(ls -Zd "$_ecl" 2>/dev/null | awk '{print $1}')"
    case "$_ecc" in
      ?*:?*:?*:?*) chcon "$_ecc" "$_ecd" 2>/dev/null || true ;;
    esac
    _dsp_cloned="${_dsp_cloned} ${_ecd}"
    ui_print "      + ASB DSP: cloned ${_ecl} into the overlay to register into"
  done

  _dsp_reg=0
  _dsp_seen=0
  for _ec in $(find "$MODPATH/system" -type f -name 'audio_effects_config.xml' -o \
                    -type f -name 'audio_effects.xml' 2>/dev/null); do
    case "$_ec" in *_stub.xml) continue ;; esac
    _dsp_seen=$((_dsp_seen + 1))
    asb_register_dsp_effect "$_ec"
    if grep -q 'asb_loudness' "$_ec" 2>/dev/null; then
      _dsp_reg=$((_dsp_reg + 1))
      # Paths were printed one per file - four lines of /vendor/etc/audio/sku_*/... that
      # tell a user nothing. The count on the next line already says how many landed.
      :
    elif ! grep -q '<libraries>' "$_ec" 2>/dev/null || ! grep -q '<effects>' "$_ec" 2>/dev/null; then
      ui_print "    ! ASB DSP: $(basename "$(dirname "$_ec")") has no <libraries>/<effects> section"
    else
      ui_print "    ! ASB DSP: registration did not land in $(basename "$(dirname "$_ec")")"
    fi
  done
  if [ "$_dsp_reg" -gt 0 ]; then
    ui_print "      + ${ASB_SEC_AUDIO:-AUDIO} · ${ASB_SEC_DSP:-DSP ENGINE}: $(printf "${ASB_L_DSP_REG_N:-registered in %s audio config file(s)}" "$_dsp_reg")"
  elif [ "$_dsp_seen" -gt 0 ]; then
    ui_print "    ! ASB DSP: $_dsp_seen config(s) present but none registered"
  fi

  for _ecx in $_dsp_cloned; do
    [ -f "$_ecx" ] || continue
    grep -q 'asb_loudness' "$_ecx" 2>/dev/null && continue
    rm -f "$_ecx" 2>/dev/null
    ui_print "        . removed unused clone $(basename "$_ecx") (registration did not land)"
  done
  find "$MODPATH/system" -type d -empty -delete 2>/dev/null || true

  [ -f /data/adb/asb/vendor_overlay_blocked ] && return 0

  _dsp_bind_reg=0
  for _oecl in /odm/etc/audio_effects_config.xml \
               /vendor/odm/etc/audio_effects_config.xml; do
    [ -f "$_oecl" ] || continue
    asb_bind_register_odm_effects "$_oecl" && _dsp_bind_reg=$((_dsp_bind_reg + 1))
  done

  # Say it plainly when the effect landed nowhere at all, and list what the device
  # actually has. A silent no-op here is what cost two field rounds; the next report
  # should answer "which file should we have patched" without another diagnostic run.
  if [ "$_dsp_reg" = "0" ] && [ "$_dsp_bind_reg" = "0" ]; then
    ui_print "    ! ASB DSP: the effect was registered nowhere - please report this"
    _dsp_found=0
    for _ecp in /odm/etc /vendor/etc /vendor/odm/etc /system/etc; do
      for _ecf in "$_ecp"/audio_effects_config.xml "$_ecp"/audio_effects.xml; do
        [ -f "$_ecf" ] && { ui_print "        . live copy exists: $_ecf"; _dsp_found=1; }
      done
    done
    for _ecf in $(find /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio -maxdepth 4 \
                       -type f -name 'audio_effects*.xml' 2>/dev/null); do
      ui_print "        . live copy exists: $_ecf"
      _dsp_found=1
    done
    [ "$_dsp_found" = "0" ] && \
      ui_print "        . this device ships no audio_effects config in any standard location"
  fi
  return 0
}

# One odm effects config, delivered through the fuse-guarded runtime bind.
asb_bind_register_odm_effects() {
  _oecl="$1"
  _oecs="/data/adb/asb/odm_patched${_oecl}"
  _oecs_src="${_oecs}.stock"
  _oecm="/data/adb/asb/odm_bind_manifest.txt"
  mkdir -p "$(dirname "$_oecs")" 2>/dev/null
  # Never snapshot from the live path once an earlier bind is mounted: at that point
  # /odm/etc/audio_effects_config.xml IS "$_oecs", and copying it onto itself truncates the
  # file, which is how a device ended up with a bound config carrying zero ASB lines while
  # every reinstall reported success.
  if [ ! -s "$_oecs_src" ]; then
    cp -f "$_oecl" "$_oecs_src" 2>/dev/null
  fi
  cp -f "$_oecs_src" "$_oecs" 2>/dev/null || return 1
  asb_register_dsp_effect "$_oecs"
  if grep -q 'asb_loudness' "$_oecs" 2>/dev/null; then
    chmod 0644 "$_oecs" 2>/dev/null
    _oec_ctx="$(ls -Zd "$_oecl" 2>/dev/null | awk '{print $1}')"
    case "$_oec_ctx" in
      ?*:?*:?*:?*) chcon "$_oec_ctx" "$_oecs" 2>/dev/null || true ;;
    esac
    touch "$_oecm" 2>/dev/null
    grep -q "^${_oecl}|" "$_oecm" 2>/dev/null \
      || echo "${_oecl}|$_oecs" >> "$_oecm"
    # Printed once per patched config with identical wording, so a device with two of
    # them showed the same sentence twice and no way to tell them apart. Name the file.
    ui_print "      + ${ASB_SEC_AUDIO:-AUDIO} · ${ASB_SEC_DSP:-DSP ENGINE}: ${ASB_L_DSP_ODM:-registered in the config Android actually reads}: $_oecl"
    return 0
  fi
  rm -f "$_oecs" 2>/dev/null
  ui_print "    ! ASB DSP: could not patch ${_oecl}"
  return 1
}

asb_reset_learning_on_upgrade_to_v56() {
  _asb_dir="/data/adb/asb"
  _marker="$_asb_dir/learning_reset_done"
  _marker_legacy="$_asb_dir/v56_learning_reset_done"
  if [ -f "$_marker_legacy" ]; then
    [ -f "$_marker" ] || mv -f "$_marker_legacy" "$_marker" 2>/dev/null
    rm -f "$_marker_legacy" 2>/dev/null
  fi
  [ -f "$_marker" ] && return 0   # already done on this device

  _old_prop="$NVBASE/modules/$MODID/module.prop"
  [ -f "$_old_prop" ] || _old_prop="$NVBASE/modules_update/$MODID/module.prop"
  [ -f "$_old_prop" ] || return 0   # no prior install -> nothing learned yet
  _old_vc="$(grep -E '^versionCode=' "$_old_prop" 2>/dev/null | head -1 | sed 's/[^0-9]//g')"
  case "$_old_vc" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_old_vc" -le 550 ] || return 0   # 560+ already has the fixed classifier

  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Upgrade from V55 or earlier: resetting Smart Mode learning"
  ui_print "    (classifier was fixed; old buckets were trained under the buggy"
  ui_print "     one). Your settings and device data are kept."
  ui_print "${SEPARATOR}"

  rm -f "$_asb_dir/buckets.bin" "$_asb_dir/buckets.bin.bak" \
        "$_asb_dir/pstats_balanced.json" "$_asb_dir/pstats_battery.json" \
        "$_asb_dir/smart_appheat.bin" \
        "$_asb_dir/session_history.jsonl" \
        "$_asb_dir/session_history_migrated_v47" \
        "$_asb_dir/auto_battery_state" 2>/dev/null || true

  : > "$_asb_dir/learning_reset_pending" 2>/dev/null || true

  mkdir -p "$_asb_dir" 2>/dev/null
  : > "$_marker" 2>/dev/null
  ui_print "      + learning reset; settings and device data preserved"
}

# Everything at stock, nothing applied - the state a module should be in before the user
# has opened its UI.
#
# This lived inside asb_preserve_user_config, below its early return. That return fires
# exactly when there is nothing to migrate - i.e. on a first install - so the block that
# was supposed to run on a first install was the one piece of code a first install could
# never reach. Reported twice: clean install, eleven switches on, Balanced active.
# Remember the OEM toggles exactly as we found them, before anything runs.
#
# Field report from a OnePlus 13: "every time I install the module, RAM expansion turns
# itself back on; I always keep it off". ASB does not enable it - UX_MANAGE_OEM_TOGGLES
# ships at 0 and every profile sets UX_RAM_EXPAND=0 - so something on the OxygenOS side
# reconsiders the setting when the memory configuration changes underneath it, which is
# exactly what installing this module does.
#
# Whatever the mechanism, the user's answer is knowable: it is whatever the toggle said
# before we arrived. Recorded here and re-asserted once on the next boot, then the
# record is dropped - enough to undo the side effect, not enough to keep fighting a
# user who later turns it on themselves.
asb_capture_oem_toggles() {
  command -v settings >/dev/null 2>&1 || return 0
  mkdir -p /data/adb/asb 2>/dev/null
  : > /data/adb/asb/oem_preinstall 2>/dev/null
  for _ok in ram_expand_size ram_expand_size_list ram_expand_switch_state; do
    _ov="$(settings get global "$_ok" 2>/dev/null)"
    # Record "unset" too, as the literal word null.
    #
    # Skipping it lost exactly the case that matters. OxygenOS stores RAM expansion OFF by
    # leaving these keys unset, so a user who had it off produced an EMPTY record - and the
    # restore, which bails on an empty file, never ran. They watched it switch itself back
    # on after every install and had to turn it off by hand. "Unset" is a state, not a
    # missing reading, and the restore knows how to put it back.
    case "$_ov" in
      ''|null) _ov=null ;;
    esac
    printf '%s|%s\n' "$_ok" "$_ov" >> /data/adb/asb/oem_preinstall 2>/dev/null
  done
  [ -s /data/adb/asb/oem_preinstall ] \
    && ui_print "      + remembered your OEM toggles as they are now"
}

asb_neutralise_fresh_install() {
  _new_conf="$MODPATH/config/governor.conf"
  [ -f "$_new_conf" ] || return 0
  for _neu in "bt_a2dp_offload=auto" "net_route_tune=off" "sustained_temp_mode=stock" \
              "phantom_procs=stock" "log_level=stock" \
              "camera_hold_enable=0" "auto_battery_enable=0" "charge_aware_enable=0" \
              "night_quiet_enable=0" "cool_gaming=0" "bat_suppress_gaming=0"; do
    _nk="${_neu%%=*}"; _nv="${_neu#*=}"
    grep -qE "^[[:space:]]*${_nk}=" "$_new_conf" 2>/dev/null \
      && sed -i "s|^[[:space:]]*${_nk}=.*|${_nk}=${_nv}|" "$_new_conf" 2>/dev/null
  done
  # Fresh installs begin in explicit Stock mode. Unlike an absent profile it is visible in
  # WebUI and remains selected across reboot, while profile_core/service keep CPU, GPU and
  # governor policy untouched until the user explicitly chooses an ASB profile.
  printf '%s\n' stock > "$MODPATH/current_profile" 2>/dev/null
  # Tell service.sh this absence is deliberate. Without it the boot-time restore from
  # /data/adb/asb/active_profile - which outlives module removal - would put the old
  # profile straight back and the module card would show it.
  mkdir -p /data/adb/asb 2>/dev/null
  : > /data/adb/asb/no_profile_chosen 2>/dev/null
  rm -f /data/adb/asb/active_profile /data/adb/asb/current_profile.bak 2>/dev/null
  ui_print "      + first install: Stock profile active; ASB CPU/GPU/governor policy is off"
  ui_print "        open the WebUI whenever you want to choose an ASB profile"
}

# Published after installation so diagnostics can distinguish a clean first install from
# a preserved upgrade. Defaults are intentionally explicit: no absent/ambiguous state.
ASB_CONFIG_MIGRATION_MODE=unknown
ASB_CONFIG_MIGRATION_SOURCE=none
ASB_CONFIG_MIGRATED_COUNT=0

asb_preserve_user_config() {
  _new_conf="$MODPATH/config/governor.conf"
  # Only create the shipped copy if the package did not bring one.
  #
  # This copied the ACTIVE config over the reference copy, and by this point the active
  # config is the user's - migrated from the previous install a few hundred lines above.
  # So every update overwrote the factory defaults with whatever the user had, and the
  # two things that depend on shipped stopped working:
  #   - "reset to defaults" restored the user's own settings, not the defaults
  #   - the missing-config recovery restored a config that could be as broken as the one
  #     it was replacing
  #
  # The release workflow ships governor.conf.shipped in the ZIP, so on a release build
  # there is nothing to create. This branch exists for debug builds, which ship
  # governor.conf instead - and there it must run BEFORE migration, not after.
  if [ ! -f "$MODPATH/config/governor.conf.shipped" ] && [ -f "$MODPATH/config/governor.conf" ]; then
    cp -f "$MODPATH/config/governor.conf" "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
    chmod 644 "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
  fi
  _old_conf="$NVBASE/modules/$MODID/config/governor.conf"
  # The modules_update fallback must never point at the file being installed.
  #
  # MODPATH during an install IS $NVBASE/modules_update/$MODID, so on a clean install -
  # where $NVBASE/modules/$MODID/config/governor.conf does not exist - this fallback
  # resolved to the config that was just unpacked. _src then pointed at the shipped
  # defaults, the run was treated as an upgrade, and the migration faithfully copied
  # those defaults onto themselves. Every switch stayed exactly as shipped, which is
  # what a clean install kept showing: Balanced active and eleven tweaks on.
  #
  # The fallback exists for a genuine case - an interrupted update leaves a previous
  # modules_update tree behind - so it is kept, and only the self-reference removed.
  if [ ! -f "$_old_conf" ]; then
    _cand="$NVBASE/modules_update/$MODID/config/governor.conf"
    [ "$_cand" = "$_new_conf" ] || _old_conf="$_cand"
  fi
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  for _stale_conf in "$_old_conf" "$_snap_conf"; do
    [ -f "$_stale_conf" ] && sed -i '/^[[:space:]]*device_bounds_override=/d' "$_stale_conf" 2>/dev/null || true
  done
  _src=""
  [ -f "$_old_conf" ] && _src="$_old_conf"
  # Root managers do not agree on update ordering. Some remove modules/<id> before
  # customize.sh runs while durable /data/adb/asb is still intact. The snapshot is
  # module-specific and written by ASB only after an atomic config transaction, so it
  # remains a valid source for that update path. A real uninstall runs uninstall.sh and
  # clears /data/adb/asb; a later clean install therefore still starts fresh.
  if [ -z "$_src" ] && [ -f "$_snap_conf" ]; then
    _src="$_snap_conf"
  fi
  if [ -z "$_src" ]; then
    # Nothing to migrate from: this is a first install, whatever else is on disk.
    ASB_CONFIG_MIGRATION_MODE=fresh
    ASB_CONFIG_MIGRATION_SOURCE=none
    asb_neutralise_fresh_install
    return 0
  fi

  ASB_CONFIG_MIGRATION_MODE=preserved
  if [ "$_src" = "$_snap_conf" ]; then ASB_CONFIG_MIGRATION_SOURCE=snapshot; else ASB_CONFIG_MIGRATION_SOURCE=module; fi

  # Upgrade: carry the power profile across.
  #
  # current_profile is a plain file, not a governor.conf key, so the migration below
  # never touched it - and the zip now ships "none", so without this an update would
  # quietly deselect whatever the user had running. It was lost when this block moved
  # into its own function; restored here, on the upgrade path where it belongs.
  for _cp_old in "$NVBASE/modules/$MODID/current_profile" \
                 /data/adb/asb/current_profile.bak; do
    [ -f "$_cp_old" ] || continue
    _cp_val="$(cat "$_cp_old" 2>/dev/null | tr -d " \r\n")"
    case "$_cp_val" in
      stock|performance|battery|balanced|smart|none)
        printf '%s\n' "$_cp_val" > "$MODPATH/current_profile" 2>/dev/null
        ui_print "      + kept your power profile: $_cp_val"
        break ;;
    esac
  done

  # Migrate the retired audio switches.
  # We therefore only promote to "hifi" when the user had deliberately turned EQ-compat OFF and
  # aggressive ON; the shipped EQ_COMPAT=1 default maps to "stock" so nobody's sound changes
  # silently on update.
  if ! grep -qE '^[[:space:]]*audio_profile=' "$_src" 2>/dev/null; then
    _oldeq="$(grep -E '^[[:space:]]*AUDIO_EQ_COMPAT=' "$_src" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    _oldag="$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' "$_src" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    if [ -n "$_oldeq$_oldag" ]; then
      if [ "$_oldeq" != "1" ] && [ "$_oldag" = "1" ]; then _newp="hifi"; else _newp="stock"; fi
      sed -i "s|^\([[:space:]]*audio_profile=\).*|\1$_newp|" "$MODPATH/config/governor.conf" 2>/dev/null
      if [ "$_oldag" = "1" ]; then
        sed -i "s|^\([[:space:]]*audio_dac_hifi=\).*|\11|" "$MODPATH/config/governor.conf" 2>/dev/null
      fi
      ui_print "      + ${ASB_D_MIGRATED:-audio settings migrated} (profile=${_newp}, hi-fi DAC=${_oldag:-0})"
    fi
  fi

  _user_keys="audio_profile audio_dac_hifi CAMERA_LEVEL CAMERA_GRAIN CAMERA_CONTRAST CAMERA_PORTRAIT CAMERA_LOWLIGHT CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias \
bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable \
night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale disable_blur ui_effects_level haptic_strength net_congestion net_qdisc net_route_tune net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile wifi_country wifi_scan_throttle radio_policy_enable net_handover_fast net_handover_active net_avoid_bad_wifi haptic_touch_strength media_loudness dsp_loudness dsp_bass dsp_compressor dsp_effect_abi sustained_temp_enter sustained_temp_mode sustained_temp_ceiling camera_hold_enable bt_a2dp_offload bat_suppress_gaming log_level log_verbosity doze_level phantom_procs anim_speed dsp_outputs gms_trim audio_remove_volume_limit purge_vendor_logs doze_trim_whitelist gms_freeze wakelock_action perf_ceiling_pct gnss_trim athena_service net_rps net_txqueue night_modem_idle smart_media_guard"

  _migrated=0
  # Which numbering the stored values were written against. Absent means "before schemas
  # existed", i.e. the 6-stop anim_speed scale. Written unconditionally after the loop, so
  # it never depends on which keys happened to be in the old config.
  _asb_anim_schema="$(cat /data/adb/asb/config_schema 2>/dev/null)"
  case "$_asb_anim_schema" in ''|*[!0-9]*) _asb_anim_schema=1 ;; esac
  # A config that already carries the 8-stop scale is on schema 2 whether or not the file
  # says so: V62-60 shipped the wider slider before schemas existed.
  #
  # Discriminate on gms_trim, which landed in the same release as the wider scale. The
  # first attempt looked for "0.95x" in a comment and for anim_speed=7|8 - neither works:
  # the scale never appears in governor.conf at all (it lives in the WebUI's max: attribute),
  # so that half matched nothing, and the numeric half only catches users who happened to
  # pick position 7 or 8. Someone on V62-60 sitting at 4-6, which is the entire case this
  # exists for, was still shifted. A key that either exists or does not is a fact; a string
  # in a comment is a guess about a file I did not check.
  #
  # Read from $_src, not $_old_conf: when the module directory is gone but the snapshot
  # survives, _src is the snapshot, and grepping the other one would silently skip the
  # detection for exactly those users.
  if [ "$_asb_anim_schema" -lt 2 ] 2>/dev/null \
     && grep -qE '^[[:space:]]*gms_trim=' "$_src" 2>/dev/null; then
    _asb_anim_schema=2
  fi

  for _k in $_user_keys; do
    _oldval="$(grep -E "^[[:space:]]*$_k=" "$_src" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
    if [ -z "$_oldval" ] && [ "$_src" != "$_snap_conf" ] && [ -f "$_snap_conf" ]; then
      _oldval="$(grep -E "^[[:space:]]*$_k=" "$_snap_conf" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
    fi
    [ -n "$_oldval" ] || continue

    # anim_speed: shift positions written against the 6-stop scale.
    #
    # V62 inserted 0.9x and 0.95x between 0.85x and stock, so everything from 4 up moved
    # by two: 4 meant stock and now means 0.9x, 5 meant 1.25x and now means 0.95x, 6 meant
    # 1.5x and now means stock. Carrying the raw number across would silently change the
    # animation speed of anyone sitting on 4-6.
    #
    # Keyed on a stored SCHEMA NUMBER, not on the existence of a marker file. Two reasons,
    # both found the hard way:
    #   - a marker written inside this loop only appears when the key was present in the
    #     old config, so a user who had never touched the slider got no marker, and their
    #     first deliberate 4 would be shifted to 6 by the NEXT update;
    #   - a marker cannot tell "config from the old scale" from "config already on the new
    #     scale but predating the marker" - V62-60 prereleases shipped the 8-stop scale
    #     with no marker, and those users would be shifted wrongly.
    # A number says which scale the stored value belongs to, which is the actual question.
    if [ "$_k" = "anim_speed" ] && [ "${_asb_anim_schema:-1}" -lt 2 ] 2>/dev/null; then
      case "$_oldval" in
        4|5|6) ui_print "      + animation speed remapped for the new scale (was ${_oldval})"
               _oldval=$(( _oldval + 2 )) ;;
      esac
    fi

    # Schema 3 narrows DSP Loudness to the compatible +18 dB maximum. Prior UI
    # values 19..25 could not be honored by the legacy effect and were silently
    # clamped; persist the same safe effective value explicitly on upgrade.
    if [ "$_k" = "dsp_loudness" ] && [ "${_asb_anim_schema:-1}" -lt 3 ] 2>/dev/null; then
      case "$_oldval" in
        *[!0-9]*|'') : ;;
        *) if [ "$_oldval" -gt 18 ] 2>/dev/null; then
             ui_print "      + DSP loudness capped at +18 dB (legacy-compatible maximum)"
             _oldval=18
           fi ;;
      esac
    fi

    if grep -qE "^[[:space:]]*$_k=" "$_new_conf" 2>/dev/null; then
      _esc="$(printf '%s' "$_oldval" | sed 's/[&/\|]/\\&/g')"
      sed -i "s|^\\([[:space:]]*$_k=\\).*|\\1$_esc|" "$_new_conf" 2>/dev/null \
        && _migrated=$((_migrated + 1))
    else
      printf '%s=%s\n' "$_k" "$_oldval" >> "$_new_conf"
      _migrated=$((_migrated + 1))
    fi
  done

  ASB_CONFIG_MIGRATED_COUNT=$_migrated
  # Stamp the schema regardless of what was migrated. This is the line whose absence made
  # the first attempt defer the bug by one update instead of fixing it.
  mkdir -p /data/adb/asb 2>/dev/null
  echo 3 > /data/adb/asb/config_schema 2>/dev/null
}

asb_snapshot_user_config() {
  _new_conf="$MODPATH/config/governor.conf"
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  mkdir -p "$(dirname "$_snap_conf")" 2>/dev/null || true
  _keys="audio_profile audio_dac_hifi CAMERA_LEVEL CAMERA_GRAIN CAMERA_CONTRAST CAMERA_PORTRAIT CAMERA_LOWLIGHT CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale disable_blur ui_effects_level haptic_strength net_congestion net_qdisc net_route_tune net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile wifi_country wifi_scan_throttle radio_policy_enable net_handover_fast net_handover_active haptic_touch_strength media_loudness dsp_loudness dsp_bass dsp_compressor dsp_effect_abi sustained_temp_enter sustained_temp_mode sustained_temp_ceiling camera_hold_enable bt_a2dp_offload bat_suppress_gaming log_level log_verbosity doze_level phantom_procs anim_speed dsp_outputs gms_trim audio_remove_volume_limit purge_vendor_logs doze_trim_whitelist gms_freeze wakelock_action perf_ceiling_pct gnss_trim athena_service net_rps net_txqueue night_modem_idle smart_media_guard"
  {
    echo "# ASB WebUI settings snapshot — survives module update/reinstall"
    for _k in $_keys; do
      _v="$(grep -E "^[[:space:]]*$_k=" "$_new_conf" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
      [ -n "$_v" ] && printf '%s=%s\n' "$_k" "$_v"
    done
  } > "$_snap_conf" 2>/dev/null
  chmod 644 "$_snap_conf" 2>/dev/null || true
  # Provenance makes cross-manager update continuity diagnosable from asbdiag.
  { echo "module_id=$MODID"; echo "snapshot_epoch=$(date +%s 2>/dev/null || echo 0)"; } > /data/adb/asb/update_snapshot_state 2>/dev/null || true
}

asb_prune_module() {
  local svc="$MODPATH/service.sh"
  local prop="$MODPATH/system.prop"
  local pfd="$MODPATH/post-fs-data.sh"

  for c in AUDIO BT NFC CAMERA MEDIA CPU VM NET WIFI GPS KERNEL LOG RADIO_IMS DISPLAY FPS SECURITY BG_TRIM; do
    asb_drop_block_if_off "$c" "$svc"
    asb_drop_block_if_off "$c" "$prop"
    asb_drop_block_if_off "$c" "$pfd"
  done

  if [ "${ASB_AUDIO}" != "true" ]; then
    rm -f  "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/audio_effects_config.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/a2dp_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/bluetooth_qti_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/bluetooth_qti_hearing_aid_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/virtual_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/ftm_mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_c2_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_google_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_google_c2_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_vendor_audio.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/audio_effects_config.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/ftm_mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/virtual_audio_policy_configuration.xml" 2>/dev/null || true
  fi

  if [ "${ASB_BT}" != "true" ]; then
    rm -f "$MODPATH/system/etc/permissions/Bluetooth.xml" 2>/dev/null || true
    rm -f "$MODPATH/system/etc/compatconfig/"*bluetooth*"xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/"*bluetooth*"xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/"*a2dp*"xml" 2>/dev/null || true
  fi

  if [ "${ASB_CAMERA}" != "true" ]; then
    rm -f "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  fi
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true
  rm -f  "$MODPATH/system/odm/etc/media_profiles"*".xml" 2>/dev/null || true

  if [ "${ASB_CPU}" != "true" ]; then
    rm -rf "$MODPATH/system/vendor/etc/perf" 2>/dev/null || true
  fi

  if [ "${ASB_WIFI}" != "true" ]; then
    rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/xtwifi.conf" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/xtwifi.conf" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  fi

  if [ "${ASB_GPS}" != "true" ]; then
    rm -f "$MODPATH/system/vendor/etc/lowi.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/gps" 2>/dev/null || true
  fi

  if [ "${ASB_KERNEL}" != "true" ]; then
    rm -f  "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true

    for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml usb_audio_policy_configuration.xml virtual_audio_policy_configuration.xml; do
      rm -f "$MODPATH/system/vendor/etc/${_f}" 2>/dev/null || true
    done
    rm -f  "$MODPATH/system/vendor/etc/"media_codecs_*_audio.xml 2>/dev/null || true

    rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true

    rm -rf "$MODPATH/system/vendor/etc/vendor" 2>/dev/null || true

    for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml virtual_audio_policy_configuration.xml; do
      rm -f "$MODPATH/system/vendor/odm/etc/${_f}" 2>/dev/null || true
    done
    rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
  fi

  if [ "${ASB_LOG}" != "true" ]; then
    rm -rf "$MODPATH/system/etc/init" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/mem_logger_config.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/etc/init" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/init" 2>/dev/null || true
  fi

  find "$MODPATH/system" -type d -empty -print -delete 2>/dev/null || true
}

# Defaults, overridden below by whatever the shipped features.conf says.
#
# These were plain `true` and the generated features.conf is written from them, so the
# file in the ZIP was overwritten on every install. A build that deliberately ships
# BT=0 or VENDOR_OVERLAY=0 - which this one does, for eight features - had that choice
# silently reversed, and the installed module ran with everything on.
#
# Reading the shipped file first makes it the source of truth it was meant to be: a
# packager can disable a feature for a build, and the installer honours it.
_asb_feat_from_zip() {
  _ff="$MODPATH/features.conf"
  [ -f "$_ff" ] || return 0
  _fv="$(grep -E "^[[:space:]]*$1=" "$_ff" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r' | cut -d'#' -f1)"
  case "$_fv" in
    0) printf 'false' ;;
    1) printf 'true' ;;
    *) printf '%s' "$2" ;;
  esac
}

ASB_AUDIO="$(_asb_feat_from_zip AUDIO true)"
ASB_BT="$(_asb_feat_from_zip BT true)"
ASB_NFC="$(_asb_feat_from_zip NFC true)"
ASB_CAMERA="$(_asb_feat_from_zip CAMERA true)"
ASB_MEDIA="$(_asb_feat_from_zip MEDIA true)"
ASB_CPU="$(_asb_feat_from_zip CPU true)"
ASB_VM="$(_asb_feat_from_zip VM true)"
ASB_NET="$(_asb_feat_from_zip NET true)"
ASB_WIFI="$(_asb_feat_from_zip WIFI true)"
ASB_GPS="$(_asb_feat_from_zip GPS true)"
ASB_KERNEL="$(_asb_feat_from_zip KERNEL true)"
ASB_LOG="$(_asb_feat_from_zip LOG true)"
ASB_RADIO_IMS="$(_asb_feat_from_zip RADIO_IMS true)"
ASB_DISPLAY="$(_asb_feat_from_zip DISPLAY true)"
ASB_FPS="$(_asb_feat_from_zip FPS true)"
ASB_SECURITY="$(_asb_feat_from_zip SECURITY true)"
ASB_BG_TRIM="$(_asb_feat_from_zip BG_TRIM true)"
# These two had no variable at all: features.conf hardcoded LPM=1 / VENDOR_OVERLAY=1 while
# asb_save_user_config wrote LPM=0 / VENDOR_OVERLAY=0 - it evaluated a variable that did not
# exist, so it recorded a phantom "the user declined" that no user ever chose, and the
# end-of-install banner left both out of the enabled list while both were in fact running.
ASB_LPM="$(_asb_feat_from_zip LPM true)"
ASB_VENDOR_OVERLAY="$(_asb_feat_from_zip VENDOR_OVERLAY true)"

asb_install_prebuilt_governor
asb_big_banner

for _mroot in /data/adb/modules /data/adb/modules_update \
              /data/adb/ksu/modules /data/adb/ksu/modules_update \
              /data/adb/ap/modules /data/adb/ap/modules_update; do
  rm -f  "$_mroot/.AutoSystemBoost-files" 2>/dev/null
  rm -rf "$_mroot/AutoSystemBoost/CLEAR" 2>/dev/null
done

# Installation is deliberately non-interactive. Every capability-gated component is kept in
# the module so WebUI can enable it later, but configuration migration below decides whether
# existing settings are preserved or a clean install starts from stock defaults.
#
# Old versions persisted installer category answers in this file. They only controlled which
# assets were copied at install time, made a fresh install ask fifteen volume-key questions,
# and were independent of the actual WebUI settings. Do not reuse those historical choices:
# a user's current governor.conf is the upgrade source of truth.
asb_prepare_webui_first_install() {
  rm -f /data/adb/asb/user_config /data/adb/asb_user_config 2>/dev/null || true
  ui_print "  ${ASB_INSTALL_WEBUI_FIRST:-Full component set prepared; optional tweaks remain at stock.}"
  ui_print "  ${ASB_INSTALL_WEBUI_HINT:-After reboot, open WebUI and enable only the options you want.}"
}
asb_prepare_webui_first_install

# MUST come before any stage that reads governor.conf (audio: DSP registration and
# volume curves; camera: level). See asb_preserve_user_config for why.
ui_print " "
ui_print "  💾  ${ASB_SEC_CONFIG:-CONFIG}"
asb_reset_learning_on_upgrade_to_v56
asb_capture_oem_toggles
asb_preserve_user_config

if [ -n "${ASB_GOV_ABI:-}" ]; then
  ui_print " "
  ui_print "  🧠  ${ASB_SEC_GOVERNOR:-GOVERNOR}"
  ui_print "      + ${ASB_D_GOV:-native C governor daemon} (${ASB_GOV_ABI})"
fi

asb_detect_compat
asb_detect_manager
ui_print " "
ui_print "  🔍  ${ASB_SEC_DEVICE:-DEVICE}"
ui_print "      + ${ASB_D_IDENTIFIED:-identified}: ${ASB_DEVICE_NAME:-unknown}"
_soc="$(asb_prop_first ro.soc.model ro.board.platform 2>/dev/null)"
[ -n "$_soc" ] && ui_print "      + ${ASB_D_SOC:-SoC}: ${_soc}"
if [ "${ASB_IS_APATCH:-false}" = "true" ]; then _mgr="APatch"
elif [ -n "${KSU:-}" ] || [ -d /data/adb/ksu ]; then _mgr="KernelSU"
elif [ -d /data/adb/magisk ] || [ -n "${MAGISK_VER:-}" ]; then _mgr="Magisk"
else _mgr=""; fi
[ -n "$_mgr" ] && ui_print "      + ${ASB_D_MANAGER:-root manager}: ${_mgr}"
if [ "$ASB_IS_OP15" = "true" ]; then
  ui_print "      + ${ASB_D_FULL_PKG:-full OnePlus 15 device-native package}"
fi
asb_prune_module

if [ -f "$MODPATH/tools/asb_install_probe.sh" ]; then
  sh "$MODPATH/tools/asb_install_probe.sh" "$MODPATH/install_probe.txt" >/dev/null 2>&1 || true
  cp -f "$MODPATH/install_probe.txt" /data/adb/asb/install_probe.txt 2>/dev/null || true
  if [ -f "$MODPATH/install_probe.txt" ]; then
    ui_print "      + ${ASB_D_STOCK_ANALYSIS:-stock-file analysis:}"
    sed -n '/SUMMARY (what ASB can tune/,/Inventory only/p' "$MODPATH/install_probe.txt" 2>/dev/null \
      | grep -E '^[[:space:]]+(audio|wifi|perf|gps|camera|cpu)[[:space:]]+:' \
      | while IFS= read -r _line; do ui_print "        $_line"; done
  fi
fi

if [ "$ASB_IS_OP15" = "true" ]; then
  asb_apply_device_native_tuning "${ASB_DEVICE_NAME:-OnePlus} (canoe)" "OnePlus15"

elif [ "$ASB_IS_OP13" = "true" ]; then
  asb_apply_device_native_tuning "${ASB_DEVICE_NAME:-OnePlus} (sun / tuna / kera)" "OnePlus13"
elif [ "$ASB_IS_OP12" = "true" ]; then
  for _stale in \
      "$NVBASE/modules/$MODID/system/odm/etc/camera" \
      "$NVBASE/modules_update/$MODID/system/odm/etc/camera" \
      "$MODPATH/system/odm/etc/camera"; do
    [ -e "$_stale" ] && rm -rf "$_stale" 2>/dev/null || true
  done
  for _stalemp in \
      "$NVBASE/modules/$MODID/system/odm/etc/media_profiles"*.xml \
      "$NVBASE/modules_update/$MODID/system/odm/etc/media_profiles"*.xml; do
    [ -e "$_stalemp" ] && rm -f "$_stalemp" 2>/dev/null || true
  done
  # Label from the device, not from the platform.
  #
  # This branch covers every SM8650 phone - pineapple and cliffs - and printed "OnePlus 12"
  # for all of them. An Ace 5 owner saw their model detected correctly on one line and
  # "installation for OnePlus 12" on the next, which reads like the module got confused
  # about what it is running on. It did not: the tuning is per-platform and correct. Only
  # the label was wrong, and a wrong label on an install screen costs trust that the rest
  # of the output then has to earn back.
  #
  # ASB_DEVICE_NAME is already resolved above from the vendor's own marketing name.
  asb_apply_device_native_tuning "${ASB_DEVICE_NAME:-OnePlus} (pineapple / cliffs)" "OnePlus12"
else
  asb_prune_non_op15_vendor_overlays
  if [ "$ASB_IS_ONEPLUS" = "true" ]; then
    if [ -f /data/adb/asb/vendor_overlay_blocked ] && [ ! -f /data/adb/asb/vendor_overlay_retry_done ]; then
      rm -f /data/adb/asb/vendor_overlay_blocked 2>/dev/null
      : > /data/adb/asb/vendor_overlay_retry_done 2>/dev/null
      ui_print "[*] Non-reference OnePlus: retrying the device overlay once with the odm-safe generator"
    fi
    if [ -f /data/adb/asb/vendor_overlay_blocked ]; then
      ui_print "[*] Non-reference OnePlus: a previous device overlay failed to boot here — staying governor-only"
      ui_print "    (delete /data/adb/asb/vendor_overlay_blocked to let the next install try again)"
      rm -rf "$MODPATH/system/vendor" "$MODPATH/system/odm" 2>/dev/null || true
      for _gen_stale in \
          "$NVBASE/modules/$MODID/system/vendor" \
          "$NVBASE/modules/$MODID/system/odm" \
          "$NVBASE/modules_update/$MODID/system/vendor" \
          "$NVBASE/modules_update/$MODID/system/odm"; do
        [ -e "$_gen_stale" ] && rm -rf "$_gen_stale" 2>/dev/null || true
      done
    else
      echo generic > "$MODPATH/overlay_device_class" 2>/dev/null
      asb_apply_device_native_tuning "$ASB_DEVICE_NAME" "OnePlus"
      rm -rf "$MODPATH/system/odm" "$MODPATH/system/my_product" 2>/dev/null || true
      ui_print "[*] preparing odm runtime binds"
      asb_generate_odm_binds
      ui_print "[*] Non-reference OnePlus: device-native patched overlay, guarded by a 1-strike boot fuse"
    fi
  fi
fi
asb_register_dsp_all_configs

# The final camera clone/normalization pass can run after the first dynamic-tweak pass. Re-run
# the idempotent retouch injector here, immediately before the /odm bind payload is materialised:
# this makes the file copied into /data/adb/asb/odm_patched the same file that carries the full
# app list, rather than a later stock clone with only Discord/Teams/WeChat/WhatsApp.
if [ "$ASB_CAMERA" = "true" ] && [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
  command -v asb_tw_vb_add_apps >/dev/null 2>&1 || . "$MODPATH/runtime/asb_tweaks.sh"
  _asb_vb_final_n=0
  for _asb_vb_final in \
    "$MODPATH/system/odm/etc/camera/config/video_beauty_default_config" \
    "$MODPATH/system/vendor/odm/etc/camera/config/video_beauty_default_config"; do
    [ -f "$_asb_vb_final" ] || continue
    asb_tw_vb_add_apps "$_asb_vb_final"
    _asb_vb_final_n=$((_asb_vb_final_n + 1))
  done
  [ "$_asb_vb_final_n" -gt 0 ] && ui_print "      + ${ASB_D_RETOUCH:-retouch apps}: final camera bind payload verified"
fi
asb_generate_odm_camera_binds

# A real install came back with a zero-byte regular file named "vendor" sitting in the module
# root.
if [ -f "$MODPATH/vendor" ] && [ ! -s "$MODPATH/vendor" ]; then
  rm -f "$MODPATH/vendor" 2>/dev/null
fi

# Fall back to the DEVICE, not to "reference".
#
# The generic marker is written inside the OnePlus overlay branch, so several cases
# never reached it and landed here instead: a non-OnePlus device, one whose overlay is
# blocked by the boot fuse, and any path where that branch is skipped. All were then
# labelled "reference" - the OP15 marker - and offered OP15-only options such as flat
# effects, which on other models removes the Recents Cards/Simple selector.
#
# Only the OP15 is the reference model, so ask that directly. It matters now because
# everyone upgrading from V60 has this file written for the first time.
if [ ! -f "$MODPATH/overlay_device_class" ]; then
  if [ "${ASB_IS_OP15:-false}" = "true" ]; then
    echo reference > "$MODPATH/overlay_device_class" 2>/dev/null
  else
    echo generic > "$MODPATH/overlay_device_class" 2>/dev/null
  fi
fi
rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true

_gc="$MODPATH/config/governor.conf"
if [ -f "$_gc" ]; then
  _asb_plat="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
  if [ "$ASB_IS_OP15" = "true" ]; then
    sed -i 's/^device_bounds_override=.*/device_bounds_override=1/' "$_gc" 2>/dev/null || true
    ui_print "      + ${ASB_D_BOUNDS:-device-adaptive bounds: ON (OP15 — matches shipped tuning)}"
  else
    case "$_asb_plat" in
      *"sm8650"*|*"pineapple"*)
        # SM8650 1+3+2+1 (Ace5 / OP12 family): the global OP15-shaped rails pin the main
        # interactive cluster low in battery/smart mode (~52%), which reads as UI lag.
        sed -i 's/^device_bounds_override=.*/device_bounds_override=1/' "$_gc" 2>/dev/null || true
        ui_print "[*] Device-adaptive bounds: ON (SM8650 — interactive-cluster caps leaned up to remove battery-mode lag)" ;;
      *)
        # On by default everywhere else too.
        #
        # This branch shipped 0, so every model that was not an OP15 or an SM8650 ran on
        # the compiled OP15 rails. A OnePlus 13 field report showed what that costs: its
        # policy0 covers cpu0-5 and its frequency table has no 1190400 at all, so the cap
        # the profile asked for did not exist on the device and six cores ran unrestrained
        # - heat and drain, on the one model that most needed the caps to fit.
        #
        # The synthesis is not a guess: asb_synthesize_bounds.sh scales the OP15 ratios to
        # THIS device's hardware ceiling and then snaps every value to a frequency the
        # table actually lists. Verified on that OP13: it produced 1555200 / 1401600 for
        # battery, both real entries in its own table, and the caps then held.
        #
        # Off remains reachable through the WebUI for anyone who wants the reference rails.
        sed -i 's/^device_bounds_override=.*/device_bounds_override=1/' "$_gc" 2>/dev/null || true
        ui_print "[*] Device-adaptive bounds: ON (caps scaled to this device's own frequency table)" ;;
    esac
  fi
fi

asb_localize_region() {
  _cc=""
  _src="none"
  for _p in gsm.sim.operator.iso-country gsm.operator.iso-country; do
    _v="$(getprop "$_p" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    case "$_v" in
      [A-Z][A-Z]) _cc="$_v"; _src="$([ "$_p" = "gsm.sim.operator.iso-country" ] && echo sim || echo operator)"; break ;;
    esac
  done

  if [ -z "$_cc" ]; then
    _allow_locale="$(grep -E '^[[:space:]]*region_allow_locale=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
    if [ "$_allow_locale" = "1" ]; then
      _loc="$(getprop ro.product.locale 2>/dev/null)"
      case "$_loc" in
        *-[A-Za-z][A-Za-z]) _cc="$(echo "$_loc" | sed 's/.*-//' | tr '[:lower:]' '[:upper:]')"; _src="locale" ;;
      esac
    fi
  fi

  ASB_REGION_SOURCE="$_src"
  ASB_REGION_APPLIED="unchanged"

  for _gf in $(find "$MODPATH/system" -type f -iname "gps.conf" 2>/dev/null); do
    [ -f "$_gf" ] && sed -i "s|^NTP_SERVER=.*|NTP_SERVER=pool.ntp.org|g" "$_gf" 2>/dev/null
  done

  if [ -z "$_cc" ]; then
    return 0
  fi

  _wrote=0
  for _wf in $(find "$MODPATH/system" -type f \( -iname "WCNSS_qcom_cfg*.ini" \) 2>/dev/null); do
    [ -f "$_wf" ] || continue
    if grep -q "^gCountryCode=" "$_wf" 2>/dev/null; then
      sed -i "s/^gCountryCode=.*/gCountryCode=$_cc/g" "$_wf" 2>/dev/null && _wrote=1
    fi
  done
  for _wf in $(find "$MODPATH/system" -type f \( -iname "wpa_supplicant*.conf" -o -iname "p2p_supplicant*.conf" \) 2>/dev/null); do
    [ -f "$_wf" ] || continue
    if grep -q "^country=" "$_wf" 2>/dev/null; then
      sed -i "s/^country=.*/country=$_cc/g" "$_wf" 2>/dev/null && _wrote=1
    fi
  done
  if [ "$_wrote" = "1" ]; then
    ASB_REGION_APPLIED="$_cc"
  else
    ASB_REGION_APPLIED="unchanged (modem-driven regdomain)"
  fi
}
asb_localize_region

asb_apply_bt_absvol() {
  _prop="$MODPATH/system.prop"
  [ -f "$_prop" ] || return 0
  _mode="$(grep -E '^[[:space:]]*bt_absvol_mode=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  case "$_mode" in
    on)            _mode="disabled" ;;
    disabled)      _mode="disabled" ;;
    auto|off|''|*) _mode="stock" ;;
  esac
  if [ "$_mode" = "disabled" ]; then _val="true"; else _val="false"; fi
  sed -i "s/^persist.bluetooth.disableabsvol=.*/persist.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  sed -i "s/^persist.vendor.bluetooth.disableabsvol=.*/persist.vendor.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  if [ "$_mode" = "stock" ]; then
    sed -i '/^persist\.bluetooth\.enablenewavrcp=/d' "$_prop" 2>/dev/null
    ASB_BT_ABSVOL_APPLIED="mode=stock (absolute volume ON — loud, synced)"
    return 0
  fi
  ASB_BT_ABSVOL_APPLIED="mode=disabled (absolute volume OFF — phone-side gain)"
  ui_print "      + ${ASB_D_BT:-BT absolute volume: disabled (phone drives gain)}"
  ui_print "        ${ASB_D_BT_NOTE:-(headset drives its own level; use 'stock' if BT starts quiet)}"
}
[ "$ASB_BT" = "true" ] && asb_apply_bt_absvol

# Build the blur block into system.prop at INSTALL time, not in post-fs-data.
#
# Why install time is the only correct place: the root manager (KernelSU here, Magisk too)
# reads $MODPATH/system.prop when it MOUNTS the module, which happens BEFORE post-fs-data.sh
# runs.
# ro.* props are read once at process start and cannot be changed afterwards, which is why the
# runtime resetprop calls were rejected too (5/5 ro.* not applied).
asb_apply_blur_prop() {
  # The installer may be the first ASB code that touches this user-visible setting. Source the
  # same reversible ledger used at runtime before an explicit blur-off write; stock setup must
  # not overwrite a pre-existing user choice just because the module was installed.
  if [ -f "$MODPATH/runtime/asb_baseline.sh" ]; then
    MODDIR="$MODPATH"
    . "$MODPATH/runtime/asb_baseline.sh"
  fi
  _asb_install_setting_put() {
    if command -v asb_settings_put >/dev/null 2>&1; then asb_settings_put "$@"; else settings put "$@" >/dev/null 2>&1; fi
  }
  _prop="$MODPATH/system.prop"
  [ -f "$_prop" ] || : > "$_prop"
  _db="$(grep -E '^[[:space:]]*disable_blur=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # stock | light | off, with 0/1 still meaning stock/off.
  # install-time and runtime must agree on the vocabulary or the setting reverts on the next
  # boot.
  case "$_db" in
    1|on|true|off|light|partial) _db=1 ;;
    *)                           _db=0 ;;
  esac
  # Rewrite the managed block from scratch every install so the WebUI toggle drives it.
  # Also strip any BARE (unmarked) copies of these props first: an earlier build wrote them
  # straight into system.prop without markers, and without this cleanup a fresh install would
  # leave both the old bare lines and the new managed block, i.e.
  _pt="${_prop}.asbblur$$"
  sed -e '/^# ASB:BLUR:BEGIN$/,/^# ASB:BLUR:END$/d' \
      -e '/^ro\.surface_flinger\.supports_background_blur=/d' \
      -e '/^ro\.surface_flinger\.media_panel_bg_blur=/d' \
      -e '/^ro\.oplus\.display\.disable\.volume_blur=/d' \
      -e '/^ro\.oplus\.gaussianlevel=/d' \
      -e '/^ro\.launcher\.blur\.appLaunch=/d' \
      -e '/^persist\.sys\.oplus\.anim_level=/d' \
      -e '/^persist\.sys\.oplus\.material_blur_switch=/d' \
      -e '/^persist\.sys\.sf\.disable_blurs=/d' \
      -e '/^vendor\.display\.supports_background_blur=/d' \
      -e '/^persist\.sys\.oplus\.anim_level=/d' \
      -e '/^# ASB:UIFX:BEGIN$/,/^# ASB:UIFX:END$/d' \
      "$_prop" > "$_pt" 2>/dev/null || cp -f "$_prop" "$_pt"
  {
    echo "# ASB:BLUR:BEGIN"
    # Must match runtime/asb_blur_apply.sh exactly - this is the same block written by a
    # second implementation, and the two drifting apart is how a setting ends up behaving
    # differently after an install than after a WebUI change.
    #
    # OFF only: these are global kill switches. persist.sys.sf.disable_blurs is what
    # SurfaceFlinger reads to turn blur off entirely, and every blurred surface goes
    # through SurfaceFlinger - including the backdrop behind a notification.
    if [ "$_db" = "1" ]; then
      echo "persist.sys.sf.disable_blurs=1"
      echo "ro.surface_flinger.supports_background_blur=0"
      echo "ro.surface_flinger.media_panel_bg_blur=0"
      echo "persist.sys.oplus.material_blur_switch=false"
      echo "vendor.display.supports_background_blur=0"
    fi
    # OFF and LIGHT: targeted keys, each naming one surface. Dropping these leaves the
    # notification backdrop readable, which is what light is for. anim_level is NOT here -
    # it is the OEM effects level, not blur, and it lives in ui_effects_level now.
    if [ "$_db" = "1" ]; then
      echo "ro.oplus.display.disable.volume_blur=1"
      echo "ro.oplus.gaussianlevel=0"
      echo "ro.launcher.blur.appLaunch=0"
    fi
    echo "# ASB:BLUR:END"
    # ui_effects_level, in its own block - the installer has to write this as well.
    #
    # asb_blur_apply.sh owns it at runtime, but a reinstall rebuilds system.prop from scratch
    # here, and a block this file never writes is a block that disappears.
    # The setting would survive in governor.conf and silently stop being applied, which is the
    # same shape as the media_loudness bug: config says one thing, system does another, and
    # nothing reports a problem.
    echo "# ASB:UIFX:BEGIN"
    _ue="$(grep -E '^[[:space:]]*ui_effects_level=' "$MODPATH/config/governor.conf" 2>/dev/null \
           | head -1 | sed 's/.*=//' | tr -d ' \r')"
    # Same rule as runtime/asb_blur_apply.sh: an absent or unrecognised value follows
    # blur, so an existing install that only ever set disable_blur keeps the behaviour it
    # had. An explicit stock or flat is honoured.
    case "$_ue" in
      flat|0)  echo "persist.sys.oplus.anim_level=0" ;;
      stock|1) : ;;
      # Only an EXPLICIT flat writes anim_level.
      #
      # This used to follow blur when the value was absent - which is the default - so
      # switching blur off also flattened Recents and removed the Cards/Simple selector from
      # Recent Tasks Manager.
      # A OnePlus 13 user lost that option without ever touching a Recents setting, and
      # reinstalling never brought it back because this copy of the rule rewrote the property
      # again on every install.
      *)       : ;;
    esac
    echo "# ASB:UIFX:END"
  } >> "$_pt"
  mv -f "$_pt" "$_prop" 2>/dev/null || { cat "$_pt" > "$_prop"; rm -f "$_pt"; }
  if [ "$_db" = "1" ]; then
    # WindowManager watches this global live. It is a global switch too, so light must
    # NOT set it: that is the one that takes the backdrop out from behind notifications.
    _asb_install_setting_put global disable_window_blurs 1 || true
    ui_print " "
    ui_print "  🖥  ${ASB_SEC_DISPLAY:-DISPLAY}"
    ui_print "      + ${ASB_D_BLUR:-blur disabled via system.prop (applies after reboot)}"
    ASB_BLUR_APPLIED="disabled"
  else
    # Fresh/default stock must be a true no-touch path. A prior explicit ASB blur change is
    # restored by its recorded baseline when the user returns the control to stock.
    ASB_BLUR_APPLIED="stock (no WindowManager setting write)"
  fi
}
asb_apply_blur_prop

cat > "$MODPATH/features.conf" <<EOF
AUDIO=$([ "$ASB_AUDIO" = "true" ] && echo 1 || echo 0)
BT=$([ "$ASB_BT" = "true" ] && echo 1 || echo 0)
NFC=$([ "$ASB_NFC" = "true" ] && echo 1 || echo 0)
CAMERA=$([ "$ASB_CAMERA" = "true" ] && echo 1 || echo 0)
MEDIA=$([ "$ASB_MEDIA" = "true" ] && echo 1 || echo 0)
CPU=$([ "$ASB_CPU" = "true" ] && echo 1 || echo 0)
VM=$([ "$ASB_VM" = "true" ] && echo 1 || echo 0)
NET=$([ "$ASB_NET" = "true" ] && echo 1 || echo 0)
WIFI=$([ "$ASB_WIFI" = "true" ] && echo 1 || echo 0)
GPS=$([ "$ASB_GPS" = "true" ] && echo 1 || echo 0)
KERNEL=$([ "$ASB_KERNEL" = "true" ] && echo 1 || echo 0)
LOG=$([ "$ASB_LOG" = "true" ] && echo 1 || echo 0)
LPM=$([ "$ASB_LPM" = "true" ] && echo 1 || echo 0)
RADIO_IMS=$([ "$ASB_RADIO_IMS" = "true" ] && echo 1 || echo 0)
DISPLAY=$([ "$ASB_DISPLAY" = "true" ] && echo 1 || echo 0)
FPS=$([ "$ASB_FPS" = "true" ] && echo 1 || echo 0)
SECURITY=$([ "$ASB_SECURITY" = "true" ] && echo 1 || echo 0)
BG_TRIM=$([ "$ASB_BG_TRIM" = "true" ] && echo 1 || echo 0)
VENDOR_OVERLAY=$([ "$ASB_VENDOR_OVERLAY" = "true" ] && echo 1 || echo 0)
EOF

{
  echo "ASB install summary"
  echo "date:            $(date 2>/dev/null || echo n/a)"
  echo "module version:  $(grep -E '^version=' "$MODPATH/module.prop" 2>/dev/null | sed 's/version=//')"
  if [ "$ASB_IS_OP15" = "true" ]; then _dev="OnePlus 15 (full shipped overlay)";
  elif [ "$ASB_IS_OP13" = "true" ]; then _dev="OnePlus 13 (op13 overlay)";
  elif [ "$ASB_IS_OP12" = "true" ]; then _dev="OnePlus 12 (op12 overlay)";
  else _dev="generic OnePlus (sed patches only, vendor overlay pruned)"; fi
  echo "device detected: $_dev"
  echo "  model=$ASB_MODEL_RAW device=$ASB_DEVICE_RAW platform=$(getprop ro.board.platform 2>/dev/null)"
  echo "region source:   ${ASB_REGION_SOURCE:-none}"
  echo "region applied:  ${ASB_REGION_APPLIED:-unchanged}"
  echo "bt absvol:       ${ASB_BT_ABSVOL_APPLIED:-not-applied (BT category off)}"
  echo "camera/media:    $([ "$ASB_CAMERA" = "true" ] && echo applied || echo skipped)"
  echo "gps overlay:     $([ "$ASB_GPS" = "true" ] && echo applied || echo skipped)"
  echo "wifi localized:  $([ "${ASB_REGION_APPLIED:-unchanged}" != "unchanged" ] && echo yes || echo no)"
  echo "audio category:  $([ "$ASB_AUDIO" = "true" ] && echo on || echo off)"
} > "$MODPATH/install_summary.txt" 2>/dev/null
cp -f "$MODPATH/install_summary.txt" /data/adb/asb/install_summary.txt 2>/dev/null || true

if [ -f "$MODPATH/tools/asb_discover.sh" ]; then
  sh "$MODPATH/tools/asb_discover.sh" >/dev/null 2>&1 || true
fi

if [ -f "$MODPATH/tools/asb_synthesize_bounds.sh" ]; then
  sh "$MODPATH/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1 || true
fi

echo 0 > "/data/adb/asb/vendor_boot_counter" 2>/dev/null
# A fresh install must start from a clean slate: drop any skip_mount left by a
# previous build's fuse (it would suppress the whole module incl. asbdiag/webui/
# governor on a device that now boots), and clear a stale generic block/flag.
rm -f "$MODPATH/skip_mount" 2>/dev/null
# vendor_overlay_retry_done is deliberately NOT cleared here.
#
# It is the memory behind the one-retry rule earlier in this file: the first time the overlay
# is found blocked, unblock it and try once more; if it fails again, stay governor-only.
# Wiping it on every install meant that memory never reached the next one, so "!
rm -f /data/adb/asb/vendor_overlay_blocked /data/adb/asb/vendor_overlay_active 2>/dev/null
rm -f "/data/adb/asb/vendor_overlay_active" 2>/dev/null

  for module in $MODPATH/system
  do
    for dir in 'my_product' 'vendor/odm'
    do
      if [[ -d $module/$dir ]]; then
        # Debug echo removed: it printed a raw module path straight into the user-facing
        # install report, between DISPLAY and VIBRATION, where it means nothing to the
        # reader. What it announced is already covered by the sections themselves.
        map_files "$module" "$dir"
      fi
    done
  done

ASB_xml() {
  asb_has_xmlstarlet || return 0
  local Name0=$(echo "$3" | sed -r "s|^.*/.*\[@(.*)=\".*\".*$|\1|")
  local Value0=$(echo "$3" | sed -r "s|^.*/.*\[@.*=\"(.*)\".*$|\1|")
  [ "$(echo "$4" | grep '=')" ] && Name1=$(echo "$4" | sed "s|=.*||") || local Name1="value"
  local Value1=$(echo "$4" | sed "s|.*=||")
  case $1 in
  "-s"|"-u"|"-i")
    local SNP=$(echo "$3" | sed -r "s|(^.*/.*)\[@.*=\".*\".*$|\1|")
    local NP=$(dirname "$SNP")
    local SN=$(basename "$SNP")
	if [ "$5" ]; then
      [ "$(echo "$5" | grep '=')" ] && local Name2=$(echo "$5" | sed "s|=.*||") || local Name2="value"
      local Value2=$(echo "$5" | sed "s|.*=||")
	fi
	if [ "$6" ]; then
      [ "$(echo "$6" | grep '=')" ] && local Name3=$(echo "$6" | sed "s|=.*||") || local Name3="value"
      local Value3=$(echo "$6" | sed "s|.*=||")
	fi
	if [ "$7" ]; then
      [ "$(echo "$7" | grep '=')" ] && local Name4=$(echo "$7" | sed "s|=.*||") || local Name4="value"
      local Value4=$(echo "$7" | sed "s|.*=||")
	fi
  ;;
  esac
  case "$1" in
    "-d") xmlstarlet ed -L -d "$3" "$2";;
    "-u") xmlstarlet ed -L -u "$3/@$Name1" -v "$Value1" "$2";;
    "-s")
  	if asb_has_xmlstarlet && [ "$(xmlstarlet sel -t -m "$3" -c . "$2")" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -u "$3/@$Name1" -v "$Value1" "$2"
      else
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -r "$SNP-$MODID" -v "$SN" "$2"
  	fi;;
    "-i")
  	if asb_has_xmlstarlet && [ "$(xmlstarlet sel -t -m "$3[@$Name1=\"$Value1\"]" -c . "$2")" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -d "$3[@$Name1=\"$Value1\"]" "$2"
  	fi
  	if [ -z "$Value3" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -r "$SNP-$MODID" -v "$SN" "$2"
      elif [ "$Value4" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -i "$SNP-$MODID" -t attr -n "$Name3" -v "$Value3" \
        -i "$SNP-$MODID" -t attr -n "$Name4" -v "$Value4" \
        -r "$SNP-$MODID" -v "$SN" "$2"
      elif [ "$Value3" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -i "$SNP-$MODID" -t attr -n "$Name3" -v "$Value3" \
        -r "$SNP-$MODID" -v "$SN" "$2"
  	fi
      ;;
  esac
}


MPATHS="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "*mixer_path*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APINF="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACONFS="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_configs*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
AEFFECT="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_effects*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_cloud_control*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_policy_configuration*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
A2DPXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "a2dp*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VEHXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "vehicle*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VIRTXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "virtual*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
USBXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "usb*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTQTIXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bluetooth*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APIOCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_output_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "audio_io_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bt_configstore*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF2="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bt_stack*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
MEDCA="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "media_codecs*audio.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
SNDTRPL="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "sound_trigger_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "resourcemanager*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
if [ -f /data/adb/asb/vendor_overlay_blocked ]; then
  A2DPXML=""; ACCXML=""; ACONFS=""; AEFFECT=""; APCXML=""; APINF=""; APIOCXML=""; BTCONF=""; BTCONF2=""; BTQTIXML=""; MEDCA=""; MPATHS=""; SNDTRPL=""; USBXML=""; VEHXML=""; VIRTXML=""
fi
# Structural audio/BT XML sed-tuning is verified only against OP15/OP13/OP12 stock.
# Ace 6 on the OP15 platform, matched via shared model codes) carry a DIFFERENT audio stock,
# and applying the reference seds there corrupted vendor HAL configs (field bootloop).
_asb_audio_ref=0
_asb_ref_skus=""
[ "$ASB_IS_OP15" = "true" ] && _asb_ref_skus="sku_canoe sku_alor"
[ "$ASB_IS_OP13" = "true" ] && _asb_ref_skus="sku_sun sku_kera sku_tuna"
[ "$ASB_IS_OP12" = "true" ] && _asb_ref_skus="sku_pineapple sku_cliffs"
_asb_sibling=0
if [ -n "$_asb_ref_skus" ]; then
  for _ad in /vendor/etc/audio /system/vendor/etc/audio /odm/etc/audio; do
    [ -d "$_ad" ] || continue
    for _sk in $_asb_ref_skus; do
      ls -d "$_ad/$_sk"* >/dev/null 2>&1 && _asb_audio_ref=1
    done
  done
else
  # Generic path: a platform sibling can carry a KNOWN reference audio stock (field: Ace 6 =
  # ossi/SM8750 ships the OP13 sun/kera/tuna tree, verified byte-identical on the structural
  # files).
  for _ad in /vendor/etc/audio /system/vendor/etc/audio /odm/etc/audio; do
    [ -d "$_ad" ] || continue
    for _sk in sku_canoe sku_alor sku_sun sku_kera sku_tuna sku_pineapple sku_cliffs; do
      ls -d "$_ad/$_sk"* >/dev/null 2>&1 && { _asb_audio_ref=1; _asb_sibling=1; _asb_sib_fam="$_sk"; }
    done
  done
  [ "$_asb_sibling" = "1" ] && ui_print "[*] Known reference audio stock on sibling device (family: ${_asb_sib_fam#sku_}) - full structural tuning enabled, deferred-activation safety stays on"
fi
if [ "$_asb_audio_ref" != "1" ]; then
  A2DPXML=""; ACONFS=""; AEFFECT=""; APCXML=""; APINF=""; APIOCXML=""; BTCONF=""; BTCONF2=""; BTQTIXML=""; DAXXML=""; SNDTRPL=""; USBXML=""; VEHXML=""; VIRTXML=""
  if [ -n "$_asb_ref_skus" ]; then
    ui_print "[*] Reference match without native audio stock (platform sibling) - structural audio/BT XML patches skipped; mixer/codec/GPS/Wi-Fi tuning stays on"
  else
    ui_print "[*] Non-reference OnePlus: structural audio/BT XML patches skipped; mixer/codec/GPS/Wi-Fi tuning stays on"
  fi
fi

mkdir -p $MODPATH/tools
EXTTOOLS="$MODPATH/common/addon/External-Tools/tools/$ARCH32"
if [ -d "$EXTTOOLS" ] && ls "$EXTTOOLS"/* >/dev/null 2>&1; then
  mkdir -p "$MODPATH/tools"
  cp -af "$EXTTOOLS"/* "$MODPATH/tools/" >/dev/null 2>&1 || true
fi

  for OACCXML in ${ACCXML}; do
  	ACCXM=$MODPATH${OACCXML}
	cp_ch $ORIGDIR$OACCXML $ACCXM
	sedi "/^ *$/d" $ACCXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
  	SNDTRP=$MODPATH${OSNDTRPL}
	cp_ch $ORIGDIR$OSNDTRPL $SNDTRP
	sedi "/^ *$/d" $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
  	MEDCX=$MODPATH${OMEDCX}
	cp_ch $ORIGDIR$OMEDCX $MEDCX
	sedi "/^ *$/d" $MEDCX
	done

  for OMIX in ${MPATHS}; do
  	MIX=$MODPATH${OMIX}
	cp_ch $ORIGDIR$OMIX $MIX
	sedi "/^ *$/d" $MIX
	done

  if [ "${ASB_BT}" = "true" ]; then
  for OA2DPXML in ${A2DPXML}; do
  	A2DPXM=$MODPATH${OA2DPXML}
	cp_ch $ORIGDIR$OA2DPXML $A2DPXM
	sedi '/^ *$/d' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
  	BTQTIXM=$MODPATH${OBTQTIXML}
	cp_ch $ORIGDIR$OBTQTIXML $BTQTIXM
	sedi '/^ *$/d' $BTQTIXM
	done

  fi

  for OVEHXML in ${VEHXML}; do
  	VEHXM=$MODPATH${OVEHXML}
	cp_ch $ORIGDIR$OVEHXML $VEHXM
	sedi "/^ *$/d" $VEHXM
	done

  for OVIRTXML in ${VIRTXML}; do
  	VIRTXM=$MODPATH${OVIRTXML}
	cp_ch $ORIGDIR$OVIRTXML $VIRTXM
	sedi "/^ *$/d" $VIRTXM
	done

  for OUSBXML in ${USBXML}; do
  	USBXM=$MODPATH${OUSBXML}
	cp_ch $ORIGDIR$OUSBXML $USBXM
	sedi "/^ *$/d" $USBXM
	done

  for OAPCXM in ${APCXML}; do
  	APCXM=$MODPATH${OAPCXM}
	cp_ch $ORIGDIR$OAPCXM $APCXM
	sedi "/^ *$/d" $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
  	APIOCXM=$MODPATH${OAPIOCXM}
	cp_ch $ORIGDIR$OAPIOCXM $APIOCXM
	sedi "/^ *$/d" $APIOCXM
	done

  for OAPLI in ${APINF}; do
  	APLI=$MODPATH${OAPLI}
	cp_ch $ORIGDIR$OAPLI $APLI
	sedi "/^ *$/d" $APLI
	done

  for OACONF in ${ACONFS}; do
  	ACONF=$MODPATH${OACONF}
	cp_ch $ORIGDIR$OACONF $ACONF
	sedi "/^ *$/d" $ACONF
	done

  _v4a_lib=""
  for _vd in /vendor/lib64/soundfx /vendor/lib/soundfx \
             /odm/lib64/soundfx /odm/lib/soundfx \
             /system/lib64/soundfx /system/lib/soundfx \
             /system/vendor/lib64/soundfx /system/vendor/lib/soundfx; do
    if [ -f "$_vd/libv4a_re.so" ]; then _v4a_lib="$_vd/libv4a_re.so"; break; fi
  done
  for OAEFFECT in ${AEFFECT}; do
  	EFFECT=$MODPATH${OAEFFECT}
	sedi '/"audiosphere"/d' $EFFECT
	if [ -n "$_v4a_lib" ]; then
	  sedi '/effect name="volume"/d' $EFFECT
	  sedi '/"dvl"/d' $EFFECT
	  sedi '/"agc"/d' $EFFECT
	  sedi '/"volume_listener"/d' $EFFECT
	  sedi '/"audio_pre_processing"/d' $EFFECT
	  sedi '/v4a_standard_re/d' $EFFECT
	  sedi '/v4a_re/d' $EFFECT
	  sedi '/<libraries>/ a\\        <library name=\\"v4a_re\\" path=\\"libv4a_re.so\\"\\/>' $EFFECT
	  sedi '/<effects>/ a\\        <effect name=\\"v4a_standard_re\\" library=\\"v4a_re\\" uuid=\\"90380da3-8536-4744-a6a3-5731970e640f\\"\\/>' $EFFECT
	fi
	done

  for OACCXML in ${ACCXML}; do
  	ACCXM=$MODPATH${OACCXML}
	sedi '/<kara_app_name_list>/a\
        <com.neutroncode.mp/>\
        <ru.yandex.music/>\
        <com.hitrolab.audioeditor/>\
        <com.google.android.youtube/>\
        <com.google.android.youtube.music/>\
        <com.mxtech.videoplayer/>\
        <com.mxtech.videoplayer.pro/>\
        <com.spotify.music/>\
        <com.apple.android.music/>\
        <deezer.android.app/>\
        <com.vkontakte.android/>\
        <com.uma.musicvk/>\
        <com.vk.clips/>\
        <ru.ok.android/>\
        <com.facebook.katana/>\
        <com.instagram.android/>\
        <tunein.player/>\
        <free.zaycev.net/>\
        <fm.last.android/>\
        <com.aspiro.tidal/>\
        <com.qobuz.music/>\
        <com.extreamsd.usbaudioplayerpro/>\
        <com.zvooq.openplay/>\
        <com.jetappfactory.jetaudio/>\
        <com.jetappfactory.jetaudioplus/>\
		<ru.mts.music.android/>\
        <com.maxmpz.audioplayer/>' $ACCXM
	sedi '/<record_unsilence_app_name_list>/a\
        <com.SearingMedia.Parrot/>\
        <com.hitrolab.audioeditor/>' $ACCXM
	done
	
  if [ "${ASB_BT}" = "true" ]; then
  for OBTCONF in ${BTCONF}; do
  	BTCON=$MODPATH${OBTCONF}
	sedi 's/aacFrameCtlEnabled = true/aacFrameCtlEnabled = false/g' $BTCON
	done

  for OBTCONF2 in ${BTCONF2}; do
  	BTCON2=$MODPATH${OBTCONF2}
	sedi 's/TraceConf=true/TraceConf=false/g' $BTCON2
	sedi 's/TRC_BTM=2/TRC_BTM=0/g' $BTCON2
	sedi 's/TRC_HCI=2/TRC_HCI=0/g' $BTCON2
	sedi 's/TRC_L2CAP=2/TRC_L2CAP=0/g' $BTCON2
	sedi 's/TRC_RFCOMM=2/TRC_RFCOMM=0/g' $BTCON2
	sedi 's/TRC_OBEX=2/TRC_OBEX=0/g' $BTCON2
	sedi 's/TRC_AVCT=2/TRC_AVCT=0/g' $BTCON2
	sedi 's/TRC_AVDT=2/TRC_AVDT=0/g' $BTCON2
	sedi 's/TRC_AVRC=2/TRC_AVRC=0/g' $BTCON2
	sedi 's/TRC_AVDT_SCB=2/TRC_AVDT_SCB=0/g' $BTCON2
	sedi 's/TRC_AVDT_CCB=2/TRC_AVDT_CCB=0/g' $BTCON2
	sedi 's/TRC_A2D=2/TRC_A2D=0/g' $BTCON2
	sedi 's/TRC_SDP=2/TRC_SDP=0/g' $BTCON2
	sedi 's/TRC_SMP=2/TRC_SMP=0/g' $BTCON2
	sedi 's/TRC_BTAPP=2/TRC_BTAPP=0/g' $BTCON2
	sedi 's/TRC_BTIF=2/TRC_BTIF=0/g' $BTCON2
	sedi 's/TRC_BNEP=2/TRC_BNEP=0/g' $BTCON2
	sedi 's/TRC_PAN=2/TRC_PAN=0/g' $BTCON2
	sedi 's/TRC_HID_HOST=2/TRC_HID_HOST=0/g' $BTCON2
	sedi 's/TRC_HID_DEV=2/TRC_HID_DEV=0/g' $BTCON2
	sedi 's/TRC_GATT=2/TRC_GATT=0/g' $BTCON2
	done

  fi

  for ODAXXML in ${DAXXML}; do
  	DAXXM=$MODPATH${ODAXXML}
	sedi 's/mi-dv-leveler-steering-enable value="true"/mi-dv-leveler-steering-enable value="false"/g' $DAXXM
	sedi 's/mi-surround-compressor-steering-enable value="true"/mi-surround-compressor-steering-enable value="false"/g' $DAXXM
	sedi 's/mi-dialog-enhancer-steering-enable value="false"/mi-dialog-enhancer-steering-enable value="true"/g' $DAXXM
	sedi 's/mi-ieq-steering-enable value="false"/mi-ieq-steering-enable value="true"/g' $DAXXM
	sedi 's/mi-adaptive-virtualizer-steering-enable value="false"/mi-adaptive-virtualizer-steering-enable value="true"/g' $DAXXM
	sedi 's/low-filter-mode value="1"/low-filter-mode value="0"/g' $DAXXM
	sedi 's/band-filter-mode value="1"/band-filter-mode value="0"/g' $DAXXM
	sedi 's/middle-filter-mode value="1"/middle-filter-mode value="0"/g' $DAXXM
	sedi 's/height-filter-mode value="1"/height-filter-mode value="0"/g' $DAXXM
	sedi 's/volume-leveler-compressor-enable value="true"/volume-leveler-compressor-enable value="false"/g' $DAXXM
	sedi 's/hearing-protection-enable value="true"/hearing-protection-enable value="false"/g' $DAXXM
	sedi 's/regulator-speaker-dist-enable value="true"/regulator-speaker-dist-enable value="false"/g' $DAXXM
	sedi 's/bass-mbdrc-enable value="true"/bass-mbdrc-enable value="false"/g' $DAXXM
	sedi 's/bass-extraction-enable value="true"/bass-extraction-enable value="false"/g' $DAXXM
	sedi 's/reverb-suppression-enable value="true"/reverb-suppression-enable value="false"/g' $DAXXM
	sedi 's/audio-optimizer-enable value="true"/audio-optimizer-enable value="false"/g' $DAXXM
	sedi 's/regulator-sibilance-suppress-enable value="true"/regulator-sibilance-suppress-enable value="false"/g' $DAXXM
	sedi 's/ieq-enable value="true"/ieq-enable value="false"/g' $DAXXM
	sedi 's/complex-equalizer-enable value="true"/complex-equalizer-enable value="false"/g' $DAXXM
	sedi 's/virtual-bass-process-enable value="true"/virtual-bass-process-enable value="false"/g' $DAXXM
	sedi 's/virtualizer-enable value="true"/virtualizer-enable value="false"/g' $DAXXM
	sedi 's/bass-enhancer-enable value="false"/bass-enhancer-enable value="true"/g' $DAXXM
	sedi 's/dialog-enhancer-enable value="true"/dialog-enhancer-enable value="false"/g' $DAXXM
	sedi 's/graphic-equalizer-enable value="false"/graphic-equalizer-enable value="true"/g' $DAXXM
	sedi 's/surround-decoder-enable value="false"/surround-decoder-enable value="true"/g' $DAXXM
	sedi 's/volume-leveler-enable value="false"/volume-leveler-enable value="true"/g' $DAXXM
	sedi 's/volume-modeler-enable value="true"/volume-modeler-enable value="false"/g' $DAXXM
	sedi 's/tuned_rate="48000"/tuned_rate="96000"/g' $DAXXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
  	SNDTRP=$MODPATH${OSNDTRPL}
	sedi 's/"hifi_filter" value="false"/"hifi_filter" value="true"/g' $SNDTRP
	sedi 's/ec_ref="true"/ec_ref="false"/g' $SNDTRP
	sedi 's/support_nlpi_switch="false"/support_nlpi_switch="true"/g' $SNDTRP
	sedi 's/transit_to_non_lpi_on_charging="false"/transit_to_non_lpi_on_charging="true"/g' $SNDTRP
	sedi 's/support_non_lpi_without_ec="true"/support_non_lpi_without_ec="false"/g' $SNDTRP
	sedi 's/low_latency_bargein_enable="false"/low_latency_bargein_enable="true"/g' $SNDTRP
	sedi 's/enable_debug_dumps="true"/enable_debug_dumps="false"/g' $SNDTRP
	sedi 's/acd_enable="false"/acd_enable="true"/g' $SNDTRP
	sedi '/logging_level/d' $SNDTRP
	sedi 's/mmap_enable="false"/mmap_enable="true"/g' $SNDTRP
	sedi 's/"enc"/"enc|dec"/g' $SNDTRP
	sedi 's/"dec"/"enc|dec"/g' $SNDTRP
	sedi 's/sidetone_mode>HW/sidetone_mode>OFF/g' $SNDTRP
	sedi 's/sidetone_mode>SW/sidetone_mode>OFF/g' $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
  	MEDCX=$MODPATH${OMEDCX}
	sedi 's/name="sample-rate" ranges="8000,11025,12000,16000,22050,24000,32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="7350,8000,11025,12000,16000,22050,24000,32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-96000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-192000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="bitrate-modes" value="CBR"/name="bitrate-modes" value="CQ"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="9"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="8"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="7"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="6"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="7"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="6"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="5"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="4"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="quality" range="0-80"  default="100"/name="quality" range="0-100"  default="100"/g' $MEDCX
	sedi 's/name="bitrate" range="8000-320000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="8000-960000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-500000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="6000-510000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="1-10000000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="500-512000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-640000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-6144000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="16000-2688000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="64000"/name="bitrate" range="1-18000000"/g' $MEDCX
	done

  for OAPLI in ${APINF}; do
  	APLI=$MODPATH${OAPLI}
	sedi 's/bit_width="16"/bit_width="32"/g' $APLI
	sedi 's/bit_width="24"/bit_width="32"/g' $APLI
	sedi '/<bit_width_configs/a\
    <device name="SND_DEVICE_OUT_SPEAKER" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_HEADPHONES" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_SPEAKER_REVERSE" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_SPEAKER_PROTECTED" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_HEADPHONES_44_1" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_GAME_SPEAKER" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_GAME_HEADPHONES" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_BT_A2DP" bit_width="32"/>' $APLI
	done

  for OA2DPXML in ${A2DPXML}; do
  	A2DPXM=$MODPATH${OA2DPXML}
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $A2DPXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $A2DPXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $A2DPXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $A2DPXM
	sedi 's/samplingRates="44100"/samplingRates="96000"/g' $A2DPXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $A2DPXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $A2DPXM
	sedi 's/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink">/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
  	BTQTIXM=$MODPATH${OBTQTIXML}
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100"/samplingRates="96000"/g' $BTQTIXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $BTQTIXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $BTQTIXM
	sedi 's/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink">/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	done

  for OUSBXML in ${USBXML}; do
  	USBXM=$MODPATH${OUSBXML}
	sedi 's/samplingRates="44100"/samplingRates="48000"/g' $USBXM
	done

  for OAPCXM in ${APCXML}; do
  	APCXM=$MODPATH${OAPCXM}
	sedi 's/AUDIO_FORMAT_PCM_32_BIT/AUDIO_FORMAT_PCM_FLOAT/g' $APCXM
	sedi 's/samplingRates="44100"/samplingRates="48000"/g' $APCXM
	sedi 's/samplingRates="44100,48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/samplingRates="44100,48000,96000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/g' $APCXM
	sedi 's/samplingRates="44100 48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/samplingRates="44100 48000 96000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_FAST|AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW|AUDIO_OUTPUT_FLAG_FAST/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_FAST AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW AUDIO_OUTPUT_FLAG_FAST/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/name="raw"/name="none"/g' $APCXM
	sedi 's/,raw//g' $APCXM
	sedi 's/raw,//g' $APCXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $APCXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $APCXM
	sedi 's/speaker_drc_enabled="true"/speaker_drc_enabled="false"/g' $APCXM
	sedi 's/samplingRates="32000,44100,48000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="32000,44100,48000,64000,88200,96000,128000,176400,192000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $APCXM
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $APCXM
	sedi 's/samplingRates="32000 44100 48000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="32000 44100 48000 64000 88200 96000 128000 176400 192000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $APCXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_MONO"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_MONO"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi '/^ *#/d; /^ *$/d' $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
  	APIOCXM=$MODPATH${OAPIOCXM}
	sedi 's/sampling_rates 44100|48000|88200|96000|176400|192000|352800|384000/sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000/g' $APIOCXM
	sedi 's/sampling_rates 32000|44100|48000|88200|96000|176400|192000|352800/sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000/g' $APIOCXM
	sedi 's/AUDIO_FORMAT_PCM_32_BIT/AUDIO_FORMAT_PCM_FLOAT/g' $APIOCXM
	sedi '/AUDIO_FORMAT_MP3/a\
AutoSystemBoost' $APIOCXM
	sedi '/AutoSystemBoost/,+1d' $APIOCXM
	sedi '/AUDIO_FORMAT_MP3/a\
    sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000' $APIOCXM
	sedi '/proaudio/,+6d' $APIOCXM
	done

  for OMIX in ${MPATHS}; do
  	MIX=$MODPATH${OMIX}
	sedi 's/IIR0 Enable Band1" value="1"/IIR0 Enable Band1" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band2" value="1"/IIR0 Enable Band2" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band3" value="1"/IIR0 Enable Band3" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band4" value="1"/IIR0 Enable Band4" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band5" value="1"/IIR0 Enable Band5" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band1" value="1"/IIR1 Enable Band1" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band2" value="1"/IIR1 Enable Band2" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band3" value="1"/IIR1 Enable Band3" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band4" value="1"/IIR1 Enable Band4" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band5" value="1"/IIR1 Enable Band5" value="0"/g' $MIX
	sedi 's/"Voice Sidetone Enable" value="1"/"Voice Sidetone Enable" value="0"/g' $MIX
	sedi 's/COMP Switch" value="1"/COMP Switch" value="0"/g' $MIX
	sedi 's/COMP0 Switch" value="1"/COMP0 Switch" value="0"/g' $MIX
	sedi 's/COMP1 Switch" value="1"/COMP1 Switch" value="0"/g' $MIX
	sedi 's/COMP2 Switch" value="1"/COMP2 Switch" value="0"/g' $MIX
	sedi 's/COMP3 Switch" value="1"/COMP3 Switch" value="0"/g' $MIX
	sedi 's/COMP4 Switch" value="1"/COMP4 Switch" value="0"/g' $MIX
	sedi 's/COMP5 Switch" value="1"/COMP5 Switch" value="0"/g' $MIX
	sedi 's/COMP6 Switch" value="1"/COMP6 Switch" value="0"/g' $MIX
	sedi 's/COMP7 Switch" value="1"/COMP7 Switch" value="0"/g' $MIX
	sedi 's/COMP8 Switch" value="1"/COMP8 Switch" value="0"/g' $MIX
	sedi 's/Softclip0 Enable" value="1"/Softclip0 Enable" value="0"/g' $MIX
	sedi 's/Softclip1 Enable" value="1"/Softclip1 Enable" value="0"/g' $MIX
	sedi 's/Softclip2 Enable" value="1"/Softclip2 Enable" value="0"/g' $MIX
	sedi 's/Softclip3 Enable" value="1"/Softclip3 Enable" value="0"/g' $MIX
	sedi 's/Softclip4 Enable" value="1"/Softclip4 Enable" value="0"/g' $MIX
	sedi 's/Softclip5 Enable" value="1"/Softclip5 Enable" value="0"/g' $MIX
	sedi 's/Softclip6 Enable" value="1"/Softclip6 Enable" value="0"/g' $MIX
	sedi 's/Softclip7 Enable" value="1"/Softclip7 Enable" value="0"/g' $MIX
	sedi 's/Softclip8 Enable" value="1"/Softclip8 Enable" value="0"/g' $MIX
	sedi 's/HPHL_RDAC Switch" value="0"/HPHL_RDAC Switch" value="1"/g' $MIX
	sedi 's/HPHR_RDAC Switch" value="0"/HPHR_RDAC Switch" value="1"/g' $MIX
	sedi 's/"RX INT0 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT0 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT1 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT1 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT2 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT2 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT3 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT3 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT4 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT4 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi '/EC Reference SampleRate/d' $MIX
	sedi '/EC Reference Bit Format/d' $MIX
	sedi 's/Digital Volume" value="87"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="86"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="85"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="84"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="83"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="82"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="81"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="80"/Digital Volume" value="88"/g' $MIX
	sedi '/HPHL Volume/d' $MIX
	sedi '/HPHR Volume/d' $MIX
	ASB_xml -s $MIX '/mixer/ctl[@name="HPHL Volume"]' "20"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPHR Volume"]' "20"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPHL"]' "Switch"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPHR"]' "Switch"
	ASB_xml -u $MIX '/mixer/ctl[@name="Load acoustic model"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Audiosphere Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="Audiosphere Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set HPX OnOff"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set HPX OnOff"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set HPX ActiveBe"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set HPX ActiveBe"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="DS2 OnOff"]' "On"
	ASB_xml -s $MIX '/mixer/ctl[@name="DS2 OnOff"]' "On"
	ASB_xml -u $MIX '/mixer/ctl[@name="THD3 Compensation"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="THD3 Compensation"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="MSM ASphere Set Param"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="MSM ASphere Set Param"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Codec Wideband"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Codec Wideband"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set Custom Stereo OnOff"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set Custom Stereo OnOff"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="HiFi Function"]' "On"
	ASB_xml -s $MIX '/mixer/ctl[@name="HiFi Function"]' "On"
	ASB_xml -u $MIX '/mixer/ctl[@name="Virtual Bass Boost"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="Virtual Bass Boost"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX0 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX1 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX2 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX3 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX4 EC_HQ Switch"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT1 SEC MIX HPHL Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT2 SEC MIX HPHR Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT1 MIX3 DSD HPHL Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT2 MIX3 DSD HPHR Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPH Idle Detect"]' "ON"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPH Idle Detect"]' "ON"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BDE Enable"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="BDE Enable"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Amp DSP Enable"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Amp DSP Enable"]' "1"
	sedi 's/RX_FIR Filter" value="ON"/RX_FIR Filter" value="OFF"/g' $MIX
	sedi 's/VBAT Enable" value="1"/VBAT Enable" value="0"/g' $MIX
	done

  for OACONF in ${ACONFS}; do
  	ACONF=$MODPATH${OACONF}
	ASB_xml -u $ACONF '/configs/property[@name="audio.offload.disable"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="av.offload.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="audio.offload.video"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.av.streaming.offload.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.offload.multiple.enabled"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.offload.track.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.path.for.pcm.voip"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.alac.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.ape.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.mpegh.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.flac.sw.decoder.24bit"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="persist.vendor.audio.sva.conc.enabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="persist.vendor.audio.va_concurrency_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.conc.fallbackpath"]' "deep-buffer"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.rec.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.dsd.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.record.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.voip.conc.disabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="voice_concurrency"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_extn_formats_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_extn_hdmi_spk_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="aac_adts_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="alac_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="ape_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="flac_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="pcm_offload_enabled_16"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="pcm_offload_enabled_24"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="qti_flac_decoder"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="vorbis_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="wma_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="fm_power_opt"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="a2dp_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="anc_headset_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_zoom_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audiosphere_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="battery_listener_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="custom_stereo_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="dsm_feedback_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_hw_plugin_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_qdsp_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_spkr_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_spkr_tfa_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="hfp_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="hifi_audio_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="hwdep_cal_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="keep_alive_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="kpi_optimize_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="maxx_audio_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="record_play_concurrency"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="spkr_prot_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="snd_monitor_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="use_deep_buffer_as_primary_output"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="vbat_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="wsa_enabled"]' "true"
	done

	if [ "${ASB_KERNEL}" = "true" ]; then
	  # Only when explicitly asked. See audio_remove_volume_limit in governor.conf - this
	  # is a hearing-safety cap, and removing it silently is not a decision a performance
	  # module gets to make for someone.
	  if [ "$(grep -E '^[[:space:]]*audio_remove_volume_limit=' "$MODPATH/config/governor.conf" 2>/dev/null \
	          | head -1 | sed 's/.*=//' | tr -d ' \r')" = "1" ]; then
	    settings put global audio_safe_volume_state 0
	    ui_print "      ! headphone volume limiter removed - protect your hearing"
	  fi
	fi
	
	if [ -d "$MODPATH/tools" ]; then
	  # Whitelist prune: everything at the top of tools/ that is not named here is deleted at
	  # install time.
	  # Two user-facing tools were shipped by CI, verified present in the package, and then
	  # removed right here - so asb_camera_repair.sh never existed on any device that was told to
	  # run it, and asb_sysui_watch.sh came back "No such file or directory".
	#
	# asb_discover.sh is on this list because service.sh runs it at boot to build the
	# capability manifest before the native governor starts. The call is guarded with
	# [ -f ], so deleting it did not break the boot - it just silently skipped the step,
	# and the governor came up without the derived policy it was meant to have.
	  find "$MODPATH/tools" -maxdepth 1 -type f \
	    ! -name "asb_state_sampler.sh" \
	    ! -name "asb_drain_analyzer.sh" \
	    ! -name "asb_doctor.sh" \
	    ! -name "asb_lint.sh" \
	    ! -name "asb_session_report.py" \
	    ! -name "asb_compare_sessions.py" \
	    ! -name "asb_analyze.py" \
	    ! -name "asb_camera_repair.sh" \
	    ! -name "asb_sysui_watch.sh" \
	    ! -name "asb_diag.sh" \
	    ! -name "asb_discover.sh" \
	    ! -name "asb_synthesize_bounds.sh" \
	    ! -name "asb_recents_probe.sh" \
	    ! -name "asb_config_backup.sh" \
	    ! -name "asb_kernel_uv_coexist.sh" \
	    -delete 2>/dev/null
	  # WebUI runs these helpers by path after installation. Keep them above the prune line;
	  # packaging alone is insufficient when this allowlist deletes unrecognised top-level tools.
	  chmod 0755 "$MODPATH/tools/asb_camera_repair.sh" 2>/dev/null || true
	  chmod 0755 "$MODPATH/tools/asb_sysui_watch.sh" 2>/dev/null || true
	  chmod 0755 "$MODPATH/tools/asb_config_backup.sh" 2>/dev/null || true
	  chmod 0755 "$MODPATH/tools/asb_kernel_uv_coexist.sh" 2>/dev/null || true
	fi

	# Vendor log cleanup - explicit paths, and only when asked for.
	#
	# This was a series of unescaped globs three levels into /data - /data/*/*/*bsplog*/*
	# and friends - running silently during install under a category that is on by default.
	# The patterns are specific enough that in practice they hit vendor log directories, but
	# "in practice" is not a property you want on a recursive delete: a glob three levels
	# deep in /data will eventually match something nobody predicted, and the operation is
	# not reversible.
	#
	# Two changes. The paths are now a literal list, so what gets deleted is readable rather
	# than inferred. And it is gated on its own key rather than riding along with LOG, so
	# nobody deletes files as a side effect of wanting quieter logging.
	if [ "$(grep -E '^[[:space:]]*purge_vendor_logs=' "$MODPATH/config/governor.conf" 2>/dev/null \
	        | head -1 | sed 's/.*=//' | tr -d ' \r')" = "1" ]; then
	  for _lp in \
	    /data/anr \
	    /data/mlog \
	    /data/klog \
	    /data/ap-log \
	    /data/cp-log \
	    /data/last_alog \
	    /data/last_kmsg \
	    /data/dontpanic \
	    /data/memorydump \
	    /data/dumplog \
	    /data/tombstones \
	    /data/vendor/tombstones \
	    /data/vendor/bsplog \
	    /data/vendor/ramdump \
	    /data/vendor/log \
	  ; do
	    [ -d "$_lp" ] || continue
	    # -mindepth 1 deletes the contents and keeps the directory: several of these are
	    # created by init with specific ownership, and removing the directory itself makes
	    # the vendor daemon that owns it fail quietly on the next boot.
	    find "$_lp" -mindepth 1 -delete 2>/dev/null || true
	  done
	  # Dropbox keeps the five newest entries - it is the one place where recent crash
	  # reports are worth keeping for the user's own debugging.
	  for _dbdir in /data/system/dropbox /data/vendor/dropbox; do
	    [ -d "$_dbdir" ] || continue
	    ls -t "$_dbdir" 2>/dev/null | tail -n +6 | while read -r _f; do
	      rm -f "$_dbdir/$_f" 2>/dev/null || true
	    done
	  done
	  ui_print "      + vendor log directories cleared (purge_vendor_logs=1)"
	fi

	ASB_WEB_MODEL_CODE="$(getprop ro.product.model 2>/dev/null)"
	[ -z "$ASB_WEB_MODEL_CODE" ] && ASB_WEB_MODEL_CODE="$(getprop ro.product.name 2>/dev/null)"
	[ -z "$ASB_WEB_MODEL_CODE" ] && ASB_WEB_MODEL_CODE="UNKNOWN"

	ASB_WEB_NAME_CODE="$(getprop ro.product.name 2>/dev/null)"
	[ -z "$ASB_WEB_NAME_CODE" ] && ASB_WEB_NAME_CODE="$(getprop ro.product.device 2>/dev/null)"
	[ -z "$ASB_WEB_NAME_CODE" ] && ASB_WEB_NAME_CODE="UNKNOWN"

	ASB_WEB_SOC_CODE="$(getprop ro.soc.model 2>/dev/null)"
	[ -z "$ASB_WEB_SOC_CODE" ] && ASB_WEB_SOC_CODE="$(getprop ro.board.platform 2>/dev/null)"
	[ -z "$ASB_WEB_SOC_CODE" ] && ASB_WEB_SOC_CODE="UNKNOWN"

	mkdir -p "$MODPATH/webroot" 2>/dev/null
	cat > "$MODPATH/webroot/device_info.json" <<EOF
{
  "model_code": "$ASB_WEB_MODEL_CODE",
  "name_code": "$ASB_WEB_NAME_CODE",
  "soc_code": "$ASB_WEB_SOC_CODE"
}
EOF

	if [ -f "$MODPATH/runtime/profile_core.sh" ]; then
		chmod 0755 "$MODPATH/runtime/profile_core.sh"
	fi

	for _rt in asb_media_apply.sh asb_volume_curves.sh asb_audio_apply.sh asb_blur_apply.sh asb_lpm.sh asb_dsp_abi_apply.sh asb_haptics_apply.sh asb_camera_grade.sh asb_system_tweaks.sh asb_anim_apply.sh asb_gms_trim.sh asb_gms_freeze.sh asb_wakelock_watch.sh asb_bt_link_watch.sh asb_apply_ledger.sh asb_trial.sh asb_policy_preview.sh asb_screenoff_class.sh asb_smart_reset.sh asb_gnss_trim.sh asb_log_apply.sh asb_doze_apply.sh asb_net_offload.sh asb_athena_apply.sh asb_settings.sh asb_net_apply.sh asb_net_routes.sh asb_wifi_fallback.sh smart_dynamic_tune.sh asb_reconcile.sh asb_watchdog.sh asb_config_safe.sh asb_device_tier.sh asb_device_pack_manifest.sh asb_apply_managed_props.sh asb_quick_restart.sh asb_boot_timeline.sh asb_debug_support.sh asb_stock_policy.sh; do
		[ -f "$MODPATH/runtime/$_rt" ] && chmod 0755 "$MODPATH/runtime/$_rt"
	done

	if [ -f "$MODPATH/system/bin/asb" ]; then
	  chmod 0755 "$MODPATH/system/bin/asb"
	fi
	if [ -f "$MODPATH/system/bin/asbtrial" ]; then
	  chmod 0755 "$MODPATH/system/bin/asbtrial"
	fi

	if [ -f "$MODPATH/tools/asb_discover.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_discover.sh"
	fi

	if [ -f "$MODPATH/tools/asb_synthesize_bounds.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_synthesize_bounds.sh"
	fi

	if [ -f "$MODPATH/system/bin/asbdiag" ]; then
	  chmod 0755 "$MODPATH/system/bin/asbdiag"
	fi
	if [ -f "$MODPATH/tools/asb_diag.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_diag.sh"
	fi
	if [ -f "$MODPATH/tools/asb_effective_policy.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_effective_policy.sh"
	fi
	if [ -f "$MODPATH/tools/asb_verify_device.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_verify_device.sh"
	fi

	if [ -f "$MODPATH/bin/asb" ]; then
	  chmod 0755 "$MODPATH/bin/asb"
	fi

	asb_prune_module
	find $MODPATH -empty -type d -delete

	if [ -d "$MODPATH/system" ]; then
	  _man="$MODPATH/generated_overlay_manifest.txt"
	  { echo "# ASB generated overlay manifest (install sweep)"
	    find "$MODPATH/system" -type f ! -path "*/system/bin/*" 2>/dev/null | sed "s|^$MODPATH/||"
	  } > "$_man"
	  cp -f "$_man" /data/adb/asb/generated_overlay_manifest.txt 2>/dev/null || true
	fi

# Deferred overlay: on firmware without the detected family's native audio stock the generated
# file overlay is NOT mounted on the first boot.
# It is staged and activated by service.sh only after sys.boot_completed confirms a clean boot,
# so a bad clone can never brick the very first boot (field: Ace 6 bootloops survived the
# 1-strike fuse because users recovery-flash before boot #2).
_mo_src="$MODPATH/system/odm"; _mo_dst="$MODPATH/system/vendor/odm"
if [ -d "$_mo_src" ]; then
  ( cd "$_mo_src" && find . -type f 2>/dev/null ) | while IFS= read -r _mf; do
    _mf="${_mf#./}"
    [ -f "$_mo_dst/$_mf" ] && continue
    mkdir -p "$_mo_dst/$(dirname "$_mf")" 2>/dev/null
    cp -f "$_mo_src/$_mf" "$_mo_dst/$_mf" 2>/dev/null
  done
fi
if [ -d "$_mo_dst" ]; then
  ( cd "$_mo_dst" && find . -type f 2>/dev/null ) | while IFS= read -r _mf; do
    _mf="${_mf#./}"
    [ -f "$_mo_src/$_mf" ] && continue
    mkdir -p "$_mo_src/$(dirname "$_mf")" 2>/dev/null
    cp -f "$_mo_dst/$_mf" "$_mo_src/$_mf" 2>/dev/null
  done
fi

if [ "$_asb_audio_ref" != "1" ] || [ "${_asb_sibling:-0}" = "1" ]; then
  # ONE-reboot activation via the standard /vendor magic-mount overlay — exactly what the OP15
  # reference does.
  # The Ace 6 hard-bootloop came NOT from /vendor but from grafting /odm content into the
  # magic-mount tree (/odm is a bind-mount of another partition on these devices and breaks
  # early boot before the fuse can run).
  rm -rf "$MODPATH/system/odm" "$MODPATH/system/vendor/odm" \
         "$MODPATH/system/my_product" "$MODPATH/deferred_overlay" 2>/dev/null || true
  echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null || true
  rm -f /data/adb/asb/vendor_overlay_blocked 2>/dev/null || true
  ui_print "[*] /vendor overlay active after ONE reboot (OP15-style); /odm audio via fuse-guarded runtime binds"
fi



		asb_snapshot_user_config

		# Keep a tiny installer result record for asbdiag/support. This is evidence only;
		# governor.conf and the user snapshot remain the actual policy sources.
		mkdir -p /data/adb/asb 2>/dev/null || true
		_asb_install_state="/data/adb/asb/last_install_state"
		{
		  echo "timestamp=$(date +%s 2>/dev/null || echo 0)"
		  echo "module_version=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)"
		  echo "config_mode=${ASB_CONFIG_MIGRATION_MODE:-unknown}"
		  echo "config_source=${ASB_CONFIG_MIGRATION_SOURCE:-none}"
		  echo "config_keys=${ASB_CONFIG_MIGRATED_COUNT:-0}"
  echo "snapshot_state=$(test -f /data/adb/asb/update_snapshot_state && echo present || echo absent)"
  echo "named_profiles=$(find /data/adb/asb/config_profiles -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')"
  if [ -e /data/adb/asb/buckets.bin ] || [ -e /data/adb/asb/smart_appheat.bin ]; then echo "smart_learning=present"; else echo "smart_learning=none_yet"; fi
		} > "$_asb_install_state.tmp.$$" 2>/dev/null && mv -f "$_asb_install_state.tmp.$$" "$_asb_install_state" 2>/dev/null || true

		if [ -d "$MODPATH/config" ]; then
	  		  echo 20 > "$MODPATH/config/.schema_version" 2>/dev/null || true

	  chmod 644 "$MODPATH/config/.schema_version" 2>/dev/null || true
	fi

	_asb_ver="$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)"
	_asb_date="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	_gov_hash="$(sha256sum "$MODPATH/bin/asb" 2>/dev/null | cut -c1-12 || echo none)"
	_perf_hash="$(sha256sum "$MODPATH/profiles/performance.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_bat_hash="$(sha256sum "$MODPATH/profiles/battery.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_bal_hash="$(sha256sum "$MODPATH/profiles/balanced.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_conf_hash="$(sha256sum "$MODPATH/config/governor.conf" 2>/dev/null | cut -c1-12 || echo none)"
	mkdir -p "$MODPATH/runtime" 2>/dev/null
	cat > "$MODPATH/runtime/build_manifest.json" <<MANIFEST_EOF
{
  "asb_version": "$_asb_ver",
  "build_date": "$_asb_date",
  "schema_version": 20,
  "hashes": {
    "governor": "$_gov_hash",
    "performance": "$_perf_hash",
    "battery": "$_bat_hash",
    "balanced": "$_bal_hash",
    "governor_conf": "$_conf_hash"
  }
}
MANIFEST_EOF

asb_guard_v4a_effects

# Strip the // comments OxygenOS leaves in video_beauty_default_config.
#
# /data/adb/asb/odm_patched is in this list because on a device that delivers camera configs by
# runtime bind, that copy IS the live file - and it is made from the overlay BEFORE this loop
# runs, so stripping only the overlay left the bound copy exactly as it was.
# asb_diag reported it honestly: "strict JSON (no // comments) want 0 live 1" on both /odm and
# /vendor/odm, while the module's own overlay copy was clean.
for _vb in $(find "$MODPATH/system" "$MODPATH/deferred_overlay" /data/adb/asb/odm_patched \
                  -type f -name "video_beauty_default_config" 2>/dev/null); do
  if grep -q '//' "$_vb" 2>/dev/null; then
    _vbt="${_vb}.asbc$$"
    if sed -e '/^[[:space:]]*\/\//d' -e 's#[[:space:]]//[^"]*$##' "$_vb" > "$_vbt" 2>/dev/null; then
      chmod --reference="$_vb" "$_vbt" 2>/dev/null || chmod 0644 "$_vbt" 2>/dev/null
      _vbctx="$(ls -Z "$_vb" 2>/dev/null | awk '{print $1}')"
      case "$_vbctx" in u:object_r:*) chcon "$_vbctx" "$_vbt" 2>/dev/null ;; esac
      mv -f "$_vbt" "$_vb" 2>/dev/null || { cat "$_vbt" > "$_vb" 2>/dev/null; rm -f "$_vbt"; }
    else
      rm -f "$_vbt" 2>/dev/null
    fi
  fi
done

asb_normalize_module_layout

# Stray empty "vendor" in the module root.
#
# There is a guard for this earlier in the install, but the file was still present in a freshly
# installed module on a real device - so whatever creates it runs AFTER that guard.
# Repeating the check here, at the very end, catches it whenever it appears.
if [ ! -L "$MODPATH/vendor" ] && [ -f "$MODPATH/vendor" ] && [ ! -s "$MODPATH/vendor" ]; then
  rm -f "$MODPATH/vendor" 2>/dev/null
fi

asb_end_banner
