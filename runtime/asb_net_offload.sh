#!/system/bin/sh
# asb_net_offload.sh - spread network softirq work across cores, and size the transmit queue.
#
# WHAT THESE ARE
#
# RPS (Receive Packet Steering) hands received packets to other CPUs instead of processing
# them all on the one core the interrupt landed on. RFS (Receive Flow Steering) goes a step
# further and steers each flow to the core where the app reading that socket actually runs,
# so the data is already in the right cache.
#
# On a phone the single-core bottleneck is real at Wi-Fi 6/7 speeds: one little core doing
# all softirq work caps throughput and pins that core high, which costs battery as well as
# speed. Spreading it lets several cores each do a little at a low frequency.
#
# txqueuelen is the transmit queue depth of the interface. The stock 1000 is a wired-Ethernet
# default from the 1990s that survived into wireless drivers; on a link that varies as much
# as Wi-Fi it mostly adds latency under load (bufferbloat) without adding throughput.
#
# WHY IT IS OFF BY DEFAULT
#
# RPS trades a little CPU for throughput: waking a second core to process packets is not
# free, and on a slow link it is a loss. It earns its keep when the link is fast.
#
#   net_rps      = stock | little | all
#   net_txqueue  = stock | short | shorter
#
# Everything here is restored to the values captured before the first change.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE="/data/adb/asb/net_offload_prev"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

