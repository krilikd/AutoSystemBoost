#ifndef ASB_SMART_DEFS_H
#define ASB_SMART_DEFS_H

#include <stdint.h>

/* Bumped for V64: the learner's sign was inverted before this release.
 *
 * Warm buckets had been taught to RAISE the ceiling, and a heavy-drain bucket the same -
 * so the stored alpha, sleep bias and network conservatism are not merely stale, they are
 * pointing the wrong way. Carrying them forward would start V64 with a model actively
 * working against the thing it is supposed to optimise.
 *
 * The MEASUREMENTS in each bucket are unaffected - a thermometer reading is a
 * thermometer reading whatever was done with it - so the migration below keeps them and
 * resets only the conclusions. That leaves the phone with its own history intact and the
 * learner starting from neutral rather than from wrong.
 */
#define ASB_SMART_VER         2
#define ASB_SMART_VER_LEGACY  1
#define ASB_SMART_MAGIC       0x41534253u
#define ASB_SMART_BUCKETS     12
#define ASB_SMART_DAYPARTS    6
#define ASB_SMART_STORE_FILE  "/data/adb/asb/buckets.bin"
#define ASB_SMART_STORE_BAK   "/data/adb/asb/buckets.bin.bak"
#define ASB_SMART_FLAG_FILE   "/data/adb/asb/smart_mode_enabled"
#define ASB_SMART_PREV_PROF   "/data/adb/asb/smart_prev_profile"

typedef enum {
    ASB_DAYPART_SLEEP = 0,
    ASB_DAYPART_WAKE  = 1,
    ASB_DAYPART_MORN  = 2,
    ASB_DAYPART_DAY   = 3,
    ASB_DAYPART_EVE   = 4,
    ASB_DAYPART_LATE  = 5,
    ASB_DAYPART_N     = 6
} asb_daypart_t;

typedef enum {
    ASB_SMART_FALLBACK_EXACT        = 0,
    ASB_SMART_FALLBACK_DAYPART_ONLY = 1,
    ASB_SMART_FALLBACK_CLASS        = 2,
    ASB_SMART_FALLBACK_GLOBAL       = 3,
    ASB_SMART_FALLBACK_SAFE         = 4,
    ASB_SMART_FALLBACK_N            = 5
} asb_smart_fallback_t;

typedef enum {
    ASB_APP_IDLE   = 0,
    ASB_APP_LIGHT  = 1,
    ASB_APP_MEDIUM = 2,
    ASB_APP_HEAVY  = 3,
    ASB_APP_GAMING = 4,
    ASB_APP_N      = 5
} asb_app_hint_t;

#define ASB_SMART_CONF_LOW_X1000   350
#define ASB_SMART_CONF_HIGH_X1000  650
#define ASB_SMART_CONF_MAX_X1000   1000

/*
 * lowered from 2000.
 */
#define ASB_SMART_EFF_OBS_FULL_X100 800

#define ASB_SMART_DECAY_FRESH_DAYS  7
#define ASB_SMART_DECAY_STALE_DAYS  37
#define ASB_SMART_DECAY_FLOOR_X100  30

#define ASB_SMART_ALPHA_BATTERY_MIN_X1000  0
#define ASB_SMART_ALPHA_BATTERY_MAX_X1000  1000

#define ASB_SMART_INTERACTIVE_MIN_X1000    0
#define ASB_SMART_INTERACTIVE_MAX_X1000    150

#define ASB_SMART_IDLE_BIAS_MIN_X1000     -200
#define ASB_SMART_IDLE_BIAS_MAX_X1000      200

#define ASB_SMART_SLEEP_BIAS_MIN_X1000     0
#define ASB_SMART_SLEEP_BIAS_MAX_X1000     1000

#define ASB_SMART_NET_CONSERV_MIN_X1000    0
#define ASB_SMART_NET_CONSERV_MAX_X1000    1000

