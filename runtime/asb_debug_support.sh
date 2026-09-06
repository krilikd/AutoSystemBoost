#!/system/bin/sh
# Debug-only WebUI support actions. This helper accepts no user-supplied shell text:
# it either writes one asbdiag report or starts one bounded 24-hour full-day capture.
set -u

MODID="AutoSystemBoost"
resolve_moddir() {
  for d in \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID" \
    "/data/adb/ap/modules/$MODID"; do
    [ -f "$d/module.prop" ] || continue
    grep -qx "id=$MODID" "$d/module.prop" 2>/dev/null && { printf '%s' "$d"; return 0; }
  done
  return 1
}

MODDIR="${ASB_DEBUG_SUPPORT_MODDIR:-$(resolve_moddir 2>/dev/null || true)}"
[ -n "$MODDIR" ] || { echo 'error=module_not_found'; exit 2; }
VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
_debug_seq="${VERSION##*-debug}"
case "$VERSION:$_debug_seq" in
  *-debug[1-9]*:[1-9]* )
    case "$_debug_seq" in *[!0-9]*) echo 'error=debug_only'; exit 3 ;; esac ;;
  *) echo 'error=debug_only'; exit 3 ;;
esac

STATE_DIR="${ASB_DEBUG_SUPPORT_STATE_DIR:-/data/adb/asb/logkit}"
# A directory is an atomic lock on Android filesystems. Unlike a PID file, it cannot be
# observed as a simultaneously absent/empty guard, and it carries the recorder's own PID.
LOCKDIR="$STATE_DIR/full_day_webui.lock"
BOOTIDFILE="$LOCKDIR/boot_id"

# Identity of the current boot session.
#
# A PID only means something within the boot that produced it. This lock lives in
# /data/adb/asb/logkit, which survives a reboot, so after a restart the recorded PID is
# just a number - and the kernel hands out low PIDs again from scratch. Roughly half the
# time that number now belongs to somebody else's process, kill -0 succeeds, and the lock
# is judged live forever. That is the "log capture works every other reboot" report: it
# depends purely on whether the stale PID landed on a live one.
#
# boot_id changes on every boot and is readable without root on every Android kernel.
# Where it is absent, the boot instant derived from uptime is close enough - it moves by
# whole reboots, which is the only resolution this needs.
current_boot_id() {
  _cb="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$_cb" ]; then printf '%s' "$_cb"; return 0; fi
  _up="$(cut -d. -f1 /proc/uptime 2>/dev/null | tr -dc '0-9')"
  _now="$(date +%s 2>/dev/null || echo 0)"
  case "$_up" in ''|*[!0-9]*) _up=0 ;; esac
  # Round to the nearest minute: the fallback drifts, and a drifting boot id silently
  # invalidates live locks.
  #
  # date and /proc/uptime are sampled a moment apart and each rounds down, so two calls
  # seconds apart can differ by one - and lock_known_dead reads "different boot id" as
  # "lock is from a previous boot, release it". Two concurrent starts then both reclaim the
  # lock and both record, which is the concurrency contract failing at a random round.
  #
  # Only devices without /proc/sys/kernel/random/boot_id reach this line; on those, a minute
  # of granularity is still far finer than the thing it identifies.
  printf 'boot-%s' "$(( (_now - _up) / 60 ))"
}
PIDFILE="$LOCKDIR/pid"
LAUNCHERFILE="$LOCKDIR/launcher"
TOKENFILE="$LOCKDIR/token"
# Recorder-owned output directory. It is published only after the recorder has created it;
# a missing published directory means the user intentionally removed this capture's results.
OUTPUTFILE="$LOCKDIR/output_dir"
# Kept only to avoid starting a second recorder when the module is upgraded while a capture
# started by the pre-lock-directory helper is still alive. New starts never create this file.
LEGACY_PIDFILE="$STATE_DIR/full_day_webui.pid"
RUNLOG="${ASB_DEBUG_SUPPORT_RUNLOG:-/data/local/tmp/asb_full_day.out}"
# Debug-only bounded evidence for a manually removed capture directory. This tells a future
# diagnostic exactly why the slot was or was not recovered without writing policy state.
RECOVERY_LOG="${ASB_DEBUG_SUPPORT_RECOVERY_LOG:-$STATE_DIR/full_day_webui.recovery.log}"
# Kept injectable for the host contract only; production always reads Android's /proc.
PROC_ROOT="${ASB_DEBUG_SUPPORT_PROC_ROOT:-/proc}"
DIAG_OUTDIR="${ASB_DEBUG_SUPPORT_DIAG_OUTDIR:-/sdcard/Download}"
# A WebView bridge waits for stdout to close. Long actions therefore need a deliberately
# detached launcher and a tiny status file: otherwise the browser cannot paint feedback
# until asbdiag has already finished. This state is debug-only and never touches policy.
DIAG_LOCKDIR="$STATE_DIR/asbdiag_webui.lock"
DIAG_BOOTIDFILE="$DIAG_LOCKDIR/boot_id"
DIAG_PIDFILE="$DIAG_LOCKDIR/pid"
DIAG_TOKENFILE="$DIAG_LOCKDIR/token"
DIAG_STATUSFILE="$STATE_DIR/asbdiag_webui.status"