# Only real network interfaces, and only ones that are up. Writing to a down interface
# succeeds and is then undone by the driver when it comes up, which looks like the setting
# silently failing.
_ifaces() {
  for _d in /sys/class/net/*; do
    _n="$(basename "$_d")"
    case "$_n" in lo|dummy*|sit*|ip6tnl*|bond*) continue ;; esac
    [ -d "$_d/queues" ] || continue
    echo "$_n"
  done
}

# CPU mask as hex. little = the first cluster only, all = every online core.
# Deliberately not offering "prime only": steering softirq onto the big cores is the one
# choice that reliably costs battery for no throughput a phone can use.
_mask() {
  _n="$(grep -c ^processor /proc/cpuinfo 2>/dev/null)"
  [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null || _n=8
  case "$1" in
    little)
      # cluster 0 = the cores sharing policy0's affected_cpus
      _c="$(cat /sys/devices/system/cpu/cpufreq/policy0/affected_cpus 2>/dev/null)"
      [ -n "$_c" ] || _c="0 1 2 3"
      _m=0
      for _i in $_c; do _m=$(( _m | (1 << _i) )); done
      printf '%x' "$_m"
      ;;
    all)
      _m=$(( (1 << _n) - 1 ))
      printf '%x' "$_m"
      ;;
    *) printf '0' ;;
  esac
}

_save_once() {
  [ -f "$STATE" ] && return 0
  mkdir -p /data/adb/asb 2>/dev/null
  {
    printf 'RFS_ENTRIES=%s\n' "$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)"
    for _i in $(_ifaces); do
      printf 'TXQ:%s=%s\n' "$_i" "$(cat /sys/class/net/$_i/tx_queue_len 2>/dev/null)"
      for _q in /sys/class/net/$_i/queues/rx-*; do
        [ -r "$_q/rps_cpus" ] || continue
        printf 'RPS:%s=%s\n' "$_q" "$(cat "$_q/rps_cpus" 2>/dev/null)"
      done
    done
  } > "$STATE" 2>/dev/null
}

# Restore just one kind of record, leaving the other side of the file alone.
#
# Same parsing as _restore, filtered by prefix, and the consumed lines are dropped from
# the baseline so a later full restore does not try them twice.
_restore_kind() {
  _rk="$1"
  [ -f "$STATE" ] || return 0
  _rk_keep=""
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    case "$_line" in
      "$_rk":*)
        case "$_line" in
          TXQ:*) _if="${_line#TXQ:}"; _if="${_if%%=*}"; _v="${_line#*=}"
                 [ -n "$_v" ] && ip link set dev "$_if" txqueuelen "$_v" >/dev/null 2>&1 ;;
          RPS:*) _q="${_line#RPS:}"; _q="${_q%%=*}"; _v="${_line#*=}"
                 [ -w "$_q/rps_cpus" ] && echo "${_v:-0}" > "$_q/rps_cpus" 2>/dev/null ;;
        esac
        ;;
      *) _rk_keep="${_rk_keep}${_line}
" ;;
    esac
  done < "$STATE"
  printf '%s' "$_rk_keep" > "$STATE" 2>/dev/null
  echo "net offload: ${_rk} restored to the value the device had"
}

_restore() {
  [ -f "$STATE" ] || return 0
  while IFS= read -r _line; do
    case "$_line" in
      RFS_ENTRIES=*) echo "${_line#*=}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null ;;
      TXQ:*)  _if="${_line#TXQ:}"; _if="${_if%%=*}"; _v="${_line#*=}"
              [ -n "$_v" ] && ip link set dev "$_if" txqueuelen "$_v" >/dev/null 2>&1 ;;
      RPS:*)  _q="${_line#RPS:}"; _q="${_q%%=*}"; _v="${_line#*=}"
              [ -w "$_q/rps_cpus" ] && echo "${_v:-0}" > "$_q/rps_cpus" 2>/dev/null ;;
    esac
  done < "$STATE"
  rm -f "$STATE" 2>/dev/null
}

# Explicit restore, used by uninstall.sh. Reading the config there would be wrong: the
# module is being removed, so what the user last chose is no longer the question.
if [ "${1:-}" = "restore" ] || [ "${ASB_FORCE_RESTORE:-0}" = "1" ]; then
  _restore
  echo "net offload: restored to the values captured before ASB"
  exit 0
fi

_rps="$(_cfg net_rps)";      case "$_rps" in little|all) : ;; *) _rps=stock ;; esac
_txq="$(_cfg net_txqueue)";  case "$_txq" in short|shorter) : ;; *) _txq=stock ;; esac

# Restore per resource, not only when both are stock.
#
# The all-or-nothing check meant net_rps=stock with net_txqueue=short left RPS on the
# value ASB had written: the user set one control back to stock, the UI agreed, and the
# setting did not move. Each control owns its own resource and has to be undone on its
# own.
if [ "$_rps" = "stock" ] && [ "$_txq" != "stock" ]; then
  _restore_kind RPS
elif [ "$_txq" = "stock" ] && [ "$_rps" != "stock" ]; then
  _restore_kind TXQ
fi

if [ "$_rps" = "stock" ] && [ "$_txq" = "stock" ]; then
  _restore
  echo "net offload: stock - RPS and queue length left as the device had them"
  exit 0
fi

_save_once

if [ "$_rps" != "stock" ]; then
  _m="$(_mask "$_rps")"
  # The flow table has to be sized before RFS does anything; without it RPS spreads packets
  # but nothing steers them to the reading core, which is the half that helps latency.
  [ -w /proc/sys/net/core/rps_sock_flow_entries ] && \
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
  _n=0
  for _i in $(_ifaces); do
    for _q in /sys/class/net/$_i/queues/rx-*; do
      [ -w "$_q/rps_cpus" ] || continue
      echo "$_m" > "$_q/rps_cpus" 2>/dev/null
      [ -w "$_q/rps_flow_cnt" ] && echo 4096 > "$_q/rps_flow_cnt" 2>/dev/null
      _n=$(( _n + 1 ))
    done
  done
  echo "net offload: RPS/RFS on $_n queue(s), mask 0x$_m ($_rps)"
fi

if [ "$_txq" != "stock" ]; then
  case "$_txq" in short) _len=256 ;; shorter) _len=128 ;; esac
  _n=0
  for _i in $(_ifaces); do
    ip link set dev "$_i" txqueuelen "$_len" >/dev/null 2>&1 && _n=$(( _n + 1 ))
  done
  echo "net offload: tx queue $_len on $_n interface(s)"
fi
exit 0