#define ASB_SMART_DUR_W_SHORT_MIN_S  0
#define ASB_SMART_DUR_W_SHORT_MAX_S  600
#define ASB_SMART_DUR_W_SHORT_X100   25
#define ASB_SMART_DUR_W_MED_MAX_S    1800
#define ASB_SMART_DUR_W_MED_X100     50
#define ASB_SMART_DUR_W_LONG_MAX_S   5400
#define ASB_SMART_DUR_W_LONG_X100    100
#define ASB_SMART_DUR_W_VLONG_X100   125

#define ASB_SMART_TRUST_W_CLEAN_X100   100
#define ASB_SMART_TRUST_W_PARTIAL_X100 40
#define ASB_SMART_TRUST_W_NOISY_X100   15
#define ASB_SMART_TRUST_W_DIRTY_X100   0

/* Trust tier enum (mirror of BAT_TRUST_* from asb_governor.c, kept in sync) */
#define ASB_TRUST_DIRTY    0
#define ASB_TRUST_PARTIAL  1
#define ASB_TRUST_CLEAN    2
#define ASB_TRUST_NOISY    3

#define ASB_SMART_NIGHT_HOUR_START  0
#define ASB_SMART_NIGHT_HOUR_END    6
/*
 * was 60.
 * Battery pct must NOT block night-safe override — the whole point of override is to save
 * battery overnight.
 */
#define ASB_SMART_NIGHT_BAT_PCT_MAX 100
#define ASB_SMART_LOWBAT_ENGAGE_PCT 20
#define ASB_SMART_LOWBAT_RESTORE_PCT 40
#define ASB_SMART_LOWBAT_FORCE_ALPHA_X1000 800
#define ASB_SMART_LOWBAT_CRIT_PCT 10
#define ASB_SMART_LOWBAT_CRIT_ALPHA_X1000 900
#define ASB_SMART_TREND_MIN_TEMP_C 45
#define ASB_SMART_TREND_MIN_SLOPE_MC_MIN 3000
#define ASB_SMART_TREND_MAX_SLOPE_MC_MIN 12000
#define ASB_SMART_TREND_MAX_BUMP_X1000 120
#define ASB_SMART_TREND_WINDOW_S 30
#define ASB_SMART_TREND_STALE_S 180
#define ASB_SMART_TREND_HOT_MIN_TEMP_C 40
#define ASB_SMART_TREND_HOT_MIN_SLOPE_MC_MIN 2000
/* Charge-aware cool gaming: when gaming while charging with a warm battery,
   the worst thermal scenario (render heat + charge heat), engage the lean
   even earlier and on a gentler slope than normal cool gaming. */
#define ASB_SMART_TREND_CHARGE_MIN_TEMP_C 38
#define ASB_SMART_TREND_CHARGE_MIN_SLOPE_MC_MIN 1500
/* Battery temp (deci-C) above which charge-aware cool gaming tightens. */
#define ASB_SMART_CHARGE_WARM_BAT_DC 380
/* Minimum screen-on seconds before a drain sample is trusted enough to bank.
 *
 * Was 600, while the governor publishes its own drain estimate at 300 - two thresholds
 * for the same judgement, and the higher one meant sessions between five and ten minutes
 * produced a usable number that was then thrown away. On a device where the screen is
 * rarely on for ten unbroken minutes, that is every session: a capture shows
 * bucket_drain_x10=0 across the board with 21 sessions banked, so the learner had
 * temperature history and no drain history at all, and the battery-budget half of its
 * decision ran on defaults forever.
 *
 * 300 matches what the governor already considers a valid measurement. Five minutes of
 * continuous screen-on is a real usage window - short enough to actually occur, long
 * enough that the level counter has moved by more than its own quantisation.
 */