pid_from_file() {
  _pf="${1:-}"
  [ -r "$_pf" ] || return 1
  _pf_pid="$(tr -dc '0-9' < "$_pf" 2>/dev/null)"
  [ -n "$_pf_pid" ] || return 1
  printf '%s' "$_pf_pid"
}

pid_is_live() {
  _pl_pid="${1:-}"
  [ -n "$_pl_pid" ] || return 1
  kill -0 "$_pl_pid" 2>/dev/null || return 1
  # A killed child stays visible as a zombie until its parent reaps it, and kill -0
  # succeeds on a zombie - so "did it die?" answered no for a process that is already gone.
  # That is the "skip=still_live" line in the recovery log after a successful
  # cancel=output_removed: the slot was never reclaimed because the corpse still answered.
  #
  # /proc state Z is the difference between "running" and "finished but not collected".
  # Falls through to the kill -0 answer where /proc is unavailable.
  if [ -r "/proc/$_pl_pid/stat" ]; then
    case "$(cat "/proc/$_pl_pid/stat" 2>/dev/null)" in
      *') Z '*) return 1 ;;
    esac
  fi
  return 0
}

full_day_recovery_note() {
  # Keep this log tiny: it exists for the explicit "I deleted the output directory" recovery
  # path only, in debug builds. Never let diagnostics make a capture start fail.
  _fdrn_msg="${1:-unknown}"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  _fdrn_tmp="${RECOVERY_LOG}.tmp.$$"
  {
    [ -r "$RECOVERY_LOG" ] && tail -n 79 "$RECOVERY_LOG" 2>/dev/null || true
    printf '%s full-day-recovery %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)" "$_fdrn_msg"
  } > "$_fdrn_tmp" 2>/dev/null && mv -f "$_fdrn_tmp" "$RECOVERY_LOG" 2>/dev/null || rm -f "$_fdrn_tmp" 2>/dev/null || true
}

lock_live_pid() {
  # The launcher PID covers the tiny interval before the recorder publishes its own PID.
  # Once published, both usually name the same `sh asb_log_full_day.sh` process.
  for _lp_file in "$PIDFILE" "$LAUNCHERFILE"; do
    _lp_pid="$(pid_from_file "$_lp_file" 2>/dev/null || true)"
    if [ -n "$_lp_pid" ] && pid_is_live "$_lp_pid"; then
      printf '%s' "$_lp_pid"
      return 0
    fi
  done
  return 1
}

legacy_live_pid() {
  _legacy_pid="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
  if [ -n "$_legacy_pid" ] && pid_is_live "$_legacy_pid"; then
    printf '%s' "$_legacy_pid"
    return 0
  fi
  return 1
}

lock_wait_live_pid() {
  # A concurrent request can arrive after mkdir but before the winner publishes launcher/pid.
  # Give that bounded handoff three 100ms attempts; never remove the directory on timeout.
  _lwp_try=0
  while [ "$_lwp_try" -lt 3 ]; do
    _lwp_pid="$(lock_live_pid 2>/dev/null || true)"
    if [ -n "$_lwp_pid" ]; then
      printf '%s' "$_lwp_pid"
      return 0
    fi
    sleep 0.1
    _lwp_try=$(( _lwp_try + 1 ))
  done
  return 1
}

