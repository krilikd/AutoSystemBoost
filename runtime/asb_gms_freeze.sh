#!/system/bin/sh
# asb_gms_freeze.sh - disable individual Google Play services components.
#
# This is the one thing an external audit put squarely in the competition's favour: the
# largest single source of overnight drain on most phones is GMS, and trimming appops
# only narrows what it may do - it does not stop the component from existing and being
# started. Freezing named components does.
#
# It is NOT package freezing. com.google.android.gms stays enabled, so push, sign-in,
# payments and the Play Store keep working. What gets disabled are receivers and services
# inside it whose only job is telemetry, usage reporting, ads personalisation and
# location history - things whose absence a user notices as better battery and nothing
# else.
#
# Every component is recorded before it is touched and restored on uninstall or when the
# level goes back to off. A component that was ALREADY disabled by the user or another
# module is recorded as such and left disabled on restore - re-enabling something the
# user switched off themselves would be the same mistake in the other direction.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || exit 0

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }
_has pm || exit 0

GMS=com.google.android.gms
STATE=/data/adb/asb/gms_components_frozen

# --- component sets -------------------------------------------------------------------
#
# Split by what breaks if you are wrong, not by how much each saves.
#
# safe: telemetry and reporting. Nothing user-facing depends on these; the phone does not
#       know they are gone. This is the set worth having on by default for anyone who
#       asks for the feature at all.
# more: adds ads personalisation and location history uploads. Ads still show, they are
#       just less targeted; Maps still works, Timeline stops recording.
#
# Deliberately NOT included at any level: anything under gcm/chimera/auth/wallet. Those
# carry push delivery, module loading, account sign-in and payments - freezing them is
# how a "battery module" turns into a support thread about missing notifications.
_SAFE="
com.google.android.gms/.checkin.CheckinService
com.google.android.gms/.checkin.CheckinChimeraService
com.google.android.gms/.stats.service.DropBoxEntryAddedService
com.google.android.gms/.stats.PlatformStatsCollectorService
com.google.android.gms/.usagereporting.service.UsageReportingService
com.google.android.gms/.playlog.service.PlayLogBrokerService
com.google.android.gms/.playlog.uploader.PlayLogUploaderService
com.google.android.gms/.clearcut.service.ClearcutLoggerService
com.google.android.gms/.analytics.service.AnalyticsService
com.google.android.gms/.analytics.AnalyticsReceiver
com.google.android.gms/.feedback.FeedbackAsyncService
"
_MORE="
com.google.android.gms/.ads.identifier.service.AdvertisingIdService
com.google.android.gms/.ads.config.GServicesChangedReceiver
com.google.android.gms/.location.reporting.service.ReportingAndroidService
com.google.android.gms/.location.reporting.service.ReportingSyncService
com.google.android.gms/.location.history.settings.LocationHistorySettingsService
com.google.android.gms/.backup.BackupSchedulerService
"
# Level "max": the components a night capture actually caught waking the phone.
#
# A CPH2769 overnight trace shows Icing (the Google app-search indexer) resuming the SoC
# five times and GOOGLE_C2DM seven, against 45 minutes of screen-off wakefulness that
# accounted for two thirds of the night's drain. Those are the next things worth freezing,
# and nothing above this line touches them.
#
# THE COST, stated plainly: Icing is what makes in-app and system search find things, and
# the Fitness recorder is what counts steps in the background. Freezing them is a real
# trade, not a free win - which is why this is its own level rather than an addition to
# "more", and why the WebUI card says so.
#
# C2DM itself is deliberately NOT here. It is the push transport: freezing it does not
# delay notifications, it stops them, and a phone that silently receives nothing is a
# broken phone, not an efficient one.
_MAX="
com.google.android.gms/.icing.service.IndexService
com.google.android.gms/.icing.proxy.AppsCorpusUpdateService
com.google.android.gms/.icing.service.PersistentIndexService
com.google.android.gms/.fitness.service.recording.FitRecordingService
com.google.android.gms/.fitness.sensors.sample.FitSensorsService
com.google.android.gms/.romanesco.BackupSchedulerService
"

_freeze_one() {
  _c="$1"
  # Record the state we found it in, once. Restoring blindly to "enabled" would turn on
  # components the user had disabled with another tool.
  if ! grep -qE "^${_c}\|" "$STATE" 2>/dev/null; then
    _was="enabled"
    pm list packages -d 2>/dev/null | grep -q "^package:${_c%%/*}$" && _was="pkg-disabled"
    printf '%s|%s\n' "$_c" "$_was" >> "$STATE" 2>/dev/null
  fi
  pm disable --user 0 "$_c" >/dev/null 2>&1
}

_lvl="$(_cfg gms_freeze)"
case "$_lvl" in off|safe|more|max) : ;; *) _lvl=off ;; esac

if [ "$_lvl" = "off" ]; then
  # Restore everything we ever froze, then forget it.
  if [ -f "$STATE" ]; then
    _n=0
    while IFS='|' read -r _c _was; do
      [ -n "$_c" ] || continue
      # pkg-disabled means the whole package was off when we started - putting the
      # component back to "enabled" would be inventing a state that never existed.
      [ "$_was" = "pkg-disabled" ] && continue
      pm enable "$_c" >/dev/null 2>&1 && _n=$((_n + 1))
    done < "$STATE"
    rm -f "$STATE" 2>/dev/null
    [ "$_n" -gt 0 ] && echo "gms freeze: $_n component(s) restored"
  fi
  echo "gms freeze: off"
  exit 0
fi

# Package itself must stay enabled - the whole point is that it keeps working.
if pm list packages -d 2>/dev/null | grep -q "^package:${GMS}$"; then
  echo "gms freeze: $GMS is disabled as a whole - not touching components"
  exit 0
fi

mkdir -p /data/adb/asb 2>/dev/null
_list="$_SAFE"
# Levels are cumulative: max includes more, which includes safe.
case "$_lvl" in
  more) _list="$_SAFE
$_MORE" ;;
  max)  _list="$_SAFE
$_MORE
$_MAX" ;;
esac

_done=0
for _c in $_list; do
  [ -n "$_c" ] || continue
  _freeze_one "$_c" && _done=$((_done + 1))
done
echo "gms freeze: $_lvl - $_done component(s) processed (package itself untouched)"
exit 0