#define ASB_SMART_DRAIN_MIN_ON_SEC 300
#define ASB_SMART_DRAIN_HEAVY_PCTPH_X10 1500
#define ASB_SMART_DRAIN_HI_NUM 5
#define ASB_SMART_DRAIN_HI_DEN 4
#define ASB_SMART_DRAIN_LO_NUM 4
#define ASB_SMART_DRAIN_LO_DEN 5
#define ASB_SMART_APPHEAT_N 16
#define ASB_SMART_APPHEAT_MAGIC 0x41534148u
#define ASB_SMART_APPHEAT_VERSION 1
#define ASB_SMART_APPHEAT_BUMP 2
#define ASB_SMART_APPHEAT_MAX 100
#define ASB_SMART_APPHEAT_HOT_SCORE 10
#define ASB_SMART_APPHEAT_LEARN_SLOPE_MC_MIN 6000
#define ASB_SMART_APPHEAT_DECAY_PER_DAY 1
#define ASB_SMART_APPHEAT_FILE "/data/adb/asb/smart_appheat.bin"
#define ASB_SMART_APPHEAT_DRAIN_BUMP 2
#define ASB_SMART_APPHEAT_DRAIN_SAMPLE_X10 1200
#define ASB_SMART_BUDGET_MAX_PCT 50
#define ASB_BUDGET_SPIKE_WINDOW_S 300
#define ASB_BUDGET_ACC_WINDOW_S 1800
#define ASB_BUDGET_ACC_BIAS_MIN_ERR_PCT 25
#define ASB_BUDGET_ACC_BIAS_STREAK 3
#define ASB_SMART_BUDGET_EMERG_H_X10 20
#define ASB_SMART_BUDGET_WARN_H_X10 40
#define ASB_SMART_BUDGET_EMERG_ALPHA_X1000 700
#define ASB_SMART_BUDGET_WARN_ALPHA_X1000 600
#define ASB_SMART_BUDGET_DWELL_S 120
#define ASB_SMART_QUALITY_BAT_GOOD_X10 50
#define ASB_SMART_QUALITY_BAT_BAD_X10 250
/* Offsets from the learned device median, used instead of the absolutes below once the
 * median exists. +1 C so a session at exactly the device's normal still scores full
 * marks; the 30 C span matches what 45..75 gave, so behaviour on a phone whose median
 * happens to be 44 is unchanged. */
#define ASB_SMART_QUALITY_HEAT_GOOD_OFFSET_C  1
#define ASB_SMART_QUALITY_HEAT_SPAN_C        30
#define ASB_SMART_QUALITY_HEAT_GOOD_C 45
#define ASB_SMART_QUALITY_HEAT_BAD_C 75
#define ASB_ANOM_NONE 0
#define ASB_ANOM_PKG_MISSING 1
#define ASB_ANOM_VENDOR_WAR 2
#define ASB_ANOM_DRAIN_SPIKE 3
#define ASB_ANOM_STUCK_BATTERY 4
#define ASB_ANOM_VENDOR_WAR_CLAMPS_1H 400
#define ASB_ANOM_DRAIN_SPIKE_X10 250

#define ASB_SMART_VETO_CPU_TEMP_C        65
#define ASB_SMART_GAMING_RELAX_TEMP_C    65
#define ASB_SMART_VETO_VENDOR_CLAMP_1H   300
#define ASB_SMART_VETO_CONF_SCALE_X100   30
#define ASB_SMART_VETO_FORCE_ALPHA_X1000 700

#define ASB_SMART_SMOOTH_S        300

#define ASB_SMART_APP_CACHE_S     10

#define ASB_SMART_DAYPART_SLEEP_START 0
#define ASB_SMART_DAYPART_WAKE_START  6
#define ASB_SMART_DAYPART_MORN_START  9
#define ASB_SMART_DAYPART_DAY_START   12
#define ASB_SMART_DAYPART_EVE_START   17
#define ASB_SMART_DAYPART_LATE_START  21
#define ASB_SMART_DAYPART_LATE_END    24

#define ASB_SMART_BACKUP_PERIOD_S    (24 * 3600 * 7)

/* 50→80. Faster bias adaptation per session outcome. */
#define ASB_SMART_LEARN_RATE_X1000 80

/*
 * V50: charge-aware layer.
 * Cool-charge floors mirror the idle-screen override levels.
 */