full_day_output_path() {
  [ -r "$OUTPUTFILE" ] || return 1
  _fdo_path="$(tr -d '\r\n' < "$OUTPUTFILE" 2>/dev/null)"
  [ -n "$_fdo_path" ] || return 1
  printf '%s' "$_fdo_path"
}

full_day_output_missing() {
  _fdom_path="$(full_day_output_path 2>/dev/null || true)"
  [ -n "$_fdom_path" ] && [ ! -d "$_fdom_path" ]
}

full_day_pid_matches_recorder() {
  _fdpm_pid="${1:-}"
  [ -n "$_fdpm_pid" ] || return 1
  # Android toybox ps differs by release: `args` can be unsupported, `cmd` can be truncated,
  # and some builds expose only /proc/PID/cmdline. Read every available representation.
  _fdpm_cmd="$(ps -p "$_fdpm_pid" -o args= 2>/dev/null || ps -p "$_fdpm_pid" -o cmd= 2>/dev/null || true)"
  if [ -r "$PROC_ROOT/$_fdpm_pid/cmdline" ]; then
    _fdpm_proc="$(tr '\000' ' ' < "$PROC_ROOT/$_fdpm_pid/cmdline" 2>/dev/null || true)"
    [ -n "$_fdpm_proc" ] && _fdpm_cmd="$_fdpm_cmd $_fdpm_proc"
  fi
  # The exact path remains the strongest proof. The basename fallback is intentionally limited
  # to an already-live lock PID whose recorder-owned published output was explicitly deleted.
  # This avoids a permanent slot when toybox has shortened a legitimate command line while
  # still never killing a PID merely because it is stale or because an output path is absent.
  case "$_fdpm_cmd" in
    *"$MODDIR/tools/logkit/asb_log_full_day.sh"*) return 0 ;;
    *asb_log_full_day.sh*) return 0 ;;
  esac
  return 1
}

full_day_cancel_orphan() {
  # Deleting the published output directory is an explicit user cancellation of this capture.
  # Never kill an arbitrary reused PID: only a live command line that is our own recorder may
  # be terminated, and the atomic lock is removed only after that process is confirmed dead.
  _fdco_pid="${1:-}"
  if ! full_day_output_missing; then full_day_recovery_note "skip=output_present pid=${_fdco_pid:-none}"; return 1; fi
  if ! pid_is_live "$_fdco_pid"; then full_day_recovery_note "skip=pid_dead pid=${_fdco_pid:-none}"; return 1; fi
  if ! full_day_pid_matches_recorder "$_fdco_pid"; then full_day_recovery_note "skip=recorder_unverified pid=$_fdco_pid"; return 1; fi
  full_day_recovery_note "cancel=output_removed pid=$_fdco_pid"
  kill -TERM "$_fdco_pid" 2>/dev/null || { full_day_recovery_note "skip=term_failed pid=$_fdco_pid"; return 1; }
  _fdco_try=0
  while [ "$_fdco_try" -lt 12 ]; do
    pid_is_live "$_fdco_pid" || break
    sleep 0.1
    _fdco_try=$(( _fdco_try + 1 ))
  done
  if pid_is_live "$_fdco_pid"; then
    kill -KILL "$_fdco_pid" 2>/dev/null || return 1
    _fdco_try=0
    while [ "$_fdco_try" -lt 5 ]; do
      pid_is_live "$_fdco_pid" || break
      sleep 0.1
      _fdco_try=$(( _fdco_try + 1 ))
    done
  fi
  if pid_is_live "$_fdco_pid"; then full_day_recovery_note "skip=still_live pid=$_fdco_pid"; return 1; fi
  rm -rf "$LOCKDIR" 2>/dev/null || true
  full_day_recovery_note "recovered=output_removed pid=$_fdco_pid"
  return 0
}

lock_known_dead() {
  # A lock can be released only after both recorded process identities are known to be dead.
  # A missing PID is deliberately NOT considered stale: fail closed rather than risk a second
  # recorder during startup or after an interrupted launch.
  [ -d "$LOCKDIR" ] || return 1

  # A lock from a previous boot is dead by definition, whatever its PIDs now point at.
  # Checked before the PID logic, because that logic cannot tell our old recorder from
  # an unrelated process that inherited the number.
  _lk_boot="$(cat "$BOOTIDFILE" 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$_lk_boot" ] && [ "$_lk_boot" != "$(current_boot_id)" ]; then
    return 0
  fi
  # An older lock with no boot_id recorded cannot be attributed to this boot either.
  # Releasing it is safe: the recorder it belonged to cannot have survived a restart.
  # An unwritten boot id means "too early to tell", not "dead".
  #
  # The winner creates the lock directory and writes the boot id a moment later. In
  # that window this line declared the lock stale, so a second request reclaimed it
  # and both recorded - the concurrency contract failing at a random round, which is
  # exactly the shape of a race.
  #
  # Everywhere else this function fails closed on missing evidence; this was the one
  # place that failed open, and it undid the rest. A genuinely orphaned lock with no
  # boot id is still cleared by the PID checks below and by the output-missing path.
  [ -n "$_lk_boot" ] || return 1

  _lk_seen=0
  for _lk_file in "$PIDFILE" "$LAUNCHERFILE"; do
    _lk_pid="$(pid_from_file "$_lk_file" 2>/dev/null || true)"
    [ -n "$_lk_pid" ] || continue
    _lk_seen=1
    pid_is_live "$_lk_pid" && return 1
  done
  [ "$_lk_seen" = 1 ] || return 1
  return 0
}

full_day_status() {
  _pid="$(lock_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  _pid="$(legacy_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  if [ -d "$LOCKDIR" ]; then
    if lock_known_dead; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
      echo 'status=idle'
    else
      # Winner has the atomic directory but has not published a PID yet. Do not remove it
      # and do not start a competing capture; the next status call will show the PID.
      echo 'status=starting'
      echo 'pid=starting'
      echo "log=$RUNLOG"
    fi
    return 0
  fi
  # Safe cleanup of a legacy PID file only after its recorded process is known dead.
  if [ -f "$LEGACY_PIDFILE" ]; then
    _legacy_raw="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
    if [ -n "$_legacy_raw" ] && ! pid_is_live "$_legacy_raw"; then
      rm -f "$LEGACY_PIDFILE" 2>/dev/null || true
    fi
  fi
  echo 'status=idle'
}

diag_lock_live_pid() {
  _dlp="$(pid_from_file "$DIAG_PIDFILE" 2>/dev/null || true)"
  [ -n "$_dlp" ] && pid_is_live "$_dlp" || return 1
  printf '%s' "$_dlp"
}

diag_lock_known_dead() {
  [ -d "$DIAG_LOCKDIR" ] || return 1

  # Same reasoning as the full-day lock: a PID recorded before a reboot names nothing,
  # and roughly half the time it now names an unrelated live process. asbdiag is the
  # button people press first after restarting, so this path sees the problem more often
  # than the recorder does.
  _dld_boot="$(cat "$DIAG_BOOTIDFILE" 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$_dld_boot" ] && [ "$_dld_boot" != "$(current_boot_id)" ]; then
    return 0
  fi
  [ -n "$_dld_boot" ] || return 0
  _dld_pid="$(pid_from_file "$DIAG_PIDFILE" 2>/dev/null || true)"
  [ -n "$_dld_pid" ] && ! pid_is_live "$_dld_pid"
}

diag_status_write() {
  _ds_tmp="${DIAG_STATUSFILE}.tmp.$$"
  printf '%s\n' "$@" > "$_ds_tmp" 2>/dev/null && mv -f "$_ds_tmp" "$DIAG_STATUSFILE" 2>/dev/null || rm -f "$_ds_tmp" 2>/dev/null || true
}

diag_status() {
  _dspid="$(diag_lock_live_pid 2>/dev/null || true)"
  if [ -n "$_dspid" ]; then
    echo 'status=running'
    echo "pid=$_dspid"
    return 0
  fi
  if [ -d "$DIAG_LOCKDIR" ]; then
    # A child owns the token but has not published a PID yet. It is intentionally
    # fail-closed: no second export may start while this small handoff exists.
    echo 'status=starting'
    return 0
  fi
  [ -r "$DIAG_STATUSFILE" ] && { cat "$DIAG_STATUSFILE"; return 0; }
  echo 'status=idle'
}