#define ASB_CHARGE_POWER_FAST_W      12
#define ASB_CHARGE_POWER_SUPER_W     33
#define ASB_CHARGE_CLASS_NONE        0
#define ASB_CHARGE_CLASS_SLOW        1
#define ASB_CHARGE_CLASS_FAST        2
#define ASB_CHARGE_CLASS_SUPER       3
/* SoC temperature at which charge-assist stops raising clocks.
 *
 * 48 C is comfortably above idle on every device seen in the field captures (42-47 while
 * charging) and below the point where the vendor starts its own throttling - so this steps
 * back before the heat becomes something either side has to fight. */
#define ASB_CHARGE_SOC_SKIP_C            48

#define ASB_CHARGE_COOL_ALPHA_X1000      850
#define ASB_CHARGE_HOT_ALPHA_X1000       800
#define ASB_CHARGE_SUPER_WARN_BIAS_DC    10

/* V50: night window learner.
 * Minutes-of-day EWMA with circular wrap; onset = screen-off that
 * survives ASB_NIGHT_ONSET_HOLD_S, wake = first screen-on after
 * ASB_NIGHT_MIN_SLEEP_S of cumulative darkness. */
#define ASB_NIGHT_ONSET_HOLD_S     3600
#define ASB_NIGHT_MIN_SLEEP_S      (3 * 3600)
#define ASB_NIGHT_EWMA_NUM         1
#define ASB_NIGHT_EWMA_DEN         4
#define ASB_NIGHT_ONSET_WIN_FROM   (19 * 60)
#define ASB_NIGHT_ONSET_WIN_TO     (5 * 60)
#define ASB_NIGHT_WAKE_WIN_FROM    (4 * 60)
#define ASB_NIGHT_WAKE_WIN_TO      (14 * 60)
/* ---- learned-thermal tuning -------------------------------------------------------
 * Thresholds are in tenths of a degree to match avg_max_temp_x10.
 *
 * 42.0 C as the warm mark and 38.0 as the cool one come from a full-day capture on a
 * OnePlus 15: sleep and idle peak at 40-44, ordinary screen-on sits around 46, and a
 * loaded session reaches 77. So 42 separates "this bucket does real work" from "this
 * bucket is the phone sitting still", and 38 is below anything that capture ever saw -
 * a bucket under it is genuinely cold, not merely quiet.
 *
 * The lean is asymmetric on purpose. Being wrong about a hot bucket costs a little
 * speed; being wrong about a cool one costs heat, which is the thing this exists to
 * avoid. Caps keep either direction from dominating the confidence-scaled value it is
 * adjusting.
 */
#define ASB_SMART_THERM_MIN_OBS_X100    300   /* 3 effective observations before trusting */
/* Fallback absolutes, used only until enough buckets have history to compute this
 * device's own median. Measured on a OnePlus 15 - a reasonable starting point for that
 * family, and replaced by the device's real numbers within a few days of use. */
#define ASB_SMART_THERM_WARM_X10        420
#define ASB_SMART_THERM_COOL_X10        380
/* Offsets from the learned median. These ARE portable in a way absolute degrees are not:
 * "4 degrees above this phone's own normal" means the same thing on every SoC, while
 * "42 C" means a loaded chip on one device and an idle one on another. */
#define ASB_SMART_THERM_WARM_OFFSET_X10  40
#define ASB_SMART_THERM_COOL_OFFSET_X10  40
#define ASB_SMART_THERM_MIN_BUCKETS       4   /* populated buckets before the median is trusted */
#define ASB_SMART_THERM_LEAN_PER_DEG     12   /* alpha_x1000 per degree over warm */
#define ASB_SMART_THERM_LEAN_MAX         90
#define ASB_SMART_THERM_GAIN_PER_DEG      6   /* half the penalty rate */
#define ASB_SMART_THERM_GAIN_MAX         40
/* 8.0 %/h: above the 5-7 seen in ordinary screen-on use in the same capture, below the
 * 13.5 of a genuinely heavy hour. */
#define ASB_SMART_DRAIN_HEAVY_X10        80
#define ASB_SMART_DRAIN_LEAN_PER_PCT      8
#define ASB_SMART_DRAIN_LEAN_MAX         60

#define ASB_NIGHT_MARGIN_PRE_MIN   15
#define ASB_NIGHT_MARGIN_POST_MIN  20

#endif