write_diag() {
  _outdir="$DIAG_OUTDIR"
  # Create it rather than only testing for it.
  #
  # The fallback to /sdcard is right on a phone and meaningless on a build host, where the
  # configured directory simply does not exist yet - the write then failed, the helper
  # returned non-zero, and the regression aborted at the first assertion line with nothing
  # but "exit code 8" to show for it.
  #
  # mkdir -p is safe in both worlds: on a device the directory already exists and this is a
  # no-op, and if creation is genuinely impossible the /sdcard fallback still applies.
  [ -d "$_outdir" ] || mkdir -p "$_outdir" 2>/dev/null || true
  [ -d "$_outdir" ] || _outdir="/sdcard"
  _stamp="$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo now)"
  _out="$_outdir/asbdiag_${_stamp}.txt"
  _tmp="${_out}.tmp.$$"
  if [ ! -x "$MODDIR/system/bin/asbdiag" ]; then
    echo 'error=asbdiag_missing'
    return 4
  fi
  "$MODDIR/system/bin/asbdiag" > "$_tmp" 2>&1
  _rc=$?
  mv -f "$_tmp" "$_out" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || true; echo 'error=diag_write_failed'; return 5; }
  echo "path=$_out"
  echo "exit=$_rc"
  if [ "$_rc" -ne 0 ]; then
    echo "error=asbdiag_exit_${_rc}"
    return "$_rc"
  fi
  echo "status=saved"
  return 0
}

# Has a PID-less lock outlived the window a starting worker needs to publish its PID?
#
# The worker writes its PID immediately after taking the lock, so anything past two minutes
# means it died in between. Returns false when the timestamp cannot be read, preserving the
diag_start() {
  [ -x "$MODDIR/system/bin/asbdiag" ] || { echo 'error=asbdiag_missing'; return 4; }
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'error=state_dir_failed'; return 7; }
  _pid="$(diag_lock_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo 'status=already_running'; echo "pid=$_pid"; return 0
  fi
  if [ -d "$DIAG_LOCKDIR" ]; then
    # A recorded dead worker cannot become live again. Reclaim exactly that stale lock;
    # PID-less locks remain fail-closed because they may be in the publish window.
    if diag_lock_known_dead; then
      rm -rf "$DIAG_LOCKDIR" 2>/dev/null || true
    else
      # A lock with no PID that is older than the publish window is debris, not a
      # starting worker. Left alone it occupied the slot until reboot: the WebUI kept
      # answering "already running" while the output folder stayed empty, which is why
      echo 'status=already_running'; echo 'pid=starting'; return 0
    fi
  fi
  if ! mkdir "$DIAG_LOCKDIR" 2>/dev/null; then
    echo 'status=already_running'; echo 'pid=starting'; return 0
  fi
  _token="$(date +%s 2>/dev/null || echo now).$$"
  # Braces around the redirect, not just 2>/dev/null on the command.
  #
  # A failed redirect is reported by the shell BEFORE the command runs, so the trailing
  # 2>/dev/null never sees it: dash prints "cannot create ...: Directory nonexistent" to
  # the real stderr regardless. The canonical host regression treats that output as a
  # failure and the whole debug build stopped with exit code 8.
  #
  # Wrapping the redirect in a group puts the error inside the suppressed scope. The write
  # is genuinely optional - a missing boot stamp degrades to "cannot attribute this lock to
  # a boot", which the caller already handles - so failing quietly is correct here.
  { printf '%s\n' "$(current_boot_id)" > "$DIAG_BOOTIDFILE"; } 2>/dev/null || true
  # Every optional write here needs the braces, not just the boot stamp.
  #
  # A failed redirect is reported by the shell before the command runs, so a trailing
  # 2>/dev/null never suppresses it. I fixed this for BOOTIDFILE last round and left these
  # four alone because they predated my changes - but "it was already there" is not the
  # same as "it is correct", and the host regression fails on the printed line regardless
  # of who wrote it.
  if ! { printf '%s\n' "$_token" > "$DIAG_TOKENFILE"; } 2>/dev/null; then
    rmdir "$DIAG_LOCKDIR" 2>/dev/null || true
    echo 'error=diag_guard_failed'; return 8
  fi
  diag_status_write 'status=starting'
  # stdout/stderr/stdin are detached BEFORE backgrounding. KSU can therefore return to
  # WebView immediately; the caller gets a real PID and paints its modal on the next frame.
  (
    _owner_token="$_token"
    # In a POSIX shell $$ in a subshell may still name the parent launcher. Wait for
    # the parent to publish the actual background PID instead of writing an ambiguous
    # identity into status, then let only this token owner publish terminal state.
    _ready=0
    while [ "$_ready" -lt 20 ]; do
      _self="$(pid_from_file "$DIAG_PIDFILE" 2>/dev/null || true)"
      [ -n "$_self" ] && break
      sleep 0.05
      _ready=$(( _ready + 1 ))
    done
    diag_status_write 'status=running' "pid=${_self:-starting}"
    _result="$(write_diag)"; _rc=$?
    if [ "$_rc" -eq 0 ]; then
      diag_status_write "$_result"
    else
      diag_status_write "$_result" 'status=failed'
    fi
    [ "$(cat "$DIAG_TOKENFILE" 2>/dev/null || true)" = "$_owner_token" ] && rm -rf "$DIAG_LOCKDIR" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  _pid=$!
    # The worker is already running - do not report failure for a bookkeeping miss.
    #
    # The background job is forked on the line above; by the time this runs it is already
    # writing the report. Returning an error here told the WebUI "could not collect log"
    # while the file was visibly filling up on disk - exactly the report we received. The
    # user then has a red toast, a growing file, and no idea which to believe.
    #
    # A PID we could not record is a tracking problem, not a collection failure. Say the
    # capture started, because it did, and note the gap so status can still be read from
    # the worker's own published state.
    if ! { printf '%s\n' "$_pid" > "$DIAG_PIDFILE"; } 2>/dev/null; then
      echo 'warn=diag_pid_unrecorded'
    fi
  echo 'status=started'
  echo "pid=$_pid"
}

start_full_day() {
  _async="${1:-0}"
  [ -f "$MODDIR/tools/logkit/asb_log_full_day.sh" ] || { echo 'error=logkit_missing'; return 6; }
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'error=state_dir_failed'; return 7; }

  _pid="$(lock_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    # A live recorder normally blocks a second 24h job. The one exception is a capture whose
    # published output directory was manually removed: safely terminate that orphan and reuse
    # the single slot, instead of leaving the user with a stale PID forever.
    if full_day_output_missing && full_day_cancel_orphan "$_pid"; then
      echo 'orphan_recovered=output_dir_removed'
    else
      echo "status=already_running"
      echo "pid=$_pid"
      echo "log=$RUNLOG"
      return 0
    fi
  fi
  _pid="$(legacy_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=already_running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  if [ -d "$LOCKDIR" ]; then
    if lock_known_dead; then
      # Claim the dead lock by RENAMING it, not by deleting it.
      #
      # rm -rf followed by mkdir is two steps, and two concurrent requests can both pass
      # lock_known_dead, both delete, and both then succeed at mkdir - which is exactly the
      # "concurrent start count round=N" failure: two recorders, two status=started.
      #
      # mv of a directory onto a name that does not exist is a single rename() and only one
      # caller can win it. The loser finds the lock already gone, falls through to mkdir,
      # and one of the two ends up owning the slot - never both.
      _reclaim="$LOCKDIR.dead.$$"
      if mv "$LOCKDIR" "$_reclaim" 2>/dev/null; then
        rm -rf "$_reclaim" 2>/dev/null || true
        # The rename winner creates the fresh lock immediately, inside the same branch.
        # Doing it here rather than falling through closes the window between "the dead
        # lock is gone" and "the new lock exists", which is where a second request would
        # otherwise slip in and also succeed at mkdir - two owners, two recorders.
        if ! mkdir "$LOCKDIR" 2>/dev/null; then
          _pid="$(lock_wait_live_pid 2>/dev/null || true)"
          echo 'status=already_running'; echo "pid=${_pid:-starting}"; echo "log=$RUNLOG"
          return 0
        fi
        _lock_claimed=1
      else
        # Someone else won the rename and is already creating the lock. The request is
        # being served, just not by us.
        _pid="$(lock_wait_live_pid 2>/dev/null || true)"
        echo 'status=already_running'
        echo "pid=${_pid:-starting}"
        echo "log=$RUNLOG"
        return 0
      fi
    else
      _pid="$(lock_wait_live_pid 2>/dev/null || true)"
      # A lock without a ready PID is still owned by another request. Returning a benign
      # already-running state is safer than guessing and creating a parallel recorder.
      echo 'status=already_running'
      echo "pid=${_pid:-starting}"
      echo "log=$RUNLOG"
      return 0
    fi
  fi
  if [ -f "$LEGACY_PIDFILE" ]; then
    _legacy_raw="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
    if [ -n "$_legacy_raw" ] && ! pid_is_live "$_legacy_raw"; then
      rm -f "$LEGACY_PIDFILE" 2>/dev/null || true
    fi
  fi

  # mkdir is atomic. Metadata failures here occur before any child exists, so removing this
  # just-created directory is safe; from the nohup line onward only the recorder/dead-PID
  # verifier may release the guard.
  if [ "${_lock_claimed:-0}" != "1" ] && ! mkdir "$LOCKDIR" 2>/dev/null; then
    _pid="$(lock_wait_live_pid 2>/dev/null || true)"
    echo 'status=already_running'
    echo "pid=${_pid:-starting}"
    echo "log=$RUNLOG"
    return 0
  fi
  _token="$(date +%s 2>/dev/null || echo now).$$"
  # Stamp the boot session before anything else. Written first so a lock can never exist
  # without the one fact that makes its PIDs interpretable.
  { printf '%s\n' "$(current_boot_id)" > "$BOOTIDFILE"; } 2>/dev/null || true
  if ! { printf '%s\n' "$_token" > "$TOKENFILE"; } 2>/dev/null; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    echo 'error=pid_guard_failed'
    return 8
  fi

  # The recorder receives the lock token and publishes its own PID before it begins capture.
  # The launcher PID is written immediately after fork to cover the publish interval.
  ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR" ASB_DEBUG_SUPPORT_LOCK_TOKEN="$_token" \
    nohup sh "$MODDIR/tools/logkit/asb_log_full_day.sh" 24 > "$RUNLOG" 2>&1 < /dev/null &
  _pid=$!
  if ! { printf '%s\n' "$_pid" > "$LAUNCHERFILE"; } 2>/dev/null; then
    # Recorder may already be alive: leave the lock in place rather than clearing ownership.
    echo 'error=pid_guard_unconfirmed'
    return 8
  fi

  # The WebUI variant returns as soon as the atomic lock and launcher PID exist. The
  # recorder still claims its own token before capture; status then reports starting/running.
  if [ "$_async" = 1 ]; then
    echo 'status=started'
    echo "pid=$_pid"
    echo 'hours=24'
    echo "log=$RUNLOG"
    return 0
  fi

  _wait=0
  while [ "$_wait" -lt 3 ]; do
    _claim="$(pid_from_file "$PIDFILE" 2>/dev/null || true)"
    if [ "$_claim" = "$_pid" ] && pid_is_live "$_pid"; then
      echo 'status=started'
      echo "pid=$_pid"
      echo 'hours=24'
      echo "log=$RUNLOG"
      return 0
    fi
    if ! pid_is_live "$_pid"; then
      # The sole launched process exited before ownership claim. No recorder can begin later,
      # so cleanup is safe and a future tap can retry.
      rm -rf "$LOCKDIR" 2>/dev/null || true
      echo 'error=recorder_exited'
      tail -n 4 "$RUNLOG" 2>/dev/null || true
      return 8
    fi
    sleep 1
    _wait=$(( _wait + 1 ))
  done

  # The launch process is alive but has not claimed in time. Fail closed: it may still be
  # about to claim, therefore no path here removes the directory or starts another recorder.
  echo 'status=starting'
  echo "pid=$_pid"
  echo "log=$RUNLOG"
  return 0
}

case "${1:-status}" in
  status) full_day_status ;;
  diag) write_diag ;;
  diag-start) diag_start ;;
  diag-status) diag_status ;;
  full-day) start_full_day ;;
  full-day-start) start_full_day 1 ;;
  *) echo 'error=bad_action'; exit 64 ;;
esac
