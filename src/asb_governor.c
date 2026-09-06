#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <time.h>
#include <math.h>
#include <stdint.h>
#include <linux/netlink.h>

#include "asb_metrics.h"
#include "asb_fsm.h"
#include "asb_learner.h"
#include "asb_writer.h"
#include "asb_socket.h"
#include "asb_config.h"
#include "asb_smart.h"

#define TIMER_ACTIVE_S  2   /* metrics interval, screen ON, something happening */
/* Screen on but idle: reading, a feed at rest, music with the display lit. The state
 * machine does not move on a two-second scale there, so neither does the sampling. */
#define TIMER_ACTIVE_CALM_S 6
/* Screen-off policy does not need frame-rate feedback.  The previous 5/10 s cadence kept
 * reopening sysfs nodes hundreds of times per hour during a quiet night.  These intervals
 * retain prompt response to uevents and socket commands while materially reducing resident
 * governor wakeups and telemetry I/O. Verified deep idle can use a 45-second cadence because
 * screen-on, socket and display uevents remain independently epoll-driven. */
#define TIMER_IDLE_S   10   /* metrics interval, screen OFF */
#define TIMER_DEEP_S   45   /* metrics interval, verified deep idle */
/* Screen off with background work: halves the wakeup rate of the idle tier without
 * waiting for the verified-deep-idle conditions that busy background work prevents. */
#define TIMER_IDLE_NOISY_S 20
#define TIMER_HOURLY_S  3600

#define STATE_FILE      "/dev/.asb/state"
#define LOG_FILE        "/dev/.asb/governor.log"
#define LOG_MAX_BYTES   409600  /* 400KB max, then rotate */
#define LOG_BACKUP      "/dev/.asb/governor.log.1"

#ifndef ASB_DEBUG_BUILD
#define ASB_DEBUG_BUILD 0
#endif
#define PID_FILE        "/dev/.asb/governor.pid"
#define PROFILE_FILE    "/data/adb/modules/AutoSystemBoost/current_profile"
#define CONFIG_FILE     "/data/adb/modules/AutoSystemBoost/config/governor.conf"
#define ACTIVE_EFFICIENCY_FILE "/data/adb/asb/active_efficiency.env"

#define MAX_EVENTS      8

static FILE *g_logf = NULL;
static void asb_log(const char *fmt, ...) __attribute__((format(printf,1,2)));  /* forward decl */
asb_runtime_config_t g_asb_cfg;
static time_t g_last_reassert = 0;
static int g_last_reassert_ok = 0;

/* Smart Mode globals */
static asb_smart_store_t   g_smart_store;
static asb_smart_runtime_t g_smart_rt;

/*
 * V50: smart profile with a strong battery lean behaves like the battery profile at night, but
 * quiet-night ultra-economy and deep-idle sensor economy were hard-gated on PROFILE_BATTERY —
 * so on a full night in smart the governor never reduced its own sensor cadence.
 */
static int asb_profile_battery_like(int profile_idx) {
    if (profile_idx == PROFILE_BATTERY) return 1;
    if (profile_idx == PROFILE_SMART &&
        g_smart_rt.enabled &&
        g_smart_rt.alpha_battery_x1000 >= 800) return 1;
    return 0;
}
static int                 g_smart_store_loaded = 0;
static time_t              g_smart_last_save_ts = 0;
static time_t              g_smart_last_backup_ts = 0;
static int                 g_smart_sessions_since_save = 0;

/*
 * — Foreground package detection observability.
 * These mirror the most recent detection outcome so write_state() can publish them to
 * /dev/.asb/state for logkit + WebUI.
 */
static int g_pkg_detect_ok = 0;        /* 1 if last detection got a real pkg */
static int g_pkg_detect_source = 0;    /* 1=cmd activity top, 2=resumed, 3=window focus */
static int g_pkg_detect_status = 0;    /* asb_pkg_status_t code */

/* Opt-in Smart Media Guard runtime. These flags are deliberately separate from the
 * learner and from fsm.current_caps: the guard only narrows the writer-local GPU cap
 * after a confirmed known-media workload and becomes a no-op the instant its evidence fades. */
static int    g_smart_media_pkg_known = 0;
static int    g_smart_media_guard_active = 0;
static time_t g_smart_media_guard_since = 0;
static char   g_smart_media_guard_reason[40] = "disabled";

/* Smart Mode session counters, kept separate from the legacy battery/balanced/
 * performance counters so learner_state.json shows Smart activity honestly. */
static time_t g_smart_drain_prev_ts  = 0;
static int    g_smart_drain_prev_pct = -1;
static long   g_smart_drain_on_sec   = 0;
/* A rolling screen-on drain that does NOT reset when a session ends.
 *
 * The per-session measurement is right for the learner - mixing a gaming session into a
 * reading one describes neither - but it is the wrong thing to show on screen. Sessions end
 * on every state change, so the accumulator rarely reached the 300 s it needs and the
 * banner kept publishing the last completed reading instead: a user watched it sit at
 * 6.5 %/h all day while the phone was visibly draining faster. A state file captured
 * mid-use shows the cause plainly - smart_drain_window_s=10.
 *
 * This pair accumulates across sessions and halves itself every two hours, so it forgets
 * slowly instead of all at once and always has something current to report. */
static long   g_drain_roll_sec    = 0;
static long   g_drain_roll_x100   = 0;
static long   g_smart_drain_drop_x100 = 0;
/* Last completed screen-on drain measurement, kept across sessions so short bursts of use
 * still produce a number. Zero until the first session long enough to measure. */
#define ASB_DRAIN_STALE_SEC (6 * 3600)
static long   g_smart_drain_last_x10 = 0;
static time_t g_smart_drain_last_ts  = 0;
static int    g_smart_drain_rate_ewma_x10 = 0;
static int    g_smart_last_quality = -1;
static int    g_smart_budget_src = 0;
static time_t g_gov_start_ts = 0;
static int    g_smart_boot_settle = 0;
/* Sessions kept as telemetry but withheld from learning because they landed inside the
 * post-boot window. Counted so the quarantine is visible rather than silent. */
static unsigned long g_startup_quarantined = 0;
/* How long after governor start a session is considered untrusted for learning.
 * Five minutes covers package rescan and restore on the slowest device seen in the
 * captures, without swallowing a genuine early-morning usage session. */
#define ASB_STARTUP_QUARANTINE_S 300
static int    g_smart_cool_gaming_lvl = 0;
/* Gaming-session peak tracking (reset when a game session is not active).
   Cheap running maxima surfaced in the report card so charge-aware cooling
   can be judged on numbers, not feel. */
static int    g_game_bat_temp_peak_dc = 0;
static int    g_game_cpu_max_peak_c   = 0;
static int    g_game_cool_lvl_peak    = 0;
static int    g_game_charging_seen    = 0;
static int    g_smart_q_bat = -1;
static int    g_smart_q_heat = -1;
static int    g_smart_q_stab = -1;
static int    g_smart_q_vendor = -1;
static int    g_smart_q_fail = 0;
static unsigned long g_smart_ses_clamp_start = 0;
static int    g_smart_quality_ewma = -1;
static int    g_anom_code = 0;
static int    g_anom_count_1h = 0;
static time_t g_anom_window_start = 0;
static long   g_anom_pkg_total = 0;
static long   g_anom_pkg_ok = 0;

static int g_smart_sessions_total    = 0;
static int g_smart_sessions_day      = 0;
static int g_smart_sessions_night    = 0;
static int g_smart_sessions_gaming   = 0;
static int g_smart_bucket_updates    = 0;
static int g_smart_last_bucket_id    = -1;
static int g_smart_last_daypart      = -1;
static int g_smart_last_confidence   = 0;
static time_t g_smart_last_update_ts = 0;

static int    g_smart_last_seen_bucket = -1;
static time_t g_smart_last_periodic_ts = 0;
static time_t g_smart_screen_off_since = 0;
static int    g_smart_last_screen_on = 1;

/* Suspend tracking: is the phone actually sleeping while the screen is off?
 *
 * CLOCK_MONOTONIC stops during suspend; CLOCK_BOOTTIME does not. The ratio between
 * them over a screen-off window is the share of that window the CPU stayed awake.
 *
 * Nothing measured this at runtime. An overnight capture showed 73% awake across 8.9
 * hours of screen-off against a <5% target, and 1.58%/h drain against 0.3-0.7 - and the
 * module had no idea, because the figure was only computed afterwards by the log tools.
 * A governor that cannot see the phone failing to sleep cannot say so, let alone react.
 *
 * This only measures and publishes. Deciding what to do about a wakelock held by
 * someone else is a separate question, and guessing at it is how a performance module
 * starts breaking alarms. */
static long   g_awake_win_mono_ms = 0;   /* monotonic ms accumulated this screen-off window */
static long   g_awake_win_boot_ms = 0;   /* boottime ms over the same window */
static long   g_awake_last_mono_ms = 0;
static long   g_awake_last_boot_ms = 0;
static int    g_awake_pct = -1;          /* -1 = not measured yet */

static long asb_clock_ms(clockid_t which) {
    struct timespec ts;
    if (clock_gettime(which, &ts) != 0) return 0;
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* Called once per tick. screen_on resets the window: the figure is only meaningful
 * across a continuous screen-off stretch, and mixing screen-on time into it would
 * dilute exactly the problem it exists to expose. */
static void asb_awake_track(int screen_on) {
    long mono = asb_clock_ms(CLOCK_MONOTONIC);
    long boot = asb_clock_ms(CLOCK_BOOTTIME);
    if (screen_on) {
        g_awake_win_mono_ms = 0;
        g_awake_win_boot_ms = 0;
        g_awake_last_mono_ms = mono;
        g_awake_last_boot_ms = boot;
        g_awake_pct = -1;
        return;
    }
    if (g_awake_last_boot_ms > 0) {
        long d_mono = mono - g_awake_last_mono_ms;
        long d_boot = boot - g_awake_last_boot_ms;
        /* Guard against a clock that went backwards or a wildly long gap - both mean
         * the sample is not comparable, not that the phone was busy. */
        if (d_mono >= 0 && d_boot > 0 && d_boot < 6L * 3600L * 1000L) {
            g_awake_win_mono_ms += d_mono;
            g_awake_win_boot_ms += d_boot;
        }
    }
    g_awake_last_mono_ms = mono;
    g_awake_last_boot_ms = boot;
    /* Ten minutes before the first verdict: a phone that just locked has not had the
     * chance to suspend yet, and calling that "awake" would cry wolf every evening. */
    if (g_awake_win_boot_ms >= 600000L) {
        g_awake_pct = (int)((g_awake_win_mono_ms * 100L) / g_awake_win_boot_ms);
        if (g_awake_pct > 100) g_awake_pct = 100;
    }
}

static int    g_smart_last_tune_sig = -1;
static time_t g_smart_last_tune_ts  = 0;

static int    g_leak_streak_p0        = 0;
static int    g_leak_streak_p1        = 0;
static time_t g_last_leak_reassert    = 0;
static int    g_leak_reassert_count   = 0;
static int g_msm_boost_active = 0;

#define AC_STAGE_IDLE    0
#define AC_STAGE_BURST   1  /* aggressive 2s, max 3 attempts */
#define AC_STAGE_HOLD    2  /* maintenance 4s */
#define AC_STAGE_BACKOFF 3  /* pause 30s */

#define PLAN_CLASS_IDLE_CLEAN    0  /* battery screen-off deep idle */
#define PLAN_CLASS_IDLE_NOISY    1  /* battery screen-off but noisy (wakes/moderate) */
#define PLAN_CLASS_DAILY_ACTIVE  2  /* battery/balanced screen-on daily use */
#define PLAN_CLASS_PERF_ACTIVE   3  /* performance or heavy balanced */
#define PLAN_CLASS_PERF_CLAMPED  4  /* performance under vendor clamp */
#define PLAN_CLASS_BENCHMARK     5  /* benchmark session */
#define PLAN_CLASS_QUARANTINE    6  /* user-switch quarantine */

#define INTENT_UNKNOWN    0
#define INTENT_BENCHMARK  1
#define INTENT_LONG_GAME  2
#define INTENT_IDLE       3
#define INTENT_MIXED      4
#define INTENT_SLEEP_IDLE 5
#define INTENT_IDLE_WARM  6

static struct {
    uint8_t has_msm_perf;       /* /sys/kernel/msm_performance writable */
    uint8_t has_headroom;       /* msm_performance/cpu_max_freq readable */
    uint8_t has_thermal_cpu;    /* thermal_zone for CPU found */
    uint8_t has_thermal_skin;   /* thermal_zone for skin found */
    uint8_t has_gpu_load;       /* GPU load sysfs readable */
    uint8_t has_uclamp;         /* cpuctl/top-app/cpu.uclamp.max exists */
} g_device_caps;
static int g_ac_stage = AC_STAGE_IDLE;
static int g_ac_burst_count = 0;
static int g_ac_fails = 0;
static time_t g_ac_backoff_until = 0;
static int g_ac_backoff_count = 0;  /* backoffs this session */
static int g_ac_futile = 0;        /* 1 = anti-clamp suspended (futility) */
static int g_clamp_probe_skip = 0; /* ticks until next recovery probe */
static int g_probe_good_hits = 0;  /* consecutive good probes needed to lift hold */
static time_t g_clamp_hold_since = 0;  /* when clamp_hold was first set */
static int g_virtual_ceiling_p0 = 0;
static int g_virtual_ceiling_p1 = 0;

static int g_burst_probation = 0;     /* 1 = in probation window */
static int g_burst_early_collapse = 0; /* 1 = early collapse detected */

static void anti_clamp_reset(void) {
    g_ac_stage = AC_STAGE_IDLE;
    g_ac_burst_count = 0;
    g_ac_fails = 0;
    g_ac_backoff_until = 0;
    g_ac_backoff_count = 0;
    g_ac_futile = 0;
    g_clamp_probe_skip = 0;
    g_probe_good_hits = 0;
    g_clamp_hold_since = 0;
    g_burst_probation = 0;
    g_burst_early_collapse = 0;
}

static int g_action_waste = 0;

static void action_waste_reset(void) { g_action_waste = 0; }

static int g_quiet_night_active = 0;
/* Ticks genuinely skipped by Quiet Night. Published so the economy can be verified. */
static unsigned long g_qn_ticks_skipped = 0;
/* Set for the current tick when Quiet Night is economising. Read at the battery and
 * thermal probe sites - the ones that cost an I/O round trip - rather than skipping the
 * whole tick, which would also skip the bookkeeping the next tick relies on. */
int g_qn_skip_this_tick = 0;
static time_t g_quiet_night_since = 0;
static int g_quiet_night_ticks = 0;       /* consecutive quiet deep-idle ticks */

static int g_last_bat_clean_night = 0;

#define ENV_QUIET    0
#define ENV_NOISY    1
#define ENV_HOSTILE  2

static int g_last_session_env = ENV_QUIET;

static int g_quiet_wake_ramp = 0;
static int g_quiet_noise_ticks = 0;  /* hysteresis -- consecutive non-quiet ticks */

#define USER_QUARANTINE_SEC 90
static int g_last_user_id = -1;
static time_t g_user_quarantine_until = 0;
static int g_user_quarantine_active = 0;

static int get_current_user_id(void) {
    FILE *p = popen("cmd user get-current-user 2>/dev/null", "r");
    if (!p) return -1;
    char buf[32];
    int uid = -1;
    if (fgets(buf, sizeof(buf), p)) uid = atoi(buf);
    pclose(p);
    return uid;
}

static int user_quarantine_check(asb_fsm_t *fsm) {
    time_t now = time(NULL);
    if (g_user_quarantine_active && now >= g_user_quarantine_until) {
        g_user_quarantine_active = 0;
        fsm->plan.quarantine = 0;
        return 1;  /* expired -- caller should log */
    }
    return 0;
}

static time_t g_last_perf_end_ts = 0;
static int g_last_perf_max_temp = 0;
static int g_last_perf_was_clamped = 0;

static int g_storm_shield_active = 0;
static int g_shield_calm_ticks = 0;
static int g_shield_last_wakes = -1;
static int g_shield_exit_wakes = 0;      /* wake count at last smart exit */
static time_t g_shield_rearm_until = 0;  /* cooldown after smart exit */

static void storm_shield_reset(void) {
    g_storm_shield_active = 0;
    g_shield_calm_ticks = 0;
    g_shield_last_wakes = -1;
    g_shield_exit_wakes = 0;
    g_shield_rearm_until = 0;
}

static void session_plan_build(asb_fsm_t *fsm, int screen_on) {
    /* Cleared every pass: the branches below set what applies, and a flag left over from
     * the previous tick would keep a slower cadence after the reason for it was gone. */
    fsm->plan.idle_noisy_slow = 0;
    int p = fsm->profile_idx;
    /*
     * V56 HEAT FIX: SMART matched none of the branches below and fell through to the else =
     * the PERFORMANCE plan — full sensor polling + headroom reads + the anti-clamp armed (ASB
     * re-raising vendor thermal clamps up to 95°C) even with the screen OFF, and deep_sleep
     * never enabled.
     * Field logs showed exactly that: cap_owner=vendor on 59% of ticks (a write war with the
     * vendor thermal engine), 96-235 mA and 40°C surface in DEEP_IDLE, and the user report
     * "smart = boiler, balanced = fine".
     */
    if (p == PROFILE_SMART) {
        /* Smart is an energy/heat profile, not a hidden Balanced profile.  The previous
         * screen-on mapping selected the Balanced plan and armed anti-clamp, which could
         * re-raise vendor thermal caps.  Smart now uses the Battery-like plan for all states:
         * its adaptive bounds still choose the requested ceiling, but it never fights the
         * vendor thermal owner and its sensor cadence stays economical. */
        p = PROFILE_BATTERY;
    }
    int idle_band = (fsm->state <= ASB_STATE_LIGHT_IDLE);
    int heavy_band = (fsm->state >= ASB_STATE_HEAVY);

    /* ac_prearm recomputed on each rebuild; ac_used preserved (per-session budget) */
    fsm->plan.ac_prearm = 0;
    /* sensor_used resets on plan rebuild (per-epoch, not per-session) */
    fsm->plan.sensor_used = 0;

    if (p == PROFILE_BATTERY && !screen_on && idle_band) {
        fsm->plan.sensor_tier  = 2;
        fsm->plan.thermal_div  = 3;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_CLEAN;
        if (g_last_session_env == ENV_HOSTILE) {
            long _bt_in_s = fsm->bat_time_deep_idle_sec
                          + fsm->bat_time_light_idle_sec
                          + fsm->bat_time_moderate_sec;
            int _in_iq = (_bt_in_s > 0)
                ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_in_s) : 0;
            /* V56: judge cleanliness by BACKGROUND wakes only -- the user
             * checking the phone (screen wakes) is not environment noise. */
            int strict_clean = (fsm->bat_time_deep_idle_sec >= 600 &&
                                fsm->bat_wake_bg <= 3);
            int relaxed_clean = (fsm->bat_time_deep_idle_sec >= 900 &&
                                 fsm->bat_wake_bg <= 8 &&
                                 _in_iq >= 60);
            if (!strict_clean && !relaxed_clean) {
                fsm->plan.thermal_div = 1;
                fsm->plan.plan_class = PLAN_CLASS_IDLE_NOISY;
                asb_log("plan: primed as IDLE_NOISY (last session env=hostile)");
            } else {
                asb_log("plan: clean in-session override hostile prime (deep=%lds, wake=%d, iq=%d, mode=%s)",
                        fsm->bat_time_deep_idle_sec, fsm->bat_wake_cycles, _in_iq,
                        strict_clean ? "strict" : "relaxed");
            }
        }
    } else if (p == PROFILE_BATTERY && !screen_on) {
        /* Screen off with the state above LIGHT_IDLE: something is running, but nobody is
         * looking at it.
         *
         * This branch keeps the 10 s cadence, and measurement says that is where the phone
         * actually lives: overhead sampled across two diagnostics 14 minutes apart works
         * out at 6.1 timer wakeups per minute, which is TIMER_IDLE_S exactly. The 45 s deep
         * tier needs the state to be LIGHT_IDLE or lower, and background work keeps it just
         * above that for long stretches.
         *
         * Six wakeups a minute is 360 an hour of pulling the CPU out of idle to look at
         * sensors nobody can see the result of. The work behind them is real - a sync, a
         * download - but ASB does not need to re-evaluate it twice a minute to stay
         * correct: its own decisions here change on the scale of minutes.
         *
         * So this gets its own tier between IDLE and DEEP rather than sharing the
         * screen-on-adjacent one. Reaction to something genuinely new is slower by at most
         * a few seconds, and with the screen off nothing is waiting on it.
         */
        fsm->plan.sensor_tier  = 1;  /* REDUCED */
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 0;
        fsm->plan.idle_noisy_slow = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_NOISY;
    } else if (!screen_on && idle_band) {
        /*
         * ANY profile, screen off, idle -> the quiet plan. This branch did not exist.
         *
         * The V56 note above describes SMART falling through to the PERFORMANCE plan and
         * being called "a boiler". SMART was remapped and fixed; BALANCED was not, and it
         * has the same shape: the branch below matches BALANCED for every state that is
         * not heavy, WITHOUT looking at the screen. So with the screen off and the phone
         * doing nothing, BALANCED still ran sensor_tier 0 (full polling), ac_eligible 1
         * (the anti-clamp armed, re-raising vendor thermal limits) and deep_sleep 0 - a
         * 5-second tick that never stretched.
         *
         * Two field captures on BALANCED show the cost: idle 95 min at 83% awake and
         * charging_idle 58 min at 100% awake against a <5% target, deep sleep 3.3%, and
         * 416 throttle events of which 274 landed while charging - the anti-clamp and the
         * vendor thermal engine writing over each other. On a OnePlus 13 that was enough
         * for OxygenOS to disable its own display enhancement with "device overheated".
         *
         * Written as a rule about the STATE, not a list of profiles, because that is where
         * the bug came from: the quiet plan was granted per profile, so each one had to be
         * remembered separately. SMART was fixed in V56, BALANCED was missed until two
         * field captures showed it, and PERFORMANCE would have been the next report -
         * with the screen off it also polled fully with the anti-clamp armed, and there is
         * no reading of "performance" under which that helps a phone in someone's pocket.
         *
         * Idle with the screen off is idle whatever the profile is called. Every profile
         * keeps its full behaviour the moment the screen comes on or real load arrives -
         * this branch cannot be reached in either case.
         */
        fsm->plan.sensor_tier  = 2;
        fsm->plan.thermal_div  = 3;
        fsm->plan.allow_hr     = 0;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.deep_sleep   = 1;
        fsm->plan.ac_budget    = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_IDLE_CLEAN;
    } else if (p == PROFILE_BATTERY || (p == PROFILE_BALANCED && !heavy_band)) {
        fsm->plan.sensor_tier  = (p == PROFILE_BALANCED) ? 0 : 1;
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = (p == PROFILE_BALANCED);
        fsm->plan.ac_eligible  = (p == PROFILE_BALANCED);
        fsm->plan.deep_sleep   = 0;
        fsm->plan.ac_budget    = (p == PROFILE_BALANCED) ? 3 : 0;
        fsm->plan.sensor_budget = (p == PROFILE_BALANCED) ? 60 : 0;
        fsm->plan.plan_class   = PLAN_CLASS_DAILY_ACTIVE;
    } else {
        /* performance or heavy balanced */
        fsm->plan.sensor_tier  = 0;  /* FULL */
        fsm->plan.thermal_div  = 1;
        fsm->plan.allow_hr     = 1;
        fsm->plan.ac_eligible  = 1;
        fsm->plan.deep_sleep   = 0;
        fsm->plan.ac_budget    = (p == PROFILE_PERFORMANCE) ? 6 : 3;
        fsm->plan.sensor_budget = 120;  /* ~10 min of full reads at 5s ticks */
        fsm->plan.plan_class   = (fsm->ses_intent == INTENT_BENCHMARK)
                                  ? PLAN_CLASS_BENCHMARK : PLAN_CLASS_PERF_ACTIVE;

        /* thermal debt -- halve ac_budget if last perf session
         * was hot (>=75degC) and ended less than 120s ago */
        if (p == PROFILE_PERFORMANCE && g_last_perf_end_ts > 0) {
            time_t elapsed = time(NULL) - g_last_perf_end_ts;
            if (elapsed < 120 && g_last_perf_max_temp >= 75) {
                fsm->plan.ac_budget = fsm->plan.ac_budget / 2;
                if (fsm->plan.ac_budget < 1) fsm->plan.ac_budget = 1;
            }
            /* clamp debt -- if last perf session was vendor_clamped,
             * reduce budget and sensor reads for less aggressive start */
            if (elapsed < 300 && g_last_perf_was_clamped) {
                fsm->plan.ac_budget = fsm->plan.ac_budget / 2;
                if (fsm->plan.ac_budget < 1) fsm->plan.ac_budget = 1;
                asb_log("plan: clamp_debt active (prev session vendor_clamped %lds ago), ac_budget=%d",
                        elapsed, fsm->plan.ac_budget);
            }
        }
    }

    /* user-switch quarantine overrides aggressive settings */
    if (g_user_quarantine_active) {
        fsm->plan.quarantine   = 1;
        fsm->plan.ac_eligible  = 0;
        fsm->plan.ac_prearm    = 0;
        fsm->plan.ac_budget    = 0;
        fsm->plan.allow_hr     = 0;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class   = PLAN_CLASS_QUARANTINE;
    } else {
        fsm->plan.quarantine   = 0;
    }

    /* storm shield -- ultra-light for noisy battery screen-off */
    if (g_storm_shield_active && p == PROFILE_BATTERY && !screen_on) {
        fsm->plan.sensor_tier   = 2;
        fsm->plan.thermal_div   = 5;
        fsm->plan.allow_hr      = 0;
        fsm->plan.ac_eligible   = 0;
        fsm->plan.deep_sleep    = 1;
        fsm->plan.sensor_budget = 0;
        fsm->plan.plan_class    = PLAN_CLASS_IDLE_NOISY;
    }
}

static int g_log_writes = 0;
#define LOG_PERSIST_FILE   "/data/adb/asb/governor_persist.log"
#define LOG_PERSIST_BACKUP "/data/adb/asb/governor_persist.log.1"
#define LOG_PERSIST_MAX_BYTES (256 * 1024)
static FILE *g_logf_persist = NULL;
static int g_log_persist_writes = 0;

static void asb_log_persist(const char *fmt, va_list ap_in) {
    if (!g_logf_persist) {
        g_logf_persist = fopen(LOG_PERSIST_FILE, "a");
        if (!g_logf_persist) return;
    }
    if (++g_log_persist_writes % 50 == 0) {
        long pos = ftell(g_logf_persist);
        if (pos > LOG_PERSIST_MAX_BYTES) {
            fclose(g_logf_persist);
            rename(LOG_PERSIST_FILE, LOG_PERSIST_BACKUP);
            g_logf_persist = fopen(LOG_PERSIST_FILE, "w");
            if (!g_logf_persist) return;
            fprintf(g_logf_persist, "[rotated] previous: %s\n", LOG_PERSIST_BACKUP);
        }
    }
    char ts[32];
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
    fprintf(g_logf_persist, "[%s] ", ts);
    vfprintf(g_logf_persist, fmt, ap_in);
    fprintf(g_logf_persist, "\n");
    fflush(g_logf_persist);
}

static void asb_log_critical(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void asb_log_critical(const char *fmt, ...) {
    /* Write to transient log first */
    if (g_logf) {
        char ts[32];
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
        fprintf(g_logf, "[%s] [crit] ", ts);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(g_logf, fmt, ap);
        va_end(ap);
        fprintf(g_logf, "\n");
        fflush(g_logf);
    }
    /* Mirror to persistent log */
    va_list ap2;
    va_start(ap2, fmt);
    asb_log_persist(fmt, ap2);
    va_end(ap2);
}

static void asb_log(const char *fmt, ...) {
    if (!g_logf) return;
    if (++g_log_writes % 200 == 0) {
        long pos = ftell(g_logf);
        if (pos > LOG_MAX_BYTES) {
            fclose(g_logf);
            rename(LOG_FILE, LOG_BACKUP);
            g_logf = fopen(LOG_FILE, "w");
            if (!g_logf) return;
            fprintf(g_logf, "[rotated] previous log: %s\n", LOG_BACKUP);
        }
    }
    char ts[32];
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", tm);
    fprintf(g_logf, "[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logf, fmt, ap);
    va_end(ap);
    fprintf(g_logf, "\n");
    fflush(g_logf);
}

#define PERSISTENT_STATS_DIR  "/data/adb/modules/AutoSystemBoost/runtime"
#define PERSISTENT_STATS_FILE "/data/adb/modules/AutoSystemBoost/runtime/session_stats.json"
static const char *g_pstats_files[3] = {
    PERSISTENT_STATS_DIR "/pstats_battery.json",
    PERSISTENT_STATS_DIR "/pstats_balanced.json",
    PERSISTENT_STATS_DIR "/pstats_performance.json"
};
/*
 * session_history.jsonl moved to persistent /data/adb/asb/ so learning survives module
 * reinstall/upgrade.
 */
#define SESSION_HISTORY_FILE        "/data/adb/asb/session_history.jsonl"
#define SESSION_HISTORY_FILE_LEGACY "/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl"
#define SESSION_HISTORY_MAX   500
#define SESSION_HISTORY_LINE_MAX 2048
/* Hard size cap to prevent unbounded growth. 5 MB = ~2500 max-size lines,
 * comfortably above SESSION_HISTORY_MAX=500 × 2KB/line worst case. */
#define SESSION_HISTORY_SIZE_CAP_BYTES (5 * 1024 * 1024)
#define STATUS_JSON_MAX          4096
#define PERSISTENT_STATS_MAX_SESSIONS 10
#define BAT_FAST_IDLE_FLOOR  5  /* safety: feedback loops cannot go below 5s */

#define ASB_VERSION "V64"

static const char *intent_names[] = {"unknown","benchmark","long_game","idle","mixed","sleep_idle","idle_warm"};

static inline const char *sustained_reason_name(int r) {
    switch (r) {
        case 0:  return "thermal";
        case 1:  return "gaming_unreachable";
        case 2:  return "time_based_escape";
        default: return "unknown";
    }
}

static inline const char *cap_source_classify(int profile_cap,
                                              int runtime_declared,
                                              int actual_sysfs,
                                              int hw_ceiling) {
    if (actual_sysfs <= 0)  return "policy_unknown";
    if (hw_ceiling > 0 && actual_sysfs > hw_ceiling + 50000) return "policy_unknown";

    /*
     * Shell-only branch: runtime_declared==0 means governor didn't register caps via
     * msm_performance (typical for battery profile where caps are applied via service.sh
     * shell-layer only).
     */
    if (runtime_declared <= 0) {
        if (profile_cap <= 0) return "policy_unknown";
        if (actual_sysfs == profile_cap) return "shell_applied";
        if (actual_sysfs >  profile_cap) return "shell_overridden_up";
        /* actual < profile — could be legitimate vendor thermal cooldown,
         * not necessarily a problem. */
        return "shell_overridden_down";
    }

    /* Runtime-tracked branch: governor registered caps via msm_performance. */
    if (profile_cap > 0 && runtime_declared == profile_cap
        && actual_sysfs == profile_cap) {
        return "asb";
    }
    if (actual_sysfs == runtime_declared && runtime_declared != profile_cap) {
        return "asb_dynamic";
    }
    if (profile_cap > 0 && actual_sysfs == profile_cap
        && runtime_declared != profile_cap) {
        return "thermal_overlay";
    }
    if (actual_sysfs > runtime_declared) {
        return "vendor_raised";
    }
    if (actual_sysfs < runtime_declared
        && (hw_ceiling <= 0 || actual_sysfs < hw_ceiling)) {
        return "vendor_clamp";
    }
    return "mismatch";
}

static int atomic_write_file(const char *path, const char *content) {
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    fputs(content, f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return rename(tmp, path);
}

static int rewrite_last_history_end(const char *new_end) {
    FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
    if (!rf) return 0;

    char **lines = NULL;
    size_t count = 0, cap = 0;
    char buf[2048];
    int last_json_idx = -1;

    while (fgets(buf, sizeof(buf), rf)) {
        if (count == cap) {
            size_t new_cap = cap ? cap * 2 : 64;
            if (new_cap > SIZE_MAX / sizeof(char *)) {
                fclose(rf);
                for (size_t i = 0; i < count; i++) free(lines[i]);
                free(lines);
                return 0;
            }
            char **tmp = (char **)realloc(lines, new_cap * sizeof(char *));
            if (!tmp) {
                fclose(rf);
                for (size_t i = 0; i < count; i++) free(lines[i]);
                free(lines);
                return 0;
            }
            lines = tmp;
            cap = new_cap;
        }
        size_t blen = strlen(buf);
        lines[count] = (char *)malloc(blen + 1);
        if (!lines[count]) {
            fclose(rf);
            for (size_t i = 0; i < count; i++) free(lines[i]);
            free(lines);
            return 0;
        }
        memcpy(lines[count], buf, blen + 1);
        if (buf[0] == '{') last_json_idx = (int)count;
        count++;
    }
    fclose(rf);
    if (last_json_idx < 0) {
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    char *line = lines[last_json_idx];
    size_t len = strlen(line);
    int had_nl = (len > 0 && line[len-1] == '\n');
    if (had_nl) line[len-1] = '\0';

    char *tag = strstr(line, "\"end\":\"");
    if (!tag) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }
    char *val_start = tag + strlen("\"end\":\"");
    char *val_end = strchr(val_start, '"');
    if (!val_end) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    size_t prefix_len = (size_t)(val_start - line);
    const char *suffix = val_end;
    int add_partial = (strstr(line, "\"partial\":1") == NULL);
    size_t need = prefix_len + strlen(new_end) + strlen(suffix) +
                  (add_partial ? strlen(",\"partial\":1") : 0) + 8;
    char *patched = (char *)calloc(1, need);
    if (!patched) {
        if (had_nl) line[len-1] = '\n';
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    snprintf(patched, need, "%.*s%s%s", (int)prefix_len, line, new_end, suffix);
    if (add_partial) {
        char *brace = strrchr(patched, '}');
        if (brace) {
            *brace = '\0';
            strncat(patched, ",\"partial\":1}", need - strlen(patched) - 1);
        }
    }
    if (had_nl) strncat(patched, "\n", need - strlen(patched) - 1);

    free(lines[last_json_idx]);
    lines[last_json_idx] = patched;

    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", SESSION_HISTORY_FILE);
    FILE *wf = fopen(tmp_path, "w");
    if (!wf) {
        for (size_t i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }
    for (size_t i = 0; i < count; i++) fputs(lines[i], wf);
    fflush(wf);
    fsync(fileno(wf));
    fclose(wf);
    rename(tmp_path, SESSION_HISTORY_FILE);

    for (size_t i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 1;
}

static void sweep_stale_session(void) {
    FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
    char last_line[2048] = {0};
    char buf[2048];
    if (rf) {
        while (fgets(buf, sizeof(buf), rf)) {
            if (buf[0] == '{') {
                size_t bn = strlen(buf);
                if (bn >= sizeof(last_line)) bn = sizeof(last_line) - 1;
                memcpy(last_line, buf, bn);
                last_line[bn] = '\0';
            }
        }
        fclose(rf);
    }

    int end_missing = (last_line[0] != '\0' &&
        (strstr(last_line, "\"end\":\"\"") || strstr(last_line, "\"end\":\"none\"")));
    if (end_missing) {
        if (rewrite_last_history_end("stale_recovered"))
            asb_log("sweep: stale history session patched -> end=stale_recovered, partial=1");
        else
            asb_log("sweep: detected stale history session but failed to patch");
    }

    FILE *lf = fopen(LOG_FILE, "r");
    if (!lf) return;
    int has_session_start = 0;
    int has_session_end = 0;
    while (fgets(buf, sizeof(buf), lf)) {
        if (strstr(buf, "session_start")) has_session_start = 1;
        if (strstr(buf, "profile changed") || strstr(buf, "session_end") || strstr(buf, "idle_boundary"))
            has_session_end = 1;
    }
    fclose(lf);
    if (has_session_start && !has_session_end) {
        asb_log("sweep: previous governor session may not have closed cleanly");
        if (!end_missing && last_line[0] != '\0')
            asb_log("sweep: history already finalized or no patchable end field found");
    }
}

typedef struct {
    int   session_count;
    float avg_time_to_first_sus;
    float avg_time_to_first_thermal;
    float avg_max_temp;
    float avg_gap_p0;
    float avg_efficiency;
    int   degrade_count;
    int   hot_fail_count;
    float avg_degrade_age;
    int   bat_tune_cooldown;
    /* cause streak -- consecutive sessions with same limiter/reason */
    int   cause_streak;       /* how many consecutive same-cause sessions */
    int   cause_streak_type;  /* 0=none 1=wake_noise 2=screen_on 3=no_settle 4=vendor_clamp 5=thermal */
    /* OTA quarantine -- skip learning after environment change */
    int   quarantine_remaining; /* >0 = skip pstats learning for N more clean sessions */
    
    float avg_idle_q;            /* average idle quality across clean sessions */
    float avg_wph;               /* average wakes per hour */
    int   clean_night_count;     /* how many clean_night sessions recorded */
    float avg_quiet_duration_min;/* average quiet night duration in minutes */
    /* Battery Memory Split -- separate night vs day tracking */
    float night_avg_iq;
    float night_avg_wph;
    int   night_count;
    float day_avg_iq;
    float day_avg_wph;
    int   day_count;
    long  last_tune_ts_fast_idle;
    long  last_tune_ts_heavy_load;
    long  last_tune_ts_moderate_load;
    long  last_tune_ts_light_gpu;
} asb_persistent_stats_t;

static asb_persistent_stats_t g_pstats_per[3] = {{0},{0},{0}};
static asb_persistent_stats_t g_pstats = {0};

static void session_plan_apply_prearm(asb_fsm_t *fsm) {
    if (fsm->profile_idx != PROFILE_PERFORMANCE) return;
    if (fsm->state < ASB_STATE_HEAVY) return;
    asb_persistent_stats_t *ps = &g_pstats_per[PROFILE_PERFORMANCE];
    if (ps->cause_streak_type == 4 && ps->cause_streak >= 3)
        fsm->plan.ac_prearm = 1;
}

static void session_reset_and_replan(asb_fsm_t *fsm, int screen_on) {
    fsm_session_reset(fsm);
    fsm->plan.ac_used = 0;
    storm_shield_reset();
    anti_clamp_reset();
    action_waste_reset();
    session_plan_build(fsm, screen_on);
    session_plan_apply_prearm(fsm);
}

/* vendor clamp counters — declared early so write_state can emit them.
 * Incremented from v44_conflict_record() during status JSON build. */
static unsigned long g_v44_clamp_total = 0;       /* total times we saw "vendor_clamp" */
static unsigned long g_v44_raised_total = 0;      /* total times we saw "vendor_raised" */
static unsigned long g_v44_clamp_1h = 0;          /* rolling 1h window */
static time_t        g_v44_clamp_1h_start = 0;    /* window start ts */
static unsigned long v44_clamp_1h_now(void);

/* cap ownership — declared early so write_state can emit them.
 * Updated by asb_cap_compute_owner() from status JSON path. */
static int    g_cap_owner_eff = 0;
static time_t g_cap_owner_since = 0;
static int    g_cap_recent_vendor_clamps = 0;
static time_t g_cap_recent_window_start = 0;
static int    g_cap_slow_vendor_clamps = 0;
static time_t g_cap_slow_window_start = 0;
static time_t g_cap_vendor_hold_until = 0;
static int    g_cap_detente_active = 0;
static time_t g_cap_detente_since = 0;
static long   g_cap_detente_skipped = 0;
static long   g_write_attempts = 0;
static long   g_write_skipped_detente = 0;
static long   g_write_skipped_backoff = 0;
static int    g_drain_spike_bump = 0;
static time_t g_drain_spike_until = 0;
/* Budget accuracy: snapshot a prediction, then grade it after a window. */
static time_t g_budget_acc_anchor_ts = 0;
static int    g_budget_acc_anchor_pct = -1;
static int    g_budget_acc_pred_h_x10 = -1;
static int    g_budget_acc_error_pct = -1;
static int    g_budget_acc_score = -1;
static int    g_budget_bias_dir = 0;
static int    g_budget_bias_streak = 0;

/* Forward declarations for write_state */
static int asb_cap_writes_should_back_off(void);
static const char *asb_cap_owner_name(int o);

/*
 * — V50 night window learner.
 * Both are EWMA'd as minutes-of-day with circular midnight wrap and persisted, so after
 * night_quiet_auto_min_samples nights the learned window replaces the static hours for
 * quiet-night acceleration and for the Smart sleep override (which previously ended at the
 * fixed 09:00 daypart boundary even when the user was still asleep).
 */
#define NIGHT_WINDOW_FILE "/data/adb/asb/night_window.conf"
static int    g_night_sleep_min = -1;
static int    g_night_wake_min  = -1;
static int    g_night_samples   = 0;
static time_t g_night_off_since = 0;
static int    g_night_off_minute = -1;
static int    g_night_onset_recorded = 0;
static int    g_night_samples_accepted = 0;
static int    g_night_samples_rejected = 0;
static int    g_night_reject_reason = 0;
#define ASB_NIGHT_REJECT_NONE 0
#define ASB_NIGHT_REJECT_WAKE_OUT_OF_WINDOW 1
static long   g_night_dark_accum_s = 0;
static int    g_night_prev_screen = -1;
static int    g_night_pending_wake_min = -1;
static time_t g_night_pending_wake_ts = 0;

static int asb_minute_of_day(time_t t) {
    struct tm tmv;
    if (!localtime_r(&t, &tmv)) return -1;
    return tmv.tm_hour * 60 + tmv.tm_min;
}

static int asb_min_in_window(int m, int from, int to) {
    if (m < 0) return 0;
    return (from > to) ? (m >= from || m < to) : (m >= from && m < to);
}

static void asb_night_ewma(int *cur, int sample) {
    if (*cur < 0) { *cur = sample; return; }
    int d = ((sample - *cur) % 1440 + 1440) % 1440;
    if (d > 720) d -= 1440;
    *cur = ((*cur + (d * ASB_NIGHT_EWMA_NUM) / ASB_NIGHT_EWMA_DEN) + 1440) % 1440;
}

static void asb_night_window_save(void) {
    FILE *f = fopen(NIGHT_WINDOW_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "sleep_min=%d\nwake_min=%d\nsamples=%d\n",
            g_night_sleep_min, g_night_wake_min, g_night_samples);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename(NIGHT_WINDOW_FILE ".tmp", NIGHT_WINDOW_FILE);
}

static void asb_night_window_load(void) {
    FILE *f = fopen(NIGHT_WINDOW_FILE, "r");
    if (!f) return;
    char line[64];
    while (fgets(line, sizeof(line), f)) {
        int v;
        if (sscanf(line, "sleep_min=%d", &v) == 1 && v >= -1 && v < 1440)
            g_night_sleep_min = v;
        else if (sscanf(line, "wake_min=%d", &v) == 1 && v >= -1 && v < 1440)
            g_night_wake_min = v;
        else if (sscanf(line, "samples=%d", &v) == 1 && v >= 0 && v <= 100000)
            g_night_samples = v;
    }
    fclose(f);
    if (g_night_sleep_min >= 0 && g_night_wake_min >= 0)
        asb_log("night_window: loaded learned %02d:%02d -> %02d:%02d (n=%d)",
                g_night_sleep_min / 60, g_night_sleep_min % 60,
                g_night_wake_min / 60, g_night_wake_min % 60, g_night_samples);
}

static int asb_night_window_ready(void) {
    return g_asb_cfg.night_quiet_auto &&
           g_night_samples >= g_asb_cfg.night_quiet_auto_min_samples &&
           g_night_sleep_min >= 0 && g_night_wake_min >= 0;
}

static int asb_night_window_active(time_t now) {
    if (!asb_night_window_ready()) return 0;
    int m = asb_minute_of_day(now);
    if (m < 0) return 0;
    int from = (g_night_sleep_min - ASB_NIGHT_MARGIN_PRE_MIN + 1440) % 1440;
    int to   = (g_night_wake_min  - ASB_NIGHT_MARGIN_POST_MIN + 1440) % 1440;
    return asb_min_in_window(m, from, to);
}

static void asb_night_window_tick(int screen_on, time_t now) {
    if (!g_asb_cfg.night_quiet_auto) return;
    if (g_night_prev_screen < 0) {
        g_night_prev_screen = screen_on;
        if (!screen_on) {
            g_night_off_since = now;
            g_night_off_minute = asb_minute_of_day(now);
        }
        return;
    }
    if (screen_on != g_night_prev_screen) {
        if (!screen_on) {
            long pend_age = (g_night_pending_wake_ts > 0)
                            ? (long)(now - g_night_pending_wake_ts) : -1;
            if (pend_age >= 0 && pend_age < 600) {
                /* mid-night check, not a real wake — keep accumulating */
                g_night_pending_wake_min = -1;
                g_night_pending_wake_ts = 0;
            }
            g_night_off_since = now;
            g_night_off_minute = asb_minute_of_day(now);
            g_night_onset_recorded = 0;
        } else {
            long off_dur = (g_night_off_since > 0)
                           ? (long)(now - g_night_off_since) : 0;
            if (off_dur > 0) g_night_dark_accum_s += off_dur;
            if (g_night_dark_accum_s >= ASB_NIGHT_MIN_SLEEP_S) {
                int m = asb_minute_of_day(now);
                if (asb_min_in_window(m, ASB_NIGHT_WAKE_WIN_FROM,
                                      ASB_NIGHT_WAKE_WIN_TO)) {
                    g_night_pending_wake_min = m;
                    g_night_pending_wake_ts = now;
                } else {
                    /* Woke outside the plausible wake window — likely an
                       irregular night (nap, travel, odd schedule). Reject the
                       sample rather than dragging the learned wake time toward
                       a one-off outlier. */
                    g_night_dark_accum_s = 0;
                    g_night_samples_rejected++;
                    g_night_reject_reason = ASB_NIGHT_REJECT_WAKE_OUT_OF_WINDOW;
                }
            }
            g_night_off_since = 0;
        }
        g_night_prev_screen = screen_on;
        return;
    }
    if (screen_on) {
        if (g_night_pending_wake_min >= 0 &&
            now - g_night_pending_wake_ts >= 600) {
            asb_night_ewma(&g_night_wake_min, g_night_pending_wake_min);
            if (g_night_samples < 100000) g_night_samples++;
            g_night_samples_accepted++;
            asb_log("night_window: wake sample %02d:%02d -> learned %02d:%02d (n=%d)",
                    g_night_pending_wake_min / 60, g_night_pending_wake_min % 60,
                    g_night_wake_min / 60, g_night_wake_min % 60, g_night_samples);
            g_night_pending_wake_min = -1;
            g_night_pending_wake_ts = 0;
            g_night_dark_accum_s = 0;
            asb_night_window_save();
        }
        return;
    }
    if (!g_night_onset_recorded && g_night_off_since > 0 &&
        g_night_dark_accum_s < ASB_NIGHT_MIN_SLEEP_S &&
        now - g_night_off_since >= ASB_NIGHT_ONSET_HOLD_S &&
        asb_min_in_window(g_night_off_minute, ASB_NIGHT_ONSET_WIN_FROM,
                          ASB_NIGHT_ONSET_WIN_TO)) {
        asb_night_ewma(&g_night_sleep_min, g_night_off_minute);
        g_night_onset_recorded = 1;
        asb_log("night_window: onset sample %02d:%02d -> learned %02d:%02d",
                g_night_off_minute / 60, g_night_off_minute % 60,
                g_night_sleep_min / 60, g_night_sleep_min % 60);
        asb_night_window_save();
    }
}

/*
 * Adaptive thermal budget. It is deliberately computed inside the native FSM
 * instead of a second shell loop: no extra wakeups, one owner for state, and
 * the policy sees the same headroom/thermal-cap data as the writer.
 *
 * Increasing restraint is immediate. Releasing restraint is dwell-limited so
 * noisy headroom samples do not oscillate caps and create sysfs churn.
 */
/* Last valid control temperature, kept so the thermal read can be skipped without
 * losing the distance-to-threshold check that decides whether skipping is safe. */
static int g_last_cpu_max_c = 0;
/* Current screen-on tick interval, so the timer is only re-armed when it actually
 * changes rather than on every pass. */
static int g_active_interval = TIMER_ACTIVE_S;

static int g_budget_trim_pct = 0;
/* Whether the surface-comfort trim is currently engaged, for hysteresis.
 *
 * The threshold was a bare >= 43 with no exit band, and a field capture shows the cost:
 * mean surface temperature across 122 phases was exactly 43 C, so a 20% ceiling trim was
 * active essentially all the time - on a phone whose owner reported it running hotter and
 * draining faster WITH the module than without.
 *
 * That is race-to-idle arriving from the other direction. Trimming the ceiling makes every
 * task take longer, and a longer task keeps the cores, the panel and the radio awake for
 * the whole of it. Past a point the trim costs more heat than it saves.
 *
 * 43 C is also not a comfort problem. A phone in the hand sits there under any real use;
 * the temperature people actually describe as too hot to hold is closer to 46-48. Entering
 * at 46 and leaving at 42 keeps the guard for the case it was written for and stops it
 * living permanently in ordinary use. */
static int g_budget_surface_engaged = 0;
static time_t g_budget_trim_changed_at = 0;
static char g_budget_reason[32] = "disabled";
static int g_budget_base_trim_pct = 0;
static int g_budget_stage = 0;
static int g_budget_envelope_bonus_pct = 0;

/*
 * Device-specific active-use policy is a derived manifest, not an alternative
 * thermal controller. The shell writes it from observed platform/topology/GPU
 * facts before this daemon starts; the values are percentage/uclamp deltas only.
 * A missing, malformed or unrecognised manifest is a deliberate no-op.
 */
typedef struct {
    int active;
    int light_bonus_pct;
    int moderate_bonus_pct;
    int severe_bonus_pct;
    int gpu_idle_bonus_pct;
    int bg_uclamp_moderate_delta;
    int bg_uclamp_severe_delta;
    char tier[16];
    char reason[48];
} asb_active_efficiency_t;

static asb_active_efficiency_t g_active_efficiency;

static void asb_active_efficiency_reset(const char *reason) {
    memset(&g_active_efficiency, 0, sizeof(g_active_efficiency));
    snprintf(g_active_efficiency.tier, sizeof(g_active_efficiency.tier), "generic");
    snprintf(g_active_efficiency.reason, sizeof(g_active_efficiency.reason), "%s",
             reason ? reason : "inactive");
}

static int asb_active_efficiency_int(const char *text, int low, int high, int *out) {
    char *end = NULL;
    long value;
    if (!text || !*text || !out) return -1;
    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < low || value > high) return -1;
    *out = (int)value;
    return 0;
}

static void asb_active_efficiency_load(void) {
    FILE *f;
    char line[128];
    int schema = 0, active = 0, seen = 0, malformed = 0;

    asb_active_efficiency_reset("manifest_missing");
    f = fopen(ACTIVE_EFFICIENCY_FILE, "r");
    if (!f) return;

    while (fgets(line, sizeof(line), f)) {
        char *key = line;
        char *value = strchr(line, '=');
        size_t len;
        if (!value || key[0] == '#') continue;
        *value++ = '\0';
        len = strcspn(value, "\r\n");
        value[len] = '\0';
        if (!strcmp(key, "schema")) {
            malformed |= asb_active_efficiency_int(value, 1, 1, &schema) != 0;
        } else if (!strcmp(key, "status")) {
            active = !strcmp(value, "active");
        } else if (!strcmp(key, "tier")) {
            snprintf(g_active_efficiency.tier, sizeof(g_active_efficiency.tier), "%s", value);
            seen |= 1;
        } else if (!strcmp(key, "reason")) {
            snprintf(g_active_efficiency.reason, sizeof(g_active_efficiency.reason), "%s", value);
        } else if (!strcmp(key, "budget_light_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.light_bonus_pct) != 0;
            seen |= 2;
        } else if (!strcmp(key, "budget_moderate_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.moderate_bonus_pct) != 0;
            seen |= 4;
        } else if (!strcmp(key, "budget_severe_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.severe_bonus_pct) != 0;
            seen |= 8;
        } else if (!strcmp(key, "gpu_idle_trim_bonus_pct")) {
            malformed |= asb_active_efficiency_int(value, 0, 8, &g_active_efficiency.gpu_idle_bonus_pct) != 0;
            seen |= 16;
        } else if (!strcmp(key, "bg_uclamp_moderate_delta")) {
            malformed |= asb_active_efficiency_int(value, 0, 256,
                                                   &g_active_efficiency.bg_uclamp_moderate_delta) != 0;
            seen |= 32;
        } else if (!strcmp(key, "bg_uclamp_severe_delta")) {
            malformed |= asb_active_efficiency_int(value, 0, 320,
                                                   &g_active_efficiency.bg_uclamp_severe_delta) != 0;
            seen |= 64;
        }
    }
    fclose(f);

    if (schema != 1 || !active || malformed || seen != 127 ||
        (strcmp(g_active_efficiency.tier, "sm8750") &&
         strcmp(g_active_efficiency.tier, "sm8850") &&
         strcmp(g_active_efficiency.tier, "sm8650") &&
         strcmp(g_active_efficiency.tier, "sm8550") &&
         strcmp(g_active_efficiency.tier, "capability"))) {
        asb_active_efficiency_reset(malformed ? "manifest_invalid" : "manifest_inactive");
        return;
    }
    if (g_active_efficiency.moderate_bonus_pct < g_active_efficiency.light_bonus_pct ||
        g_active_efficiency.severe_bonus_pct < g_active_efficiency.moderate_bonus_pct ||
        g_active_efficiency.bg_uclamp_severe_delta < g_active_efficiency.bg_uclamp_moderate_delta) {
        asb_active_efficiency_reset("manifest_nonmonotonic");
        return;
    }
    g_active_efficiency.active = 1;
    asb_log("active_efficiency: tier=%s reason=%s bonus=%d/%d/%d gpu=%d bg=%d/%d",
            g_active_efficiency.tier, g_active_efficiency.reason,
            g_active_efficiency.light_bonus_pct, g_active_efficiency.moderate_bonus_pct,
            g_active_efficiency.severe_bonus_pct, g_active_efficiency.gpu_idle_bonus_pct,
            g_active_efficiency.bg_uclamp_moderate_delta,
            g_active_efficiency.bg_uclamp_severe_delta);
}

static int asb_active_efficiency_bonus(int stage) {
    if (!g_active_efficiency.active) return 0;
    if (stage >= 3) return g_active_efficiency.severe_bonus_pct;
    if (stage == 2) return g_active_efficiency.moderate_bonus_pct;
    if (stage == 1) return g_active_efficiency.light_bonus_pct;
    return 0;
}
/* Self-overhead counters: event-driven native loop only, no extra sampler. */
static unsigned long g_governor_event_wakeups = 0;
static unsigned long g_governor_timer_wakeups = 0;

static void asb_budget_raise(int *candidate, const char **reason, int trim, const char *why) {
    if (trim > *candidate) {
        *candidate = trim;
        *reason = why;
    }
}

static int asb_adaptive_budget_trim_pct(const asb_metrics_t *m, const asb_fsm_t *fsm) {
    int candidate = 0;
    int base_candidate = 0;
    int stage = 0;
    int envelope_bonus = 0;
    const char *reason = "cool";
    if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&
        fsm->state != ASB_STATE_SUSTAINED) {
        if (m->therm.headroom_valid) {
            int hr = m->therm.headroom_pct;
            /* Hysteresis on the headroom stages.
             *
             * Three bare thresholds with no exit band, and headroom wanders by a couple of
             * points from tick to tick. A capture shows the result: 193 ceiling changes
             * across 613 samples - almost every third tick - with a mean temperature delta
             * of 2.5 C behind them, cycling through six different p0 values while the die
             * sat between 47 and 49 C.
             *
             * That is not thermal management, it is chatter. Every change is a write, the
             * governor re-plans around it, and the cluster ramps to a new ceiling for a few
             * seconds before the next tick moves it again - which costs more energy than
             * the trim saves.
             *
             * Widening by 4 points on the way OUT only: entering a stage is as prompt as
             * before, leaving it requires the headroom to have genuinely recovered rather
             * than to have jittered across the line.
             */
            int hyst = (g_budget_trim_pct > 0) ? 4 : 0;
            if (hr <= g_asb_cfg.thermal_budget_severe_headroom_pct + hyst)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "headroom_severe");
            else if (hr <= g_asb_cfg.thermal_budget_moderate_headroom_pct + hyst)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "headroom_moderate");
            else if (hr <= g_asb_cfg.thermal_budget_light_headroom_pct + hyst)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_light_trim_pct, "headroom_light");
        }
        /* Skin is the user-facing safety signal. A fast trend anticipates heat
         * before the emergency CPU junction guard is crossed. */
        if (m->therm.temp_valid && m->therm.skin_temp_c > 0) {
            if (m->therm.skin_temp_c >= g_asb_cfg.thermal_skin_c + 3)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "skin_severe");
            else if (m->therm.skin_temp_c >= g_asb_cfg.thermal_skin_c)
                asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "skin_moderate");
        }
        if (fsm->thermal_trend >= 10)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_severe_trim_pct, "thermal_trend_fast");
        else if (fsm->thermal_trend >= 6)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_moderate_trim_pct, "thermal_trend_rising");
        /* Battery current is a tie-breaker only; it never escalates beyond a
         * light trim and is ignored while charging because its semantics vary. */
        if (!m->bat.charging && m->bat.current_ma >= 1800)
            asb_budget_raise(&candidate, &reason, g_asb_cfg.thermal_budget_light_trim_pct, "battery_current");
        /* Screen-on comfort is intentionally a tie-breaker, not a generic cap.
         *
         * Battery keeps its proven 450 mA evidence gate. Debug 6 telemetry adds a second
         * safe case: ordinary screen-on feed/browser use averaged about 430 mA with a warm
         * CPU, while its foreground load was not gaming or camera work. Waiting for the old
         * Battery-bias opt-in misses that common Smart profile use case.
         *
         * Admit only a freshly identified light/medium Smart foreground app at a modest
         * 350 mA. It still reuses the existing light trim (not a new cap ladder), requires
         * valid thermal evidence, and excludes games, camera, charging and screen-off work.
         * Unknown/stale package context fails closed; the explicit battery-bias setting retains
         * its earlier 250 mA path. */
        int smart_screenon_comfort =
            fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled && g_pkg_detect_ok &&
            (g_smart_rt.app_hint <= ASB_APP_MEDIUM || g_asb_cfg.smart_battery_bias >= 400);
        int comfort_current_ma = g_asb_cfg.smart_battery_bias >= 400 ? 250 :
                                 (smart_screenon_comfort ? 350 : 450);
        if (!m->bat.charging && m->misc.screen_on && !m->misc.camera_active &&
            fsm->state != ASB_STATE_GAMING && m->therm.temp_valid &&
            m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp &&
            m->bat.current_ma >= comfort_current_ma &&
            (fsm->profile_idx == PROFILE_BATTERY || smart_screenon_comfort))
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_light_trim_pct,
                             smart_screenon_comfort ? "screenon_comfort_smart_medium" : "screenon_comfort");
        /* The multi-user V64 captures repeat a second safe Smart-only foreground pattern:
         * a fresh light/medium app at a high sampled discharge current can warm the CPU/body
         * before the ordinary 48C comfort point.  Do not turn that into a universal current
         * cap: require valid low-GPU data, current >=600mA, a recognised non-heavy app,
         * screen-on discharge and a small 42C CPU floor. Games, camera, charging, screen-off,
         * SUSTAINED and unknown/stale app context all fail closed. It reuses the same light
         * trim rather than changing the profile's frequency tables or radio policy. */
        int smart_high_current_comfort =
            fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled && g_pkg_detect_ok &&
            g_smart_rt.app_hint <= ASB_APP_MEDIUM && m->gpu.load_valid &&
            m->gpu.load_pct < g_asb_cfg.heavy_gpu_enter &&
            fsm->state != ASB_STATE_GAMING && fsm->state != ASB_STATE_SUSTAINED;
        if (smart_high_current_comfort && !m->bat.charging && m->misc.screen_on &&
            !m->misc.camera_active && m->therm.temp_valid &&
            m->therm.cpu_max_c >= 42 && m->bat.current_ma >= 600)
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_light_trim_pct,
                             "screenon_comfort_smart_high_current");
        /* Some vendor `skin` zones are internal/remote and remain 35-40C while the
         * body-adjacent hotspot that the user actually feels reaches 43-45C.  The
         * new capture on canoe showed exactly that: CPU/skin remained below the
         * configured skin threshold, so Smart only kept the headroom light trim
         * despite sustained screen-on LTE/media drain and a 44C surface hotspot.
         *
         * Treat that verified surface signal as an earlier, bounded Smart-only
         * comfort trigger.  It reuses the existing moderate budget ladder rather
         * than introducing a per-device frequency table.  Battery, gaming, camera,
         * charging and screen-off paths remain excluded; vendor thermal is still
         * authoritative above it. */
        /* SUSTAINED is normally excluded from the generic budget ladder to protect a
         * genuinely heavy/video workload. The capture here exposes a narrow exception:
         * a high-bias Smart session can be SUSTAINED while the CPU/body hotspot is warm,
         * yet the foreground classification is only idle/light/medium and GPU remains below
         * the HEAVY gate. Waiting for SUSTAINED to exit leaves the user under a vendor cap
         * without ASB first lowering its own requested rail. Keep this fail-closed: no
         * package evidence, heavy/gaming hint, invalid/high GPU, camera, charging or screen
         * off all retain the existing no-trim SUSTAINED behavior. */
        int surface_comfort_sustained =
            fsm->state == ASB_STATE_SUSTAINED && g_pkg_detect_ok &&
            g_smart_rt.app_hint <= ASB_APP_MEDIUM && m->gpu.load_valid &&
            m->gpu.load_pct < g_asb_cfg.heavy_gpu_enter;
        if (smart_screenon_comfort && !m->bat.charging && m->misc.screen_on &&
            !m->misc.camera_active && fsm->state != ASB_STATE_GAMING &&
            m->therm.temp_valid &&
            m->therm.surface_hotspot_c >= (g_budget_surface_engaged ? 42 : 46) &&
            m->bat.current_ma >= 250 &&
            (fsm->state != ASB_STATE_SUSTAINED || surface_comfort_sustained))
            asb_budget_raise(&candidate, &reason,
                             g_asb_cfg.thermal_budget_moderate_trim_pct,
                             surface_comfort_sustained ? "surface_comfort_smart_sustained"
                                                       : "surface_comfort_smart");
        /* Camera deadlines are a QoS lease: do not introduce a light-only trim
         * during capture. Real thermal stress still wins at moderate/severe. */
        if (m->misc.camera_active && candidate <= g_asb_cfg.thermal_budget_light_trim_pct) {
            candidate = 0;
            reason = "camera_qos";
        }
    } else if (fsm->thermal_cap || fsm->state == ASB_STATE_SUSTAINED) {
        reason = "platform_thermal";
    }
    /*
     * Universal active thermal recovery for recognised media/feed use. Sustained state keeps
     * its normal conservative rail, but a warm LTE/video/feed session can keep generating heat
     * after the interactive burst ends. Reduce that residual generation with the existing light
     * budget only when a fresh foreground package is positively known as media. This is not a
     * broad SUSTAINED cap: games and unknown/heavy apps fail closed, as do camera, charging,
     * screen-off and any missing/stale package signal. It therefore works across SoCs through
     * capabilities and QoS evidence rather than device names or fixed frequencies.
     */
    if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&
        fsm->state == ASB_STATE_SUSTAINED &&
        fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
        m->misc.screen_on && !m->misc.camera_active && !m->bat.charging &&
        m->therm.temp_valid && m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp &&
        m->bat.current_ma >= 450 &&
        g_pkg_detect_ok && g_smart_media_pkg_known &&
        g_smart_rt.app_hint < ASB_APP_GAMING) {
        asb_budget_raise(&candidate, &reason,
                         g_asb_cfg.thermal_budget_light_trim_pct, "media_recovery");
    }
    base_candidate = candidate;
    if (candidate > 0) {
        if (candidate >= g_asb_cfg.thermal_budget_severe_trim_pct) stage = 3;
        else if (candidate >= g_asb_cfg.thermal_budget_moderate_trim_pct) stage = 2;
        else stage = 1;
        envelope_bonus = asb_active_efficiency_bonus(stage);
        candidate += envelope_bonus;
        if (candidate > 60) candidate = 60;
    }
    time_t now = time(NULL);
    if (candidate > g_budget_trim_pct ||
        now - g_budget_trim_changed_at >= g_asb_cfg.thermal_budget_dwell_s) {
        if (candidate != g_budget_trim_pct || strcmp(reason, g_budget_reason) != 0) {
            g_budget_trim_pct = candidate;
            /* Track engagement for the surface hysteresis: the band only means anything
             * if the exit threshold is checked against a state we actually recorded. */
            g_budget_surface_engaged =
                (reason && strncmp(reason, "surface_comfort", 15) == 0) ? 1 : 0;
            g_budget_trim_changed_at = now;
            g_budget_base_trim_pct = base_candidate;
            g_budget_stage = stage;
            g_budget_envelope_bonus_pct = envelope_bonus;
            snprintf(g_budget_reason, sizeof(g_budget_reason), "%s", reason);
            asb_log("thermal_budget: trim=%d base=%d bonus=%d stage=%d reason=%s headroom=%d skin=%d trend=%d ma=%d camera=%d state=%s",
                    g_budget_trim_pct, g_budget_base_trim_pct, g_budget_envelope_bonus_pct,
                    g_budget_stage, g_budget_reason, m->therm.headroom_pct,
                    m->therm.skin_temp_c, fsm->thermal_trend, m->bat.current_ma,
                    m->misc.camera_active, asb_state_names[fsm->state]);
        }
    }
    return g_budget_trim_pct;
}

static void asb_active_efficiency_apply_caps(asb_profile_caps_t *caps,
                                              const asb_metrics_t *m,
                                              const asb_fsm_t *fsm) {
    int delta;
    int media_recovery;
    if (!g_asb_cfg.thermal_budget_enable || !g_active_efficiency.active ||
        g_budget_stage <= 0 || fsm->thermal_cap) return;

    /* A warm recognised media/feed SUSTAINED session may shrink background cgroups only.
     * Re-check every QoS gate here instead of trusting the dwell-held budget reason: an app
     * switch to a game, camera launch, charging event or stale package evidence immediately
     * restores the normal policy. Foreground/top-app caps are deliberately untouched. */
    media_recovery = !strcmp(g_budget_reason, "media_recovery") &&
                     fsm->state == ASB_STATE_SUSTAINED &&
                     fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                     m && m->misc.screen_on && !m->misc.camera_active && !m->bat.charging &&
                     m->therm.temp_valid && m->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp &&
                     m->bat.current_ma >= 450 && g_pkg_detect_ok &&
                     g_smart_media_pkg_known && g_smart_rt.app_hint < ASB_APP_GAMING;
    if (fsm->state == ASB_STATE_SUSTAINED && !media_recovery) return;

    /* Extend existing idle trim only outside PERFORMANCE, gaming/video and thermal-cap paths. */
    if (g_active_efficiency.gpu_idle_bonus_pct > 0 &&
        fsm->profile_idx != PROFILE_PERFORMANCE && fsm->gpu_video_ticks < 2 &&
        (fsm->state == ASB_STATE_LIGHT_IDLE || fsm->state == ASB_STATE_MODERATE) &&
        g_asb_cfg.gpu_idle_trim_pct > 0) {
        int floor_gpu = g_asb_cfg.gpu_idle_trim_floor > 0
                        ? g_asb_cfg.gpu_idle_trim_floor : 55;
        int trimmed = caps->gpu_max_pct - g_active_efficiency.gpu_idle_bonus_pct;
        if (trimmed < floor_gpu) trimmed = floor_gpu;
        if (trimmed < caps->gpu_max_pct) caps->gpu_max_pct = trimmed;
    }

    /* Keep foreground/top-app caps intact: only background cgroups lean further. Known
     * media recovery is allowed at light stage; every other workload still needs the existing
     * moderate/severe threshold before background restraint changes. */
    if ((!media_recovery && g_budget_stage < 2) || caps->uclamp_bg_max <= 0) return;
    delta = g_budget_stage >= 3 ? g_active_efficiency.bg_uclamp_severe_delta
                                : g_active_efficiency.bg_uclamp_moderate_delta;
    if (delta > 0) {
        int target = caps->uclamp_bg_max - delta;
        if (target < 128) target = 128;
        if (target < caps->uclamp_bg_max) caps->uclamp_bg_max = target;
    }
}

static void asb_apply_adaptive_budget_caps(asb_profile_caps_t *caps,
                                           const asb_metrics_t *m,
                                           const asb_fsm_t *fsm) {
    int trim = asb_adaptive_budget_trim_pct(m, fsm);
    if (trim > 0 && trim < 100) {
        int keep = 100 - trim;
        for (int i = 0; i < 3; i++) {
            if (caps->cpu_max[i] > 0) caps->cpu_max[i] = caps->cpu_max[i] * keep / 100;
            if (caps->cpu_min[i] > 0 && caps->cpu_max[i] > 0 && caps->cpu_min[i] > caps->cpu_max[i])
                caps->cpu_min[i] = caps->cpu_max[i];
        }
        if (caps->gpu_max_pct > 0) {
            caps->gpu_max_pct = caps->gpu_max_pct * keep / 100;
            if (caps->gpu_max_pct < 10) caps->gpu_max_pct = 10;
            if (caps->gpu_min_pct > caps->gpu_max_pct) caps->gpu_min_pct = caps->gpu_max_pct;
        }
    }
    asb_active_efficiency_apply_caps(caps, m, fsm);
}

static void write_state(const asb_fsm_t *fsm, const asb_metrics_t *m,
                        asb_prediction_t pred)
{
    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *pred_names[] = {"unknown","idle","light","active"};

    FILE *f = fopen(STATE_FILE ".tmp", "w");
    if (!f) return;
    int rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    fprintf(f,
        "state=%s\nprofile=%s\n"
        "mA=%d\ngpu_pct=%d\ngpu_valid=%d\nload1=%.2f\n"
        "cpu_max=%d,%d,%d\ncpu_max_live=%d,%d\n"
        "thermal=%d\ncap_temp=%d\n"
        "headroom_pct=%d\nheadroom_valid=%d\nperf_cap_p0=%d\nperf_cap_p6=%d\n"
        "predict=%s\n"
        "screen=%d\ncapacity=%d\n"
        "dwell_sec=%ld\nboost=%d\n"
        "cap_gap_p0=%d\ncap_gap_p1=%d\n"
        "last_sustained_reason=%s\n"
        "highload_mode=%s\n"
        "ses_gaming=%d\nses_sustained=%d\nses_thermal=%d\nses_unreachable=%d\n"
        "ses_t_heavy=%ld\nses_t_gaming=%ld\nses_t_sustained=%ld\n"
        "ses_avg_gap_p0=%d\nses_max_gap_p0=%d\nses_max_temp=%d\nses_auto_degraded=%d\n"
        "bat_deep_idle=%ld\nbat_light_idle=%ld\nbat_moderate=%ld\nbat_wake_cycles=%d\n"
        "bat_screen_off=%d\nbat_ttd=%ld\n"
        "ses_t2s=%ld\nses_t2thermal=%ld\nses_t2g=%ld\nses_efficiency=%d\nses_recovery=%d\n"
        "hist_sessions=%d\nhist_t2s=%.0f\nhist_temp=%.0f\nhist_gap=%.0f\nhist_eff=%.0f\nhist_deg=%d\n",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma,
        m->gpu.load_pct,
        m->gpu.load_valid,
        m->cpu.load1,
        /* cpu_max stays the REQUESTED cap - asb_reconcile.sh reads this field as its target.
         *
         * I briefly published the live sysfs value here instead, to stop the state file lying
         * about unsnapped numbers. That turned the reconcile loop into a no-op that could not
         * see drift, and worse: whatever the vendor had raised the cap to became the value the
         * shell then reasserted. A two-hour capture shows the result - 15 of 16 idle samples
         * owned by "shell", three parties writing, and 65 degC during light use.
         *
         * The live value is published separately as cpu_max_live below, so reporting is honest
         * without the enforcement loop losing its reference. */
        fsm->current_caps.cpu_max[0],
        fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        /* What the CPU actually holds, for diagnostics only - kept in its own field so
           nothing that enforces caps can start following it by mistake. */
        sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0),
        sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0),
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        m->therm.headroom_pct,
        m->therm.headroom_valid,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        (rmax0 > 0) ? (fsm->current_caps.cpu_max[0] - rmax0) : 0,
        (rmax1 > 0) ? (fsm->current_caps.cpu_max[1] - rmax1) : 0,
        sustained_reason_name(fsm->sustained_reason),
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" :
        g_asb_cfg.highload_mode == 3 ? "auto" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_time_moderate_sec,
        fsm->bat_wake_cycles,
        fsm->bat_screen_off_count,
        fsm->bat_time_to_first_deep,
        fsm->ses_time_to_first_sus,
        fsm->ses_time_to_first_thermal,
        fsm->ses_time_to_first_gaming,
        fsm->ses_sustained_efficiency,
        fsm->ses_recovery_count,
        g_pstats.session_count,
        g_pstats.avg_time_to_first_sus,
        g_pstats.avg_max_temp,
        g_pstats.avg_gap_p0,
        g_pstats.avg_efficiency,
        g_pstats.degrade_count);
    /* requested/applied/failure/backoff counters from readback-aware native writers */
    writer_write_health_dump(f);
    fprintf(f, "shadow_mode=%d\nthermal_budget_enabled=%d\nthermal_budget_trim_pct=%d\n"
               "thermal_budget_base_trim_pct=%d\nthermal_budget_envelope_bonus_pct=%d\n"
               "thermal_budget_stage=%d\nthermal_budget_reason=%s\nthermal_budget_dwell_s=%d\n"
               "active_efficiency_active=%d\nactive_efficiency_tier=%s\n"
               "active_efficiency_reason=%s\nactive_efficiency_gpu_idle_bonus_pct=%d\n"
               "active_efficiency_bg_uclamp_moderate_delta=%d\n"
               "active_efficiency_bg_uclamp_severe_delta=%d\n",
            g_asb_cfg.shadow_mode, g_asb_cfg.thermal_budget_enable,
            g_budget_trim_pct, g_budget_base_trim_pct, g_budget_envelope_bonus_pct,
            g_budget_stage, g_budget_reason, g_asb_cfg.thermal_budget_dwell_s,
            g_active_efficiency.active, g_active_efficiency.tier,
            g_active_efficiency.reason, g_active_efficiency.gpu_idle_bonus_pct,
            g_active_efficiency.bg_uclamp_moderate_delta,
            g_active_efficiency.bg_uclamp_severe_delta);
    fprintf(f, "governor_event_wakeups=%lu\ngovernor_timer_wakeups=%lu\n"
               "governor_cpu_ms=%ld\n",
            g_governor_event_wakeups, g_governor_timer_wakeups,
            (long)(clock() * 1000 / CLOCKS_PER_SEC));
    long _active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
    int _sus_pct = (_active > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _active) : 0;
    long _bat_tot = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
    int _idle_q = -1;
    if (_bat_tot > 30) {
        _idle_q = (int)(fsm->bat_time_deep_idle_sec * 100 / _bat_tot);
        int _wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
        _idle_q -= _wp;
        if (_idle_q < 0) _idle_q = 0;
    }
    int _cap_eff = -1;
    if (fsm->ses_gaming_entries > 0 && fsm->ses_gap_samples > 0) {
        int _avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
        int _target = (fsm->current_caps.cpu_max[0] > 0) ? fsm->current_caps.cpu_max[0] / 10 : 1;
        _cap_eff = (int)((_target - _avg_gap) * 100 / _target);
        if (_cap_eff < 0) _cap_eff = 0;
        if (_cap_eff > 100) _cap_eff = 100;
    }
    fprintf(f, "sus_pct=%d\nidle_q=%d\ncap_eff=%d\n", _sus_pct, _idle_q, _cap_eff);
    {
        int _pidx = fsm->profile_idx;
        if (_pidx < 0 || _pidx > 2) _pidx = 1;
        fprintf(f, "intent=%s\nhot_fail=%d\ndegrade_at_age=%ld\nprofile_deg=%d\n",
                (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
                    ? intent_names[fsm->ses_intent] : "unknown",
                g_pstats_per[_pidx].hot_fail_count,
                fsm->ses_degrade_at_age,
                g_pstats_per[_pidx].degrade_count);
    }
    fprintf(f, "plan_sensor=%d\nplan_hr=%d\nplan_ac=%d\nplan_deep=%d\nplan_thermal_div=%d\nplan_budget=%d\nplan_prearm=%d\nplan_used=%d\nplan_class=%d\nplan_sensor_budget=%d\nplan_sensor_used=%d\n",
            fsm->plan.sensor_tier, fsm->plan.allow_hr,
            fsm->plan.ac_eligible, fsm->plan.deep_sleep, fsm->plan.thermal_div,
            fsm->plan.ac_budget, fsm->plan.ac_prearm, fsm->plan.ac_used,
            fsm->plan.plan_class, fsm->plan.sensor_budget, fsm->plan.sensor_used);
    {
        long qleft = (g_user_quarantine_active && g_user_quarantine_until > 0)
                     ? (long)(g_user_quarantine_until - time(NULL)) : 0;
        if (qleft < 0) qleft = 0;
        fprintf(f, "quarantine=%d\nuser_id=%d\nquarantine_left=%ld\n",
                fsm->plan.quarantine, g_last_user_id, qleft);
    }
    /*
     * Warm-up flag.
     * Reported exactly that way.
     */
    {
        static int _warm_ticks = 0;
        if (_warm_ticks < 3) _warm_ticks++;
        fprintf(f, "state_warmup=%d\n", (_warm_ticks < 3) ? 1 : 0);
    }
    /* Smart Mode state fields */
    fprintf(f,
            "smart_mode=%d\nsmart_bucket_id=%d\nsmart_daypart=%d\nsmart_is_weekend=%d\n"
            "smart_confidence=%d\nsmart_alpha_battery=%d\nsmart_interactive_bonus=%d\n"
            "smart_sleep_override=%d\nsmart_thermal_veto=%d\n"
            "smart_app_hint=%d\nsmart_fallback_level=%d\n"
            /* Learned per-bucket history, exposed so the effect is observable. Without
             * these two the thermal lean is invisible: alpha moves and nothing says why. */
            "smart_bucket_temp_x10=%d\nsmart_bucket_drain_x10=%d\n"
            "smart_therm_warm_x10=%d\nsmart_therm_cool_x10=%d\n"
            "smart_media_guard_setting=%d\nsmart_media_guard_pkg_known=%d\n"
            "smart_media_guard_active=%d\nsmart_media_guard_age_s=%ld\n"
            "smart_media_guard_reason=%s\n",
            g_smart_rt.enabled,
            g_smart_rt.bucket_id,
            g_smart_rt.daypart,
            g_smart_rt.is_weekend,
            g_smart_rt.conf_x1000,
            g_smart_rt.alpha_battery_x1000,
            g_smart_rt.interactive_bonus_x1000,
            g_smart_rt.night_safe_override ? 1 : 0,
            g_smart_rt.thermal_veto ? 1 : 0,
            g_smart_rt.app_hint,
            g_smart_rt.fallback_level,
            g_smart_rt.bucket_temp_x10,
            g_smart_rt.bucket_drain_x10,
            g_smart_rt.therm_warm_x10,
            g_smart_rt.therm_cool_x10,
            g_asb_cfg.smart_media_guard,
            g_smart_media_pkg_known,
            g_smart_media_guard_active,
            g_smart_media_guard_since > 0 ? (long)(time(NULL) - g_smart_media_guard_since) : 0L,
            g_smart_media_guard_reason);
    fprintf(f, "camera_hold=%d\n", g_cam_guard_on ? 1 : 0);
    fprintf(f, "smart_lowbat_override=%d\nsmart_thermal_trend=%d\nsmart_trend_slope=%d\n",
            g_smart_rt.low_battery_override ? 1 : 0,
            g_smart_rt.thermal_trend_bump,
            g_smart_trend_slope_mc_min);
    /*
     * Cumulative Smart session total, same number the WebUI shows from learner_state.json
     * (smart_sessions.total).
     */
    /* Published so the report can say "the phone is not sleeping" instead of only
     * showing a drain figure and leaving the user to guess why. */
    fprintf(f, "awake_pct_screenoff=%d\nawake_window_min=%ld\n",
            g_awake_pct, g_awake_win_boot_ms / 60000L);
    fprintf(f, "smart_sessions_total=%d\nsmart_last_confidence=%d\n",
            g_smart_sessions_total, g_smart_last_confidence);
    {
        long live_x10 = 0;
        if (g_smart_drain_on_sec >= 300 && g_smart_drain_drop_x100 > 0) {
            live_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
        } else if (g_drain_roll_sec >= 300 && g_drain_roll_x100 > 0) {
            /* The rolling figure, when the current session is too young to have one of its
             * own. This is the case almost all the time - sessions restart on every state
             * change - and it is what stops the banner from freezing on a reading that may
             * be hours old. */
            live_x10 = (g_drain_roll_x100 * 360L) / g_drain_roll_sec;
        }
        /* Halve the rolling window every two hours: the number should follow how the phone
         * is behaving now, not average the whole day into a figure that never moves. */
        if (g_drain_roll_sec >= 7200) {
            g_drain_roll_sec  /= 2;
            g_drain_roll_x100 /= 2;
        } else if (g_smart_drain_last_x10 > 0 &&
                   (time(NULL) - g_smart_drain_last_ts) < ASB_DRAIN_STALE_SEC) {
            /* Nothing measurable in the current session yet - report the previous one
             * rather than nothing. Expires after a few hours: a rate from this morning
             * says little about this evening. */
            live_x10 = g_smart_drain_last_x10;
        }
        int hot = (asb_smart_appheat_score(g_smart_rt.app_hash, time(NULL))
                   >= ASB_SMART_APPHEAT_HOT_SCORE);
        int known = 0;
        for (int i = 0; i < ASB_SMART_APPHEAT_N; i++)
            if (g_smart_appheat.entries[i].hash != 0) known++;
        long _pub_win = (g_smart_drain_on_sec >= 300) ? g_smart_drain_on_sec : g_drain_roll_sec;
        /* P0-4: confidence travels with the measurement.
         *
         * A %/h number is only as good as the window it came from. A short window, a SOC
         * that moved by a single integer step, or a charge transition mid-window all
         * produce a figure that looks authoritative and is not - and the report was
         * presenting "4% in 15 minutes" as a definitive ASB drain claim regardless.
         *
         * high   = long window, real SOC movement, no charge transition
         * medium = usable but short, or derived from a smoothed gauge
         * low    = single-step SOC or very short window; show as estimate
         * none   = no valid window at all
         */
        int _bconf;
        const char *_breason;
        if (m->bat.charging) {
            _bconf = 0; _breason = "charging sample excluded from drain estimate";
        } else if (_pub_win < 300) {
            _bconf = 0; _breason = "window under 5 min";
        } else if (g_smart_drain_drop_x100 <= 100) {
            _bconf = 1; _breason = "SOC moved one integer step or less";
        } else if (_pub_win < 900) {
            _bconf = 2; _breason = "short but usable window";
        } else {
            _bconf = 3; _breason = "settled window with real SOC movement";
        }
        fprintf(f, "smart_drain_window_s=%ld\nsmart_drain_pctph_x10=%ld\n"
                   "smart_app_hot=%d\nsmart_appheat_n=%d\n"
                   "battery_window_confidence=%d\nbattery_window_reason=\"%s\"\n"
                   "battery_current_source=\"%s\"\n",
                _pub_win, live_x10, hot, known,
                _bconf, _breason, g_batt_current_source);
        fprintf(f, "smart_budget_sev=%d\nsmart_budget_pred_h_x10=%d\n"
                   "smart_drain_ewma_x10=%d\n"
                   "smart_quality_last=%d\nsmart_quality_avg=%d\n"
                   "smart_app_drain=%d\n"
                   "anomaly_code=%d\nanomaly_count_1h=%d\n",
                g_smart_rt.budget_severity, g_smart_rt.budget_pred_h_x10,
                g_smart_drain_rate_ewma_x10,
                g_smart_last_quality, g_smart_quality_ewma,
                asb_smart_appheat_drain(g_smart_rt.app_hash, time(NULL)),
                g_anom_code, g_anom_count_1h);
        fprintf(f, "smart_q_bat=%d\nsmart_q_heat=%d\nsmart_q_stab=%d\n"
                   "smart_q_vendor=%d\nsmart_q_fail=%d\nsmart_budget_src=%d\n",
                g_smart_q_bat, g_smart_q_heat, g_smart_q_stab,
                g_smart_q_vendor, g_smart_q_fail, g_smart_budget_src);
        fprintf(f, "smart_boot_settle=%d\nstartup_quarantined=%lu\n"
                   "thermal_control_source=\"%s\"\nthermal_control_zone=%d\n"
                   "thermal_source_confidence=%d\nthermal_rejected_type=\"%s\"\n"
                   "thermal_rejected_raw=%d\nthermal_peer_hi=%d\nthermal_peer_lo=%d\n"
                   "thermal_peer_n=%d\nthermal_consensus=\"%s\"\n"
                   /* Same file the diagnostic reads. This was published only into the
                    * status JSON, so the report could never see it - the identical
                    * producer/consumer split that hid the consensus fields before. */
                   "freq_table_n=\"%d,%d,%d\"\n"
                   /* What the writer was ASKED for, next to what the node holds.
                    * The report shows the live tiers; without the request beside
                    * them a tier stuck at stock is indistinguishable from a tier
                    * the FSM deliberately left alone, and that ambiguity has cost
                    * several rounds of guessing already. */
                   "uclamp_want=\"%d,%d\"\n",
                g_smart_boot_settle, g_startup_quarantined,
                g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown", g_thermal_cpu_zone,
                g_thermal_source_confidence, g_thermal_rejected_type, g_thermal_rejected_raw,
                g_thermal_peer_hi, g_thermal_peer_lo, g_thermal_peer_n,
                g_thermal_consensus_note,
                writer_freq_table_len(0), writer_freq_table_len(1), writer_freq_table_len(2),
                writer_last_uclamp_top(), writer_last_uclamp_bg());
        fprintf(f, "cool_gaming=%d\n", g_asb_cfg.cool_gaming);
        fprintf(f, "cool_gaming_level=%d\n", g_smart_cool_gaming_lvl);
        fprintf(f, "game_charging=%d\ngame_bat_temp_peak_dc=%d\n"
                   "game_cpu_max_peak_c=%d\ngame_cool_lvl_peak=%d\n",
                g_game_charging_seen, g_game_bat_temp_peak_dc,
                g_game_cpu_max_peak_c, g_game_cool_lvl_peak);
        {
            /* While grading is suspended (charging or the night/sleep override),
               don't publish a stale accuracy figure — it reads as a failed
               forecast when really the loop is just paused. Emit the no-data
               sentinel so the report card shows nothing instead of 0/100. */
            int _acc_pub = g_budget_acc_score;
            int _err_pub = g_budget_acc_error_pct;
            if (g_smart_rt.night_safe_override) { _acc_pub = -1; _err_pub = -1; }
            fprintf(f, "budget_accuracy_score=%d\nbudget_error_pct=%d\n",
                    _acc_pub, _err_pub);
        }
        fprintf(f, "budget_bias_dir=%d\nbudget_bias_streak=%d\n",
                g_budget_bias_dir, g_budget_bias_streak);
        fprintf(f, "night_samples_accepted=%d\nnight_samples_rejected=%d\n"
                   "night_reject_reason=%d\n",
                g_night_samples_accepted, g_night_samples_rejected,
                g_night_reject_reason);
        fprintf(f, "charging=%d\nsmart_charge_assist=%d\nsmart_charge_cool=%d\n"
                   "smart_charge_class=%d\nsmart_charge_w_x10=%d\n",
                m->bat.charging,
                g_smart_rt.charge_assist, g_smart_rt.charge_cool_guard,
                g_smart_rt.charge_power_class, g_smart_rt.charge_power_w_x10);
        fprintf(f, "night_auto=%d\nnight_auto_ready=%d\nnight_window_active=%d\n"
                   "night_sleep_min=%d\nnight_wake_min=%d\nnight_samples=%d\n",
                g_asb_cfg.night_quiet_auto,
                asb_night_window_ready(),
                asb_night_window_active(time(NULL)),
                g_night_sleep_min, g_night_wake_min, g_night_samples);
        fprintf(f, "write_attempts=%ld\nwrite_skipped_detente=%ld\n"
                   "write_skipped_backoff=%ld\nbudget_spike_bump=%d\n",
                g_write_attempts, g_write_skipped_detente,
                g_write_skipped_backoff, g_drain_spike_bump);
        fprintf(f, "cap_sleep_detente=%d\ncap_detente_skipped=%ld\n"
                   "build_flavor=%s\nbat_cur_unit=%d\n",
                g_cap_detente_active, g_cap_detente_skipped,
                ASB_DEBUG_BUILD ? "debug" : "release",
                g_batt_cur_unit);
    }
    /* Debug build only: include plaintext pkg if cached */
#if ASB_DEBUG_BUILD
    if (g_asb_cfg.smart_pkg_plaintext || ASB_DEBUG_BUILD) {
        fprintf(f, "smart_pkg=%s\n",
                g_smart_rt.app_pkg_cached[0] ? g_smart_rt.app_pkg_cached : "");
    }
#endif
    fprintf(f, "smart_pkg_hash=%016llx\n",
            (unsigned long long)g_smart_rt.app_hash);
    /* — Foreground package detection observability */
    fprintf(f, "smart_pkg_detect_ok=%d\nsmart_pkg_source=%d\nsmart_pkg_status=%d\n",
            g_pkg_detect_ok, g_pkg_detect_source, g_pkg_detect_status);
    /* — Cap ownership */
    fprintf(f, "cap_owner=%s\ncap_owner_since=%ld\ncap_vendor_holddown=%d\n",
            asb_cap_owner_name(g_cap_owner_eff),
            (long)g_cap_owner_since,
            asb_cap_writes_should_back_off());
    /* Vendor clamp counters for WebUI Live page */
    fprintf(f, "vendor_clamp_1h=%lu\nvendor_clamp_total=%lu\nvendor_raised_total=%lu\n",
            v44_clamp_1h_now(), g_v44_clamp_total, g_v44_raised_total);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename(STATE_FILE ".tmp", STATE_FILE);
}

static int g_total_writes = 0;
static time_t g_last_write_ts = 0;

static char          g_v44_last_clamp_source[32] = "";  /* last cap_source seen (any non-asb) */
static time_t        g_v44_last_clamp_ts = 0;

static void v44_conflict_record(const char *cap_source) {
    if (!cap_source) return;
    /* Track all non-asb / non-shell sources of cap changes. */
    int is_clamp  = (strcmp(cap_source, "vendor_clamp") == 0);
    int is_raised = (strcmp(cap_source, "vendor_raised") == 0);
    int is_thermal = (strcmp(cap_source, "thermal_overlay") == 0);
    if (!is_clamp && !is_raised && !is_thermal) return;
    time_t now = time(NULL);
    if (g_v44_clamp_1h_start == 0) g_v44_clamp_1h_start = now;
    if (now - g_v44_clamp_1h_start >= 3600) {
        g_v44_clamp_1h = 0;
        g_v44_clamp_1h_start = now;
    }
    if (is_clamp)  { g_v44_clamp_total++;  g_v44_clamp_1h++; }
    if (is_raised) { g_v44_raised_total++; }
    strncpy(g_v44_last_clamp_source, cap_source, sizeof(g_v44_last_clamp_source) - 1);
    g_v44_last_clamp_source[sizeof(g_v44_last_clamp_source) - 1] = '\0';
    g_v44_last_clamp_ts = now;
}

/*
 * V50: the 1h window above only reset lazily when the NEXT vendor event arrived.
 * On a clean night after a noisy evening that next event never came, so a stale count (e.g.
 */
static unsigned long v44_clamp_1h_now(void) {
    if (g_v44_clamp_1h_start != 0 &&
        time(NULL) - g_v44_clamp_1h_start >= 3600) {
        g_v44_clamp_1h = 0;
        g_v44_clamp_1h_start = 0;
    }
    return g_v44_clamp_1h;
}

/*
 * — Cap ownership model.
 */
typedef enum {
    ASB_CAP_OWNER_UNKNOWN = 0,
    ASB_CAP_OWNER_ASB     = 1,
    ASB_CAP_OWNER_SHELL   = 2,
    ASB_CAP_OWNER_VENDOR  = 3,
} asb_cap_owner_t;

/*
 * Compute effective owner from observed cap_source.
 */
static int asb_cap_compute_owner(const char *cap_source) {
    time_t now = time(NULL);
    int owner;
    if (!cap_source) owner = ASB_CAP_OWNER_UNKNOWN;
    else if (strcmp(cap_source, "vendor_clamp") == 0 ||
             strcmp(cap_source, "vendor_raised") == 0) {
        owner = ASB_CAP_OWNER_VENDOR;
    }
    /*
     * shell_overridden_up is somebody else raising our cap, not us owning it.
     *
     * Every shell_* source was counted as ASB's own, so the anti-thrash logic below never
     * saw a conflict and never backed off. Field report from a OnePlus 13: cap_verify said
     * DESYNC_shell_overridden_up in 5 samples out of 8 - the profile asked for 1190400 on
     * policy0 and the device sat at 2227200 - while vendor_clamp_1h was 32 and
     * cap_vendor_holddown_active stayed 0. ASB rewrote the cap, something rewrote it back,
     * and the loop ran all day. Six cores fighting over their own ceiling is exactly the
     * heat and drain those users reported, and it is the case the anti-clamp was built for.
     *
     * OnePlus 15 and Ace 6 do not show it because their policy0 is the little cluster
     * alone; on OP13 and Ace 5 policy0 covers cpu0-5, so the same losing write costs six
     * cores instead of two.
     *
     * "up" means our value did not hold. "down" is different - a value below ours is
     * usually a legitimate vendor cooldown, and treating that as a fight would make ASB
     * push back against thermal protection.
     */
    else if (strcmp(cap_source, "shell_overridden_up") == 0) owner = ASB_CAP_OWNER_VENDOR;
    else if (strncmp(cap_source, "shell_", 6) == 0) owner = ASB_CAP_OWNER_SHELL;
    else if (strcmp(cap_source, "asb") == 0 ||
             strncmp(cap_source, "asb_", 4) == 0) {
        owner = ASB_CAP_OWNER_ASB;
    }
    else owner = ASB_CAP_OWNER_UNKNOWN;

    /*
     * Track recent vendor clamp pattern for anti-thrash.
     */
    /* REVERTED: not backing off on vendor_raised made the phone stutter, not cool.
     *
     * The reasoning was that clamping down and raising up are opposite messages and should
     * not share one anti-thrash counter. That still reads as correct. But shipped together
     * with the cap-ownership change it produced a phone that stuttered in audio, animation,
     * camera and lock screen, held the prime below 1.2 GHz a fifth of the time, and ran no
     * cooler. Fighting the vendor for the ceiling is a write war, and the phone loses it.
     *
     * Both are reverted together because they shipped together: with two changes and one
     * bad outcome there is no way to tell which caused it, and guessing again is how this
     * got here. If the ownership question is worth reopening, it goes back one change at a
     * time with a capture between them.
     */
    if (owner == ASB_CAP_OWNER_VENDOR) {
        /* Burst window (60s) */
        if (g_cap_recent_window_start == 0 || (now - g_cap_recent_window_start) > 60) {
            g_cap_recent_window_start = now;
            g_cap_recent_vendor_clamps = 1;
        } else {
            g_cap_recent_vendor_clamps++;
        }
        /* Slow-thrash window (5 min) */
        if (g_cap_slow_window_start == 0 || (now - g_cap_slow_window_start) > 300) {
            g_cap_slow_window_start = now;
            g_cap_slow_vendor_clamps = 1;
        } else {
            g_cap_slow_vendor_clamps++;
        }
        /* Back off from a WRITE WAR, not from the vendor simply being present.
         *
         * The old thresholds - 3 clamps in 60 s, 8 in 300 s - describe a vendor HAL that
         * intervenes occasionally. Every Qualcomm thermal HAL in this fleet re-evaluates far
         * more often than once per 37 seconds, so `slow_trip` was true essentially always and
         * the governor spent its life in a 15-30 second hold. A device diag shows the bill
         * directly: attempts=282 applied=241 backoff_skips=174. Two thirds of the governor's
         * writes were never attempted, which is why cap_owner reads vendor 92% / asb 0% on a
         * phone with Smart active - and why none of the thermal work in this file reached the
         * hardware.
         *
         * A write war is two writers fighting over the SAME tick, not a vendor that also has
         * opinions. The burst window is what detects that, so it keeps a tight threshold and a
         * short hold. The slow window now needs a rate no normal HAL produces, and its hold is
         * cut to the length of a couple of ticks: long enough to break a feedback loop, short
         * enough that the governor is back before the next thermal decision matters.
         *
         * Both counters also decay on a tick where the vendor did NOT clamp, so a quiet minute
         * earns the governor its voice back instead of the count ratcheting up all session.
         */
        int burst_trip = (g_cap_recent_vendor_clamps >= 6);
        int slow_trip  = (g_cap_slow_vendor_clamps  >= 40);
        int persistent = (g_cap_slow_vendor_clamps  >= 90);
        if (persistent) {
            g_cap_vendor_hold_until = now + 6;
        } else if (burst_trip || slow_trip) {
            g_cap_vendor_hold_until = now + 3;
        }
    }
    else {
        /* A tick the vendor did not take: give the governor its voice back gradually.
         *
         * Without this the counters only ever climb until their window rolls over, so one
         * busy minute could hold the governor quiet for the following four. Decaying on
         * quiet ticks means the backoff tracks what is happening now rather than what
         * happened at the start of the window. */
        if (g_cap_recent_vendor_clamps > 0) g_cap_recent_vendor_clamps--;
        if (g_cap_slow_vendor_clamps  > 0) g_cap_slow_vendor_clamps--;
    }

    if (owner != g_cap_owner_eff) {
        g_cap_owner_eff = owner;
        g_cap_owner_since = now;
    }
    return owner;
}

/* Anti-thrash gate: returns 1 if ASB should back off cap writes right now. */
static int asb_cap_writes_should_back_off(void) {
    time_t now = time(NULL);
    return (g_cap_vendor_hold_until > 0 && now < g_cap_vendor_hold_until) ? 1 : 0;
}

/* Translate owner enum to short string for JSON */
static const char *asb_cap_owner_name(int o) {
    switch (o) {
        case ASB_CAP_OWNER_ASB:    return "asb";
        case ASB_CAP_OWNER_SHELL:  return "shell";
        case ASB_CAP_OWNER_VENDOR: return "vendor";
        default:                   return "unknown";
    }
}

static void write_conflicts_json(void) {
    FILE *f = fopen("/dev/.asb/conflicts.json.tmp", "w");
    if (!f) return;
    fprintf(f,
        "{\n"
        "  \"last_cap_source\": \"%s\",\n"
        "  \"last_cap_source_ts\": %lld,\n"
        "  \"vendor_clamp_total\": %lu,\n"
        "  \"vendor_raised_total\": %lu,\n"
        "  \"vendor_clamp_1h\": %lu,\n"
        "  \"cap_owner\": \"%s\",\n"
        "  \"cap_owner_since\": %ld,\n"
        "  \"cap_vendor_holddown_active\": %d,\n"
        "  \"cap_recent_vendor_clamps_60s\": %d,\n"
        "  \"cap_sleep_detente\": %d,\n"
        "  \"cap_detente_skipped\": %ld\n"
        "}\n",
        g_v44_last_clamp_source[0] ? g_v44_last_clamp_source : "none",
        (long long)g_v44_last_clamp_ts,
        g_v44_clamp_total,
        g_v44_raised_total,
        v44_clamp_1h_now(),
        asb_cap_owner_name(g_cap_owner_eff),
        (long)g_cap_owner_since,
        asb_cap_writes_should_back_off(),
        g_cap_recent_vendor_clamps,
        g_cap_detente_active, g_cap_detente_skipped);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename("/dev/.asb/conflicts.json.tmp", "/dev/.asb/conflicts.json");
}

static int g_v44_last_bat_trust = -1;          /* -1=unknown, 0=dirty, 1=partial, 2=clean */
static char g_v44_last_bat_outcome[24] = "";   /* "clean", "partial", "dirty", "noise" */

static void write_learner_state_json(const asb_fsm_t *fsm) {
    FILE *f = fopen("/dev/.asb/learner_state.json.tmp", "w");
    if (!f) return;
    const char *tier_name = "unknown";
    if (g_v44_last_bat_trust == 0) tier_name = "dirty";
    else if (g_v44_last_bat_trust == 1) tier_name = "partial";
    else if (g_v44_last_bat_trust == 2) tier_name = "clean";
    else if (g_v44_last_bat_trust == 3) tier_name = "noisy";

    int bat_sessions = g_pstats_per[PROFILE_BATTERY].session_count;
    int balanced_sessions = g_pstats_per[PROFILE_BALANCED].session_count;
    int perf_sessions = g_pstats_per[PROFILE_PERFORMANCE].session_count;
    int night_count = g_pstats_per[PROFILE_BATTERY].night_count;
    int day_count = g_pstats_per[PROFILE_BATTERY].day_count;

    fprintf(f,
        "{\n"
        "  \"trust_tier\": \"%s\",\n"
        "  \"trust_tier_num\": %d,\n"
        "  \"last_outcome\": \"%s\",\n"
        "  \"sessions\": {\n"
        "    \"battery\": %d,\n"
        "    \"balanced\": %d,\n"
        "    \"performance\": %d,\n"
        "    \"night\": %d,\n"
        "    \"day\": %d\n"
        "  },\n"
        "  \"smart_sessions\": {\n"
        "    \"total\": %d,\n"
        "    \"day\": %d,\n"
        "    \"night\": %d,\n"
        "    \"gaming\": %d,\n"
        "    \"bucket_updates\": %d,\n"
        "    \"last_bucket_id\": %d,\n"
        "    \"last_daypart\": %d,\n"
        "    \"last_confidence\": %d,\n"
        "    \"last_update_ts\": %ld,\n"
        "    \"last_quality\": %d,\n"
        "    \"avg_quality\": %d\n"
        "  },\n"
        "  \"self_tuned\": {\n"
        "    \"bat_fast_idle_s\": %d,\n"
        "    \"bat_heavy_load_enter\": %.0f,\n"
        "    \"bat_moderate_load_enter\": %.0f,\n"
        "    \"bat_light_idle_gpu\": %d\n"
        "  },\n"
        "  \"battery_aggregates\": {\n"
        "    \"avg_idle_q\": %.1f,\n"
        "    \"avg_wph\": %.2f,\n"
        "    \"night_avg_iq\": %.1f,\n"
        "    \"day_avg_iq\": %.1f,\n"
        "    \"clean_night_count\": %d\n"
        "  }\n"
        "}\n",
        tier_name,
        g_v44_last_bat_trust,
        g_v44_last_bat_outcome[0] ? g_v44_last_bat_outcome : "unknown",
        bat_sessions, balanced_sessions, perf_sessions, night_count, day_count,
        g_smart_sessions_total, g_smart_sessions_day, g_smart_sessions_night,
        g_smart_sessions_gaming, g_smart_bucket_updates,
        g_smart_last_bucket_id, g_smart_last_daypart, g_smart_last_confidence,
        (long)g_smart_last_update_ts,
        g_smart_last_quality, g_smart_quality_ewma,
        g_asb_cfg.bat_fast_idle_s,
        g_asb_cfg.bat_heavy_load_enter,
        g_asb_cfg.bat_moderate_load_enter,
        g_asb_cfg.bat_light_idle_gpu,
        g_pstats_per[PROFILE_BATTERY].avg_idle_q,
        g_pstats_per[PROFILE_BATTERY].avg_wph,
        g_pstats_per[PROFILE_BATTERY].night_avg_iq,
        g_pstats_per[PROFILE_BATTERY].day_avg_iq,
        g_pstats_per[PROFILE_BATTERY].clean_night_count);
    (void)fsm;
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename("/dev/.asb/learner_state.json.tmp", "/dev/.asb/learner_state.json");
}

static void build_status_json(const asb_fsm_t *fsm, const asb_metrics_t *m,
                               asb_prediction_t pred,
                               char *out, int outlen)
{
    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *pred_names[] = {"unknown","idle","light","active"};
    int ma_valid = (m->bat.current_ma > 0 && !m->bat.charging);
    int real_max_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
    int real_max_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
    int cap_gap_p0  = (real_max_p0 > 0) ? (fsm->current_caps.cpu_max[0] - real_max_p0) : 0;
    int cap_gap_p1  = (real_max_p1 > 0) ? (fsm->current_caps.cpu_max[1] - real_max_p1) : 0;
    /* cap_source classification — who controls the actual cap right now. */
    int hw_ceil_p0 = sysfs_read_int(cpu_policy_path(0, "cpuinfo_max_freq"), 0);
    int hw_ceil_p1 = sysfs_read_int(cpu_policy_path(1, "cpuinfo_max_freq"), 0);
    int profile_cap_p0 = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[0];
    int profile_cap_p6 = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[1];
    int headroom_real_pct = -1;
    if (hw_ceil_p0 > 0 && real_max_p0 > 0) {
        headroom_real_pct = (int)((long)real_max_p0 * 100 / hw_ceil_p0);
    }
    if (hw_ceil_p1 > 0 && real_max_p1 > 0) {
        int _hr1 = (int)((long)real_max_p1 * 100 / hw_ceil_p1);
        if (headroom_real_pct < 0 || _hr1 < headroom_real_pct) headroom_real_pct = _hr1;
    }
    if (headroom_real_pct > 100) headroom_real_pct = 100;
    /*
     * classifier gets runtime_declared from msm_performance read (m->therm.perf_cap_*), not
     * from fsm->current_caps.
     */
    const char *cap_src_p0 = cap_source_classify(profile_cap_p0,
                                                 m->therm.perf_cap_p0,
                                                 real_max_p0, hw_ceil_p0);
    const char *cap_src_p6 = cap_source_classify(profile_cap_p6,
                                                 m->therm.perf_cap_p6,
                                                 real_max_p1, hw_ceil_p1);
    /*
     * record conflicts to /dev/.asb/conflicts.json (written below).
     */
    v44_conflict_record(cap_src_p0);
    v44_conflict_record(cap_src_p6);
    /* compute effective cap owner from observed source. The owner with
     * the more-restrictive cap wins; default to p6 since prime cores matter
     * most for perf decisions. */
    asb_cap_compute_owner(cap_src_p6);
    snprintf(out, outlen,
        "{\"state\":\"%s\",\"profile\":\"%s\","
        "\"mA\":%d,\"mA_valid\":%d,\"charging\":%d,"
        "\"capacity\":%d,\"bat_temp_dC\":%d,"
        "\"gpu\":%d,\"load\":%.2f,"
        "\"cpu_max\":[%d,%d,%d],"
        "\"thermal\":%d,\"temp\":%d,\"temp_valid\":%d,\"temp_age_s\":%d,\"temp_invalid_reason\":\"%s\","
        "\"skin_temp\":%d,\"surface_hotspot\":%d,\"board_temp\":%d,"
        /* Confidence travels with the source. A temperature whose sensor could not be
         * cross-checked, or that came from a peer median after socd was rejected, is
         * not the same claim as one validated against twenty per-core zones - and the
         * report should not present them identically. */
        "\"thermal_cpu_zone\":%d,\"thermal_cpu_type\":\"%s\",\"thermal_src_conf\":%d,"
        /* Rejected candidate travels separately and unformatted. A consumer that
         * wants to show it must choose to, and cannot accidentally print it as C. */
        "\"thermal_rejected_type\":\"%s\",\"thermal_rejected_raw\":%d,"
        /* Consensus v2: what the control value was checked against, and what that
         * check concluded. An empty note means the sources agreed. */
        "\"thermal_peer_hi\":%d,\"thermal_peer_n\":%d,\"thermal_consensus\":\"%s\","
        /* How many OPP steps the writer could enumerate per cluster. Zero means
         * cpu_snap_freq is a no-op and every ceiling is written unsnapped - which
         * looks identical to a vendor override in the failure log and took three
         * rounds to tell apart. Published so it can be read instead of inferred. */
        "\"freq_table_n\":\"%d,%d,%d\","
        "\"thermal_skin_zone\":%d,\"thermal_surface_zone\":%d,"
        "\"soft_clamp\":%d,\"hard_clamp\":%d,"
        "\"headroom_pct\":%d,\"headroom_valid\":%d,\"headroom_invalid_reason\":\"%s\",\"headroom_real_pct\":%d,"
        "\"perf_cap_p0\":%d,\"perf_cap_p6\":%d,"
        "\"cap_source_p0\":\"%s\",\"cap_source_p6\":\"%s\","
        "\"thermal_cpu_fallback_type\":\"%s\","
        "\"predict\":\"%s\",\"screen\":%d,\"bat\":%d,"
        "\"writes\":%d,\"last_write\":%ld,"
        "\"dwell_sec\":%ld,\"boost\":%d,"
        "\"cap_gap_p0\":%d,\"cap_gap_p1\":%d,"
        "\"last_sustained_reason\":\"%s\",\"highload_mode\":\"%s\",\"ses_gaming\":%d,\"ses_sustained\":%d,\"ses_thermal\":%d,\"ses_unreachable\":%d,\"ses_t_heavy\":%ld,\"ses_t_gaming\":%ld,\"ses_t_sustained\":%ld,\"ses_avg_gap_p0\":%d,\"ses_max_gap_p0\":%d,\"ses_max_temp\":%d,\"ses_max_skin_temp\":%d,\"ses_max_surface_temp\":%d,\"ses_max_board_temp\":%d,\"ses_auto_degraded\":%d,\"bat_deep_idle\":%ld,\"bat_light_idle\":%ld,\"bat_wake_cycles\":%d,\"clamp_hold\":%d,\"cap_owner\":\"%s\",\"cap_vendor_holddown_active\":%d,\"cap_recent_vendor_clamps_60s\":%d,\"vendor_clamp_1h\":%lu}",
        asb_state_names[fsm->state],
        profile_names[fsm->profile_idx],
        m->bat.current_ma, ma_valid, m->bat.charging,
        m->bat.capacity_pct, m->bat.temp_dC,
        m->gpu.load_pct,
        m->cpu.load1,
        /* Same as the state file above: report the cap being held, not the one requested. */
        (sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0) > 0)
            ? sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0)
            : fsm->current_caps.cpu_max[0],
        (sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0) > 0)
            ? sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0)
            : fsm->current_caps.cpu_max[1],
        fsm->current_caps.cpu_max[2],
        fsm->thermal_cap,
        m->therm.cpu_max_c,
        m->therm.temp_valid,
        m->therm.temp_age_s,
        m->therm.temp_invalid_reason[0] ? m->therm.temp_invalid_reason : "init",
        m->therm.skin_temp_c,
        m->therm.surface_hotspot_c,
        m->therm.board_temp_c,
        g_thermal_cpu_zone,
        g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown",
        g_thermal_source_confidence,
        g_thermal_rejected_type,
        g_thermal_rejected_raw,
        g_thermal_peer_hi,
        g_thermal_peer_n,
        g_thermal_consensus_note,
        writer_freq_table_len(0), writer_freq_table_len(1), writer_freq_table_len(2),
        g_thermal_skin_zone,
        g_thermal_surface_zone,
        m->therm.soft_clamp,
        m->therm.hard_clamp,
        m->therm.headroom_pct,
        m->therm.headroom_valid,
        m->therm.headroom_invalid_reason[0] ? m->therm.headroom_invalid_reason : "ok",
        headroom_real_pct,
        m->therm.perf_cap_p0,
        m->therm.perf_cap_p6,
        cap_src_p0, cap_src_p6,
        g_thermal_cpu_fallback_type[0] ? g_thermal_cpu_fallback_type : "none",
        pred_names[pred],
        m->misc.screen_on,
        m->bat.capacity_pct,
        g_total_writes,
        (long)g_last_write_ts,
        fsm_elapsed_sec(fsm),
        g_msm_boost_active,
        cap_gap_p0,
        cap_gap_p1,
        sustained_reason_name(fsm->sustained_reason),
        g_asb_cfg.highload_mode == 1 ? "burst" :
        g_asb_cfg.highload_mode == 2 ? "stable" :
        g_asb_cfg.highload_mode == 3 ? "auto" : "default",
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec, fsm->ses_time_sustained_sec,
        fsm->ses_gap_samples > 0 ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0,
        fsm->ses_max_gap_p0,
        fsm->ses_max_temp,
        fsm->ses_max_skin_temp,
        fsm->ses_max_surface_temp,
        fsm->ses_max_board_temp,
        fsm->ses_auto_degraded,
        fsm->bat_time_deep_idle_sec,
        fsm->bat_time_light_idle_sec,
        fsm->bat_wake_cycles,
        fsm->clamp_hold,
        asb_cap_owner_name(g_cap_owner_eff),
        (g_cap_vendor_hold_until > time(NULL)) ? 1 : 0,
        g_cap_recent_vendor_clamps,
        v44_clamp_1h_now());
    {
        long _act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec + fsm->ses_time_sustained_sec;
        int _sp = (_act > 0) ? (int)(fsm->ses_time_sustained_sec * 100 / _act) : 0;
        long _bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec + fsm->bat_time_moderate_sec;
        int _iq = -1;
        if (_bt > 30) {
            _iq = (int)(fsm->bat_time_deep_idle_sec * 100 / _bt);
            int _wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
            _iq -= _wp; if (_iq < 0) _iq = 0;
        }
        int _ce = -1;
        if (fsm->ses_gaming_entries > 0 && fsm->ses_gap_samples > 0) {
            int _ag = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
            int _tg = fsm->current_caps.cpu_max[0] > 0 ? fsm->current_caps.cpu_max[0] / 10 : 1;
            _ce = (int)((_tg - _ag) * 100 / _tg);
            if (_ce < 0) _ce = 0;
            if (_ce > 100) _ce = 100;
        }
        snprintf(out + strlen(out) - 1, outlen - (int)strlen(out),
            ",\"sus_pct\":%d,\"idle_q\":%d,\"cap_eff\":%d,"
            "\"mem_psi_peak\":%d,\"mem_press_ticks\":%d,"
            "\"eff_sus_lvl\":%.2f,\"eff_sus_temp\":%d,\"eff_gr_cd\":%d,\"eff_gr_temp\":%d,"
            "\"eff_bat_fi\":%d,\"eff_bat_hl\":%.1f,\"eff_bat_ml\":%.1f,\"eff_bat_idle_gpu\":%d}",
            _sp, _iq, _ce,
            fsm->mem_psi_peak_x100, fsm->mem_pressure_ticks,
            g_asb_cfg.sustained_level,
            asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm->profile_idx),
            g_asb_cfg.gaming_retry_cooldown_s, g_asb_cfg.gaming_retry_temp_max,
            g_asb_cfg.bat_fast_idle_s,
            g_asb_cfg.bat_heavy_load_enter,
            g_asb_cfg.bat_moderate_load_enter,
            g_asb_cfg.bat_light_idle_gpu);
        int _pidx = fsm->profile_idx;
        if (_pidx < 0 || _pidx > 2) _pidx = 1;
        snprintf(out + strlen(out) - 1, outlen - (int)strlen(out),
            ",\"intent\":\"%s\",\"hot_fail\":%d,\"deg_age\":%ld,"
            "\"auto_bat\":%d,\"auto_bat_restore\":%d,\"qn_active\":%d,"
            "\"auto_bat_reason\":\"%s\",\"auto_bat_since\":%lld,"
            "\"adv_score\":%d,\"adv_active\":%d,\"cold_skin\":%d,\"cold_surface\":%d,\"cold_board\":%d,"
            "\"vote_skin\":%d,\"vote_surface\":%d,\"vote_board\":%d,\"would_bias_exit\":%d,"
            "\"bias_a\":%d,\"bias_b\":%d}",
            (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
                ? intent_names[fsm->ses_intent] : "unknown",
            g_pstats_per[_pidx].hot_fail_count,
            fsm->ses_degrade_at_age,
            fsm->auto_battery_active,
            fsm->auto_battery_restore_idx,
            g_quiet_night_active,
            fsm->auto_battery_reason[0] ? fsm->auto_battery_reason : "none",
            (long long)fsm->auto_battery_since,
            fsm->thermal_advisory_score,
            fsm->thermal_advisory_active,
            fsm->cold_baseline_skin,
            fsm->cold_baseline_surface,
            fsm->cold_baseline_board,
            fsm->thermal_vote_skin,
            fsm->thermal_vote_surface,
            fsm->thermal_vote_board,
            fsm->would_bias_exit_gaming,
            fsm->would_bias_mode_a,
            fsm->would_bias_mode_b);
    }
}

static void pstats_load_one(const char *path, asb_persistent_stats_t *ps) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    int _n = fscanf(f, "{\"count\":%d,\"t2s\":%f,\"t2th\":%f,\"temp\":%f,\"gap\":%f,\"eff\":%f",
           &ps->session_count, &ps->avg_time_to_first_sus,
           &ps->avg_time_to_first_thermal, &ps->avg_max_temp,
           &ps->avg_gap_p0, &ps->avg_efficiency);
    (void)_n;
    if (fscanf(f, ",\"deg\":%d", &ps->degrade_count) != 1)
        ps->degrade_count = 0;
    if (fscanf(f, ",\"hot\":%d", &ps->hot_fail_count) != 1)
        ps->hot_fail_count = 0;
    if (fscanf(f, ",\"deg_age\":%f", &ps->avg_degrade_age) != 1)
        ps->avg_degrade_age = 0;
    if (fscanf(f, ",\"btcd\":%d", &ps->bat_tune_cooldown) != 1)
        ps->bat_tune_cooldown = 0;
    if (fscanf(f, ",\"cstrk\":%d", &ps->cause_streak) != 1)
        ps->cause_streak = 0;
    if (fscanf(f, ",\"ctype\":%d", &ps->cause_streak_type) != 1)
        ps->cause_streak_type = 0;
    if (fscanf(f, ",\"quar\":%d", &ps->quarantine_remaining) != 1)
        ps->quarantine_remaining = 0;
    
    if (fscanf(f, ",\"iq\":%f", &ps->avg_idle_q) != 1)
        ps->avg_idle_q = 0;
    if (fscanf(f, ",\"wph\":%f", &ps->avg_wph) != 1)
        ps->avg_wph = 0;
    if (fscanf(f, ",\"cn\":%d", &ps->clean_night_count) != 1)
        ps->clean_night_count = 0;
    if (fscanf(f, ",\"qmin\":%f", &ps->avg_quiet_duration_min) != 1)
        ps->avg_quiet_duration_min = 0;
    /* Battery Memory Split */
    if (fscanf(f, ",\"niq\":%f", &ps->night_avg_iq) != 1)
        ps->night_avg_iq = 0;
    if (fscanf(f, ",\"nwph\":%f", &ps->night_avg_wph) != 1)
        ps->night_avg_wph = 0;
    if (fscanf(f, ",\"nc\":%d", &ps->night_count) != 1)
        ps->night_count = 0;
    if (fscanf(f, ",\"diq\":%f", &ps->day_avg_iq) != 1)
        ps->day_avg_iq = 0;
    if (fscanf(f, ",\"dwph\":%f", &ps->day_avg_wph) != 1)
        ps->day_avg_wph = 0;
    if (fscanf(f, ",\"dc\":%d", &ps->day_count) != 1)
        ps->day_count = 0;
    if (fscanf(f, ",\"tfi\":%ld", &ps->last_tune_ts_fast_idle) != 1)
        ps->last_tune_ts_fast_idle = 0;
    if (fscanf(f, ",\"thl\":%ld", &ps->last_tune_ts_heavy_load) != 1)
        ps->last_tune_ts_heavy_load = 0;
    if (fscanf(f, ",\"tml\":%ld", &ps->last_tune_ts_moderate_load) != 1)
        ps->last_tune_ts_moderate_load = 0;
    if (fscanf(f, ",\"tlg\":%ld", &ps->last_tune_ts_light_gpu) != 1)
        ps->last_tune_ts_light_gpu = 0;
    fclose(f);
    if (ps->session_count > PERSISTENT_STATS_MAX_SESSIONS)
        ps->session_count = PERSISTENT_STATS_MAX_SESSIONS;
}

static void pstats_save_one(const char *path, const asb_persistent_stats_t *ps) {
    char buf[896];
    snprintf(buf, sizeof(buf),
        "{\"count\":%d,\"t2s\":%.1f,\"t2th\":%.1f,\"temp\":%.1f,\"gap\":%.0f,\"eff\":%.1f,"
        "\"deg\":%d,\"hot\":%d,\"deg_age\":%.1f,\"btcd\":%d,\"cstrk\":%d,\"ctype\":%d,\"quar\":%d,"
        "\"iq\":%.1f,\"wph\":%.1f,\"cn\":%d,\"qmin\":%.0f,"
        "\"niq\":%.1f,\"nwph\":%.1f,\"nc\":%d,\"diq\":%.1f,\"dwph\":%.1f,\"dc\":%d,"
        "\"tfi\":%ld,\"thl\":%ld,\"tml\":%ld,\"tlg\":%ld}",
            ps->session_count, ps->avg_time_to_first_sus,
            ps->avg_time_to_first_thermal, ps->avg_max_temp,
            ps->avg_gap_p0, ps->avg_efficiency, ps->degrade_count,
            ps->hot_fail_count, ps->avg_degrade_age,
            ps->bat_tune_cooldown, ps->cause_streak,
            ps->cause_streak_type, ps->quarantine_remaining,
            ps->avg_idle_q, ps->avg_wph,
            ps->clean_night_count, ps->avg_quiet_duration_min,
            ps->night_avg_iq, ps->night_avg_wph, ps->night_count,
            ps->day_avg_iq, ps->day_avg_wph, ps->day_count,
            ps->last_tune_ts_fast_idle, ps->last_tune_ts_heavy_load,
            ps->last_tune_ts_moderate_load, ps->last_tune_ts_light_gpu);
    if (atomic_write_file(path, buf) != 0)
        asb_log("pstats: atomic write failed for %s", path);
}

static void persistent_stats_load(void) {
    pstats_load_one(PERSISTENT_STATS_FILE, &g_pstats);
    for (int i = 0; i < 3; i++)
        pstats_load_one(g_pstats_files[i], &g_pstats_per[i]);
}

#define BAT_TRUST_DIRTY   0
#define BAT_TRUST_PARTIAL 1
#define BAT_TRUST_CLEAN   2
#define BAT_TRUST_NOISY   3
#define BAT_CAUSE_NONE       0
#define BAT_CAUSE_WAKE_NOISE 1
#define BAT_CAUSE_SCREEN_ON  2
#define BAT_CAUSE_NO_SETTLE  3
static int battery_session_trust(const asb_fsm_t *fsm);
static int classify_environment(const asb_fsm_t *fsm);
static int battery_fail_cause(const asb_fsm_t *fsm, int iq);

static void persistent_stats_save(const asb_fsm_t *fsm) {
    /*
     * battery-aware save gate.
     */
    if (fsm->profile_idx == PROFILE_BATTERY) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;
        long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        if (bat_total < 120 && dur < 180)
            return;
    } else {
        if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 30
            && fsm->bat_time_deep_idle_sec < 60)
            return;
    }

    int pidx = fsm->profile_idx;
    if (pidx < 0 || pidx > 2) pidx = 1;

    /* record thermal debt for performance sessions */
    if (pidx == PROFILE_PERFORMANCE) {
        g_last_perf_end_ts = time(NULL);
        g_last_perf_max_temp = fsm->ses_max_temp;
        g_last_perf_was_clamped = (fsm->had_futility && fsm->clamp_hold) ? 1 : 0;
    }
    /* Clean-Night Reward -- remember if last battery session was a good night.
     * V50: smart sessions spend nights battery-like and accumulate the same
     * idle telemetry now, so they can earn (and lose) the reward too. */
    if (pidx == PROFILE_BATTERY || fsm->profile_idx == PROFILE_SMART) {
        long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        long _bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                   + fsm->bat_time_moderate_sec;
        int _iq = (_bt > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt) : 0;
        g_last_bat_clean_night = (_dur >= 7200 && _iq >= 40 &&
                                  fsm->bat_wake_bg <= 4 &&
                                  !fsm->ses_auto_degraded) ? 1 : 0;
        if (g_last_bat_clean_night)
            asb_log("pstats: clean_night_reward active for next battery session");
    }
    /* Start-of-session Priming -- save env for next session */
    g_last_session_env = classify_environment(fsm);

    asb_persistent_stats_t *ps = &g_pstats_per[pidx];

    int skip_per_profile = 0;
    float trust_weight = 1.0f;  /* learning weight: clean=1.0, partial=0.25, noisy=0.10, dirty=0 */
    if (pidx == PROFILE_BATTERY) {
        int trust = battery_session_trust(fsm);
        /* expose trust + outcome to learner_state.json */
        g_v44_last_bat_trust = trust;
        if (trust == BAT_TRUST_DIRTY) {
            strncpy(g_v44_last_bat_outcome, "dirty", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_NOISY) {
            strncpy(g_v44_last_bat_outcome, "noisy", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_PARTIAL) {
            strncpy(g_v44_last_bat_outcome, "partial", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        } else if (trust == BAT_TRUST_CLEAN) {
            strncpy(g_v44_last_bat_outcome, "clean", sizeof(g_v44_last_bat_outcome) - 1);
            g_v44_last_bat_outcome[sizeof(g_v44_last_bat_outcome) - 1] = '\0';
        }
        if (trust == BAT_TRUST_DIRTY) {
            skip_per_profile = 1;
            /*
             * bootstrap pstats_battery.json on first meaningful session even if noisy.
             */
            if (access(g_pstats_files[pidx], F_OK) != 0) {
                pstats_save_one(g_pstats_files[pidx], ps);
                asb_log("pstats: battery trust=%d, bootstrapped %s (no learning)",
                        trust, g_pstats_files[pidx]);
            } else {
                /* log specific reason for rejection */
                long _bt = fsm->bat_time_deep_idle_sec +
                           fsm->bat_time_light_idle_sec +
                           fsm->bat_time_moderate_sec;
                int _iq = (_bt > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt) : 0;
                long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
                float _wph = (_dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / _dur : 0;
                asb_log("pstats: battery trust=%d (iq=%d bg_wph=%.1f wake_bg=%d wake_scr=%d), "
                        "skipping per-profile memory update",
                        trust, _iq, _wph, fsm->bat_wake_bg, fsm->bat_wake_screen);
            }
        } else if (trust == BAT_TRUST_NOISY) {
            trust_weight = 0.10f;
            asb_log("pstats: battery trust=noisy, learning with weight=0.10");
        } else if (trust == BAT_TRUST_PARTIAL) {
            trust_weight = 0.25f;
            asb_log("pstats: battery trust=partial, learning with weight=0.25");
        }
    }
    if (pidx == PROFILE_PERFORMANCE && fsm->ses_intent == INTENT_BENCHMARK) {
        skip_per_profile = 1;
        asb_log("pstats: benchmark session, skipping per-profile memory update");
    }
    /* quarantine -- don't learn from user-switch storm */
    if (fsm->plan.quarantine) {
        skip_per_profile = 1;
        asb_log("pstats: quarantine active, skipping per-profile memory update");
    }
    /* storm shield -- don't learn from noisy battery data */
    if (g_storm_shield_active) {
        skip_per_profile = 1;
        asb_log("pstats: storm shield active, skipping per-profile memory update");
    }

    /* OTA quarantine -- skip learning during environment adjustment
     * Only decrement on quality sessions (dur >= 120, not benchmark) */
    if (!skip_per_profile && ps->quarantine_remaining > 0) {
        long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
        skip_per_profile = 1;
        if (dur >= 120 && fsm->ses_intent != INTENT_BENCHMARK) {
            ps->quarantine_remaining--;
            asb_log("pstats: quarantine active (%d remaining), skipping per-profile learning",
                    ps->quarantine_remaining);
        } else {
            asb_log("pstats: quarantine active (session too short/benchmark, not counting down)");
        }
        pstats_save_one(g_pstats_files[pidx], ps);
    }

    if (!skip_per_profile) {
        float alpha = 1.0f / (ps->session_count + 1);
        if (alpha < 0.1f) alpha = 0.1f;
        alpha *= trust_weight;  /* partial trust = 25% learning rate */

        if (fsm->ses_time_to_first_sus > 0)
            ps->avg_time_to_first_sus =
                ps->avg_time_to_first_sus * (1 - alpha) + fsm->ses_time_to_first_sus * alpha;
        if (fsm->ses_time_to_first_thermal > 0)
            ps->avg_time_to_first_thermal =
                ps->avg_time_to_first_thermal * (1 - alpha) + fsm->ses_time_to_first_thermal * alpha;
        if (fsm->ses_max_temp > 0)
            ps->avg_max_temp =
                ps->avg_max_temp * (1 - alpha) + fsm->ses_max_temp * alpha;
        if (fsm->ses_gap_samples > 0) {
            int avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
            ps->avg_gap_p0 =
                ps->avg_gap_p0 * (1 - alpha) + avg_gap * alpha;
        }
        if (fsm->ses_sustained_efficiency >= 0)
            ps->avg_efficiency =
                ps->avg_efficiency * (1 - alpha) + fsm->ses_sustained_efficiency * alpha;
        if (ps->session_count < PERSISTENT_STATS_MAX_SESSIONS)
            ps->session_count++;
        if (fsm->ses_auto_degraded) {
            ps->degrade_count++;
            if (fsm->ses_degrade_at_age > 0)
                ps->avg_degrade_age =
                    ps->avg_degrade_age * (1 - alpha) + fsm->ses_degrade_at_age * alpha;
        }
        {
            long total_act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                            + fsm->ses_time_sustained_sec;
            int sp = (total_act > 0)
                     ? (int)(fsm->ses_time_sustained_sec * 100 / total_act) : 0;
            if (fsm->ses_max_temp >= 100 &&
                (sp >= 50 || (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus <= 90))) {
                ps->hot_fail_count++;
                const char *reason = (sp >= 50 && fsm->ses_time_to_first_sus > 0 &&
                                      fsm->ses_time_to_first_sus <= 90) ? "temp+sus+t2s"
                                   : (sp >= 50) ? "temp+sus" : "temp+t2s";
                asb_log("pstats: hot_fail #%d reason=%s temp=%d sus_pct=%d t2s=%ld",
                        ps->hot_fail_count, reason, fsm->ses_max_temp, sp,
                        fsm->ses_time_to_first_sus);
            }
            if (pidx == PROFILE_PERFORMANCE &&
                fsm->ses_max_temp < 90 && !fsm->ses_auto_degraded) {
                if (ps->hot_fail_count > 0) {
                    ps->hot_fail_count--;
                    asb_log("pstats: good perf session (temp=%d) -> hot_fail decayed to %d",
                            fsm->ses_max_temp, ps->hot_fail_count);
                } else if (ps->degrade_count > 0) {
                    ps->degrade_count--;
                    asb_log("pstats: good perf session -> degrade_count decayed to %d",
                            ps->degrade_count);
                }
                if (ps->avg_degrade_age > 0 && ps->avg_degrade_age < 300.0f) {
                    float old_da = ps->avg_degrade_age;
                    ps->avg_degrade_age += 15.0f;
                    if (ps->avg_degrade_age > 300.0f) ps->avg_degrade_age = 300.0f;
                    asb_log("pstats: good perf session -> avg_degrade_age %.0f->%.0f (rehab)",
                            old_da, ps->avg_degrade_age);
                }
            }
        }

        /* cause_streak -- track consecutive same-cause sessions */
        {
            int cur_cause = 0;
            if (pidx == PROFILE_BATTERY) {
                long bt = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                         + fsm->bat_time_moderate_sec;
                int iq = -1;
                if (bt > 60) {
                    iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bt);
                    int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
                    iq -= wp; if (iq < 0) iq = 0;
                }
                int bc = battery_fail_cause(fsm, iq);
                if (bc == BAT_CAUSE_WAKE_NOISE) cur_cause = 1;
                else if (bc == BAT_CAUSE_SCREEN_ON) cur_cause = 2;
                else if (bc == BAT_CAUSE_NO_SETTLE) cur_cause = 3;
            } else if (fsm->ses_headroom_samples >= 10) {
                int _b50 = (int)(100L * fsm->ses_headroom_below50 / fsm->ses_headroom_samples);
                int _hmin = fsm->ses_headroom_min;
                if (fsm->ses_max_temp >= 90) cur_cause = 5;
                else if (_b50 >= 15 || _hmin < 50) cur_cause = 4;
            }
            if (cur_cause > 0 && cur_cause == ps->cause_streak_type) {
                ps->cause_streak++;
            } else {
                ps->cause_streak = (cur_cause > 0) ? 1 : 0;
                ps->cause_streak_type = cur_cause;
            }
            if (ps->cause_streak >= 3 &&
                (ps->cause_streak == 3 || ps->cause_streak == 5 ||
                 ps->cause_streak == 10 || ps->cause_streak % 10 == 0)) {
                static const char *_cn[] = {"none","wake_noise","screen_on","no_settle","vendor_clamp","thermal"};
                asb_log("cause_streak: %s x%d consecutive", _cn[ps->cause_streak_type], ps->cause_streak);
            }
        }

        
        if (pidx == PROFILE_BATTERY) {
            long _dur_bm = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
            long _bt_bm = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                          + fsm->bat_time_moderate_sec;
            int _iq_bm = (_bt_bm > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_bm) : 0;
            float _wph_bm = (_dur_bm > 0) ? (float)fsm->bat_wake_bg * 3600.0f / _dur_bm : 0;
            ps->avg_idle_q = ps->avg_idle_q * (1 - alpha) + _iq_bm * alpha;
            ps->avg_wph = ps->avg_wph * (1 - alpha) + _wph_bm * alpha;
            /* Track clean nights separately */
            if (_dur_bm >= 7200 && _iq_bm >= 40 && fsm->bat_wake_bg <= 4) {
                ps->clean_night_count++;
                float qn_min = _dur_bm / 60.0f;
                float cn_a = 1.0f / ps->clean_night_count;
                if (cn_a < 0.15f) cn_a = 0.15f;
                ps->avg_quiet_duration_min =
                    ps->avg_quiet_duration_min * (1 - cn_a) + qn_min * cn_a;
            }
            /* Battery Memory Split -- night vs day */
            int is_night = (_dur_bm >= 7200 && _iq_bm >= 30 && !fsm->ses_auto_degraded);
            if (is_night) {
                ps->night_count++;
                float na = 1.0f / ps->night_count;
                if (na < 0.15f) na = 0.15f;
                ps->night_avg_iq = ps->night_avg_iq * (1 - na) + _iq_bm * na;
                ps->night_avg_wph = ps->night_avg_wph * (1 - na) + _wph_bm * na;
            } else {
                ps->day_count++;
                float da = 1.0f / ps->day_count;
                if (da < 0.15f) da = 0.15f;
                ps->day_avg_iq = ps->day_avg_iq * (1 - da) + _iq_bm * da;
                ps->day_avg_wph = ps->day_avg_wph * (1 - da) + _wph_bm * da;
            }
        }

        pstats_save_one(g_pstats_files[pidx], ps);
    }

    float ga = 1.0f / (g_pstats.session_count + 1);
    if (ga < 0.1f) ga = 0.1f;
    if (fsm->ses_time_to_first_sus > 0)
        g_pstats.avg_time_to_first_sus =
            g_pstats.avg_time_to_first_sus * (1-ga) + fsm->ses_time_to_first_sus * ga;
    if (fsm->ses_time_to_first_thermal > 0)
        g_pstats.avg_time_to_first_thermal =
            g_pstats.avg_time_to_first_thermal * (1-ga) + fsm->ses_time_to_first_thermal * ga;
    if (fsm->ses_max_temp > 0)
        g_pstats.avg_max_temp =
            g_pstats.avg_max_temp * (1-ga) + fsm->ses_max_temp * ga;
    if (fsm->ses_gap_samples > 0) {
        int avg_gap = (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples);
        g_pstats.avg_gap_p0 =
            g_pstats.avg_gap_p0 * (1-ga) + avg_gap * ga;
    }
    if (fsm->ses_sustained_efficiency >= 0)
        g_pstats.avg_efficiency =
            g_pstats.avg_efficiency * (1-ga) + fsm->ses_sustained_efficiency * ga;
    if (g_pstats.session_count < PERSISTENT_STATS_MAX_SESSIONS)
        g_pstats.session_count++;
    if (fsm->ses_auto_degraded)
        g_pstats.degrade_count++;
    pstats_save_one(PERSISTENT_STATS_FILE, &g_pstats);
}

static const char *classify_confidence(
    const asb_fsm_t *fsm, long dur, int hr_n, int idle_quality)
{
    (void)idle_quality;  /* used by caller for classify_signature */
    if (fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED) {
        /* For non-battery profiles, trust = duration-based only.
         * battery_session_trust() checks bat_total which is always 0
         * for performance sessions -- don't reuse it here. */
        if (dur < 120) return "low";  /* too short to be meaningful */
        if (dur >= 300 && hr_n >= 30) return "high";
        if (dur >= 120 && hr_n >= 10) return "medium";
        return "low";
    }
    if (fsm->profile_idx == PROFILE_BATTERY) {
        int trust = battery_session_trust(fsm);
        if (trust == BAT_TRUST_CLEAN && dur >= 300) return "high";
        if (trust != BAT_TRUST_DIRTY && dur >= 120) return "medium";
        return "low";
    }
    return "low";
}

static const char *classify_signature(
    const asb_fsm_t *fsm, int sus_pct,
    const char *limiter, int reach, const char *bat_reason,
    const char *conf, int idle_quality)
{
    if (fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED) {
        if (strcmp(limiter, "vendor_clamp") == 0) return "vendor_clamped";
        /* thermal_limited beats stable_dominant when session is hot */
        int thermal_hot = (fsm->profile_idx == PROFILE_PERFORMANCE)
                          ? (fsm->ses_max_temp >= 90)
                          : (fsm->ses_max_temp >= 80);
        if (strcmp(limiter, "thermal") == 0 || thermal_hot) return "thermal_limited";
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 60 && reach < 50)
            return "early_collapse";
        if (reach >= 70 && fsm->ses_time_to_first_sus >= 90 && strcmp(limiter, "reachable") == 0)
            return "clean_burst";
        if (sus_pct >= 60) return "stable_dominant";
        return "mixed";
    }
    if (fsm->profile_idx == PROFILE_BATTERY) {
        /* clean_sleep requires high confidence + good idle + no heavy */
        if (strcmp(bat_reason, "none") == 0 &&
            strcmp(conf, "high") == 0 &&
            idle_quality >= 70 &&
            fsm->ses_time_heavy_sec == 0)
            return "clean_sleep";
        if (strcmp(bat_reason, "wake_noise") == 0) return "wake_noisy";
        if (strcmp(bat_reason, "screen_on") == 0) return "screen_on_drag";
        if (strcmp(bat_reason, "no_settle") == 0) return "no_settle";
        return "mixed";
    }
    return "mixed";
}

static const char *classify_anomaly(
    const asb_fsm_t *fsm, long dur, int idle_quality, int cap_eff)
{
    /* extreme_temp: profile-aware (98 perf, 100 others) */
    int extreme_thresh = (fsm->profile_idx == PROFILE_PERFORMANCE) ? 98 : 100;
    if (fsm->ses_max_temp >= extreme_thresh) return "extreme_temp";
    if (fsm->ses_unreachable_entries >= 5) return "unreachable";
    /* efficiency_collapse: performance with very low cap_eff + degraded or low efficiency */
    if ((fsm->profile_idx == PROFILE_PERFORMANCE || fsm->profile_idx == PROFILE_BALANCED)
        && dur >= 600 && cap_eff >= 0 && cap_eff < 45
        && (fsm->ses_sustained_efficiency < 60 || fsm->ses_auto_degraded))
        return "efficiency_collapse";
    /* failed_settle: battery session with terrible idle quality */
    if (fsm->profile_idx == PROFILE_BATTERY && dur >= 900
        && idle_quality >= 0 && idle_quality < 25)
        return "failed_settle";
    if (fsm->profile_idx == PROFILE_BATTERY && fsm->bat_wake_bg >= 10) return "wake_spike";
    if (dur < 60) return "too_short";
    return "none";
}

static void session_history_append_ex(const asb_fsm_t *fsm, const char *reason) {
    if (fsm->ses_sustained_entries == 0 && fsm->ses_time_heavy_sec < 10
        && fsm->bat_time_deep_idle_sec < 60)
        return;

    /* skip boundary carry-over sessions
     * dur<=0: impossible real session for any profile -- always skip
     * dur<60: short hot profile switches for non-battery non-benchmark */
    long _dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (_dur <= 0) return;
    if (_dur < 60 && fsm->profile_idx != PROFILE_BATTERY
        && fsm->ses_intent != INTENT_BENCHMARK) {
        asb_log("session_history: skipping short boundary session (%lds, profile=%d)", _dur, fsm->profile_idx);
        return;
    }

    static const char *profile_names[] = {"battery","balanced","performance","smart"};
    static const char *mode_names[] = {"default","burst","stable","auto"};
    int mode_idx = g_asb_cfg.highload_mode;
    if (mode_idx < 0 || mode_idx > 3) mode_idx = 0;
    int avg_gap = (fsm->ses_gap_samples > 0)
                  ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0;
    long total_active = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                       + fsm->ses_time_sustained_sec;
    int sus_pct = (total_active > 0)
                  ? (int)(fsm->ses_time_sustained_sec * 100 / total_active) : 0;

    /*
     * session_history rotation — stream-based to avoid 1 MB stack allocation.
     * If file exceeds SESSION_HISTORY_SIZE_CAP_BYTES, force tighter trim by skipping more
     * lines until the resulting file fits.
     */
    int line_count = 0;
    long file_size = 0;
    {
        FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
        if (rf) {
            char buf[SESSION_HISTORY_LINE_MAX];
            while (fgets(buf, sizeof(buf), rf)) {
                file_size += (long)strlen(buf);
                if (buf[0] == '{') line_count++;
            }
            fclose(rf);
        }
    }

    /* Determine how many lines to skip from the start to keep last (MAX-1) */
    int skip = (line_count >= SESSION_HISTORY_MAX) ? line_count - SESSION_HISTORY_MAX + 1 : 0;

    /* Hard size cap: if estimated retained bytes still exceed cap, increase skip */
    if (file_size > SESSION_HISTORY_SIZE_CAP_BYTES && line_count > 0) {
        long avg_line = file_size / (line_count > 0 ? line_count : 1);
        if (avg_line < 1) avg_line = 1;
        long max_lines_for_cap = SESSION_HISTORY_SIZE_CAP_BYTES / avg_line;
        if (max_lines_for_cap > 0 && line_count - skip > (int)max_lines_for_cap) {
            skip = line_count - (int)max_lines_for_cap + 1;
            if (skip < 0) skip = 0;
        }
    }

    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", SESSION_HISTORY_FILE);
    FILE *wf = fopen(tmp_path, "w");
    if (!wf) return;

    /* Pass 2: stream existing lines, skipping first `skip` */
    {
        FILE *rf = fopen(SESSION_HISTORY_FILE, "r");
        if (rf) {
            char buf[SESSION_HISTORY_LINE_MAX];
            int idx = 0;
            while (fgets(buf, sizeof(buf), rf)) {
                if (buf[0] != '{') continue;
                if (idx >= skip) {
                    /* strip trailing newline then re-emit */
                    int len = (int)strlen(buf);
                    if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';
                    fputs(buf, wf);
                    fputc('\n', wf);
                }
                idx++;
            }
            fclose(rf);
        }
    }

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M", tm);
    
    long dur = (fsm->ses_start_ts > 0) ? (now - fsm->ses_start_ts) : 0;
    int idle_quality = -1;
    if (fsm->profile_idx == PROFILE_BATTERY ||
        fsm->profile_idx == PROFILE_SMART) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;
        if (bat_total > 60) {
            idle_quality = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
            int wake_penalty = (fsm->bat_wake_bg > 2)
                               ? (fsm->bat_wake_bg - 2) * 5 : 0;
            idle_quality -= wake_penalty;
            if (idle_quality < 0) idle_quality = 0;
        }
    }
    int cap_eff = -1;
    if (fsm->ses_gaming_entries > 0 && avg_gap > 0) {
        int target = asb_profile_bounds_for(fsm->profile_idx)->ceil.cpu_max[0];
        if (target > 0) {
            cap_eff = (int)((target - avg_gap) * 100 / target);
            if (cap_eff < 0) cap_eff = 0;
            if (cap_eff > 100) cap_eff = 100;
        }
    }
    /* headroom session metrics */
    int hr_avg = (fsm->ses_headroom_samples > 0)
                 ? (int)(fsm->ses_headroom_sum / fsm->ses_headroom_samples) : -1;
    int hr_min = (fsm->ses_headroom_samples > 0) ? fsm->ses_headroom_min : -1;
    int hr_b70 = fsm->ses_headroom_below70;
    int hr_b50 = fsm->ses_headroom_below50;

    /* session-level limiter, reachability, battery reason */
    const char *limiter = "none";
    int reach = -1;
    const char *bat_reason = "none";

    if (fsm->profile_idx == PROFILE_BATTERY) {
        /* Battery: compute reason from same logic as self_tune */
        int cause = battery_fail_cause(fsm, idle_quality);
        static const char *br_names[] = {"none","wake_noise","screen_on","no_settle"};
        bat_reason = (cause >= 0 && cause <= 3) ? br_names[cause] : "none";
    } else if (hr_avg >= 0 && fsm->ses_headroom_samples >= 10) {
        /* Performance/Balanced: classify limiter from headroom data */
        int hr_n = fsm->ses_headroom_samples;
        int b50_pct = (hr_n > 0) ? (int)(100L * hr_b50 / hr_n) : 0;
        int b70_pct = (hr_n > 0) ? (int)(100L * hr_b70 / hr_n) : 0;
        /* thermal_hot: profile-aware threshold
         * performance: 90degC (high thermal headroom expected)
         * balanced/other: 80degC (lower threshold matches Python fallback) */
        int thermal_hot = 0;
        if (fsm->profile_idx == PROFILE_PERFORMANCE) {
            thermal_hot = (fsm->ses_max_temp >= 90);
        } else {
            thermal_hot = (fsm->ses_max_temp >= 80);
        }

        if (cap_eff >= 70 && b70_pct < 10 && hr_min >= 70)
            limiter = "reachable";
        else if (cap_eff >= 0 && cap_eff < 40 && hr_min >= 80
                 && !thermal_hot && fsm->ses_unreachable_entries >= 5)
            limiter = "vendor_clamp";  /* hard clamp: good headroom, low temp, but caps not reached */
        else if (cap_eff >= 0 && cap_eff < 40 && !thermal_hot
                 && fsm->ses_unreachable_entries >= 10 && b50_pct < 10)
            limiter = "vendor_clamp";  /* unreachable-dominant: massive gap, moderate headroom, not thermal */
        else if (cap_eff >= 0 && cap_eff < 40 && !thermal_hot
                 && fsm->clamp_hold && b50_pct < 10)
            limiter = "vendor_clamp";  /* hold-aware -- futility confirmed clamp, unreachable suppressed */
        else if (cap_eff >= 0 && cap_eff < 55 && (b50_pct >= 15 || hr_min < 50) && !thermal_hot)
            limiter = "vendor_clamp";
        else if (thermal_hot && (b70_pct >= 20 || (cap_eff >= 0 && cap_eff < 60)))
            limiter = "thermal";
        else
            limiter = "mixed";

        /* Reachability score: 0-100, combines cap_eff and headroom */
        if (cap_eff >= 0 && hr_avg >= 0) {
            reach = (cap_eff + hr_avg) / 2;
            if (reach > 100) reach = 100;
        } else if (cap_eff >= 0) {
            reach = cap_eff;
        } else if (hr_avg >= 0) {
            reach = hr_avg;
        }
    }

    /* session-level classification fields */
    const char *conf = classify_confidence(fsm, dur, fsm->ses_headroom_samples, idle_quality);
    const char *sig  = classify_signature(fsm, sus_pct, limiter, reach, bat_reason, conf, idle_quality);
    const char *anomaly = classify_anomaly(fsm, dur, idle_quality, cap_eff);

    /* cap reach when anomaly shows session was clearly limited */
    if (strcmp(anomaly, "extreme_temp") == 0 && reach > 75) {
        reach = 75;
        if (fsm->ses_time_to_first_sus > 0 && fsm->ses_time_to_first_sus < 90)
            reach = 65;
    }
    int mid_tune_n = fsm->ses_mid_tune_count;
    const char *mid_tune = "none";
    if (mid_tune_n > 0) mid_tune = (mid_tune_n >= 3) ? "heavy" : "light";

    /* battery outcome classification + trust for session history */
    int bat_trust_val = -1;
    const char *bat_outcome = "none";
    if (fsm->profile_idx == PROFILE_BATTERY ||
        fsm->profile_idx == PROFILE_SMART) {
        bat_trust_val = battery_session_trust(fsm);
        long _bt_o = fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec
                     + fsm->bat_time_moderate_sec;
        int _iq_o = (_bt_o > 0) ? (int)(fsm->bat_time_deep_idle_sec * 100 / _bt_o) : 0;
        /* V56: noise = BACKGROUND wakes; the user's own screen checks are not
         * wake noise (field data: 53% of sessions were rejected as wake_noisy
         * with wake_bg=0 -- every single wake was the user's screen). */
        float _wph_o = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
        if (bat_trust_val == BAT_TRUST_CLEAN && _iq_o >= 40 && _wph_o < 2.0f
            && dur >= 7200 && !fsm->ses_auto_degraded)
            bat_outcome = "clean_night";
        else if (bat_trust_val == BAT_TRUST_CLEAN && _iq_o >= 20)
            bat_outcome = "clean_day";
        else if (_wph_o > 10.0f)
            bat_outcome = "wake_noisy";
        else if (_iq_o < 20 && dur >= 300)
            bat_outcome = "no_settle";
        else if (fsm->ses_max_temp >= 45)
            bat_outcome = "thermal_warm";
        else if (bat_trust_val == BAT_TRUST_DIRTY)
            bat_outcome = "hostile";
        else
            bat_outcome = "mixed";
    }

    /* performance outcome classification */
    const char *perf_outcome = "none";
    if (fsm->profile_idx == PROFILE_PERFORMANCE) {
        if (fsm->had_futility && fsm->clamp_hold && cap_eff < 40)
            perf_outcome = "vendor_clamped";
        else if (fsm->had_futility && !fsm->clamp_hold)
            perf_outcome = "recovered_clamp";
        else if (fsm->ses_max_temp >= 90 || (fsm->ses_thermal_entries >= 3 && sus_pct >= 30))
            perf_outcome = "thermal_limited";
        else if (fsm->ses_auto_degraded)
            perf_outcome = "degraded";
        else if (fsm->ses_sustained_entries == 0 && fsm->ses_max_temp < 70)
            perf_outcome = "clean";
        else
            perf_outcome = "mixed";
    }

    int would_be_noisy = 0;
    char noisy_dim[96] = "";
    if (fsm->profile_idx == PROFILE_BATTERY) {
        long _bt = fsm->bat_time_deep_idle_sec
                   + fsm->bat_time_light_idle_sec
                   + fsm->bat_time_moderate_sec;
        float _wph = (dur > 0)
                     ? (float)fsm->bat_wake_cycles * 3600.0f / dur : 0.0f;
        if (idle_quality >= 8 && idle_quality <= 19
            && _wph >= 12.0f && _wph <= 25.0f
            && fsm->bat_wake_cycles >= 10 && fsm->bat_wake_cycles <= 50
            && dur >= 1800 && _bt > 600) {
            would_be_noisy = 1;
        }
        snprintf(noisy_dim, sizeof(noisy_dim),
                 "iq=%d wph=%.1f wake=%d bg=%d scr=%d dur=%ld bt=%ld",
                 idle_quality, _wph, fsm->bat_wake_cycles,
                 fsm->bat_wake_bg, fsm->bat_wake_screen, dur, _bt);
    }

    fprintf(wf,
        "{\"v\":16,\"ts\":\"%s\",\"profile\":\"%s\",\"mode\":\"%s\",\"end\":\"%s\","
        "\"gaming\":%d,\"sustained\":%d,\"thermal\":%d,\"unreachable\":%d,"
        "\"t_heavy\":%ld,\"t_gaming\":%ld,\"t_sustained\":%ld,"
        "\"avg_gap\":%d,\"max_temp\":%d,\"skin_max_temp\":%d,\"surface_max_temp\":%d,\"board_max_temp\":%d,\"degraded\":%d,"
        "\"temp_invalid_n\":%d,\"temp_last_reason\":\"%s\","
        "\"t2s\":%ld,\"t2th\":%ld,\"t2g\":%ld,\"eff\":%d,\"recovery\":%d,"
        "\"sus_pct\":%d,"
        "\"bat_deep\":%ld,\"bat_light\":%ld,\"bat_mod\":%ld,"
        "\"bat_wake\":%d,\"bat_ttd\":%ld,"
        "\"wake_screen\":%d,\"wake_bg\":%d,\"radio_ticks\":%d,"
        "\"idle_q\":%d,\"cap_eff\":%d,\"dur\":%ld,"
        "\"intent\":\"%s\",\"deg_age\":%ld,"
        "\"asb\":\"%s\",\"learn_exempt\":%d,"
        "\"hr_avg\":%d,\"hr_min\":%d,\"hr_b70\":%d,\"hr_b50\":%d,\"hr_n\":%d,"
        "\"limiter\":\"%s\",\"reach\":%d,\"bat_reason\":\"%s\","
        "\"conf\":\"%s\",\"sig\":\"%s\",\"mid_tune\":\"%s\",\"mid_n\":%d,\"anomaly\":\"%s\","
        "\"clamp_hold\":%d,\"had_clamp_hold\":%d,\"had_futility\":%d,"
        "\"bat_trust\":%d,\"bat_outcome\":\"%s\",\"perf_outcome\":\"%s\","
        "\"env\":\"%s\","
        "\"mem_psi_peak\":%d,\"mem_press_ticks\":%d,"
        "\"would_be_noisy\":%d,\"noisy_dim\":\"%s\","
        "\"adv_score\":%d,\"adv_active\":%d,\"adv_vote_skin\":%d,\"adv_vote_surface\":%d,\"adv_vote_board\":%d,\"adv_would_bias\":%d,"
        "\"bias_mode_a_count\":%d,\"bias_mode_b_count\":%d,"
        "\"smart_mode\":%d,\"bucket_id\":%d,\"daypart\":%d,\"is_weekend\":%d,"
        "\"bucket_confidence\":%d,\"alpha_battery\":%d,"
        "\"smart_fallback_level\":%d,\"sleep_override_n\":%d,\"thermal_veto_n\":%d,"
        "\"app_hint_top\":%d,\"pkg_hash_top\":\"%016llx\"}\n",
        ts, profile_names[fsm->profile_idx], mode_names[mode_idx], reason,
        fsm->ses_gaming_entries, fsm->ses_sustained_entries,
        fsm->ses_thermal_entries, fsm->ses_unreachable_entries,
        fsm->ses_time_heavy_sec, fsm->ses_time_gaming_sec,
        fsm->ses_time_sustained_sec,
        avg_gap, fsm->ses_max_temp, fsm->ses_max_skin_temp, fsm->ses_max_surface_temp, fsm->ses_max_board_temp, fsm->ses_auto_degraded,
        fsm->ses_temp_invalid_count,
        fsm->ses_last_temp_reason[0] ? fsm->ses_last_temp_reason : "ok",
        fsm->ses_time_to_first_sus, fsm->ses_time_to_first_thermal,
        fsm->ses_time_to_first_gaming,
        fsm->ses_sustained_efficiency, fsm->ses_recovery_count,
        sus_pct,
        fsm->bat_time_deep_idle_sec, fsm->bat_time_light_idle_sec,
        fsm->bat_time_moderate_sec,
        fsm->bat_wake_cycles, fsm->bat_time_to_first_deep,
        fsm->bat_wake_screen, fsm->bat_wake_bg, fsm->bat_radio_active_ticks,
        idle_quality, cap_eff, dur,
        (fsm->ses_intent >= 0 && fsm->ses_intent <= 6)
            ? intent_names[fsm->ses_intent] : "unknown",
        fsm->ses_degrade_at_age,
        ASB_VERSION,
        (fsm->ses_intent == INTENT_BENCHMARK) ? 1 : 0,
        hr_avg, hr_min, hr_b70, hr_b50, fsm->ses_headroom_samples,
        limiter, reach, bat_reason,
        conf, sig, mid_tune, mid_tune_n, anomaly,
        fsm->clamp_hold, fsm->had_clamp_hold, fsm->had_futility,
        bat_trust_val, bat_outcome, perf_outcome,
        (const char *[]){"quiet","noisy","hostile"}[classify_environment(fsm)],
        fsm->mem_psi_peak_x100, fsm->mem_pressure_ticks,
        would_be_noisy, noisy_dim,
        fsm->thermal_advisory_score, fsm->thermal_advisory_active,
        fsm->thermal_vote_skin, fsm->thermal_vote_surface, fsm->thermal_vote_board,
        fsm->would_bias_exit_gaming,
        fsm->would_bias_mode_a_count, fsm->would_bias_mode_b_count,
        /* Smart Mode fields */
        g_smart_rt.enabled,
        g_smart_rt.bucket_id,
        g_smart_rt.daypart,
        g_smart_rt.is_weekend,
        g_smart_rt.conf_x1000,
        g_smart_rt.alpha_battery_x1000,
        g_smart_rt.fallback_level,
        /* sleep_override_n / thermal_veto_n: alpha tracks current state only,
         * not session counters (deferred to dedicated counters) */
        g_smart_rt.night_safe_override ? 1 : 0,
        g_smart_rt.thermal_veto ? 1 : 0,
        g_smart_rt.app_hint_session_top,
        (unsigned long long)g_smart_rt.app_hash_session_top);

    /* Smart Mode: feed session outcome into bucket learning (smart_mode=1 only) */
    if (g_smart_rt.enabled && g_smart_store_loaded && dur > 0) {
        asb_smart_session_input_t sin = {0};
        sin.dur_s = (int)dur;
        sin.max_temp_c = fsm->ses_max_temp;
        sin.max_skin_c = fsm->ses_max_skin_temp;
        sin.trust = (bat_trust_val >= 0) ? bat_trust_val : ASB_TRUST_PARTIAL;
        sin.was_heavy = (fsm->ses_time_heavy_sec > 60 || fsm->ses_time_gaming_sec > 60) ? 1 : 0;
        sin.was_thermal_hit = (fsm->ses_thermal_entries > 0) ? 1 : 0;
        sin.sustained_pct = sus_pct;
        sin.idle_q_x10 = (idle_quality >= 0) ? idle_quality * 10 : 0;
        sin.drain_pctph_x10 = 0;
        sin.drain_on_sec = (int)g_smart_drain_on_sec;
        if (g_smart_drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC) {
            long r = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
            if (r < 0) r = 0;
            if (r > 6000) r = 6000;
            sin.drain_pctph_x10 = (int)r;
        }
        if (sin.drain_pctph_x10 > 0) {
            if (g_smart_drain_rate_ewma_x10 <= 0)
                g_smart_drain_rate_ewma_x10 = sin.drain_pctph_x10;
            else
                g_smart_drain_rate_ewma_x10 =
                    (g_smart_drain_rate_ewma_x10 * 3 + sin.drain_pctph_x10) / 4;
            if (sin.drain_pctph_x10 >= ASB_SMART_APPHEAT_DRAIN_SAMPLE_X10 &&
                g_smart_rt.app_hash_session_top != 0) {
                asb_smart_appheat_drain_bump(g_smart_rt.app_hash_session_top, time(NULL));
            }
        }
        {
            int _qv = (sin.drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC);
            int _vph = -1;
            if (sin.dur_s >= 900 &&
                sin.drain_on_sec >= 600 &&
                g_v44_clamp_total >= g_smart_ses_clamp_start) {
                unsigned long _cd = g_v44_clamp_total - g_smart_ses_clamp_start;
                /* Only judge vendor-war when the absolute clamp count is
                   meaningful; a handful of clamps extrapolated over a short
                   session produces a misleading per-hour rate and false
                   primary_failure=vendor_war verdicts. */
                if (_cd >= 20) {
                    _vph = (int)((_cd * 3600UL) / (unsigned long)sin.dur_s);
                    if (_vph > 9999) _vph = 9999;
                }
            }
            asb_smart_quality_t _qb;
            int _q = asb_smart_session_quality_ex(sin.drain_pctph_x10, _qv,
                                               fsm->ses_max_temp,
                                               fsm->ses_thermal_entries,
                                               fsm->ses_recovery_count,
                                               _vph,
                                                  g_smart_rt.therm_warm_x10 > 0 ? (g_smart_rt.therm_warm_x10 - ASB_SMART_THERM_WARM_OFFSET_X10) / 10 : 0, &_qb);
            g_smart_last_quality = _q;
            g_smart_q_bat = _qb.q_battery;
            g_smart_q_heat = _qb.q_heat;
            g_smart_q_stab = _qb.q_stability;
            g_smart_q_vendor = _qb.q_vendor;
            g_smart_q_fail = _qb.primary_failure;
            if (g_smart_quality_ewma < 0) g_smart_quality_ewma = _q;
            else g_smart_quality_ewma = (g_smart_quality_ewma * 3 + _q) / 4;
            g_smart_ses_clamp_start = g_v44_clamp_total;
        }
        /* Carry the last usable rate across the session boundary.
         *
         * The window resets at the end of every session, and a session ends whenever the
         * screen goes off - so a phone used in short bursts almost never accumulated the
         * 300 seconds of continuous screen-on the estimate needs, and the banner sat on
         * "measuring..." for hours. Reported after three hours of ordinary use.
         *
         * The measurement itself must stay per-session: mixing a gaming session into a
         * reading one produces a number describing neither. But the LAST completed
         * measurement is still the best answer available until a new one exists, so it is
         * kept and published as such rather than thrown away.
         */
        if (g_smart_drain_on_sec >= 300 && g_smart_drain_drop_x100 > 0) {
            g_smart_drain_last_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
            g_smart_drain_last_ts  = time(NULL);
        }
        g_smart_drain_on_sec = 0;
        g_smart_drain_drop_x100 = 0;
        /* Estimate screen_on_pct from bat_wake counters (rough approximation) */
        if (fsm->bat_wake_cycles > 0 && dur > 0) {
            sin.screen_on_pct = (int)((fsm->bat_wake_screen * 100L) / fsm->bat_wake_cycles);
        }

        /* P0-3: startup quarantine.
         *
         * The first minutes after boot are package rescan, app restore, sync and whatever
         * the user immediately opened - a burst that looks nothing like how the phone
         * behaves settled. Banked as a normal session it teaches the learner that this
         * bucket is expensive, and that conclusion outlives the boot by weeks.
         *
         * The samples are NOT discarded: the phase ledger and telemetry keep them, because
         * they are real evidence of what the phone did. They are marked DIRTY, which the
         * bucket updater already refuses - one mechanism, not a second policy.
         *
         * Thermal safety is untouched by this. Nothing here gates a temperature read or an
         * emergency clamp; a phone that overheats two minutes after boot is still
         * protected. Only the energy conclusions wait for a settled sample.
         */
        if (g_gov_start_ts > 0 &&
            (long)(time(NULL) - g_gov_start_ts) < ASB_STARTUP_QUARANTINE_S) {
            sin.trust = ASB_TRUST_DIRTY;
            g_startup_quarantined++;
            asb_log("smart: session inside startup window (%lds) - kept as telemetry, "
                    "not banked into learning",
                    (long)(time(NULL) - g_gov_start_ts));
        }

        /* Find current bucket and update */
        int bid = (int)asb_smart_bucket_id(g_smart_rt.daypart, g_smart_rt.is_weekend);
        if (bid >= 0 && bid < ASB_SMART_BUCKETS) {
            asb_smart_bucket_update_from_session(
                &g_smart_store.buckets[bid], &sin, time(NULL));
            g_smart_sessions_since_save++;
            /* separate Smart-specific accounting */
            g_smart_sessions_total++;
            g_smart_bucket_updates++;
            g_smart_last_bucket_id = bid;
            g_smart_last_daypart = g_smart_rt.daypart;
            g_smart_last_confidence = g_smart_rt.conf_x1000;
            g_smart_last_update_ts = time(NULL);
            /* Day = morn/day/eve (2/3/4); Night = sleep/late (0/5); wake=1 floats */
            if (g_smart_rt.daypart == 0 || g_smart_rt.daypart == 5) {
                g_smart_sessions_night++;
            } else if (g_smart_rt.daypart >= 2 && g_smart_rt.daypart <= 4) {
                g_smart_sessions_day++;
            }
            if (g_smart_rt.app_hint_session_top >= ASB_APP_GAMING) {
                g_smart_sessions_gaming++;
            }
        }

        /* Reset session-top tracking for next session */
        g_smart_rt.app_hint_session_top = 0;
        g_smart_rt.app_hash_session_top = 0;
    }
    fflush(wf);
    fsync(fileno(wf));
    fclose(wf);
    rename(tmp_path, SESSION_HISTORY_FILE);
}

static int battery_session_trust(const asb_fsm_t *fsm) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 120) return BAT_TRUST_DIRTY;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    if (dur > 3600 && bat_total < 120 && fsm->bat_wake_cycles <= 2)
        return BAT_TRUST_PARTIAL;
    if (fsm->ses_intent == INTENT_SLEEP_IDLE)
        return BAT_TRUST_PARTIAL;
    if (fsm->ses_intent == INTENT_IDLE_WARM)
        return BAT_TRUST_PARTIAL;
    int iq = 0;
    if (bat_total > 0) {
        iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
        int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
        iq -= wp;
        if (iq < 0) iq = 0;
    }
    /* V56: wake NOISE = background wakes only; screen wakes are the user. */
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
    if (iq >= 12 && iq < 20 && dur >= 600 &&
        wph < 12.0f && fsm->bat_wake_bg < 24)
        return BAT_TRUST_PARTIAL;
    if (iq >= 8 && iq < 20 && dur >= 1800 && bat_total > 600 &&
        wph >= 12.0f && wph <= 25.0f &&
        fsm->bat_wake_bg >= 10 && fsm->bat_wake_bg <= 50)
        return BAT_TRUST_NOISY;
    if (iq < 20 && dur >= 300)
        return BAT_TRUST_DIRTY;
    if (wph > 10.0f)
        return BAT_TRUST_DIRTY;
    return BAT_TRUST_CLEAN;
}

/*
 * V56: read /proc/pressure/memory 'some avg10' as an integer x100 (e.g.
 * Note asb_smart.h has its own bucketed PSI reader for the alpha-bias path; this one returns
 * the raw scaled value for telemetry, which is why it's separate.
 */
static int asb_read_mem_psi_x100(void) {
    FILE *f = fopen("/proc/pressure/memory", "r");
    if (!f) return -1;
    char line[256];
    int out = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "some ", 5) != 0) continue;
        char *p = strstr(line, "avg10=");
        if (!p) break;
        p += 6;
        int whole = 0, frac = 0;
        if (sscanf(p, "%d.%d", &whole, &frac) >= 1)
            out = whole * 100 + frac;
        break;
    }
    fclose(f);
    return out;
}

static int classify_environment(const asb_fsm_t *fsm) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 60) return ENV_QUIET;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    int iq = 0;
    if (bat_total > 0) {
        iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
        int wp = (fsm->bat_wake_bg > 2) ? (fsm->bat_wake_bg - 2) * 5 : 0;
        iq -= wp;
        if (iq < 0) iq = 0;
    }
    /* V56: environment hostility is about the RADIO/BACKGROUND environment;
     * the user picking the phone up is not a hostile environment. wph is
     * therefore background-wake rate (screen wakes excluded). */
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600.0f / dur : 0;
    /* radio-aware -- heavy mobile data activity during screen-off
     * is a sign of hostile radio environment (push services, sync storms) */
    int radio_noisy = 0;
    if (dur > 120) {
        /* Most screen-off time now runs at TIMER_DEEP_S.  Dividing by the shorter idle period
         * after an adaptive cadence change would inflate the active-radio share and falsely
         * classify a quiet night as hostile, which in turn re-enables costly monitoring. */
        long expected_samples = dur / (TIMER_DEEP_S > 0 ? TIMER_DEEP_S : 30);
        if (expected_samples < 1) expected_samples = 1;
        int radio_pct = (int)((long)fsm->bat_radio_active_ticks * 100 / expected_samples);
        if (radio_pct > 30) radio_noisy = 1;  /* >30% of conservative samples had active data */
    }
    /*
     * V56 FIX: the idle-quality (iq) branch below is only meaningful when the session is
     * genuinely idle/screen-off dominant.
     */
    int idle_dominant = (bat_total > 0 &&
                         (fsm->bat_time_deep_idle_sec + fsm->bat_time_light_idle_sec)
                             * 2 >= bat_total);

    /* Real radio-storm / excessive-wake signals apply in any session. */
    if (wph > g_asb_cfg.env_wph_hostile || (radio_noisy && iq < 20 && idle_dominant))
        return ENV_HOSTILE;
    /* Idle-quality-based hostility only when the session is idle-dominant. */
    if (idle_dominant && iq < g_asb_cfg.env_iq_hostile)
        return ENV_HOSTILE;
    if (wph > g_asb_cfg.env_wph_noisy || radio_noisy ||
        (idle_dominant && iq < g_asb_cfg.env_iq_quiet))
        return ENV_NOISY;
    return ENV_QUIET;
}

static int battery_fail_cause(const asb_fsm_t *fsm, int iq) {
    long dur = (fsm->ses_start_ts > 0) ? (time(NULL) - fsm->ses_start_ts) : 0;
    if (dur < 120) return BAT_CAUSE_NONE;
    long bat_total = fsm->bat_time_deep_idle_sec +
                     fsm->bat_time_light_idle_sec +
                     fsm->bat_time_moderate_sec;
    float wph = (dur > 0) ? (float)fsm->bat_wake_bg * 3600 / dur : 0;
    float heavy_pct = (bat_total + fsm->ses_time_heavy_sec > 0)
                      ? (float)fsm->ses_time_heavy_sec /
                        (bat_total + fsm->ses_time_heavy_sec) : 0;
    if (iq >= 0 && iq < 20 && fsm->bat_time_to_first_deep > 600)
        return BAT_CAUSE_NO_SETTLE;
    if (wph > 12.0f && iq < 40)
        return BAT_CAUSE_WAKE_NOISE;
    if (heavy_pct > 0.5f && iq < 40)
        return BAT_CAUSE_SCREEN_ON;
    if (iq >= 0 && iq < 30)
        return BAT_CAUSE_NO_SETTLE;
    return BAT_CAUSE_NONE;
}

static void session_end_self_tune(const asb_fsm_t *fsm) {
    int tuned = 0;

    /* don't self-tune during quarantine */
    if (fsm->plan.quarantine) {
        asb_log("self_tune: quarantine active, skipping");
        return;
    }
    /* don't self-tune during storm shield (noisy battery data) */
    if (g_storm_shield_active) {
        asb_log("self_tune: storm shield active, skipping");
        return;
    }

    if (fsm->ses_gaming_entries >= 2 &&
        fsm->ses_intent != INTENT_BENCHMARK) {
        int avg_gap = (fsm->ses_gap_samples > 0)
                      ? (int)(fsm->ses_gap_p0_sum / fsm->ses_gap_samples) : 0;

        if (avg_gap > 1500000 && g_asb_cfg.sustained_level > 0.75f) {
            float old = g_asb_cfg.sustained_level;
            g_asb_cfg.sustained_level -= 0.02f;
            if (g_asb_cfg.sustained_level < 0.75f)
                g_asb_cfg.sustained_level = 0.75f;
            asb_log("self_tune: avg_gap=%d >1.5M -> sustained_level %.2f->%.2f",
                    avg_gap, old, g_asb_cfg.sustained_level);
            tuned++;
        }

        if (fsm->ses_sustained_efficiency >= 0 &&
            fsm->ses_sustained_efficiency < 50 &&
            g_asb_cfg.highload_mode != 2) {
            g_asb_cfg.highload_mode = 2;
            asb_config_apply_highload_mode(&g_asb_cfg);
            asb_log("self_tune: efficiency=%d <50 -> forced stable mode",
                    fsm->ses_sustained_efficiency);
            tuned++;
        }

        /*
         * Never raise the throttle point above what the user configured.
         * Hitting SUSTAINED inside a minute usually means the threshold is too low for this
         * device, and nudging it up is the right reflex - unless a person went into the WebUI
         * and deliberately chose a LOWER one.
         */
        if (fsm->ses_time_to_first_sus > 0 &&
            fsm->ses_time_to_first_sus < 60 &&
            g_asb_cfg.sustained_temp_enter < 68 &&
            g_asb_cfg.sustained_temp_enter < g_asb_cfg.sustained_temp_enter_user) {
            int old = g_asb_cfg.sustained_temp_enter;
            g_asb_cfg.sustained_temp_enter += 2;
            if (g_asb_cfg.sustained_temp_enter > 68)
                g_asb_cfg.sustained_temp_enter = 68;
            if (g_asb_cfg.sustained_temp_enter > g_asb_cfg.sustained_temp_enter_user)
                g_asb_cfg.sustained_temp_enter = g_asb_cfg.sustained_temp_enter_user;
            asb_log("self_tune: t2s=%lds <60s -> sustained_temp_enter %d->%d",
                    fsm->ses_time_to_first_sus, old, g_asb_cfg.sustained_temp_enter);
            tuned++;
        }

        if (fsm->ses_max_temp >= 100 && g_asb_cfg.highload_mode != 2) {
            long total_act = fsm->ses_time_heavy_sec + fsm->ses_time_gaming_sec
                            + fsm->ses_time_sustained_sec;
            int sp = (total_act > 0)
                     ? (int)(fsm->ses_time_sustained_sec * 100 / total_act) : 0;
            if (sp >= 40) {
                g_asb_cfg.highload_mode = 2;
                asb_config_apply_highload_mode(&g_asb_cfg);
                asb_log("self_tune: max_temp=%d>=100 sus_pct=%d>=40 -> forced stable",
                        fsm->ses_max_temp, sp);
                tuned++;
            }
        }
    }

    if (fsm_profile_is_battery) {
        long bat_total = fsm->bat_time_deep_idle_sec +
                         fsm->bat_time_light_idle_sec +
                         fsm->bat_time_moderate_sec;

        int iq = -1;
        if (bat_total > 60) {
            iq = (int)(fsm->bat_time_deep_idle_sec * 100 / bat_total);
            int wake_pen = (fsm->bat_wake_cycles > 2)
                           ? (fsm->bat_wake_cycles - 2) * 5 : 0;
            iq -= wake_pen;
            if (iq < 0) iq = 0;
        }

        int trust = battery_session_trust(fsm);
        int cause = battery_fail_cause(fsm, iq);
        static const char *cause_names[] = {"none","wake_noise","screen_on","no_settle"};
        asb_persistent_stats_t *bps = &g_pstats_per[PROFILE_BATTERY];
        long _now_ts = time(NULL);
        const long TUNE_MIN_GAP_S = 2 * 3600;

        if (trust == BAT_TRUST_DIRTY) {
            asb_log("self_tune: bat session dirty (too short), skipping");
        } else if (trust == BAT_TRUST_PARTIAL) {
            asb_log("self_tune: bat session partial (sleep/insufficient signal), skipping");
        } else if (trust == BAT_TRUST_NOISY) {
            asb_log("self_tune: bat session noisy (mixed-use), defensive tune only");
            /* Fall through to the cause-driven block via shared logic — */
            /* Implementation: jump directly to the bad-iq path below */
            if (iq >= 0 && iq < 40 && bat_total > 300 && cause != BAT_CAUSE_NONE) {
                asb_log("self_tune: noisy + bad iq=%d cause=%s, tuning by cause",
                        iq, cause_names[cause]);
                switch (cause) {
                case BAT_CAUSE_WAKE_NOISE:
                    if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                        (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s -= 1;
                        bps->last_tune_ts_fast_idle = _now_ts;
                        asb_log("self_tune: noisy+wake_noise -> bat_fast_idle %d->%d (cadence-gated)",
                                old, g_asb_cfg.bat_fast_idle_s);
                        tuned++;
                    }
                    break;
                default:
                    /* don't adjust on noisy + non-wake-noise causes */
                    break;
                }
            }
        } else if (bps->bat_tune_cooldown > 0) {
            bps->bat_tune_cooldown--;
            asb_log("self_tune: bat cooldown=%d, skipping tune this session", bps->bat_tune_cooldown + 1);
        } else if (iq >= 70 && bat_total > 300) {
            if (g_asb_cfg.bat_fast_idle_s < 8 &&
                (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                int old = g_asb_cfg.bat_fast_idle_s;
                g_asb_cfg.bat_fast_idle_s += 1;
                bps->last_tune_ts_fast_idle = _now_ts;
                asb_log("self_tune: bat good iq=%d -> bat_fast_idle %d->%d (relax)",
                        iq, old, g_asb_cfg.bat_fast_idle_s);
                tuned++;
            }
            if (g_asb_cfg.bat_heavy_load_enter > 10.0f &&
                (_now_ts - bps->last_tune_ts_heavy_load) >= TUNE_MIN_GAP_S) {
                float old = g_asb_cfg.bat_heavy_load_enter;
                g_asb_cfg.bat_heavy_load_enter -= 1.0f;
                bps->last_tune_ts_heavy_load = _now_ts;
                asb_log("self_tune: bat good iq=%d -> bat_heavy_load %.1f->%.1f (relax)",
                        iq, old, g_asb_cfg.bat_heavy_load_enter);
                tuned++;
            }
            if (g_asb_cfg.bat_moderate_load_enter > 8.0f &&
                (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
                float old = g_asb_cfg.bat_moderate_load_enter;
                g_asb_cfg.bat_moderate_load_enter -= 1.0f;
                asb_log("self_tune: bat good iq=%d -> bat_moderate_load %.1f->%.1f (relax)",
                        iq, old, g_asb_cfg.bat_moderate_load_enter);
                tuned++;
            }
            bps->bat_tune_cooldown = 1;
        } else if (iq >= 0 && iq < 40 && bat_total > 300 && cause != BAT_CAUSE_NONE) {
            asb_log("self_tune: bat bad iq=%d cause=%s, tuning by cause",
                    iq, cause_names[cause]);
            switch (cause) {
            case BAT_CAUSE_WAKE_NOISE:
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                    (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    bps->last_tune_ts_fast_idle = _now_ts;
                    asb_log("self_tune: wake_noise -> bat_fast_idle %d->%d (cadence-gated)",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                break;
            case BAT_CAUSE_SCREEN_ON:
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f &&
                    (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    bps->last_tune_ts_moderate_load = _now_ts;
                    asb_log("self_tune: screen_on -> bat_moderate_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                if (g_asb_cfg.bat_heavy_load_enter < 20.0f &&
                    (_now_ts - bps->last_tune_ts_heavy_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_heavy_load_enter;
                    g_asb_cfg.bat_heavy_load_enter += 1.0f;
                    bps->last_tune_ts_heavy_load = _now_ts;
                    asb_log("self_tune: screen_on -> bat_heavy_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_heavy_load_enter);
                    tuned++;
                }
                break;
            case BAT_CAUSE_NO_SETTLE:
                if (g_asb_cfg.bat_fast_idle_s > BAT_FAST_IDLE_FLOOR &&
                    (_now_ts - bps->last_tune_ts_fast_idle) >= TUNE_MIN_GAP_S) {
                    int old = g_asb_cfg.bat_fast_idle_s;
                    g_asb_cfg.bat_fast_idle_s -= 1;
                    if (g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR)
                        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
                    bps->last_tune_ts_fast_idle = _now_ts;
                    asb_log("self_tune: no_settle -> bat_fast_idle %d->%d (cadence-gated)",
                            old, g_asb_cfg.bat_fast_idle_s);
                    tuned++;
                }
                if (g_asb_cfg.bat_moderate_load_enter < 15.0f &&
                    (_now_ts - bps->last_tune_ts_moderate_load) >= TUNE_MIN_GAP_S) {
                    float old = g_asb_cfg.bat_moderate_load_enter;
                    g_asb_cfg.bat_moderate_load_enter += 1.0f;
                    bps->last_tune_ts_moderate_load = _now_ts;
                    asb_log("self_tune: no_settle -> bat_moderate_load %.1f->%.1f (cadence-gated)",
                            old, g_asb_cfg.bat_moderate_load_enter);
                    tuned++;
                }
                break;
            }
            bps->bat_tune_cooldown = 2;
        }

        if (bat_total > 300 && fsm->bat_time_moderate_sec > 0 &&
            (_now_ts - bps->last_tune_ts_light_gpu) >= TUNE_MIN_GAP_S) {
            int mod_pct = (int)(fsm->bat_time_moderate_sec * 100 / bat_total);
            if (mod_pct > 40 && g_asb_cfg.bat_light_idle_gpu > 5) {
                int old = g_asb_cfg.bat_light_idle_gpu;
                g_asb_cfg.bat_light_idle_gpu -= 2;
                if (g_asb_cfg.bat_light_idle_gpu < 5)
                    g_asb_cfg.bat_light_idle_gpu = 5;
                bps->last_tune_ts_light_gpu = _now_ts;
                asb_log("self_tune: bat MODERATE=%d%% -> bat_light_idle_gpu %d->%d (cadence-gated)",
                        mod_pct, old, g_asb_cfg.bat_light_idle_gpu);
                tuned++;
            }
        }
    }

    if (tuned > 0)
        asb_log("self_tune: %d adjustments applied (no restart needed)", tuned);
}

static int read_profile_idx(void) {
    char buf[32] = {0};
    int fd = open(PROFILE_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return PROFILE_BALANCED;
    int n = read(fd, buf, sizeof(buf)-1);
    close(fd);
    if (n <= 0) return PROFILE_BALANCED;
    buf[n] = '\0';
    for (int i = 0; buf[i]; i++)
        if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
    if (strcmp(buf, "battery")     == 0) return PROFILE_BATTERY;
    if (strcmp(buf, "performance") == 0) return PROFILE_PERFORMANCE;
    if (strcmp(buf, "smart")       == 0) return PROFILE_SMART;
    return PROFILE_BALANCED;
}

static int make_timerfd(int secs) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
    return fd;
}

/* Change a periodic timer's interval in place, keeping it periodic.
 *
 * arm_timerfd below is one-shot: it sets it_value and leaves it_interval zero, which is
 * right for the wake-up nudge it was written for and would silently stop the screen-on
 * tick after a single fire. */
static void arm_timerfd_periodic(int fd, int secs) {
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
}

static void arm_timerfd(int fd, int secs) {
    struct itimerspec its = {
        .it_interval = { secs, 0 },
        .it_value    = { secs, 0 }
    };
    timerfd_settime(fd, 0, &its, NULL);
}

static void disarm_timerfd(int fd) {
    struct itimerspec its = {0};
    timerfd_settime(fd, 0, &its, NULL);
}

static void timerfd_drain(int fd) {
    uint64_t exp;
    ssize_t _r = read(fd, &exp, sizeof(exp));
    (void)_r;
}

static int make_uevent_fd(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    struct sockaddr_nl addr = {
        .nl_family = AF_NETLINK,
        .nl_pid    = getpid(),
        .nl_groups = 1
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd); return -1;
    }
    int buf = 256 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    return fd;
}

static int parse_uevent_screen(int fd) {
    char buf[4096];
    int n = recv(fd, buf, sizeof(buf)-1, MSG_DONTWAIT);
    if (n <= 0) return -1;
    buf[n] = '\0';

    int is_display = 0, is_power = 0;
    char *p = buf;
    while (p < buf + n) {
        if (strstr(p, "SUBSYSTEM=backlight") ||
            strstr(p, "SUBSYSTEM=drm")       ||
            strstr(p, "oplus_display")        ||
            strstr(p, "panel"))
            is_display = 1;

        if (strstr(p, "POWER=0") || strstr(p, "brightness=0") ||
            strstr(p, "screen_off") || strstr(p, "BLANK=1"))
            is_power = 0; /* off */
        else if (strstr(p, "POWER=1") || strstr(p, "screen_on") ||
                 strstr(p, "BLANK=0"))
            is_power = 1; /* on */

        p += strlen(p) + 1;
    }
    if (!is_display) return -1;
    return is_power;
}

/*
 * Smart Media Guard: a narrow, explicit guard for a known media/feed/browser app that
 * reaches the FSM's game-like CPU+GPU band. A package has to be freshly detected and
 * positively recognised as media; an unknown app, stale package and any known game all
 * fail closed. This keeps the switch from becoming a universal performance cap.
 */
static int asb_smart_media_guard_observe(const asb_metrics_t *m,
                                         const asb_fsm_t *fsm,
                                         time_t now) {
    int was_active = g_smart_media_guard_active;
    const char *why = "disabled";
    int eligible = 0;
    if (!g_asb_cfg.smart_media_guard) {
        why = "disabled";
    } else if (!m || !fsm || fsm->profile_idx != PROFILE_SMART) {
        why = "profile_not_smart";
    } else if (!m->misc.screen_on || m->bat.charging) {
        why = "not_screenon_discharge";
    } else if (fsm->thermal_cap) {
        why = "thermal_cap";
    } else if (fsm->state != ASB_STATE_GAMING) {
        why = "state_not_gaming";
    } else if (!g_pkg_detect_ok || !g_smart_media_pkg_known ||
               g_smart_rt.app_hint >= ASB_APP_GAMING) {
        why = "no_fresh_known_media_pkg";
    } else if (m->gpu.load_pct < g_asb_cfg.gaming_gpu_enter) {
        why = "gpu_below_gaming_entry";
    } else if (m->cpu.load1 < ASB_GAMING_MIN_LOAD1 || m->cpu.load1 >= 12.0f) {
        why = "cpu_outside_media_band";
    } else {
        eligible = 1;
        why = "warming";
    }

    if (!eligible) {
        g_smart_media_guard_since = 0;
        g_smart_media_guard_active = 0;
    } else {
        if (g_smart_media_guard_since == 0) g_smart_media_guard_since = now;
        if ((long)(now - g_smart_media_guard_since) >= 60) {
            g_smart_media_guard_active = 1;
            why = "active";
        } else {
            g_smart_media_guard_active = 0;
        }
    }
    snprintf(g_smart_media_guard_reason, sizeof(g_smart_media_guard_reason), "%s", why);
    return was_active != g_smart_media_guard_active;
}

static void asb_smart_media_guard_apply_caps(asb_profile_caps_t *caps) {
    enum { ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT = 70 };
    if (!caps || !g_smart_media_guard_active) return;
    if (caps->gpu_max_pct > ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT)
        caps->gpu_max_pct = ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT;
    if (caps->gpu_min_pct > caps->gpu_max_pct)
        caps->gpu_min_pct = caps->gpu_max_pct;
}

/*
 * Smart Mode tick — compute effective runtime values and update g_smart_bounds slot if a
 * meaningful change occurred.
 * Returns: 1 if g_smart_bounds was updated this tick (caller should refresh FSM caps
 * immediately so they reflect the new bounds), 0 otherwise.
 */
static int asb_smart_tick(const asb_metrics_t *m, const asb_fsm_t *fsm) {
    if (!m) return 0;
    /* Defensive consistency: if FSM is in PROFILE_SMART, ensure runtime flag
     * is on so g_smart_bounds gets refreshed (FSM reads from it). */
    if (fsm && fsm->profile_idx == PROFILE_SMART) {
        g_smart_rt.enabled = 1;
    }
    if (!g_smart_rt.enabled || !g_smart_store_loaded) return 0;

    time_t now = time(NULL);

    /* 1. Build context */
    int daypart = asb_smart_daypart_now(now);
    int is_weekend = asb_smart_is_weekend(now);
    int bid = (int)asb_smart_bucket_id(daypart, is_weekend);
    int charging = m->bat.charging;
    int screen_on = m->misc.screen_on;
    int battery_pct = m->bat.capacity_pct;
    int cpu_max_c = m->therm.cpu_max_c;
    int skin_temp_c = m->therm.skin_temp_c;

    /* Daypart transition detection (for smoothing) */
    if (g_smart_rt.prev_daypart >= 0 &&
        g_smart_rt.prev_daypart != daypart &&
        g_smart_rt.smoothing_start_ts == 0) {
        g_smart_rt.smoothing_start_ts = now;
        g_smart_rt.smoothing_active = 1;
    }

    g_smart_rt.daypart = daypart;
    g_smart_rt.is_weekend = is_weekend;
    g_smart_rt.bucket_id = bid;

    /*
     * app detection: cascading foreground package sources.
     */
    if (now - g_smart_rt.app_cache_last_refresh >= ASB_SMART_APP_CACHE_S) {
        if (!screen_on) {
            g_smart_rt.app_hint = ASB_APP_IDLE;
            g_smart_rt.app_hash = 0;
            g_pkg_detect_ok = 0;
            g_pkg_detect_source = 0;
            g_pkg_detect_status = ASB_PKG_MISSING;
            g_smart_media_pkg_known = 0;
        } else {
            char fg_pkg[128] = {0};
            uint64_t fg_hash = 0;
            int fg_hint = ASB_APP_MEDIUM;
            int fg_source = 0;
            asb_pkg_status_t pst = asb_smart_detect_foreground_pkg(
                fg_pkg, sizeof(fg_pkg), &fg_hash, &fg_hint, &fg_source);

            g_pkg_detect_status = pst;
            g_pkg_detect_source = fg_source;

            if (pst == ASB_PKG_OK || pst == ASB_PKG_STALE) {
                /* Real package signal — use it */
                g_smart_rt.app_hash = fg_hash;
                g_smart_rt.app_hint = fg_hint;
                g_pkg_detect_ok = 1;
                /* Only a current, positively recognised media package may opt into the
                 * media guard. A stale cache deliberately does not qualify. */
                g_smart_media_pkg_known = (pst == ASB_PKG_OK &&
                                            asb_smart_pkg_is_media_candidate(fg_pkg));
                /* For heavy/gaming hints, double-check with load to avoid
                 * stale cache mistakes (e.g. user backgrounded the game) */
                if (fg_hint >= ASB_APP_HEAVY && m->cpu.load1 < 3.0f) {
                    g_smart_rt.app_hint = ASB_APP_LIGHT;
                }
                /*
                 * Game/heavy app is foreground but the FSM has settled into an idle state with
                 * low GPU — the game is paused, in a menu, or loading.
                 */
                else if (fg_hint >= ASB_APP_HEAVY && fsm &&
                         (fsm->state == ASB_STATE_DEEP_IDLE ||
                          fsm->state == ASB_STATE_LIGHT_IDLE) &&
                         m->gpu.load_pct < 15) {
                    g_smart_rt.app_hint = fg_hint - 1;
                }
            } else {
                /* No package signal — fall back to load-based heuristic,
                 * but mark detect_ok=0 so observability shows the gap */
                g_smart_rt.app_hash = 0;
                g_pkg_detect_ok = 0;
                g_smart_media_pkg_known = 0;
                if (m->cpu.load1 >= 12.0f) g_smart_rt.app_hint = ASB_APP_HEAVY;
                else if (m->cpu.load1 >= 6.0f) g_smart_rt.app_hint = ASB_APP_MEDIUM;
                else g_smart_rt.app_hint = ASB_APP_LIGHT;
            }
            if (g_smart_rt.app_hint < ASB_APP_GAMING &&
                m->misc.screen_on && fsm) {
                int fresh_pkg = (pst == ASB_PKG_OK);
                /*
                 * Boot grace.
                 * The SUSTAINED branch below infers "this must be a game" from heat plus GPU
                 * load, because an unrecognised game looks exactly like that.
                 */
                int boot_grace = (g_gov_start_ts > 0 &&
                                  (long)(now - g_gov_start_ts) < 180);
                if (fsm->state == ASB_STATE_GAMING && fresh_pkg &&
                    !g_smart_media_pkg_known) {
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                } else if (!boot_grace &&
                           fsm->state == ASB_STATE_SUSTAINED &&
                           cpu_max_c >= 60 && m->gpu.load_pct >= 30 &&
                           fresh_pkg && !g_smart_media_pkg_known) {
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                } else if (!boot_grace &&
                           g_asb_cfg.bat_suppress_gaming &&
                           fsm->state == ASB_STATE_HEAVY &&
                           cpu_max_c >= 60 && m->gpu.load_pct >= 45 &&
                           m->cpu.load1 >= 3.0f &&
                           fresh_pkg && !g_smart_media_pkg_known) {
                    /* A suppressed game is still a game.
                     *
                     * bat_suppress_gaming deliberately keeps the FSM in HEAVY on a
                     * battery-leaning profile, so a game never unlocks GAMING clocks. That
                     * part works. What it also does is hide the workload from every
                     * gaming-specific thermal control - cool_gaming, the retry cooldown,
                     * the gap-to-SUSTAINED escape - because all of them key off this hint,
                     * and this hint was only ever set from GAMING or SUSTAINED.
                     *
                     * The result is the worst of both: the phone does not get game
                     * performance, and it does not get game heat management either. A user
                     * reported exactly that - "played briefly, the device turned into a
                     * heater" - with cool_gaming=1 and suppress_gaming_on_battery=1 both
                     * enabled, GPU past the gaming threshold and 95 C on the die.
                     *
                     * The thresholds here are stricter than the GAMING entry, not looser:
                     * hot, GPU busy past the exit threshold, AND real CPU load. That
                     * combination is not a video feed - the case the GPU-only check was
                     * tightened for in V63 - it is sustained rendering work.
                     */
                    g_smart_rt.app_hint = ASB_APP_GAMING;
                }
            }
        }
        g_smart_rt.app_cache_last_refresh = now;
    }
    /* Track session-top app hint + hash (max-of-session). Sync both so the
     * session record at end-of-session shows the actual heaviest app's hash. */
    if (g_smart_rt.app_hint > g_smart_rt.app_hint_session_top) {
        g_smart_rt.app_hint_session_top = g_smart_rt.app_hint;
        g_smart_rt.app_hash_session_top = g_smart_rt.app_hash;
    } else if (g_smart_rt.app_hint == g_smart_rt.app_hint_session_top &&
               g_smart_rt.app_hash != 0 &&
               g_smart_rt.app_hash_session_top == 0) {
        /* Same level but we now have a real hash where we had none — record it */
        g_smart_rt.app_hash_session_top = g_smart_rt.app_hash;
    }

    /* 3. Bucket lookup with fallback hierarchy */
    asb_smart_bucket_t *b = asb_smart_lookup_bucket(
        &g_smart_store, daypart, is_weekend, now, &g_smart_rt.fallback_level);
    if (g_smart_rt.fallback_level == ASB_SMART_FALLBACK_EXACT) {
        g_smart_rt.exact_bucket_hits++;
    } else {
        g_smart_rt.fallback_hits++;
    }

    int conf = asb_smart_confidence_x1000(b, now);
    asb_smart_compute_effective(b, conf, &g_smart_store, &g_smart_rt);

    /*
     * Optional user autonomy dial: smart_battery_bias (governor.conf, x1000, default 0 =
     * unchanged) nudges the effective battery lean upward so Smart leans harder toward economy
     * without touching the learner or the profiles.
     * Bias is clamped to 0..600 and is confidence-scaled; the final alpha is still hard-capped
     * at ASB_SMART_ALPHA_BATTERY_MAX_X1000 (1000), so it can never exceed pure-battery
     * behaviour.
     */
    if (g_asb_cfg.smart_battery_bias > 0) {
        int bbias = g_asb_cfg.smart_battery_bias;
        if (bbias > 600) bbias = 600;
        /* scale by confidence so low-confidence Smart isn't over-biased */
        int scaled = (bbias * conf) / 1000;
        int biased = (int)g_smart_rt.alpha_battery_x1000 + scaled;
        if (biased > ASB_SMART_ALPHA_BATTERY_MAX_X1000)
            biased = ASB_SMART_ALPHA_BATTERY_MAX_X1000;
        g_smart_rt.alpha_battery_x1000 = biased;
    }

    /* 4. Safety overrides — these can lift floors but never reduce safety */
    asb_smart_apply_night_override(daypart,
                                   asb_night_window_active(now),
                                   screen_on, charging,
                                   g_smart_rt.app_hint, battery_pct, &g_smart_rt);

    if (screen_on != g_smart_last_screen_on) {
        if (!screen_on) {
            g_smart_screen_off_since = now;
        } else {
            g_smart_screen_off_since = 0;
        }
        g_smart_last_screen_on = screen_on;
    }
    long screen_off_secs = (g_smart_screen_off_since > 0)
                           ? (long)(now - g_smart_screen_off_since) : 0;
    asb_smart_apply_idle_screen_override(screen_on, charging,
                                          g_smart_rt.app_hint,
                                          screen_off_secs, &g_smart_rt);

    asb_smart_apply_low_battery_override(battery_pct, charging, &g_smart_rt);

    {
        /* V50 charge-aware: classify charger power from |I|x|V| at the pack,
         * then let the layer trade lean direction against pack temperature. */
        int pclass = ASB_CHARGE_CLASS_NONE;
        int pw_x10 = 0;
        if (charging) {
            long w_x10 = ((long)m->bat.current_ma * (m->bat.voltage_uv / 1000L)) / 100000L;
            if (w_x10 < 0) w_x10 = 0;
            if (w_x10 > 2000) w_x10 = 2000;
            pw_x10 = (int)w_x10;
            if (pw_x10 >= ASB_CHARGE_POWER_SUPER_W * 10) pclass = ASB_CHARGE_CLASS_SUPER;
            else if (pw_x10 >= ASB_CHARGE_POWER_FAST_W * 10) pclass = ASB_CHARGE_CLASS_FAST;
            else pclass = ASB_CHARGE_CLASS_SLOW;
        }
        g_smart_rt.charge_power_class = pclass;
        g_smart_rt.charge_power_w_x10 = pw_x10;
        asb_smart_apply_charge_aware(g_asb_cfg.charge_aware_enable,
                                     charging, screen_on,
                                     m->bat.temp_dC, pclass,
                                     g_asb_cfg.charge_assist_alpha_max,
                                     m->therm.cpu_max_c,
                                     g_asb_cfg.charge_temp_warn_dC,
                                     g_asb_cfg.charge_temp_hot_dC,
                                     &g_smart_rt);
    }
    {
        int _budget_rate = g_smart_drain_rate_ewma_x10;
        g_smart_budget_src = 0;
        if (g_smart_rt.bucket_id < ASB_SMART_BUCKETS &&
            g_smart_rt.conf_x1000 >= 350) {
            int _bew = (int)g_smart_store.buckets[g_smart_rt.bucket_id].avg_drain_pctph_x10;
            if (_bew > 0) {
                _budget_rate = _bew;
                g_smart_budget_src = 1;
            }
        }
        /*
         * Self-correction: when the forecast has consistently missed in the same direction
         * across several windows, nudge the drain rate fed to the budget by a small bounded
         * factor (max +-12%).
         */
        if (g_budget_bias_streak >= ASB_BUDGET_ACC_BIAS_STREAK) {
            int _adj = g_budget_bias_streak - ASB_BUDGET_ACC_BIAS_STREAK + 1;
            if (_adj > 12) _adj = 12;
            _budget_rate += (g_budget_bias_dir * _budget_rate * _adj) / 100;
            if (_budget_rate < 1) _budget_rate = 1;
        }
        g_drain_spike_bump = (g_drain_spike_until > now) ? 1 : 0;
        asb_smart_apply_energy_budget(battery_pct, charging,
                                      _budget_rate, now, &g_smart_rt);
        /*
         * Budget accuracy grading.
         * The anchor is also suspended while the night/sleep override is active: deep-idle
         * drain (often <0.3%/h) is a different regime from the active EWMA the budget predicts
         * with, so grading — and especially the self-correction — must not learn from it, or
         * it would drag the daytime rate down and then under-predict once normal use resumes.
         */
        if (charging || battery_pct < 0 || g_smart_rt.night_safe_override) {
            g_budget_acc_anchor_ts = 0;
            g_budget_acc_anchor_pct = -1;
            if (g_smart_rt.night_safe_override || charging) {
                /* Don't let a streak built from a non-representative regime
                   (deep-idle night, or charging windows) persist into a
                   correction — reset it as we enter that regime. The daytime
                   budget must only learn from genuine on-battery discharge. */
                g_budget_bias_streak = 0;
                g_budget_bias_dir = 0;
            }
        } else if (g_budget_acc_anchor_ts == 0 &&
                   g_smart_rt.budget_pred_h_x10 > 0) {
            g_budget_acc_anchor_ts = now;
            g_budget_acc_anchor_pct = battery_pct;
            g_budget_acc_pred_h_x10 = g_smart_rt.budget_pred_h_x10;
        } else if (g_budget_acc_anchor_ts > 0 &&
                   (long)(now - g_budget_acc_anchor_ts) >= ASB_BUDGET_ACC_WINDOW_S &&
                   g_budget_acc_anchor_pct >= 0) {
            long _elapsed = (long)(now - g_budget_acc_anchor_ts);
            int _actual_drop = g_budget_acc_anchor_pct - battery_pct;
            if (_actual_drop > 0 && g_budget_acc_pred_h_x10 > 0) {
                /* predicted drop over the window = elapsed_h / pred_h * 100 */
                long _pred_drop_x100 =
                    (_elapsed * 100L * 100L) /
                    ((long)g_budget_acc_pred_h_x10 * 360L);
                long _actual_x100 = (long)_actual_drop * 100L;
                long _err = _actual_x100 - _pred_drop_x100;
                if (_err < 0) _err = -_err;
                long _err_pct = (_actual_x100 > 0)
                    ? (_err * 100L) / _actual_x100 : 100;
                if (_err_pct > 100) _err_pct = 100;
                g_budget_acc_error_pct = (int)_err_pct;
                g_budget_acc_score = (int)(100 - _err_pct);
                /* Signed bias: did we under- or over-predict drain? Track a
                   streak of same-direction misses. A correction is applied only
                   when several consecutive windows agree, so a single noisy
                   window never moves anything. */
                int _signed = (_actual_x100 > _pred_drop_x100) ? 1
                            : (_actual_x100 < _pred_drop_x100) ? -1 : 0;
                if (_err_pct >= ASB_BUDGET_ACC_BIAS_MIN_ERR_PCT && _signed != 0) {
                    if (_signed == g_budget_bias_dir) {
                        if (g_budget_bias_streak < 100) g_budget_bias_streak++;
                    } else {
                        g_budget_bias_dir = _signed;
                        g_budget_bias_streak = 1;
                    }
                } else {
                    g_budget_bias_streak = 0;
                    g_budget_bias_dir = 0;
                }
            }
            g_budget_acc_anchor_ts = 0;
            g_budget_acc_anchor_pct = -1;
        }
        if (g_drain_spike_bump && g_smart_rt.budget_severity < 2 &&
            !charging && battery_pct <= ASB_SMART_BUDGET_MAX_PCT) {
            g_smart_rt.budget_severity++;
            if (g_smart_rt.budget_severity == 1 &&
                g_smart_rt.alpha_battery_x1000 < ASB_SMART_BUDGET_WARN_ALPHA_X1000)
                g_smart_rt.alpha_battery_x1000 = ASB_SMART_BUDGET_WARN_ALPHA_X1000;
            else if (g_smart_rt.budget_severity == 2 &&
                     g_smart_rt.alpha_battery_x1000 < ASB_SMART_BUDGET_EMERG_ALPHA_X1000)
                g_smart_rt.alpha_battery_x1000 = ASB_SMART_BUDGET_EMERG_ALPHA_X1000;
        }
    }

    if (battery_pct >= 1 && battery_pct <= 100) {
        if (screen_on && !charging && g_smart_drain_prev_ts > 0 &&
            g_smart_drain_prev_pct >= 1) {
            long ddt = (long)(now - g_smart_drain_prev_ts);
            if (ddt > 0 && ddt <= 30) {
                g_smart_drain_on_sec += ddt;
                g_drain_roll_sec += ddt;
                int ddrop = g_smart_drain_prev_pct - battery_pct;
                if (ddrop > 0 && ddrop <= 5) {
                    g_smart_drain_drop_x100 += (long)ddrop * 100L;
                g_drain_roll_x100 += (long)ddrop * 100L;
                }
            }
        }
        g_smart_drain_prev_ts = now;
        g_smart_drain_prev_pct = battery_pct;
        if (screen_on) {
            g_anom_pkg_total++;
            if (g_pkg_detect_ok) g_anom_pkg_ok++;
        }
    } else {
        g_smart_drain_prev_ts = 0;
        g_smart_drain_prev_pct = -1;
    }

    int vendor_clamp_1h = (int)v44_clamp_1h_now();
    int recovery_active = 0;  /* recovery state; conservatively 0 in alpha */
    asb_smart_apply_thermal_veto(cpu_max_c, skin_temp_c, &g_asb_cfg, vendor_clamp_1h, recovery_active, &g_smart_rt);
    {
        /*
         * Cool-gaming engage level fed to the thermal lean: 0 = none, 1 = game active (engage
         * from 40 C / 2 C/min), 2 = charge-aware: game active AND charging AND the battery is
         * warm, the worst thermal case (render heat stacked on charge heat) — engage even
         * earlier (38 C / 1.5 C/min).
         */
        int _settle_lvl = (g_gov_start_ts > 0 &&
                           (long)(now - g_gov_start_ts) < 1200) ? 1 : 0;
        int _cool_lvl = 0;
        if (g_asb_cfg.cool_gaming && g_smart_rt.app_hint >= ASB_APP_GAMING) {
            _cool_lvl = 1;
            if (m->bat.charging &&
                m->bat.temp_dC >= ASB_SMART_CHARGE_WARM_BAT_DC) {
                _cool_lvl = 2;
            }
        }
        int _engage = _settle_lvl > _cool_lvl ? _settle_lvl : _cool_lvl;
        asb_smart_apply_thermal_trend(cpu_max_c, now, g_smart_rt.app_hash,
                                      _engage, &g_smart_rt);
        g_smart_boot_settle = (_settle_lvl > 0);
        g_smart_cool_gaming_lvl = _cool_lvl;

        /* Gaming-session peak tracking: while a game is the foreground app,
           accumulate running maxima; when it isn't, decay the session so the
           next game starts clean. Lightweight — just a few comparisons. */
        if (g_smart_rt.app_hint >= ASB_APP_GAMING) {
            if (m->bat.temp_dC > g_game_bat_temp_peak_dc)
                g_game_bat_temp_peak_dc = m->bat.temp_dC;
            if (cpu_max_c > g_game_cpu_max_peak_c)
                g_game_cpu_max_peak_c = cpu_max_c;
            if (_cool_lvl > g_game_cool_lvl_peak)
                g_game_cool_lvl_peak = _cool_lvl;
            if (m->bat.charging) g_game_charging_seen = 1;
        } else {
            g_game_bat_temp_peak_dc = 0;
            g_game_cpu_max_peak_c   = 0;
            g_game_cool_lvl_peak    = 0;
            g_game_charging_seen    = 0;
        }
    }

    /* intelligent modifiers — memory pressure, signal-aware net, refresh-rate,
     * gaming relax. Each is a no-op if its signal is unavailable on this device,
     * and all skip when night_override or thermal_veto fired (those keep priority). */
    asb_smart_apply_v48_modifiers(g_smart_rt.app_hint, cpu_max_c, &g_smart_rt);

    /* camera relax runs last: it is the only modifier allowed to override the
     * soft thermal lean, and it must not be undone by one that runs after it. */
    asb_smart_apply_camera_relax(m->misc.camera_active, &g_smart_rt);

    /* 5. Slot-update gating: should we rebuild g_smart_bounds? */
    int do_update = asb_smart_should_update_slot(&g_smart_rt, now, charging, g_smart_rt.app_hint);
    if (!do_update) return 0;

    /* 6. Blend battery↔balanced into g_smart_bounds */
    const asb_profile_bounds_t *bat = &g_profile_bounds[PROFILE_BATTERY];
    const asb_profile_bounds_t *bal = &g_profile_bounds[PROFILE_BALANCED];
    asb_profile_bounds_t out;
    memset(&out, 0, sizeof(out));

    int alpha = g_smart_rt.alpha_battery_x1000;

    /*
     * daypart smoothing: when we just crossed a daypart boundary and BOTH the previous bucket
     * and the current bucket had decent confidence (≥ low threshold), linearly blend from
     * prev_alpha to current_alpha over ASB_SMART_SMOOTH_S (5 min).
     * Thermal veto and night override break smoothing — they're already applied above and
     * force alpha to safety floor, which we must respect.
     */
    if (g_smart_rt.smoothing_active &&
        !g_smart_rt.night_safe_override &&
        !g_smart_rt.thermal_veto)
    {
        int prev_conf = g_smart_rt.smoothing_from_alpha_x1000 > 0 ? ASB_SMART_CONF_LOW_X1000 : 0;
        int cur_conf  = g_smart_rt.conf_x1000;
        int factor = asb_smart_daypart_smoothing_factor_x100(
            g_smart_rt.smoothing_start_ts, now, prev_conf, cur_conf);
        if (factor < 100) {
            /* Blend: result = from + (to - from) × factor/100 */
            int from = g_smart_rt.smoothing_from_alpha_x1000;
            int to   = alpha;
            alpha = from + ((to - from) * factor) / 100;
        } else {
            /* Smoothing window finished */
            g_smart_rt.smoothing_active = 0;
            g_smart_rt.smoothing_start_ts = 0;
        }
    }
    /* Remember current alpha for the next daypart transition */
    if (g_smart_rt.smoothing_start_ts == 0) {
        g_smart_rt.smoothing_from_alpha_x1000 = (uint16_t)alpha;
    }

    /* CPU max (floor → DEEP_IDLE cap, ceil → GAMING peak) per cluster */
    int bat_vals[3], bal_vals[3], out_vals[3];
    for (int i = 0; i < 3; i++) bat_vals[i] = bat->floor.cpu_max[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->floor.cpu_max[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.floor.cpu_max[i] = out_vals[i];

    for (int i = 0; i < 3; i++) bat_vals[i] = bat->ceil.cpu_max[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->ceil.cpu_max[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    /* Apply interactive bonus on ceil (peak) — capped at balanced */
    for (int i = 0; i < 3; i++) {
        out.ceil.cpu_max[i] = asb_smart_apply_interactive_bonus(
            out_vals[i], bal->ceil.cpu_max[i], g_smart_rt.interactive_bonus_x1000);
    }

    /* CPU min — no interactive bonus (it's the floor for DEEP_IDLE / GAMING) */
    for (int i = 0; i < 3; i++) bat_vals[i] = bat->floor.cpu_min[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->floor.cpu_min[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.floor.cpu_min[i] = out_vals[i];

    for (int i = 0; i < 3; i++) bat_vals[i] = bat->ceil.cpu_min[i];
    for (int i = 0; i < 3; i++) bal_vals[i] = bal->ceil.cpu_min[i];
    asb_smart_blend_values_int(bat_vals, bal_vals, 3, alpha, out_vals);
    for (int i = 0; i < 3; i++) out.ceil.cpu_min[i] = out_vals[i];

    /* GPU pcts */
    int gpu_min_bat[1] = { bat->floor.gpu_min_pct };
    int gpu_min_bal[1] = { bal->floor.gpu_min_pct };
    int gpu_min_out[1];
    asb_smart_blend_values_int(gpu_min_bat, gpu_min_bal, 1, alpha, gpu_min_out);
    out.floor.gpu_min_pct = gpu_min_out[0];

    int gpu_max_bat[1] = { bat->floor.gpu_max_pct };
    int gpu_max_bal[1] = { bal->floor.gpu_max_pct };
    int gpu_max_out[1];
    asb_smart_blend_values_int(gpu_max_bat, gpu_max_bal, 1, alpha, gpu_max_out);
    out.floor.gpu_max_pct = gpu_max_out[0];

    gpu_min_bat[0] = bat->ceil.gpu_min_pct;
    gpu_min_bal[0] = bal->ceil.gpu_min_pct;
    asb_smart_blend_values_int(gpu_min_bat, gpu_min_bal, 1, alpha, gpu_min_out);
    out.ceil.gpu_min_pct = gpu_min_out[0];

    gpu_max_bat[0] = bat->ceil.gpu_max_pct;
    gpu_max_bal[0] = bal->ceil.gpu_max_pct;
    asb_smart_blend_values_int(gpu_max_bat, gpu_max_bal, 1, alpha, gpu_max_out);
    out.ceil.gpu_max_pct = gpu_max_out[0];

    /* Hard invariant: never exceed balanced sustained envelope */
    for (int i = 0; i < 3; i++) {
        if (out.ceil.cpu_max[i] > bal->ceil.cpu_max[i]) out.ceil.cpu_max[i] = bal->ceil.cpu_max[i];
        if (out.ceil.cpu_min[i] > bal->ceil.cpu_min[i]) out.ceil.cpu_min[i] = bal->ceil.cpu_min[i];
    }
    if (out.ceil.gpu_max_pct > bal->ceil.gpu_max_pct) out.ceil.gpu_max_pct = bal->ceil.gpu_max_pct;

    /* Commit to global slot */
    g_smart_bounds = out;
    g_smart_bounds_initialized = 1;

    asb_smart_mark_slot_updated(&g_smart_rt, now, charging, g_smart_rt.app_hint);

    /* Dynamic tuner: re-apply readahead/MGLRU/VM/swappiness when the scenario
     * meaningfully changed. Rate-limited to once per 30 seconds and only on
     * a change in hint or thermal bucket or screen-on state. */
    {
        int therm_bucket = (cpu_max_c >= 60) ? 2 : (cpu_max_c >= 50 ? 1 : 0);
        int screen_on_v  = m->misc.screen_on ? 1 : 0;
        int sig = (g_smart_rt.app_hint << 4) | (therm_bucket << 2) | screen_on_v;
        if (sig != g_smart_last_tune_sig && (now - g_smart_last_tune_ts) >= 30) {
            char cmd[256];
            /*
             * Run it THROUGH sh.
             * Exec'ing the path directly therefore failed with EACCES on every device, and
             * because the command is backgrounded into /dev/null with its return value
             * discarded, it failed in complete silence: the Smart dynamic tuner has never
             * actually run.
             */
            snprintf(cmd, sizeof(cmd),
                     "sh /data/adb/modules/AutoSystemBoost/runtime/smart_dynamic_tune.sh "
                     "%d %d %d >/dev/null 2>&1 &",
                     g_smart_rt.app_hint, therm_bucket, screen_on_v);
            int _rc = system(cmd);
            (void)_rc;
            g_smart_last_tune_sig = sig;
            g_smart_last_tune_ts  = now;
        }
    }

    if (g_asb_cfg.smart_debug_log) {
        asb_log("smart_tick: bucket=%d daypart=%d we=%d fb=%d conf=%d alpha=%d "
                "night=%d veto=%d app=%d cpu=%d",
                bid, daypart, is_weekend, g_smart_rt.fallback_level,
                g_smart_rt.conf_x1000, g_smart_rt.alpha_battery_x1000,
                g_smart_rt.night_safe_override, g_smart_rt.thermal_veto,
                g_smart_rt.app_hint, cpu_max_c);
    }
    return 1;
}

/*
 * Smart Mode periodic persistence.
 */
static void asb_smart_persist_check(void) {
    if (!g_smart_rt.enabled || !g_smart_store_loaded) return;
    time_t now = time(NULL);
    /* Save throttled: at most once per 5 minutes */
    if (now - g_smart_last_save_ts >= 300) {
        g_smart_store.last_update_ts = (uint32_t)now;
        int rc = asb_smart_store_save_atomic(&g_smart_store, ASB_SMART_STORE_FILE);
        if (rc == 0) {
            g_smart_last_save_ts = now;
        }
        asb_smart_appheat_save();
    }
    /* Weekly backup */
    if (now - g_smart_last_backup_ts >= ASB_SMART_BACKUP_PERIOD_S) {
        int rc = asb_smart_store_backup(ASB_SMART_STORE_FILE, ASB_SMART_STORE_BAK);
        if (rc == 0) {
            g_smart_last_backup_ts = now;
            asb_log("smart_persist: weekly backup written");
        }
    }
}

static volatile int g_running = 1;
static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/*
 * Smart Mode init helpers.
 * Returns 1 if Smart Mode enabled, 0 otherwise.
 */
static int asb_smart_init(void) {
    /* Initialise g_smart_bounds to BALANCED defaults so any reads during
     * boot/uninit get a safe envelope */
    memcpy(&g_smart_bounds, &g_profile_bounds[PROFILE_BALANCED], sizeof(g_smart_bounds));
    g_smart_bounds_initialized = 1;

    /* Initialise runtime state */
    memset(&g_smart_rt, 0, sizeof(g_smart_rt));
    g_smart_rt.prev_bucket_id = -1;
    g_smart_rt.prev_daypart = -1;
    g_smart_rt.last_conf_tier = -1;
    g_smart_rt.last_charging = -1;
    g_smart_rt.last_app_hint_tier = -1;
    g_smart_rt.last_night_override = -1;
    g_smart_rt.last_thermal_veto = -1;

    /* Read on/off flag */
    int flag = asb_smart_flag_read();
    if (flag < 0) {
        /*
         * No flag file yet — treat as disabled, but still load the store so a manual profile
         * switch to 'smart' (e.g.
         */
        g_smart_rt.enabled = 0;
        g_asb_cfg.smart_mode_enabled = 0;
        flag = 0;
    } else {
        g_smart_rt.enabled = flag;
        g_asb_cfg.smart_mode_enabled = flag;
    }

    /* Load bucket store (chain: main → bak → seed defaults) regardless of
     * flag — store availability and on/off are separate concerns. */
    asb_smart_load_outcome_t outcome;
    int rc = asb_smart_store_load(&g_smart_store, &outcome);
    asb_smart_appheat_load();
    g_smart_store_loaded = 1;

    /*
     * The runtime session counters reset on every daemon start, which made the WebUI show "0
     * ses" after a reboot even though the learning itself (the bucket observations) persisted
     * fine.
     */
    {
        unsigned long _obs = 0;
        for (int _b = 0; _b < ASB_SMART_BUCKETS; _b++)
            _obs += g_smart_store.buckets[_b].observations_raw;
        g_smart_sessions_total = (int)_obs;
        g_smart_bucket_updates = (int)_obs;
        /*
         * Also seed the displayed confidence from the best persisted bucket.
         */
        time_t _now_seed = time(NULL);
        int _best_conf = 0;
        for (int _b = 0; _b < ASB_SMART_BUCKETS; _b++) {
            int _c = asb_smart_confidence_x1000(&g_smart_store.buckets[_b], _now_seed);
            if (_c > _best_conf) _best_conf = _c;
        }
        g_smart_last_confidence = _best_conf;
    }

    if (outcome.loaded_from_main) {
        asb_log("smart_init: loaded main store, %d buckets, version %d",
            g_smart_store.bucket_count, g_smart_store.version);
    } else if (outcome.loaded_from_backup) {
        asb_log("smart_init: main store invalid (reason=%d), restored from backup",
            outcome.reset_reason);
    } else if (outcome.seeded) {
        asb_log("smart_init: store unreadable (reason=%d), seeded fresh defaults",
            outcome.reset_reason);
    }
    (void)rc;

    g_smart_last_save_ts = time(NULL);
    g_smart_last_backup_ts = g_smart_last_save_ts;
    return flag;
}

int main(int argc, char **argv) {
    if (argc >= 2) {
        /*
         * expanded status JSON with 6 new thermal fields (skin_temp, surface_hotspot,
         * thermal_cpu_zone/type, thermal_skin_zone, thermal_surface_zone,
         * ses_max_surface_temp) pushed worst-case payload to ~1000 bytes.
         */
        char reply[4096] = {0};
        asb_sock_send_cmd(argv[1], reply, sizeof(reply));
        if (reply[0]) puts(reply);
        return 0;
    }

    {
        char pidbuf[16] = {0};
        int pfd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
        if (pfd >= 0) {
            ssize_t _r = read(pfd, pidbuf, sizeof(pidbuf)-1);
            (void)_r;
            close(pfd);
            pid_t old = (pid_t)atoi(pidbuf);
            if (old > 1 && kill(old, 0) == 0) {
                fprintf(stderr, "asb_governor already running (pid %d)\n", old);
                return 1;
            }
        }
    }

    mkdir("/dev/.asb", 0700);

    {
        char pidbuf[16];
        snprintf(pidbuf, sizeof(pidbuf), "%d\n", getpid());
        int pfd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (pfd >= 0) {
            ssize_t _w = write(pfd, pidbuf, strlen(pidbuf));
            (void)_w;
            close(pfd);
        }
    }

    g_gov_start_ts = time(NULL);
    g_logf = fopen(LOG_FILE, "a");
    asb_log("=== asb_governor starting (pid %d, flavor=%s) ===", getpid(),
            ASB_DEBUG_BUILD ? "debug" : "release");

    signal(SIGTERM, sig_handler);
    signal(SIGINT,  sig_handler);
    signal(SIGPIPE, SIG_IGN);

    asb_config_defaults(&g_asb_cfg);
    int initial_cfg_rc = asb_config_load_file(CONFIG_FILE, &g_asb_cfg);
    if (initial_cfg_rc != 0) {
        asb_log("config_reject: startup load failed rc=%d; using built-in safe defaults", initial_cfg_rc);
        asb_config_defaults(&g_asb_cfg);
    } else {
        asb_config_apply_highload_mode(&g_asb_cfg);
    }
    /*
     * Per-device bounds override (Phase 2, opt-in via device_bounds_override=1).
     */
    {
        static asb_profile_bounds_t _bounds_defaults[3];
        memcpy(_bounds_defaults, g_profile_bounds, sizeof(_bounds_defaults));
        int _ovr = asb_load_device_bounds_override(g_asb_cfg.device_bounds_override,
                                                   _bounds_defaults);
        if (_ovr > 0) asb_log("device_bounds: applied %d per-device override(s) from %s",
                              _ovr, ASB_DEVICE_BOUNDS_FILE);
    }
    asb_active_efficiency_load();
    asb_night_window_load();
    {
        int stale_warnings = 0;
        if (g_asb_cfg.heavy_load_enter < 10.0f) {
            asb_log("config_audit: heavy_load_enter=%.1f is much lower than the default (20.0). "
                    "If you didn't customize this, your config may be stale. "
                    "To restore defaults: rm /data/adb/modules/AutoSystemBoost/config/governor.conf "
                    "&& reflash module.",
                    g_asb_cfg.heavy_load_enter);
            stale_warnings++;
        }
        if (g_asb_cfg.bat_heavy_load_enter < 10.0f && g_asb_cfg.bat_heavy_load_enter > 0) {
            asb_log("config_audit: bat_heavy_load_enter=%.1f is much lower than the default (20.0). "
                    "Likely stale config.",
                    g_asb_cfg.bat_heavy_load_enter);
            stale_warnings++;
        }
        if (g_asb_cfg.bat_fast_idle_s < 10) {
            asb_log("config_audit: bat_fast_idle_s=%d is much lower than the default (15). "
                    "Likely stale config.",
                    g_asb_cfg.bat_fast_idle_s);
            stale_warnings++;
        }
        if (stale_warnings > 0) {
            FILE *sf = fopen("/dev/.asb/config_stale_detected", "w");
            if (sf) {
                fprintf(sf, "stale_warnings=%d\n", stale_warnings);
                fprintf(sf, "heavy_load_enter=%.1f (default 20.0)\n", g_asb_cfg.heavy_load_enter);
                fprintf(sf, "bat_heavy_load_enter=%.1f (default 20.0)\n", g_asb_cfg.bat_heavy_load_enter);
                fprintf(sf, "bat_fast_idle_s=%d (default 15)\n", g_asb_cfg.bat_fast_idle_s);
                fprintf(sf, "to_reset_to_defaults: rm %s && reflash\n", CONFIG_FILE);
                fclose(sf);
            }
        }
    }

    thermal_discover();
    writer_init_cache();
    persistent_stats_load();
    sweep_stale_session();

    /* Smart Mode init (no-op if smart_mode_enabled file flag not set) */
    asb_smart_init();

    /* OTA quarantine -- detect environment changes */
    {
        #define ENV_FP_FILE PERSISTENT_STATS_DIR "/env_fingerprint"
        #define QUARANTINE_SESSIONS 3
        char cur_fp[256] = {0};
        char kern[128] = {0};
        FILE *kf = fopen("/proc/version", "r");
        if (kf) {
            char *_g = fgets(kern, sizeof(kern), kf);
            (void)_g;
            fclose(kf);
        }
        /* trim newline */
        char *nl = strchr(kern, '\n'); if (nl) *nl = '\0';
        snprintf(cur_fp, sizeof(cur_fp), "%s|%s", ASB_VERSION, kern);

        char old_fp[256] = {0};
        FILE *ef = fopen(ENV_FP_FILE, "r");
        if (ef) {
            char *_g = fgets(old_fp, sizeof(old_fp), ef);
            (void)_g;
            fclose(ef);
        }
        nl = strchr(old_fp, '\n'); if (nl) *nl = '\0';

        if (old_fp[0] && strcmp(cur_fp, old_fp) != 0) {
            asb_log("quarantine: environment changed, activating %d-session quarantine", QUARANTINE_SESSIONS);
            asb_log("quarantine: old=%s", old_fp);
            asb_log("quarantine: new=%s", cur_fp);
            for (int i = 0; i < 3; i++) {
                g_pstats_per[i].quarantine_remaining = QUARANTINE_SESSIONS;
                pstats_save_one(g_pstats_files[i], &g_pstats_per[i]);
            }
        }
        /* Always write current fingerprint */
        atomic_write_file(ENV_FP_FILE, cur_fp);
    }

    asb_log_critical("asb_governor %s started (pid %d)", ASB_VERSION, getpid());
    asb_log("persistent stats: sessions=%d avg_t2s=%.0fs avg_temp=%.0fdegC avg_gap=%.0f avg_eff=%.0f degraded=%d",
            g_pstats.session_count, g_pstats.avg_time_to_first_sus,
            g_pstats.avg_max_temp, g_pstats.avg_gap_p0, g_pstats.avg_efficiency,
            g_pstats.degrade_count);

    if (g_pstats.session_count >= 3) {
        if (g_pstats.avg_time_to_first_sus > 0) {
            FILE *_hf = fopen(SESSION_HISTORY_FILE, "r");
            if (_hf) {
                char _hbuf[SESSION_HISTORY_LINE_MAX];
                float _ttd_sum = 0; int _ttd_n = 0;
                while (fgets(_hbuf, sizeof(_hbuf), _hf)) {
                    if (!strstr(_hbuf, "\"profile\":\"battery\"")) continue;
                    if (strstr(_hbuf, "\"intent\":\"sleep_idle\"")) continue;
                    char *_pdur = strstr(_hbuf, "\"dur\":");
                    if (_pdur && atol(_pdur + 5) < 120) continue;
                    char *_p = strstr(_hbuf, "\"bat_ttd\":");
                    if (_p) {
                        int _ttd = atoi(_p + 10);
                        if (_ttd > 0) { _ttd_sum += _ttd; _ttd_n++; }
                    }
                }
                fclose(_hf);
                if (_ttd_n >= 2) {
                    float avg_ttd = _ttd_sum / _ttd_n;
                    if (avg_ttd > 60 && g_asb_cfg.bat_fast_idle_s > 10) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 10;
                        asb_log("feedback: avg_bat_ttd=%.0fs >60s -> bat_fast_idle %d->%d",
                                avg_ttd, old, g_asb_cfg.bat_fast_idle_s);
                    } else if (avg_ttd > 30 && g_asb_cfg.bat_fast_idle_s > 12) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 12;
                        asb_log("feedback: avg_bat_ttd=%.0fs >30s -> bat_fast_idle %d->%d",
                                avg_ttd, old, g_asb_cfg.bat_fast_idle_s);
                    }
                }
            }
        }
        {
            FILE *_hf2 = fopen(SESSION_HISTORY_FILE, "r");
            if (_hf2) {
                char _hbuf2[SESSION_HISTORY_LINE_MAX];
                long _mod_sum = 0, _total_sum = 0; int _bat_n = 0;
                while (fgets(_hbuf2, sizeof(_hbuf2), _hf2)) {
                    if (!strstr(_hbuf2, "\"profile\":\"battery\"")) continue;
                    if (strstr(_hbuf2, "\"intent\":\"sleep_idle\"")) continue;
                    char *_pdur2 = strstr(_hbuf2, "\"dur\":");
                    if (_pdur2 && atol(_pdur2 + 5) < 120) continue;
                    char *_pd = strstr(_hbuf2, "\"bat_deep\":");
                    char *_pl = strstr(_hbuf2, "\"bat_light\":");
                    char *_pm = strstr(_hbuf2, "\"bat_mod\":");
                    if (_pd && _pl && _pm) {
                        long bd = atol(_pd + 11);
                        long bl = atol(_pl + 12);
                        long bm = atol(_pm + 10);
                        long bt = bd + bl + bm;
                        if (bt > 60) {
                            _mod_sum += bm; _total_sum += bt; _bat_n++;
                        }
                    }
                }
                fclose(_hf2);
                if (_bat_n >= 2 && _total_sum > 0) {
                    int mod_pct = (int)(_mod_sum * 100 / _total_sum);
                    if (mod_pct > 60 && g_asb_cfg.bat_fast_idle_s > 8) {
                        int old = g_asb_cfg.bat_fast_idle_s;
                        g_asb_cfg.bat_fast_idle_s = 8;
                        asb_log("feedback: battery MODERATE=%d%% of idle time "
                                "-> bat_fast_idle %d->%d (tighter wake discipline)",
                                mod_pct, old, g_asb_cfg.bat_fast_idle_s);
                    }
                }
            }
        }
        if (g_asb_cfg.highload_mode == 3 &&
            g_pstats.degrade_count > g_pstats.session_count / 2) {
            asb_config_apply_stable_override(&g_asb_cfg);
            asb_log("feedback: %d/%d sessions degraded -> auto starting as stable",
                    g_pstats.degrade_count, g_pstats.session_count);
        }
    }
    if (g_asb_cfg.bat_fast_idle_s > 0 && g_asb_cfg.bat_fast_idle_s < BAT_FAST_IDLE_FLOOR) {
        asb_log("feedback: bat_fast_idle_s=%d clamped to floor=%d",
                g_asb_cfg.bat_fast_idle_s, BAT_FAST_IDLE_FLOOR);
        g_asb_cfg.bat_fast_idle_s = BAT_FAST_IDLE_FLOOR;
    }

    int profile_idx = read_profile_idx();
    asb_log("initial profile: %d", profile_idx);

    asb_fsm_t fsm;
    fsm_init(&fsm, profile_idx);
    fsm_profile_is_battery = (profile_idx == PROFILE_BATTERY);
    fsm_profile_is_performance = (profile_idx == PROFILE_PERFORMANCE);
    fsm_profile_is_smart   = (profile_idx == PROFILE_SMART);
    fsm_profile_is_balanced = (profile_idx == PROFILE_BALANCED);

    asb_learn_db_t learn;
    learner_init(&learn);

    asb_accum_t accum;
    accum_init(&accum);

    asb_prediction_t cur_pred = learner_predict(&learn);
    learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
    asb_log("learner predict: %d, windows up=%d down=%d",
            cur_pred, fsm.up_window, fsm.down_window);

    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) { perror("epoll_create1"); return 1; }

    int tfd_active = make_timerfd(TIMER_ACTIVE_S);
    int tfd_idle   = make_timerfd(TIMER_IDLE_S);
    int tfd_hourly = make_timerfd(TIMER_HOURLY_S);
    int uefd       = make_uevent_fd();
    int sockfd     = asb_sock_create();

    if (tfd_active < 0 || tfd_idle < 0 || tfd_hourly < 0) {
        asb_log("failed to create timerfds");
        return 1;
    }

    int screen_on = metrics_screen_on();
    if (!screen_on) {
        disarm_timerfd(tfd_active);
    }

    struct epoll_event ev = {0};
    ev.events = EPOLLIN;

    ev.data.fd = tfd_active; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_active, &ev);
    ev.data.fd = tfd_idle;   epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_idle,   &ev);
    ev.data.fd = tfd_hourly; epoll_ctl(epfd, EPOLL_CTL_ADD, tfd_hourly, &ev);
    if (uefd  >= 0) { ev.data.fd = uefd;   epoll_ctl(epfd, EPOLL_CTL_ADD, uefd,   &ev); }
    if (sockfd >= 0) { ev.data.fd = sockfd; epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev); }

    asb_metrics_t metrics;
    memset(&metrics, 0, sizeof(metrics));

    metrics_read_all(&metrics, 1, 1);  /* startup: always read headroom + thermal */
    fsm_update(&fsm, &metrics);

    /* detect initial user ID */
    g_last_user_id = get_current_user_id();

    session_plan_build(&fsm, metrics.misc.screen_on);
    session_plan_apply_prearm(&fsm);
    {
        static const char *_pc_names[] = {
            "idle_clean","idle_noisy","daily_active","perf_active",
            "perf_clamped","benchmark","quarantine"
        };
        const char *pc = (fsm.plan.plan_class <= 6) ? _pc_names[fsm.plan.plan_class] : "?";
        asb_log("plan: class=%s sensor=%d thermal_div=%d hr=%d ac=%d deep=%d "
                "ac_budget=%d prearm=%d sensor_budget=%d quar=%d user=%d",
                pc, fsm.plan.sensor_tier, fsm.plan.thermal_div,
                fsm.plan.allow_hr, fsm.plan.ac_eligible, fsm.plan.deep_sleep,
                fsm.plan.ac_budget, fsm.plan.ac_prearm, fsm.plan.sensor_budget,
                fsm.plan.quarantine, g_last_user_id);
    }
    /* run smart_tick BEFORE the first writer_apply_caps so the boot
     * write already reflects fresh g_smart_bounds when profile is SMART.
     * Without this, the first write uses BALANCED defaults until the next
     * tick refreshes — visible as a brief envelope flicker at boot. */
    {
        /* Track suspend before anything else this tick: the numbers come from the
         * clocks, not from the metrics, so they are valid even when a probe failed. */
        asb_awake_track(metrics.misc.screen_on);
        int _smart_updated = asb_smart_tick(&metrics, &fsm);
        if (_smart_updated && fsm.profile_idx == PROFILE_SMART) {
            asb_profile_caps_t _new_caps;
            fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                 fsm.profile_idx, fsm.state, &_new_caps);
            if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                for (int i = 0; i < 3; i++)
                    _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
            }
            /* The user's ceiling trim, applied to what the governor just computed.
             *
             * The shell path already honoured perf_ceiling_pct when writing the uclamp
             * tiers, but on Smart the CPU caps are recomputed here every tick from the
             * profile bounds - so the full value went straight back and the setting did
             * nothing. Reported as: set to 75, games still hot.
             *
             * Ceilings only, and floors are left alone, matching what the shell does.
             */
            /* Snap the caps here, where they are decided - not only in the writer.
             *
             * The writer already snapped before writing, so the hardware got a real
             * frequency. But current_caps kept the raw ratio value, and the anti-clamp
             * detector compares current_caps against what sysfs reads back. Part of the
             * difference it saw was therefore its own rounding, reported as a vendor
             * clamp: the log shows cpu_max=[3140760,2627631], numbers no device has.
             *
             * Snapping at the decision point makes the request, the write and the
             * comparison all refer to the same number, which is the only way the detector
             * can tell "somebody overrode us" from "we asked for something impossible".
             */
            for (int i = 0; i < 3; i++) {
                if (_new_caps.cpu_max[i] <= 0) continue;
                int _si = -1;
                for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++) {
                    if (g_cpu_all_max_paths[k][0] && g_cpu_max_paths[i][0] &&
                        strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[i]) == 0) { _si = k; break; }
                }
                if (_si >= 0)
                    _new_caps.cpu_max[i] = (int)cpu_snap_freq(_si, (long)_new_caps.cpu_max[i]);
            }
            if (g_asb_cfg.perf_ceiling_pct > 0 && g_asb_cfg.perf_ceiling_pct < 100) {
                /* Trim the PEAK, not the whole ladder.
                 *
                 * Applied flat, this multiplies the idle and light states too - and those
                 * are already low by design, so there it does harm instead of good. Worse,
                 * because the ladder rises faster than the trim, a low setting inverts it:
                 * at 60% on an OP15 little cluster GAMING lands on 1566720 while HEAVY
                 * lands on 1593630. The phone ends up SLOWER under load than off it, which
                 * is the opposite of every reason someone touches this control.
                 *
                 * A user lowering this expects a calmer phone under load. What they got was
                 * one that crawls at rest: a task needing 100 ms at full clock needs 330 ms
                 * at a third of it, with every core, the display and the radio awake for
                 * the whole stretch. That is race-to-idle, and it is why a capture with
                 * perf_ceiling_pct=70 showed higher drain than none at all.
                 *
                 * Weighted by ladder position: full effect at GAMING, none at DEEP_IDLE.
                 * The setting keeps meaning what the user thinks it means, and the ladder
                 * stays monotonic at every value the slider can produce.
                 */
                float _pc_w = (fsm.state >= 0 && fsm.state < ASB_STATE_COUNT)
                              ? g_state_level[fsm.state] : 1.0f;
                if (_pc_w < 0.0f) _pc_w = 0.0f;
                if (_pc_w > 1.0f) _pc_w = 1.0f;

                /* Scale the weighting to the ladder this profile actually has.
                 *
                 * Raising the slider's minimum was not enough, and could not be: the trim
                 * grows with ladder position at a fixed rate, while how much room the
                 * ladder has depends on the profile. Battery spans 45% between its floor
                 * and ceiling, Performance only 36% - so the same 35% trim eats the whole
                 * ladder on one and not the other, and the state above ends up capped
                 * lower than the state below it.
                 *
                 * Checked across all six profile/cluster pairs at every slider value: five
                 * inversions remained at 65%, all of them on the narrow ladders.
                 *
                 * Limiting the weighted trim to half the ladder's own span keeps the peak
                 * above every rung under it on any profile, and on any SoC - the span is
                 * read from the bounds in force, not assumed.
                 */
                {
                    const asb_profile_bounds_t *_pb = asb_profile_bounds_for(fsm.profile_idx);
                    if (_pb && _pb->ceil.cpu_max[0] > 0 && _pb->floor.cpu_max[0] > 0) {
                        long _span = _pb->ceil.cpu_max[0] - _pb->floor.cpu_max[0];
                        long _room = _span * 50 / (_pb->ceil.cpu_max[0] ? _pb->ceil.cpu_max[0] : 1);
                        /* Explicit casts: the strict-warning budget counts implicit
                         * int-to-float conversions, and these two were the whole overage. */
                        float _pc_gap = (float)(100 - g_asb_cfg.perf_ceiling_pct);
                        if (_room > 0 && _pc_gap > 0.0f && _pc_w * _pc_gap > (float)_room)
                            _pc_w = (float)_room / _pc_gap;
                    }
                }

                int _pc_eff = 100 - (int)((float)(100 - g_asb_cfg.perf_ceiling_pct) * _pc_w);
                if (_pc_eff < g_asb_cfg.perf_ceiling_pct) _pc_eff = g_asb_cfg.perf_ceiling_pct;
                if (_pc_eff > 100) _pc_eff = 100;


                for (int i = 0; i < 3; i++) {
                    if (_new_caps.cpu_max[i] > 0)
                        _new_caps.cpu_max[i] =
                            (int)((long)_new_caps.cpu_max[i] * _pc_eff / 100);
                }
                if (_new_caps.gpu_max_pct > 0)
                    _new_caps.gpu_max_pct =
                        _new_caps.gpu_max_pct * _pc_eff / 100;
                for (int i = 0; i < 3; i++) {
                    /* Never leave a floor above the ceiling we just lowered - that is the
                     * contradiction the writer had to clean up after. */
                    if (_new_caps.cpu_min[i] > 0 && _new_caps.cpu_max[i] > 0 &&
                        _new_caps.cpu_min[i] > _new_caps.cpu_max[i])
                        _new_caps.cpu_min[i] = _new_caps.cpu_max[i];
                }
            }
            fsm.current_caps = _new_caps;
        }
    }
    {
        asb_profile_caps_t _effective_caps = fsm.current_caps;
        asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
        writer_apply_caps(&_effective_caps, 1, fsm.state, fsm.thermal_cap);
    }
    write_state(&fsm, &metrics, cur_pred);
    {
        int bidx = metrics_find_batt_current_path();
        asb_log("diag: battery_current_path=%s (raw=%d uA = %d mA)",
                bidx >= 0 ? g_batt_current_paths[bidx] : "NOT_FOUND",
                metrics.bat.current_ua,
                metrics.bat.current_ma);
        asb_log("diag: screen_on=%d thermal_cpu_zone=%d thermal_skin_zone=%d",
                metrics.misc.screen_on, g_thermal_cpu_zone, g_thermal_skin_zone);
        {
            char _zt_path[128], _zt_cpu[64] = "none", _zt_skin[64] = "none";
            if (g_thermal_cpu_zone >= 0) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", g_thermal_cpu_zone);
                FILE *_f = fopen(_zt_path, "r");
                if (_f) { if (fgets(_zt_cpu, sizeof(_zt_cpu), _f)) { char *n=strchr(_zt_cpu,'\n'); if(n)*n=0; } fclose(_f); }
            }
            if (g_thermal_skin_zone >= 0) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", g_thermal_skin_zone);
                FILE *_f = fopen(_zt_path, "r");
                if (_f) { if (fgets(_zt_skin, sizeof(_zt_skin), _f)) { char *n=strchr(_zt_skin,'\n'); if(n)*n=0; } fclose(_f); }
            }
            asb_log("diag: thermal_cpu=%s (zone%d) thermal_skin=%s (zone%d)",
                    _zt_cpu, g_thermal_cpu_zone, _zt_skin, g_thermal_skin_zone);
            asb_log("diag: thermal_cpu_choice=%s reason=%s",
                    g_thermal_cpu_type[0] ? g_thermal_cpu_type : "unknown",
                    g_thermal_cpu_reason);
        }
        /* dump every thermal zone on startup -- one line per zone -- so
         * next tuning cycle doesn't require pulling thermal_zones from adb. */
        {
            char _zt_path[128], _zt_type[64], _zt_tmp[32];
            int _dumped = 0;
            for (int _z = 0; _z < 128; _z++) {
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/type", _z);
                FILE *_ft = fopen(_zt_path, "r");
                if (!_ft) continue;
                _zt_type[0] = '\0';
                if (fgets(_zt_type, sizeof(_zt_type), _ft)) {
                    char *n = strchr(_zt_type, '\n'); if (n) *n = 0;
                }
                fclose(_ft);
                snprintf(_zt_path, sizeof(_zt_path),
                         "/sys/class/thermal/thermal_zone%d/temp", _z);
                FILE *_fv = fopen(_zt_path, "r");
                int _rawv = 0;
                if (_fv) {
                    if (fgets(_zt_tmp, sizeof(_zt_tmp), _fv)) {
                        _rawv = atoi(_zt_tmp);
                    }
                    fclose(_fv);
                }
                int _c = (_rawv > 200) ? (_rawv / 1000) : _rawv;
                asb_log("tz_dump: zone%d|%s|raw=%d|c=%d", _z, _zt_type, _rawv, _c);
                _dumped++;
            }
            asb_log("tz_dump: total=%d zones scanned", _dumped);
        }
        /* one-line thermal summary so users don't have to read 96 tz_dump lines.
         * Format: thermal_summary: cpu=<type>(z<N>,val=<C>,valid=<0|1>) skin=<type>(z<N>,val=<C>) surface=<type>(z<N>,val=<C>) */
        {
            char _ttype[3][64]; int _tval[3] = {0,0,0}; int _zlist[3];
            _zlist[0] = g_thermal_cpu_zone;
            _zlist[1] = g_thermal_skin_zone;
            _zlist[2] = g_thermal_surface_zone;
            for (int _ti = 0; _ti < 3; _ti++) {
                _ttype[_ti][0] = '\0';
                if (_zlist[_ti] < 0) { snprintf(_ttype[_ti], sizeof(_ttype[_ti]), "none"); continue; }
                char _p[128]; FILE *_f;
                snprintf(_p, sizeof(_p), "/sys/class/thermal/thermal_zone%d/type", _zlist[_ti]);
                _f = fopen(_p, "r");
                if (_f) { if (fgets(_ttype[_ti], sizeof(_ttype[_ti]), _f)) { char *n=strchr(_ttype[_ti],'\n'); if(n)*n=0; } fclose(_f); }
                snprintf(_p, sizeof(_p), "/sys/class/thermal/thermal_zone%d/temp", _zlist[_ti]);
                _f = fopen(_p, "r");
                if (_f) { char b[32]; if (fgets(b,sizeof(b),_f)) { int r=atoi(b); _tval[_ti] = (r>200)?(r/1000):r; } fclose(_f); }
            }
            asb_log("thermal_summary: cpu=%s(z%d,val=%dC,valid=%d) skin=%s(z%d,val=%dC) surface=%s(z%d,val=%dC)",
                    _ttype[0], g_thermal_cpu_zone, _tval[0], metrics.therm.temp_valid,
                    _ttype[1], g_thermal_skin_zone, _tval[1],
                    _ttype[2], g_thermal_surface_zone, _tval[2]);
        }
        asb_log("diag: gpu_load=%d%% valid=%d gpu_maxfreq=%ld",
                metrics.gpu.load_pct, metrics.gpu.load_valid, metrics.gpu.max_freq_hz);
        cpu_topology_discover();
        if (g_cpu_policy_count == 2)
            asb_log("diag: cpu_topology=policy0+policy6 (2-cluster SD8Elite)");
        else
            asb_log("diag: cpu_topology=policy0+policy4+policy7 (3-cluster fallback)");
        for (int _i = 0; _i < 3; _i++) {
            char _mp[128]; int _maxf;
            if (g_cpu_policy_ids[_i] < 0) continue;
            snprintf(_mp, sizeof(_mp),
                "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq",
                g_cpu_policy_ids[_i]);
            _maxf = sysfs_read_int(_mp, -1);
            asb_log("diag: policy%d cpuinfo_max=%d kHz cap_target=%d kHz",
                    g_cpu_policy_ids[_i], _maxf,
                    (_i < 3) ? fsm.current_caps.cpu_max[_i] : 0);
        }
        asb_log("diag: msm_performance_interface=%s",
                msm_perf_check() ? "available (kernel-level write)" : "not available (cpufreq only)");

        /* probe device capabilities once at startup */
        memset(&g_device_caps, 0, sizeof(g_device_caps));
        g_device_caps.has_msm_perf = msm_perf_check() ? 1 : 0;
        g_device_caps.has_headroom = (access("/sys/kernel/msm_performance/parameters/cpu_max_freq", R_OK) == 0);
        g_device_caps.has_thermal_cpu = (g_thermal_cpu_zone >= 0);
        g_device_caps.has_thermal_skin = (g_thermal_skin_zone >= 0);
        g_device_caps.has_gpu_load = (uint8_t)(metrics.gpu.load_valid ? 1 : 0);
        g_device_caps.has_uclamp = (access("/dev/cpuctl/top-app/cpu.uclamp.max", W_OK) == 0);
        asb_log("caps: msm=%d hr=%d thermal_cpu=%d thermal_skin=%d gpu=%d uclamp=%d",
                g_device_caps.has_msm_perf, g_device_caps.has_headroom,
                g_device_caps.has_thermal_cpu, g_device_caps.has_thermal_skin,
                g_device_caps.has_gpu_load, g_device_caps.has_uclamp);
        asb_log("diag: cfg heavy_gpu=%d heavy_load=%.1f gaming_gpu=%d sustained_gpu=%d sustained_load=%.1f sustained_temp=%d/%d sustained_lvl=%.2f dwell=%d/%d/%d reassert=%d/%d boost_only=%d throttle_temp=%d highload_mode=%s bat_fast_idle=%d bat_suppress=%d",
                g_asb_cfg.heavy_gpu_enter, g_asb_cfg.heavy_load_enter,
                g_asb_cfg.gaming_gpu_enter, g_asb_cfg.sustained_gpu_min,
                g_asb_cfg.sustained_load_min,
                asb_config_profile_sustained_temp_enter(&g_asb_cfg, PROFILE_PERFORMANCE),
                asb_config_profile_sustained_temp_exit(&g_asb_cfg, PROFILE_PERFORMANCE),
                asb_config_profile_sustained_level(&g_asb_cfg, PROFILE_PERFORMANCE),
                g_asb_cfg.heavy_min_dwell_s, g_asb_cfg.sustained_min_dwell_s,
                g_asb_cfg.gaming_min_dwell_s,
                g_asb_cfg.reassert_heavy_s, g_asb_cfg.reassert_gaming_s,
                g_asb_cfg.msm_perf_boost_only,
                    g_asb_cfg.thermal_throttle_temp,
                    g_asb_cfg.highload_mode == 1 ? "burst" :
                    g_asb_cfg.highload_mode == 2 ? "stable" :
                    g_asb_cfg.highload_mode == 3 ? "auto" : "default",
                    g_asb_cfg.bat_fast_idle_s,
                    g_asb_cfg.bat_suppress_gaming);
        asb_log("diag: bat_fast_idle=%ds bat_light_idle_gpu=%d%% bat_suppress_gaming=%d bat_heavy_load=%.1f",
                g_asb_cfg.bat_fast_idle_s,
                g_asb_cfg.bat_light_idle_gpu,
                g_asb_cfg.bat_suppress_gaming,
                g_asb_cfg.bat_heavy_load_enter);
    }
    asb_log("initial state: %s mA=%d gpu=%d%% load=%.2f",
            asb_state_names[fsm.state],
            metrics.bat.current_ma,
            metrics.gpu.load_pct,
            metrics.cpu.load1);
    asb_log("session_start profile=%s highload=%s bat=%d%% temp=%d sus_enter=%d sus_exit=%d gaming_gpu=%d",
            asb_profile_name(profile_idx),
            g_asb_cfg.highload_mode == 1 ? "burst" :
            g_asb_cfg.highload_mode == 2 ? "stable" :
            g_asb_cfg.highload_mode == 3 ? "auto" : "default",
            metrics.bat.capacity_pct, metrics.therm.cpu_max_c,
                    asb_config_profile_sustained_temp_enter(&g_asb_cfg, profile_idx),
                    asb_config_profile_sustained_temp_exit(&g_asb_cfg, profile_idx),
                    g_asb_cfg.gaming_gpu_enter);

    struct epoll_event events[MAX_EVENTS];

    while (g_running) {
        int nev = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }

        g_governor_event_wakeups += (unsigned long)nev;
        int need_metrics = 0;
        int force_write  = 0;
        int profile_changed = 0;

        static time_t g_last_state_touch = 0;
        static time_t g_last_heartbeat   = 0;
        static time_t g_last_profile_sync = 0;
        {
            time_t _now = time(NULL);
            if (_now - g_last_state_touch >= 60) {
                /*
                 * profile drift safety net.
                 */
                if (_now - g_last_profile_sync >= 60) {
                    int _file_idx = read_profile_idx();
                    if (_file_idx != fsm.profile_idx) {
                        asb_log("profile_drift_detected: fsm=%d file=%d resyncing",
                                fsm.profile_idx, _file_idx);
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_drift_resync");
                        session_end_self_tune(&fsm);
                        fsm_session_reset(&fsm);
                        fsm.plan.ac_used = 0;
                        fsm.profile_idx = _file_idx;
                        fsm_profile_is_battery = (_file_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (_file_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (_file_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (_file_idx == PROFILE_BALANCED);
                        force_write = 1;
                        g_last_reassert = 0;
                        storm_shield_reset();
                        anti_clamp_reset();
                        session_plan_build(&fsm, metrics.misc.screen_on);
                        session_plan_apply_prearm(&fsm);
                        asb_log("session_start profile=%s highload=%s bat=%d%% temp=%d "
                                "sus_enter=%d sus_exit=%d gaming_gpu=%d (drift_resync)",
                                asb_profile_name(_file_idx),
                                g_asb_cfg.highload_mode == 1 ? "burst" :
                                g_asb_cfg.highload_mode == 2 ? "stable" :
                                g_asb_cfg.highload_mode == 3 ? "auto" : "default",
                                metrics.bat.capacity_pct, metrics.therm.cpu_max_c,
                                asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm.profile_idx),
                                asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm.profile_idx),
                                g_asb_cfg.gaming_gpu_enter);
                    }
                    g_last_profile_sync = _now;
                }
                {
                    /* Suspend tracking belongs in the loop, not only in the pre-loop
                     * init block where it was.
                     *
                     * Called once at startup it can never accumulate a window, so
                     * awake_pct_screenoff sat at -1 forever - the diagnostic said "not
                     * measured yet" on a phone that had been running for a day, and
                     * asb_wakelock_watch.sh, which gates on that figure, never took a
                     * single snapshot. Two features silently inert because their input
                     * was computed in the wrong place.
                     */
                    asb_awake_track(metrics.misc.screen_on);
                    int _smart_updated = asb_smart_tick(&metrics, &fsm);
                    if (_smart_updated && fsm.profile_idx == PROFILE_SMART) {
                        asb_profile_caps_t _new_caps;
                        fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                             fsm.profile_idx, fsm.state, &_new_caps);
                        if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                            float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                            for (int i = 0; i < 3; i++)
                                _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
                        }
                        int _diff = 0;
                        for (int i = 0; i < 3; i++) {
                            if (_new_caps.cpu_max[i] != fsm.current_caps.cpu_max[i]) { _diff = 1; break; }
                            if (_new_caps.cpu_min[i] != fsm.current_caps.cpu_min[i]) { _diff = 1; break; }
                        }
                        if (_diff) {
                            fsm.current_caps = _new_caps;
                            asb_profile_caps_t _effective_caps = fsm.current_caps;
                            asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
                            int _w = writer_apply_caps(&_effective_caps, 1, fsm.state, fsm.thermal_cap);
                            if (_w > 0) { g_total_writes += _w; g_last_write_ts = time(NULL); }
                            if (g_asb_cfg.smart_debug_log) {
                                asb_log("smart_tick(heartbeat): forced caps refresh");
                            }
                        }
                    }
                }
                write_state(&fsm, &metrics, cur_pred);
                /*
                 * also write conflicts.json and learner_state.json for WebUI.
                 */
                write_conflicts_json();
                write_learner_state_json(&fsm);
                g_last_state_touch = _now;
            }
            if (g_last_heartbeat == 0) g_last_heartbeat = _now;
            if (_now - g_last_heartbeat >= 900) {
                static const char *_snames[] = {"DEEP_IDLE","LIGHT_IDLE","MODERATE","HEAVY","GAMING","SUSTAINED"};
                static const char *_enames[] = {"quiet","noisy","hostile"};
                fsm_flush_state_time(&fsm);  /* flush before heartbeat so bat_deep/light/mod are current */
                int _hb_env = classify_environment(&fsm);
                asb_log("heartbeat: state=%s profile=%d temp=%d%s headroom=%d%% load=%.1f gpu=%d bat=%d "
                        "ses_heavy=%lds ses_sus=%lds bat_deep=%lds bat_wake=%d env=%s waste=%d sc=%d hc=%d",
                        (fsm.state >= 0 && fsm.state < 6) ? _snames[fsm.state] : "?",
                        fsm.profile_idx,
                        metrics.therm.cpu_max_c,
                        metrics.therm.temp_valid ? "" : "(stale)",
                        metrics.therm.headroom_pct,
                        metrics.cpu.load1,
                        metrics.gpu.load_pct,
                        metrics.bat.capacity_pct,
                        fsm.ses_time_heavy_sec,
                        fsm.ses_time_sustained_sec,
                        fsm.bat_time_deep_idle_sec,
                        fsm.bat_wake_cycles,
                        _enames[_hb_env],
                        g_action_waste,
                        metrics.therm.soft_clamp,
                        metrics.therm.hard_clamp);
                g_last_heartbeat = _now;
                /*
                 * action waste decay -- env-aware.
                 */
                if (g_action_waste > 0) {
                    int _hb_env_d = classify_environment(&fsm);
                    if (_hb_env_d == ENV_QUIET && !fsm.clamp_hold)
                        g_action_waste = (g_action_waste >= 2) ? g_action_waste - 2 : 0;
                    else if (_hb_env_d == ENV_HOSTILE || fsm.clamp_hold)
                        { /* no decay -- still in trouble */ }
                    else
                        g_action_waste--;
                }
            }
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            if (fd == tfd_active) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                need_metrics = 1;

                /* Slow the screen-on cadence while the screen is quiet.
                 *
                 * Two seconds is the right answer for a game or a burst: the ladder can
                 * move that fast and being late shows up as a stutter. It is the wrong
                 * answer for reading, a feed at rest, or music with the display on - the
                 * FSM's decision does not change for tens of seconds there, and 30 samples
                 * a minute buys nothing.
                 *
                 * Measurement says this is where the module's own cost lives: with the
                 * screen on 66% of the time, the overhead line works out at 17 wakeups per
                 * minute, and the 2 s tier is nearly all of it.
                 *
                 * Backing off only from the calm states, and returning to 2 s the moment
                 * anything rises above them. A UI burst re-arms this from the state change
                 * path below, so the first busy tick is already back at full cadence -
                 * the slow tier can delay noticing by a few seconds at most, and only when
                 * nothing has been happening.
                 */
                int calm = (fsm.state <= ASB_STATE_LIGHT_IDLE) &&
                           !metrics.misc.camera_active;
                int want_active = calm ? TIMER_ACTIVE_CALM_S : TIMER_ACTIVE_S;
                if (want_active != g_active_interval) {
                    arm_timerfd_periodic(tfd_active, want_active);
                    g_active_interval = want_active;
                    if (g_asb_cfg.log_level >= 1)
                        asb_log("adaptive_tick: screen-on interval -> %ds (%s)",
                                want_active, calm ? "calm" : "busy");
                }
            }
            else if (fd == tfd_idle) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                need_metrics = 1;
            }
            else if (fd == tfd_hourly) {
                timerfd_drain(fd);
                g_governor_timer_wakeups++;
                float avg_drain = 0, avg_screen = 0;
                if (accum.drain_count > 0) {
                    avg_drain  = accum.drain_sum / accum.drain_count;
                    avg_screen = accum.total_ticks > 0
                                 ? (float)accum.screen_on_ticks / accum.total_ticks
                                 : 0.0f;
                    learner_update(&learn, avg_drain, avg_screen);
                    cur_pred = learner_predict(&learn);
                    learner_adjust_windows(&learn,
                                          &fsm.up_window, &fsm.down_window);
                    if (g_asb_cfg.log_level >= 1) asb_log("learner updated: drain=%.1fmA screen=%.0f%% "
                            "predict=%d windows=%d/%d",
                            avg_drain, avg_screen * 100,
                            cur_pred, fsm.up_window, fsm.down_window);
                    accum.drain_sum       = 0;
                    accum.drain_count     = 0;
                    accum.screen_on_ticks = 0;
                    accum.total_ticks     = 0;
                }
            }
            else if (fd == uefd) {
                int final_scr = -1;
                int cur;
                int drained = 0;
                while ((cur = parse_uevent_screen(uefd)) >= 0 || drained == 0) {
                    if (cur >= 0) final_scr = cur;
                    drained++;
                    if (drained > 64) break;
                    cur = parse_uevent_screen(uefd);
                    if (cur < 0 && drained > 0) break;
                    if (cur >= 0) final_scr = cur;
                    drained++;
                }
                if (final_scr >= 0) {
                    int was_on = metrics.misc.screen_on;
                    int real_scr = metrics_screen_on();
                    int confirmed = (final_scr == real_scr) ? final_scr : real_scr;
                    metrics.misc.screen_on = confirmed;

                    if (confirmed != was_on) {
                        if (g_asb_cfg.log_level >= 1) asb_log("screen %s (uevent, drained=%d events)",
                                confirmed ? "ON" : "OFF", drained);
                        need_metrics = 1;
                        if (confirmed) {
                            /* Screen just came on: full cadence immediately, and reset
                             * the tracker so the next tick re-evaluates rather than
                             * assuming it is still where it left off. */
                            arm_timerfd_periodic(tfd_active, TIMER_ACTIVE_S);
                            g_active_interval = TIMER_ACTIVE_S;
                            /* Clear storm shield on screen wake */
                            if (g_storm_shield_active) {
                                storm_shield_reset();
                                asb_log("storm_shield: cleared (screen ON)");
                            }
                            /* check user switch on screen ON */
                            int cur_uid = get_current_user_id();
                            if (cur_uid >= 0 && g_last_user_id >= 0 && cur_uid != g_last_user_id) {
                                asb_log("user_quarantine: user switch %d -> %d, active for %ds",
                                        g_last_user_id, cur_uid, USER_QUARANTINE_SEC);
                                g_last_user_id = cur_uid;
                                g_user_quarantine_active = 1;
                                g_user_quarantine_until = time(NULL) + USER_QUARANTINE_SEC;
                            } else if (cur_uid >= 0) {
                                g_last_user_id = cur_uid;
                            }
                        } else {
                            disarm_timerfd(tfd_active);
                            persistent_stats_save(&fsm);
                            if (fsm_profile_is_battery)
                                fsm.bat_screen_off_count++;
                        }
                        session_plan_build(&fsm, confirmed);
                        session_plan_apply_prearm(&fsm);
                    }
                }
            }
            else if (fd == sockfd) {
                char cmd[256] = {0};
                struct sockaddr_un src = {0};
                socklen_t srclen = sizeof(src);
                int n = asb_sock_recv(sockfd, cmd, sizeof(cmd), &src, &srclen);
                if (n <= 0) continue;

                if (g_asb_cfg.log_level >= 1) asb_log("cmd: %s", cmd);

                if (strncmp(cmd, "profile:", 8) == 0) {
                    const char *pname = cmd + 8;
                    char _pbuf[16];
                    int _is_auto = 0;
                    {
                        size_t _plen = strlen(pname);
                        if (_plen >= 5 && strcmp(pname + _plen - 5, ":auto") == 0) {
                            _is_auto = 1;
                            if (_plen - 5 < sizeof(_pbuf)) {
                                memcpy(_pbuf, pname, _plen - 5);
                                _pbuf[_plen - 5] = '\0';
                                pname = _pbuf;
                            }
                        }
                    }
                    int new_idx = PROFILE_BALANCED;
                    if (strcmp(pname, "battery")     == 0) new_idx = PROFILE_BATTERY;
                    if (strcmp(pname, "performance") == 0) new_idx = PROFILE_PERFORMANCE;
                    if (strcmp(pname, "smart")       == 0) new_idx = PROFILE_SMART;
                    if (!_is_auto) {
                        FILE *_amf = fopen("/data/adb/asb/auto_switch_marker", "r");
                        if (_amf) {
                            char _am[32];
                            if (fgets(_am, sizeof(_am), _amf)) {
                                size_t _aml = strlen(_am);
                                while (_aml > 0 && (_am[_aml-1] == '\n' || _am[_aml-1] == '\r' || _am[_aml-1] == ' ')) {
                                    _am[--_aml] = '\0';
                                }
                                if (strcmp(_am, pname) == 0) _is_auto = 1;
                            }
                            fclose(_amf);
                            remove("/data/adb/asb/auto_switch_marker");
                        }
                    }
                    if (new_idx != fsm.profile_idx) {
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_change");
                        session_end_self_tune(&fsm);
                        fsm_session_reset(&fsm);
                        fsm.plan.ac_used = 0;  /* budget reset on new session */

                        if (fsm.auto_battery_active && !_is_auto) {
                            asb_log("auto_battery: cleared by user profile change");
                            fsm.auto_battery_active = 0;
                            fsm.auto_battery_restore_idx = -1;
                            
                            strncpy(fsm.auto_battery_reason, "manual_clear", sizeof(fsm.auto_battery_reason) - 1);
                            fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                            fsm.auto_battery_since = time(NULL);
                            fsm_auto_battery_persist(&fsm);
                            remove("/data/adb/asb/auto_battery_origin");
                        }

                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
                        if (new_idx == PROFILE_PERFORMANCE) {
                            asb_config_apply_burst_override(&g_asb_cfg);
                            fsm.gaming_retry_until = 0;
                            asb_persistent_stats_t *pps = &g_pstats_per[PROFILE_PERFORMANCE];
                            if (pps->session_count >= 3 &&
                                pps->avg_max_temp >= 95.0f &&
                                pps->avg_efficiency < 60.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> history says burst futile "
                                        "(avg_temp=%.0f avg_eff=%.0f %d sessions) -> stable",
                                        pps->avg_max_temp, pps->avg_efficiency,
                                        pps->session_count);
                            } else if (pps->session_count >= 2 &&
                                       pps->degrade_count > pps->session_count / 2) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> %d/%d degraded -> stable",
                                        pps->degrade_count, pps->session_count);
                            } else if (pps->hot_fail_count >= 2) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> %d thermal wall hits -> stable",
                                        pps->hot_fail_count);
                            } else if (pps->session_count >= 3 &&
                                       pps->avg_time_to_first_sus > 0 &&
                                       pps->avg_time_to_first_sus < 90.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> avg_t2s=%.0fs <90s -> stable",
                                        pps->avg_time_to_first_sus);
                            } else if (pps->degrade_count >= 2 &&
                                       pps->avg_degrade_age > 0 &&
                                       pps->avg_degrade_age < 120.0f) {
                                asb_config_apply_stable_override(&g_asb_cfg);
                                asb_log("profile:performance -> avg_degrade_age=%.0fs <120s -> stable",
                                        pps->avg_degrade_age);
                            } else {
                                asb_log("profile:performance -> auto-burst applied, cooldown cleared");
                            }
                        } else if (new_idx == PROFILE_BATTERY &&
                                   (g_asb_cfg.highload_mode == 1 ||
                                    g_asb_cfg.highload_mode == 3)) {
                            asb_config_defaults_highload(&g_asb_cfg);
                            asb_log("profile:battery -> highload burst/auto cleared");
                        }
                        profile_changed = 1;
                        force_write = 1;
                        need_metrics = 1;
                        g_last_reassert = 0;
                        storm_shield_reset();
                        anti_clamp_reset();
                        session_plan_build(&fsm, metrics.misc.screen_on);
                        session_plan_apply_prearm(&fsm);
                        asb_sock_reply(sockfd, &src, srclen, "ok");
                        asb_log_critical("profile changed to %d (session reset)", new_idx);
                    } else {
                        asb_sock_reply(sockfd, &src, srclen, "ok:nochange");
                    }
                }
                else if (strcmp(cmd, "status") == 0) {
                    char jbuf[STATUS_JSON_MAX];
                    build_status_json(&fsm, &metrics, cur_pred, jbuf, sizeof(jbuf));
                    asb_sock_reply(sockfd, &src, srclen, jbuf);
                }
                else if (strcmp(cmd, "reset-stats") == 0) {
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    asb_log("session telemetry reset by cmd");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "reload") == 0) {
                    int new_idx = read_profile_idx();
                    asb_runtime_config_t candidate_cfg;
                    asb_config_defaults(&candidate_cfg);
                    int reload_cfg_rc = asb_config_load_file(CONFIG_FILE, &candidate_cfg);
                    if (reload_cfg_rc != 0) {
                        asb_log("config_reject: reload refused rc=%d; keeping last-known-good policy", reload_cfg_rc);
                        asb_sock_reply(sockfd, &src, srclen, "err:invalid_config");
                        continue;
                    }
                    asb_config_apply_highload_mode(&candidate_cfg);
                    g_asb_cfg = candidate_cfg;
                    /* if profile is changing, preserve old session in history
                     * BEFORE resetting. Previously reload silently discarded
                     * running sessions, leaving history with stale attribution. */
                    if (new_idx != fsm.profile_idx) {
                        fsm_flush_state_time(&fsm);
                        persistent_stats_save(&fsm);
                        session_history_append_ex(&fsm, "profile_change");
                        session_end_self_tune(&fsm);
                    }
                    fsm_session_reset(&fsm);
                    fsm.plan.ac_used = 0;
                    storm_shield_reset();
                    anti_clamp_reset();
                    if (new_idx != fsm.profile_idx) {
                        fsm.profile_idx = new_idx;
                        fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                        fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                        fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                        fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
                        force_write = 1;
                        need_metrics = 1;
                    }
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strncmp(cmd, "start-session:", 14) == 0) {
                    char *rest = cmd + 14;
                    char *colon = strchr(rest, ':');
                    int new_idx = PROFILE_BALANCED;
                    if (strncmp(rest, "battery", 7) == 0)     new_idx = PROFILE_BATTERY;
                    if (strncmp(rest, "performance", 11) == 0) new_idx = PROFILE_PERFORMANCE;
                    if (strncmp(rest, "smart", 5) == 0)       new_idx = PROFILE_SMART;
                    fsm_flush_state_time(&fsm);
                    persistent_stats_save(&fsm);
                    session_history_append_ex(&fsm, "new_session");
                    session_end_self_tune(&fsm);
                    fsm.profile_idx = new_idx;
                    fsm_profile_is_battery = (new_idx == PROFILE_BATTERY);
                    fsm_profile_is_performance = (new_idx == PROFILE_PERFORMANCE);
                    fsm_profile_is_smart   = (new_idx == PROFILE_SMART);
                    fsm_profile_is_balanced = (new_idx == PROFILE_BALANCED);
                    if (colon && *(colon+1)) {
                        char *mode = colon + 1;
                        if (strcmp(mode, "burst") == 0)  g_asb_cfg.highload_mode = 1;
                        else if (strcmp(mode, "stable") == 0) g_asb_cfg.highload_mode = 2;
                        else if (strcmp(mode, "auto") == 0)   g_asb_cfg.highload_mode = 3;
                        else g_asb_cfg.highload_mode = 0;
                        asb_config_apply_highload_mode(&g_asb_cfg);
                    }
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    force_write = 1;
                    need_metrics = 1;
                    g_last_reassert = 0;
                    asb_log("session_start profile=%s highload=%s (start-session cmd)",
                            asb_profile_name(new_idx),
                            g_asb_cfg.highload_mode == 1 ? "burst" :
                            g_asb_cfg.highload_mode == 2 ? "stable" :
                            g_asb_cfg.highload_mode == 3 ? "auto" : "default");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "end-session") == 0) {
                    fsm_flush_state_time(&fsm);
                    session_history_append_ex(&fsm, "manual_end");
                    session_end_self_tune(&fsm);
                    persistent_stats_save(&fsm);
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    asb_log("session_end: manual end-session cmd");
                    asb_sock_reply(sockfd, &src, srclen, "ok");
                }
                else if (strcmp(cmd, "quit") == 0) {
                    asb_sock_reply(sockfd, &src, srclen, "bye");
                    g_running = 0;
                }
                (void)profile_changed;
            }
        }

        if (need_metrics) {
            /* sensor scheduler reads from session plan.
             * sensor_budget limits expensive full-mode reads per plan epoch. */
            static int g_sensor_skip = 0;
            int need_hr = fsm.plan.allow_hr;
            int need_thermal = 1;

            /* Read the thermal zones less often when nothing is close to a threshold.
             *
             * Every pass opens eight or more zone files. That is the right price when the
             * die is near the throttle point and a decision might change this tick; at
             * 35 C with a 60 C threshold it buys nothing - the answer cannot change fast
             * enough to matter between one tick and the next.
             *
             * plan.thermal_div already existed for exactly this and was only ever
             * published, never applied. Using it now means the cadence follows the plan the
             * FSM already built rather than a second rule that can drift from it.
             *
             * The skip is bounded by distance, not by state alone: within 12 C of the
             * threshold every tick reads, whatever the plan says. Heat rises faster than
             * a state machine notices, and being late there costs a hot phone.
             */
            if (fsm.plan.thermal_div > 1 && g_last_cpu_max_c > 0) {
                int trip = asb_config_profile_sustained_temp_enter(&g_asb_cfg, 1);
                if (trip > 0 && g_last_cpu_max_c <= trip - 12) {
                    static int g_therm_skip = 0;
                    g_therm_skip++;
                    if (g_therm_skip % fsm.plan.thermal_div != 0)
                        need_thermal = 0;
                }
            }

            /* Quiet Night Baseline -- after sustained quiet DEEP_IDLE,
             * enter ultra-quiet mode: even less reads, longer ticks. */
            if (fsm.state == ASB_STATE_DEEP_IDLE &&
                asb_profile_battery_like(fsm.profile_idx) &&
                !metrics.misc.screen_on) {
                g_quiet_night_ticks++;
                g_quiet_noise_ticks = 0;  /* reset hysteresis -- we're quiet again */
                /*
                 * night-window acceleration.
                 */
                int _use_fast = g_last_bat_clean_night;
                if (g_asb_cfg.night_quiet_enable && !_use_fast) {
                    time_t _t = time(NULL);
                    if (asb_night_window_ready()) {
                        /* V50: learned per-user window replaces static hours */
                        if (asb_night_window_active(_t)) _use_fast = 3;
                    } else {
                        struct tm _tm;
                        if (localtime_r(&_t, &_tm)) {
                            int _h = _tm.tm_hour;
                            int _hs = g_asb_cfg.night_quiet_hour_start;
                            int _he = g_asb_cfg.night_quiet_hour_end;
                            int _in_window = (_hs > _he)
                                             ? (_h >= _hs || _h < _he)   /* crosses midnight */
                                             : (_h >= _hs && _h < _he);  /* same-day window */
                            if (_in_window) _use_fast = 2;  /* 2=night-window source, distinct from clean-reward */
                        }
                    }
                }
                int threshold = _use_fast
                                ? g_asb_cfg.quiet_fast_ticks   /* 5min with reward or night-window */
                                : g_asb_cfg.quiet_entry_ticks; /* 10min normal */
                if (!g_quiet_night_active && g_quiet_night_ticks >= threshold) {
                    g_quiet_night_active = 1;
                    g_quiet_night_since = time(NULL);
                    asb_log("quiet_night: entered ultra-quiet mode (ticks=%d%s)",
                            g_quiet_night_ticks,
                            (_use_fast == 1) ? " reward=fast" :
                            (_use_fast == 2) ? " night_window=fast" :
                            (_use_fast == 3) ? " learned_window=fast" : "");
                }
            } else {
                /*
                 * Quiet Lock Hysteresis -- don't exit quiet on single noise burst.
                 */
                if (g_quiet_night_active) {
                    g_quiet_noise_ticks++;
                    if (g_quiet_noise_ticks >= g_asb_cfg.quiet_exit_grace || metrics.misc.screen_on) {
                        long qn_dur = g_quiet_night_since > 0
                                      ? (time(NULL) - g_quiet_night_since) : 0;
                        asb_log("quiet_night: exited after %ldmin (noise=%d screen=%d)",
                                qn_dur / 60, g_quiet_noise_ticks, metrics.misc.screen_on);
                        g_quiet_wake_ramp = 3;
                        g_quiet_night_active = 0;
                        g_quiet_night_ticks = 0;
                        g_quiet_noise_ticks = 0;
                    }
                } else {
                    g_quiet_night_active = 0;
                    g_quiet_night_ticks = 0;
                    g_quiet_noise_ticks = 0;
                }
            }

            /* deep idle economy -- in battery DEEP_IDLE with screen off,
             * GPU/headroom/thermal reads are waste. Only battery level matters. */
            int deep_idle_economy = (fsm.state == ASB_STATE_DEEP_IDLE &&
                                     asb_profile_battery_like(fsm.profile_idx) &&
                                     !metrics.misc.screen_on);
            if (deep_idle_economy) {
                need_hr = 0;
                need_thermal = 0;
            }

            /* Quiet Night ultra-economy -- skip even battery current reads
             * on alternating ticks. Device is sleeping, minimal governor footprint. */
            /* Clear first, unconditionally.
             *
             * The reset used to live in the else branch of the test below, so it only ran
             * while Quiet Night was still active. If the mode ended on a skipping tick the
             * flag stayed set for the rest of the session: metrics_read_battery() returned
             * immediately on every subsequent tick and the daemon ran on the current,
             * voltage, temperature and level it had read that morning.
             *
             * Everything downstream trusts those numbers - auto-battery switching, charge
             * awareness, the drain the learner banks, the time-to-empty estimates - so a
             * stuck flag is worse than the economy it was buying. Default is "read", and
             * only an active skipping tick turns it off.
             */
            g_qn_skip_this_tick = 0;
            if (g_quiet_night_active) {
                static int g_qn_skip = 0;
                g_qn_skip++;
                if (g_qn_skip % 2 != 0) {
                    /* Actually skip the tick.
                     *
                     * This set need_metrics = 0 - after the only place that reads it, so
                     * nothing was skipped and the comment described an economy that never
                     * happened. Clang flagged the write as dead; the interesting part is
                     * that the feature was dead with it.
                     *
                     * Counted so the saving is observable rather than asserted: a
                     * footprint claim nobody can check is how this went unnoticed.
                     */
                    /* Skip the expensive reads for this tick.
                     *
                     * Not a goto: the metrics block runs to ~1400 lines and jumping out of
                     * it would hop over cleanup and state updates that later ticks depend
                     * on. The flag is checked at the individual read sites instead, which
                     * keeps the control flow intact and makes the saving auditable per
                     * source rather than all-or-nothing.
                     */
                    g_qn_ticks_skipped++;
                    g_qn_skip_this_tick = 1;
                }
            }

            /*
             * Exit-from-Quiet Brain -- after quiet night ends, ramp up sensor reads gradually
             * instead of full blast.
             */
            if (g_quiet_wake_ramp > 0) {
                if (g_quiet_wake_ramp >= 3) { need_hr = 0; need_thermal = 0; }
                else if (g_quiet_wake_ramp == 2) { need_hr = 0; }
                g_quiet_wake_ramp--;
            }

            /*
             * Burst Probation Window -- detect early ceiling collapse.
             */
            if (fsm.profile_idx == PROFILE_PERFORMANCE && fsm.ses_start_ts > 0) {
                long ses_age = time(NULL) - fsm.ses_start_ts;
                if (ses_age <= 60 && !g_burst_early_collapse) {
                    g_burst_probation = 1;
                    if (fsm.clamp_hold) {
                        int obs_p1_now = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                        if (obs_p1_now > 0 && obs_p1_now < 2000000) {
                            g_burst_early_collapse = 1;
                            g_burst_probation = 0;
                            fsm.plan.ac_budget = fsm.plan.ac_budget / 2;
                            if (fsm.plan.ac_budget < 1) fsm.plan.ac_budget = 1;
                            asb_log("burst_probation: early collapse detected "
                                    "(p6_max=%dkHz < 2GHz at %lds), ac_budget halved to %d",
                                    obs_p1_now / 1000, ses_age, fsm.plan.ac_budget);
                        }
                    }
                } else if (ses_age > 60 && g_burst_probation) {
                    g_burst_probation = 0;  /* window expired, no collapse */
                }
            }

            /* ceiling-adaptive economy -- when vendor clamp confirmed >45s,
             * headroom reads are pointless (always clamped) and thermal reads
             * can be reduced (device is stable, not in thermal danger).
             * early_collapse bypasses the timer entirely. */
            int clamp_economy = (fsm.clamp_hold && g_clamp_hold_since > 0 &&
                                 ((time(NULL) - g_clamp_hold_since) > g_asb_cfg.clamp_economy_after_s ||
                                  g_burst_early_collapse) &&
                                 fsm.profile_idx == PROFILE_PERFORMANCE);
            if (clamp_economy) {
                need_hr = 0;
                /* thermal every 3rd tick instead of every tick */
                static int g_clamp_thermal_skip = 0;
                g_clamp_thermal_skip++;
                if (g_clamp_thermal_skip % g_asb_cfg.clamp_thermal_every_n != 0) need_thermal = 0;
                /* Ceiling-Adaptive Reshaping -- track actual ceiling with EMA.
                 * This becomes the reference for gap/eff instead of target. */
                int obs_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                int obs_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                if (obs_p0 > 0) {
                    if (g_virtual_ceiling_p0 == 0) g_virtual_ceiling_p0 = obs_p0;
                    else g_virtual_ceiling_p0 = (g_virtual_ceiling_p0 * g_asb_cfg.virtual_ceiling_alpha + obs_p0) / (g_asb_cfg.virtual_ceiling_alpha + 1);
                }
                if (obs_p1 > 0) {
                    if (g_virtual_ceiling_p1 == 0) g_virtual_ceiling_p1 = obs_p1;
                    else g_virtual_ceiling_p1 = (g_virtual_ceiling_p1 * g_asb_cfg.virtual_ceiling_alpha + obs_p1) / (g_asb_cfg.virtual_ceiling_alpha + 1);
                }
            } else {
                g_virtual_ceiling_p0 = 0;
                g_virtual_ceiling_p1 = 0;
            }

            if (fsm.plan.thermal_div > 1) {
                g_sensor_skip++;
                if (g_sensor_skip % fsm.plan.thermal_div != 0) need_thermal = 0;
            } else {
                g_sensor_skip = 0;
            }
            /* sensor budget -- downgrade to reduced when budget exhausted */
            if (need_hr && fsm.plan.sensor_budget > 0) {
                if (fsm.plan.sensor_used >= fsm.plan.sensor_budget) {
                    need_hr = 0;  /* budget exhausted, skip headroom reads */
                } else {
                    fsm.plan.sensor_used++;
                }
            }
            metrics_read_all(&metrics, need_hr, need_thermal);
            /* Remember the last real reading: on a skipped tick the struct still holds it,
             * and the distance check above needs a value it can trust. */
            if (need_thermal && metrics.therm.cpu_max_c > 0)
                g_last_cpu_max_c = metrics.therm.cpu_max_c;

            /*
             * low-battery auto-switch.
             */
            if (g_asb_cfg.auto_battery_enable && metrics.bat.capacity_pct > 0) {
                time_t _now_t = time(NULL);
                int _can_act = (fsm.auto_battery_last_action == 0) ||
                               (_now_t - fsm.auto_battery_last_action >= g_asb_cfg.auto_battery_min_gap_s);

                if (!fsm.auto_battery_active &&
                    metrics.bat.capacity_pct <= g_asb_cfg.auto_battery_low_pct &&
                    fsm.profile_idx != PROFILE_BATTERY &&
                    _can_act) {
                    fsm.auto_battery_restore_idx = fsm.profile_idx;
                    fsm.auto_battery_active = 1;
                    fsm.auto_battery_last_action = _now_t;
                    
                    strncpy(fsm.auto_battery_reason, "low_pct", sizeof(fsm.auto_battery_reason) - 1);
                    fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                    fsm.auto_battery_since = time(NULL);
                    fsm_auto_battery_persist(&fsm);
                    /*
                     * Durable record of where we came from, by name and independent of the
                     * in-memory flag.
                     * auto_battery_state stores active and restore_idx together, so the moment
                     * "active" is lost the restore target is lost with it - and then nothing
                     * knows whether this device is in battery because the module put it there
                     * or because the user chose it.
                     */
                    {
                        FILE *_of = fopen("/data/adb/asb/auto_battery_origin", "w");
                        if (_of) {
                            fprintf(_of, "%s\n", asb_profile_name(fsm.auto_battery_restore_idx));
                            fclose(_of);
                        }
                    }
                    asb_log("auto_battery: trigger bat=%d%% (low=%d) saving=%d -> spawning apply_profile.sh battery auto",
                            metrics.bat.capacity_pct,
                            g_asb_cfg.auto_battery_low_pct,
                            fsm.auto_battery_restore_idx);
                    int _rc = system("sh /data/adb/modules/AutoSystemBoost/apply_profile.sh battery auto >/dev/null 2>&1 &");
                    (void)_rc;
                } else if (fsm.auto_battery_active &&
                           metrics.bat.capacity_pct >= g_asb_cfg.auto_battery_high_pct &&
                           _can_act) {
                    int _restore = fsm.auto_battery_restore_idx;
                    /*
                     * Consult the durable record before falling back.
                     * The old code then silently chose BALANCED, which is why a Smart user who
                     * discharged to 15% and charged back to 40% came back to Balanced: nothing
                     * was broken about the trigger or the flag, the restore target had simply
                     * been forgotten and the fallback guessed.
                     */
                    if (_restore < 0 || _restore >= ASB_PROFILE_COUNT) {
                        FILE *_orf = fopen("/data/adb/asb/auto_battery_origin", "r");
                        if (_orf) {
                            char _on[24] = {0};
                            if (fgets(_on, sizeof(_on), _orf)) {
                                size_t _ol = strlen(_on);
                                while (_ol > 0 && (_on[_ol-1] == '\n' || _on[_ol-1] == '\r' ||
                                                   _on[_ol-1] == ' ')) _on[--_ol] = '\0';
                                if      (!strcmp(_on, "balanced"))    _restore = PROFILE_BALANCED;
                                else if (!strcmp(_on, "performance")) _restore = PROFILE_PERFORMANCE;
                                else if (!strcmp(_on, "smart"))       _restore = PROFILE_SMART;
                            }
                            fclose(_orf);
                        }
                    }
                    if (_restore < 0 || _restore >= ASB_PROFILE_COUNT) {
                        if (asb_smart_flag_read() == 1) _restore = PROFILE_SMART;
                        else                            _restore = PROFILE_BALANCED;
                    }
                    const char *_pname = asb_profile_name(_restore);
                    fsm.auto_battery_active = 0;
                    fsm.auto_battery_restore_idx = -1;
                    fsm.auto_battery_last_action = _now_t;
                    
                    strncpy(fsm.auto_battery_reason, "high_pct_restore", sizeof(fsm.auto_battery_reason) - 1);
                    fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                    fsm.auto_battery_since = time(NULL);
                    fsm_auto_battery_persist(&fsm);
                    remove("/data/adb/asb/auto_battery_origin");
                    asb_log("auto_battery: restore bat=%d%% (high=%d) -> spawning apply_profile.sh %s auto",
                            metrics.bat.capacity_pct,
                            g_asb_cfg.auto_battery_high_pct, _pname);
                    char _cmd[160];
                    snprintf(_cmd, sizeof(_cmd),
                             "sh /data/adb/modules/AutoSystemBoost/apply_profile.sh %s auto >/dev/null 2>&1 &",
                             _pname);
                    int _rc = system(_cmd);
                    (void)_rc;
                } else if (!fsm.auto_battery_active &&
                           fsm.profile_idx == PROFILE_BATTERY &&
                           metrics.bat.capacity_pct >= g_asb_cfg.auto_battery_high_pct &&
                           _can_act) {
                    /*
                     * Recovery when the in-memory flag was lost.
                     * That distinction matters: someone who CHOSE battery must not be pulled
                     * out of it, which is why a bare "in battery and charged" test is not
                     * enough on its own.
                     */
                    int _rec_idx = -1;
                    {
                        FILE *_rf = fopen("/data/adb/asb/auto_battery_origin", "r");
                        if (_rf) {
                            char _rn[24] = {0};
                            if (fgets(_rn, sizeof(_rn), _rf)) {
                                size_t _rl = strlen(_rn);
                                while (_rl > 0 && (_rn[_rl-1] == '\n' || _rn[_rl-1] == '\r' ||
                                                   _rn[_rl-1] == ' ')) _rn[--_rl] = '\0';
                                if      (!strcmp(_rn, "balanced"))    _rec_idx = PROFILE_BALANCED;
                                else if (!strcmp(_rn, "performance")) _rec_idx = PROFILE_PERFORMANCE;
                                else if (!strcmp(_rn, "smart"))       _rec_idx = PROFILE_SMART;
                            }
                            fclose(_rf);
                        }
                    }
                    if (_rec_idx < 0 && asb_smart_flag_read() == 1) _rec_idx = PROFILE_SMART;

                    if (_rec_idx >= 0) {
                        const char *_rname = asb_profile_name(_rec_idx);
                        fsm.auto_battery_last_action = _now_t;
                        fsm.auto_battery_restore_idx = -1;
                        strncpy(fsm.auto_battery_reason, "recovery_restore", sizeof(fsm.auto_battery_reason) - 1);
                        fsm.auto_battery_reason[sizeof(fsm.auto_battery_reason) - 1] = '\0';
                        fsm.auto_battery_since = time(NULL);
                        fsm_auto_battery_persist(&fsm);
                        remove("/data/adb/asb/auto_battery_origin");
                        asb_log("auto_battery: recovery restore bat=%d%% (high=%d) -> spawning apply_profile.sh %s auto",
                                metrics.bat.capacity_pct,
                                g_asb_cfg.auto_battery_high_pct, _rname);
                        char _rcmd[160];
                        snprintf(_rcmd, sizeof(_rcmd),
                                 "sh /data/adb/modules/AutoSystemBoost/apply_profile.sh %s auto >/dev/null 2>&1 &",
                                 _rname);
                        int _rc2 = system(_rcmd);
                        (void)_rc2;
                    }
                }
            }

            {
                time_t _an_now = time(NULL);
                if (g_anom_window_start == 0 ||
                    (long)(_an_now - g_anom_window_start) >= 3600) {
                    g_anom_window_start = _an_now;
                    g_anom_count_1h = 0;
                    g_anom_pkg_total = 0;
                    g_anom_pkg_ok = 0;
                }
                int _code = ASB_ANOM_NONE;
                long _live_x10 = 0;
                if (g_smart_drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC &&
                    g_smart_drain_drop_x100 > 0) {
                    _live_x10 = (g_smart_drain_drop_x100 * 360L) / g_smart_drain_on_sec;
                }
                if (_live_x10 >= ASB_ANOM_DRAIN_SPIKE_X10) {
                    _code = ASB_ANOM_DRAIN_SPIKE;
                    g_drain_spike_until = _an_now + ASB_BUDGET_SPIKE_WINDOW_S;
                } else if (v44_clamp_1h_now() >= ASB_ANOM_VENDOR_WAR_CLAMPS_1H) {
                    _code = ASB_ANOM_VENDOR_WAR;
                } else if (fsm.profile_idx == PROFILE_BATTERY &&
                           !metrics.bat.charging &&
                           /*
                            * Absolute 40%, not high_pct + 10.
                            * Tying it to high_pct meant that narrowing that hysteresis from 30
                            * to 21 silently moved the anomaly from 40% to 31%, and would have
                            * flagged anyone who simply picked Battery by hand at a third of a
                            * charge.
                            */
                           metrics.bat.capacity_pct >= 40 &&
                           asb_smart_flag_read() == 1) {
                    _code = ASB_ANOM_STUCK_BATTERY;
                } else if (g_anom_pkg_total >= 50 &&
                           g_anom_pkg_ok * 10 < g_anom_pkg_total) {
                    _code = ASB_ANOM_PKG_MISSING;
                }
                if (_code != ASB_ANOM_NONE && g_anom_code == ASB_ANOM_NONE) {
                    g_anom_count_1h++;
                    asb_log("anomaly: code=%d count_1h=%d", _code, g_anom_count_1h);
                }
                g_anom_code = _code;
            }

            /* log thermal CPU source flips (primary <-> fallback)
             * visible in governor.log for runtime thermal path diagnostics. */
            if (metrics.therm.fallback_just_flipped) {
                asb_log("thermal_cpu_switch: primary=%s fallback=%s -> used_fallback=%d (cpu_max=%dC)",
                        g_thermal_cpu_type,
                        g_thermal_cpu_fallback_type[0] ? g_thermal_cpu_fallback_type : "none",
                        metrics.therm.used_fallback,
                        metrics.therm.cpu_max_c);
            }

            float dummy_drain, dummy_screen;
            if (accum_tick(&accum,
                           metrics.bat.current_ma,
                           metrics.misc.screen_on,
                           &dummy_drain, &dummy_screen)) {
                learner_update(&learn, dummy_drain, dummy_screen);
                cur_pred = learner_predict(&learn);
                learner_adjust_windows(&learn, &fsm.up_window, &fsm.down_window);
            }

            asb_night_window_tick(metrics.misc.screen_on, time(NULL));

            /* radio-aware -- track mobile data activity during battery idle */
            if ((fsm.profile_idx == PROFILE_BATTERY ||
                 fsm.profile_idx == PROFILE_SMART) && !metrics.misc.screen_on) {
                long net_bps = metrics.misc.rmnet_rx_bps + metrics.misc.rmnet_tx_bps;
                if (net_bps > 5000)  /* >5KB/s = active data transfer */
                    fsm.bat_radio_active_ticks++;
            }

            /* V56: sample memory pressure (PSI some avg10) every tick so the
             * session record can carry a peak + a pressured-tick count. Pure
             * observation -- gives the module its first memory visibility. */
            {
                int _mp = asb_read_mem_psi_x100();
                if (_mp >= 0) {
                    if (_mp > fsm.mem_psi_peak_x100) fsm.mem_psi_peak_x100 = _mp;
                    if (_mp >= 500) fsm.mem_pressure_ticks++;  /* >=5.0 avg10 */
                }
            }

            /* pass virtual ceiling to FSM for gap reshaping */
            fsm.virtual_ceiling_p0 = g_virtual_ceiling_p0;
            fsm.virtual_ceiling_p1 = g_virtual_ceiling_p1;

            /*
             * thermal_pwrlevel monitoring (KGSL devices where msm_performance is dead).
             * Skip if screen off (vendor thermal not relevant when GPU idle) 3.
             */
            {
                int monitor_skipped = 1;
                static time_t g_last_thermal_pl_read = 0;
                time_t now_for_pl = time(NULL);
                int min_interval_ok = (now_for_pl - g_last_thermal_pl_read >= 2);

                if (g_asb_cfg.thermal_pwrlevel_div_idle > 0 &&
                    metrics.misc.screen_on &&
                    fsm.state != ASB_STATE_DEEP_IDLE &&
                    min_interval_ok)
                {
                    int should_read = 0;
                    if (fsm.state == ASB_STATE_HEAVY ||
                        fsm.state == ASB_STATE_SUSTAINED ||
                        fsm.state == ASB_STATE_GAMING)
                    {
                        should_read = 1;
                    } else {
                        /* LIGHT_IDLE / MODERATE: gate by div counter */
                        static int g_thermal_pl_idle_skip = 0;
                        if (++g_thermal_pl_idle_skip >= g_asb_cfg.thermal_pwrlevel_div_idle) {
                            should_read = 1;
                            g_thermal_pl_idle_skip = 0;
                        }
                    }
                    if (should_read) {
                        int level = gpu_read_thermal_pwrlevel();
                        (void)level; /* used by FSM via gpu_thermal_pwrlevel_last() */
                        g_last_thermal_pl_read = now_for_pl;
                        monitor_skipped = 0;
                    }
                }
                if (monitor_skipped) gpu_thermal_pl_record_skip();

                /*
                 * thread thermal_pwrlevel into thermal struct for FSM use.
                 */
                {
                    int tpl = gpu_thermal_pwrlevel_last();
                    metrics.therm.gpu_thermal_pwrlevel = tpl;
                    metrics.therm.gpu_thermal_pwrlevel_active = 0;
                    if (tpl > 0) {
                        /* Read our current max_pwrlevel write to compare. Cheap
                         * because it's the same path we discovered + write to. */
                        int our_max = -1;
                        if (g_gpu_uses_pwrlevel && g_gpu_max_path[0]) {
                            int fd = open(g_gpu_max_path, O_RDONLY | O_CLOEXEC);
                            if (fd >= 0) {
                                char b[8] = {0};
                                ssize_t _n = read(fd, b, sizeof(b)-1);
                                close(fd);
                                if (_n > 0) our_max = atoi(b);
                            }
                        }
                        if (our_max >= 0 && tpl > our_max) {
                            /* Vendor wants stricter cap than us — soft signal */
                            metrics.therm.gpu_thermal_pwrlevel_active = 1;
                            if (!metrics.therm.soft_clamp) {
                                metrics.therm.soft_clamp = 1;
                                /* Don't escalate to hard_clamp from this signal alone;
                                 * thermal_pwrlevel is a soft hint, not actionable
                                 * confirmation like CPU thermal throttling is. */
                            }
                        }
                    }
                }

                /* Audit logger: flush counters periodically so user can verify
                 * the cost claim ("not eating battery") with real numbers. */
                static time_t g_thermal_pl_last_audit = 0;
                if (g_asb_cfg.thermal_pwrlevel_audit_log_s > 0) {
                    time_t now_s = time(NULL);
                    if (g_thermal_pl_last_audit == 0)
                        g_thermal_pl_last_audit = now_s;
                    if (now_s - g_thermal_pl_last_audit >= g_asb_cfg.thermal_pwrlevel_audit_log_s) {
                        char audit_buf[256];
                        gpu_thermal_pl_audit_path(audit_buf, sizeof(audit_buf));
                        asb_log("thermal_pl_audit: %s elapsed_s=%ld",
                                audit_buf, (long)(now_s - g_thermal_pl_last_audit));
#if ASB_DEBUG_BUILD
                        FILE *af = fopen("/dev/.asb/thermal_pl_audit", "w");
                        if (af) {
                            fprintf(af, "%s\nelapsed_s=%ld\n",
                                    audit_buf, (long)(now_s - g_thermal_pl_last_audit));
                            fclose(af);
                        }
#endif
                        g_thermal_pl_last_audit = now_s;

                        char vo_buf[256];
                        gpu_vendor_override_audit_path(vo_buf, sizeof(vo_buf));
                        asb_log("vendor_override_audit: %s", vo_buf);
#if ASB_DEBUG_BUILD
                        FILE *vf = fopen("/dev/.asb/vendor_override_audit", "w");
                        if (vf) {
                            fprintf(vf, "%s\n", vo_buf);
                            fclose(vf);
                        }
#endif
                    }
                }

                /* vendor override detection — check if vendor
                 * PowerHAL or thermal HAL stomped our pwrlevel writes. Same
                 * cost gating as thermal_pwrlevel monitor (skip DEEP_IDLE,
                 * skip screen-off, 2s minimum interval). */
                if (!monitor_skipped) {
                    gpu_check_vendor_override(fsm.profile_idx,
                                              asb_state_names[fsm.state]);
                }
            }

            writer_camera_guard(metrics.misc.camera_active);

            /*
             * Modem LPM.
             * The policy is about what the device is DOING, not which profile is selected, so
             * it lives here rather than in the Smart tick: an online match wants the data call
             * hot because coming back from an idle radio state is the latency spike that costs
             * the round, and a sleeping phone wants the opposite.
             */
            {
                /*
                 * The Battery profile outranks the load state.
                 * Reported as exactly that mismatch.
                 */
                /* A deeper step for the learned sleep window.
                 *
                 * "save" drops the always-on data call the moment the screen goes off, which is
                 * right for a pocket: the phone may be picked up any second. Overnight it is too
                 * timid. A five-hour sleep capture shows bluetooth 2.69 against cpu 3.96 in
                 * batterystats and roughly a thousand kernel wakeups down the modem path -
                 * rmnet_ipa 180, rmnet_ctl 300, IPA_LAN 318. The CPU slept 97% of the time and the
                 * phone still drew 96 mA, because something kept knocking on the door.
                 *
                 * "night" stretches keepalives much further and lets the radio settle - affordable
                 * at 3am, not at 3pm. It engages only inside a window the learner derived from this
                 * user's own nights, so a shift worker gets theirs rather than someone's idea of
                 * night. */
                /* Smart can deliberately lean into the Battery envelope (bias >= 400),
                 * which means its active session is asking for economy over latency.  Do not
                 * defeat that choice by holding mobile_data_always_on in fast merely because
                 * a feed/media burst reached HEAVY.  Confirmed GAMING stays fast, as does a
                 * camera session or any Smart context that is not explicitly battery-lean.
                 * The user-facing handover opt-in remains independent: normal mode still
                 * honours net_handover_fast inside asb_lpm.sh. */
                int smart_battery_lean =
                    fsm.profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                    g_asb_cfg.smart_battery_bias >= 400 &&
                    !metrics.misc.camera_active && !metrics.bat.charging &&
                    g_smart_rt.app_hint < ASB_APP_GAMING;
                const char *lpm_mode =
                    (g_asb_cfg.night_modem_idle && !metrics.misc.screen_on &&
                     asb_night_window_active(time(NULL)))   ? "night" :
                    !metrics.misc.screen_on                 ? "save" :
                    (fsm.profile_idx == PROFILE_BATTERY)    ? "save" :
                    (fsm.state == ASB_STATE_GAMING ||
                     (fsm.state == ASB_STATE_HEAVY && !smart_battery_lean))
                                                        ? "fast" : "normal";
                static const char *g_lpm_last = NULL;
                static time_t g_lpm_last_ts = 0;
                time_t lpm_now = time(NULL);
                if (lpm_mode != g_lpm_last && (lpm_now - g_lpm_last_ts) >= 15) {
                    char lcmd[192];
                    snprintf(lcmd, sizeof(lcmd),
                             "sh /data/adb/modules/AutoSystemBoost/runtime/asb_lpm.sh %s"
                             " >/dev/null 2>&1 &", lpm_mode);
                    int _lrc = system(lcmd);
                    (void)_lrc;
                    g_lpm_last    = lpm_mode;
                    g_lpm_last_ts = lpm_now;
                }
            }

            /*
             * Periodic maintenance, on this loop's clock rather than its own process.
             * asb_reconcile and asb_watchdog each ran as a permanent shell loop with its own
             * sleep - two resident processes, two independent timers, and every wake a
             * separate wakeup for the CPU to come out of idle for.
             */
            {
                static time_t _rec_last = 0, _wd_last = 0;
                time_t _mnow = time(NULL);
                if (_rec_last == 0) { _rec_last = _mnow; _wd_last = _mnow; }
                /* Reconcile leans on the screen state the same way its shell loop did. */
                int _rec_period = metrics.misc.screen_on ? 120 : 300;
                if ((_mnow - _rec_last) >= _rec_period) {
                    _rec_last = _mnow;
                    int _rr = system("sh /data/adb/modules/AutoSystemBoost/runtime/asb_reconcile.sh"
                                     " --once >/dev/null 2>&1 &");
                    (void)_rr;
                }
                /* doze=night has to be re-evaluated when the window opens and closes,
                 * and boot is the only time anything ran it. Hourly is plenty: the
                 * window has hour granularity, and the script is a no-op unless the
                 * side of the boundary changed. */
                {
                    static time_t _doze_last = 0;
                    if (_doze_last == 0) _doze_last = _mnow;
                    if ((_mnow - _doze_last) >= 600) {
                        _doze_last = _mnow;
                        int _dr = system("grep -q '^doze_level=night' "
                                         "/data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null"
                                         " && sh /data/adb/modules/AutoSystemBoost/runtime/asb_doze_apply.sh"
                                         " >/dev/null 2>&1 &");
                        (void)_dr;
                    }
                }
                if ((_mnow - _wd_last) >= 300) {
                    _wd_last = _mnow;
                    int _wr = system("sh /data/adb/modules/AutoSystemBoost/runtime/asb_watchdog.sh"
                                     " --once >/dev/null 2>&1 &");
                    (void)_wr;
                }
            }

            int changed = fsm_update(&fsm, &metrics);

            /* rebuild plan on state band cross (idle<->active<->heavy) */
            if (changed) {
                int new_band = (fsm.state <= ASB_STATE_LIGHT_IDLE) ? 0
                             : (fsm.state < ASB_STATE_HEAVY) ? 1 : 2;
                static int g_last_band = -1;
                if (new_band != g_last_band) {
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                    g_last_band = new_band;
                }
            }
            /* accumulate headroom telemetry (only real reads) */
            if (metrics.therm.headroom_valid) {
                fsm.ses_headroom_sum += metrics.therm.headroom_pct;
                fsm.ses_headroom_samples++;
                if (metrics.therm.headroom_pct < fsm.ses_headroom_min)
                    fsm.ses_headroom_min = metrics.therm.headroom_pct;
                if (metrics.therm.headroom_pct < 70)
                    fsm.ses_headroom_below70++;
                if (metrics.therm.headroom_pct < 50)
                    fsm.ses_headroom_below50++;
            }

            if (!fsm.ses_auto_degraded &&
                fsm.ses_intent != INTENT_BENCHMARK) {
                int avg_gap = (fsm.ses_gap_samples > 0)
                              ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
                if (asb_config_auto_should_degrade(
                        &g_asb_cfg, avg_gap,
                        fsm.ses_gaming_entries,
                        fsm.ses_sustained_entries,
                        fsm.ses_time_heavy_sec,
                        fsm.ses_time_gaming_sec,
                        fsm.ses_time_sustained_sec,
                        fsm.ses_auto_degraded))
                {
                    asb_config_apply_stable_override(&g_asb_cfg);
                    fsm.ses_auto_degraded = 1;
                    fsm.ses_degrade_at_age = (fsm.ses_start_ts > 0)
                                             ? (long)(time(NULL) - fsm.ses_start_ts) : 0;
                    long _total = fsm.ses_time_heavy_sec + fsm.ses_time_gaming_sec
                                 + fsm.ses_time_sustained_sec;
                    int _sus_pct = (_total > 0)
                                  ? (int)(fsm.ses_time_sustained_sec * 100 / _total) : 0;
                    asb_log("auto: degraded burst->stable avg_gap=%d sus=%d gaming=%d sus_pct=%d",
                            avg_gap, fsm.ses_sustained_entries,
                            fsm.ses_gaming_entries, _sus_pct);
                }
            }
            if (!fsm.ses_intent_locked && fsm.ses_start_ts > 0) {
                long ses_age = time(NULL) - fsm.ses_start_ts;
                int have_thermal = (fsm.ses_thermal_entries > 0);
                int have_gaming  = (fsm.ses_gaming_entries > 0);

                if (ses_age >= 90 || have_thermal) {
                    fsm_flush_state_time(&fsm);
                    long total_act = fsm.ses_time_heavy_sec +
                                     fsm.ses_time_gaming_sec +
                                     fsm.ses_time_sustained_sec;

                    if (fsm_profile_is_battery) {
                        if (fsm.state == ASB_STATE_DEEP_IDLE &&
                            fsm.bat_wake_cycles <= 1 &&
                            ses_age >= 1800 &&
                            fsm.bat_time_deep_idle_sec > ses_age / 2) {
                            fsm.ses_intent = INTENT_SLEEP_IDLE;
                        } else if (fsm.bat_time_deep_idle_sec > 60) {
                            if (fsm.ses_time_sustained_sec > 300 ||
                                fsm.ses_max_temp >= 65) {
                                fsm.ses_intent = INTENT_IDLE_WARM;
                            } else {
                                fsm.ses_intent = INTENT_IDLE;
                            }
                        } else {
                            fsm.ses_intent = INTENT_MIXED;
                        }
                    } else if (have_thermal && total_act > 30 && ses_age < 600 &&
                               (have_gaming || fsm.profile_idx == PROFILE_PERFORMANCE)) {
                        fsm.ses_intent = INTENT_BENCHMARK;
                    } else if (have_gaming && ses_age >= 300) {
                        fsm.ses_intent = INTENT_LONG_GAME;
                    } else if (total_act > 60) {
                        fsm.ses_intent = INTENT_MIXED;
                    }

                    if (fsm.ses_intent != INTENT_UNKNOWN) {
                        fsm.ses_intent_locked = 1;
                        asb_log("intent: classified as %s (age=%lds gaming=%d thermal=%d)",
                                intent_names[fsm.ses_intent], ses_age,
                                have_gaming, have_thermal);

                        if (fsm.profile_idx == PROFILE_PERFORMANCE) {
                            if (fsm.ses_intent == INTENT_BENCHMARK && have_thermal) {
                                asb_log("intent: benchmark+thermal detected but burst preserved (letting kernel thermal protect)");
                            } else if (fsm.ses_intent == INTENT_LONG_GAME) {
                                if (g_asb_cfg.sustained_reentry_cooldown_s < 30)
                                    g_asb_cfg.sustained_reentry_cooldown_s = 30;
                                asb_log("intent: long_game -> reentry_cooldown=30s");
                            }
                        }
                    }

                }
            }
            /*
             * benchmark false-positive guard -- runs EVERY tick regardless of lock status.
             * Must be OUTSIDE !ses_intent_locked block to actually fire.
             */
            if (fsm.ses_intent == INTENT_BENCHMARK &&
                fsm.ses_intent_locked && fsm.ses_start_ts > 0) {
                long _bfp_age = time(NULL) - fsm.ses_start_ts;
                if (_bfp_age >= 900) {
                    int _bfp_gaming = (fsm.ses_gaming_entries > 0);
                    fsm.ses_intent = _bfp_gaming ? INTENT_LONG_GAME : INTENT_MIXED;
                    asb_log("intent: benchmark downgraded to %s "
                            "(age=%lds > 900s, not a real benchmark)",
                            intent_names[fsm.ses_intent], _bfp_age);
                }
            }
            if (fsm.state == ASB_STATE_DEEP_IDLE) {
                /* use session age, not fsm_elapsed (which resets on heartbeat flush) */
                long ses_age_b = (fsm.ses_start_ts > 0) ? (time(NULL) - fsm.ses_start_ts) : 0;
                if (ses_age_b >= 1800 && fsm.bat_time_deep_idle_sec > 900) {
                    fsm_flush_state_time(&fsm);
                    if (fsm.ses_time_heavy_sec > 0 ||
                        fsm.bat_time_deep_idle_sec > 60) {
                        session_history_append_ex(&fsm, "idle_boundary");
                        session_end_self_tune(&fsm);
                        persistent_stats_save(&fsm);
                        session_reset_and_replan(&fsm, metrics.misc.screen_on);
                        asb_log("session_boundary: 30min DEEP_IDLE, stats saved+reset");
                    }
                }
            }

            /*
             * Smart Mode periodic learning: keep learning even when the user never switches
             * profiles.
             */
            if (fsm.profile_idx == PROFILE_SMART && g_smart_rt.enabled &&
                g_smart_store_loaded) {
                long _ses_age = (fsm.ses_start_ts > 0)
                                ? (time(NULL) - fsm.ses_start_ts) : 0;
                int _bucket_rollover =
                    (g_smart_last_seen_bucket >= 0 &&
                     g_smart_last_seen_bucket != (int)g_smart_rt.bucket_id &&
                     metrics.misc.screen_on);
                /*
                 * Fire a soft session after the session has run long enough, regardless of
                 * whether it was heavy.
                 * Light daily use (browsing, messaging, idle) must advance the learner too —
                 * otherwise a user who never switches profiles would never accumulate
                 * confidence.
                 */
                long _active_s = fsm.ses_time_heavy_sec
                               + fsm.ses_time_gaming_sec
                               + fsm.ses_time_sustained_sec;
                int _meaningful = (_active_s > 60 || fsm.bat_wake_screen > 0);
                int _smart_age_trigger =
                    (_ses_age >= 1200 && _meaningful &&
                     (time(NULL) - g_smart_last_periodic_ts) >= 1200);
                if (_bucket_rollover || _smart_age_trigger) {
                    const char *_reason = _bucket_rollover
                                          ? "smart_bucket_rollover"
                                          : "smart_periodic";
                    fsm_flush_state_time(&fsm);
                    session_history_append_ex(&fsm, _reason);
                    session_end_self_tune(&fsm);
                    persistent_stats_save(&fsm);
                    session_reset_and_replan(&fsm, metrics.misc.screen_on);
                    g_smart_last_periodic_ts = time(NULL);
                    asb_log("smart_learn: %s fired (age=%lds, bucket=%u, heavy=%lds)",
                            _reason, _ses_age,
                            (unsigned)g_smart_rt.bucket_id,
                            fsm.ses_time_heavy_sec);
                }
                g_smart_last_seen_bucket = (int)g_smart_rt.bucket_id;
            }
            /*
             * Smart Mode tick: refresh g_smart_bounds BEFORE writer_apply_caps.
             * Force a write so the change reaches sysfs immediately rather than waiting for
             * the next state transition.
             */
            int smart_updated = asb_smart_tick(&metrics, &fsm);
            int smart_media_guard_changed = asb_smart_media_guard_observe(&metrics, &fsm, time(NULL));
            if (smart_media_guard_changed) force_write = 1;
            asb_smart_persist_check();
            if (smart_updated && fsm.profile_idx == PROFILE_SMART) {
                asb_profile_caps_t _new_caps;
                fsm_interpolate_caps(asb_profile_bounds_for(fsm.profile_idx),
                                     fsm.profile_idx, fsm.state, &_new_caps);
                /* Apply same thermal overlay as the normal FSM path */
                if (fsm.thermal_cap && fsm.state != ASB_STATE_SUSTAINED) {
                    float keep = (100 - g_asb_cfg.thermal_overlay_pct) / 100.0f;
                    for (int i = 0; i < 3; i++)
                        _new_caps.cpu_max[i] = (int)(_new_caps.cpu_max[i] * keep);
                }
                /* Detect if caps actually changed to avoid spurious writes */
                int _diff = 0;
                int _thr = fsm.thermal_cap ? 1 : 38400;
                for (int i = 0; i < 3; i++) {
                    if (abs(_new_caps.cpu_max[i] - fsm.current_caps.cpu_max[i]) >= _thr) { _diff = 1; break; }
                    if (abs(_new_caps.cpu_min[i] - fsm.current_caps.cpu_min[i]) >= _thr) { _diff = 1; break; }
                }
                if (!_diff) {
                    int _gthr = fsm.thermal_cap ? 1 : 2;
                    if (abs(_new_caps.gpu_max_pct - fsm.current_caps.gpu_max_pct) >= _gthr ||
                        abs(_new_caps.gpu_min_pct - fsm.current_caps.gpu_min_pct) >= _gthr) {
                        _diff = 1;
                    }
                }
                if (_diff) {
                    fsm.current_caps = _new_caps;
                    force_write = 1;
                    if (g_asb_cfg.smart_debug_log) {
                        asb_log("smart_tick: forced caps refresh (alpha=%d, fb=%d)",
                                g_smart_rt.alpha_battery_x1000,
                                g_smart_rt.fallback_level);
                    }
                }
            }
            {
                int _det = asb_cap_detente_check(
                        metrics.misc.screen_on,
                        fsm.state == ASB_STATE_DEEP_IDLE ||
                            fsm.state == ASB_STATE_LIGHT_IDLE,
                        g_cap_owner_eff == ASB_CAP_OWNER_VENDOR ||
                            g_cap_owner_eff == ASB_CAP_OWNER_SHELL,
                        (long)(time(NULL) - g_cap_owner_since),
                        metrics.therm.cpu_max_c,
                        fsm.thermal_cap);
                static int _det_false_ticks = 0;
                int _hard_exit = (metrics.misc.screen_on || fsm.thermal_cap);
                if (_det) _det_false_ticks = 0;
                if (_det && !g_cap_detente_active) {
                    g_cap_detente_active = 1;
                    g_cap_detente_since = time(NULL);
                    asb_log("cap_detente: enter (foreign-owned deep idle, freezing cap writes)");
                } else if (!_det && g_cap_detente_active) {
                    _det_false_ticks++;
                    if (_hard_exit || _det_false_ticks >= 3) {
                        g_cap_detente_active = 0;
                        _det_false_ticks = 0;
                        asb_log("cap_detente: exit after %lds (%s, skipped %ld writes total)",
                                (long)(time(NULL) - g_cap_detente_since),
                                _hard_exit ? "wake/thermal" : "conditions faded",
                                g_cap_detente_skipped);
                    }
                }
            }
            if ((changed || force_write) && g_cap_detente_active) {
                g_cap_detente_skipped++;
                g_write_skipped_detente++;
            } else if ((changed || force_write) &&
                       asb_cap_writes_should_back_off() &&
                       !force_write && !metrics.misc.screen_on &&
                       (fsm.state == ASB_STATE_DEEP_IDLE ||
                        fsm.state == ASB_STATE_LIGHT_IDLE) &&
                       !fsm.thermal_cap) {
                g_cap_detente_skipped++;
                g_write_skipped_backoff++;
            } else if (changed || force_write) {
                g_write_attempts++;
                asb_profile_caps_t _effective_caps = fsm.current_caps;
                asb_apply_adaptive_budget_caps(&_effective_caps, &metrics, &fsm);
                asb_smart_media_guard_apply_caps(&_effective_caps);
                int writes = writer_apply_caps(&_effective_caps, force_write, fsm.state, fsm.thermal_cap);
                if (writes > 0) {
                    g_total_writes += writes;
                    g_last_write_ts = time(NULL);
                }

                write_state(&fsm, &metrics, cur_pred);
                
                write_conflicts_json();
                write_learner_state_json(&fsm);

                if (fsm.state_changed) {
                    int ma_v = (metrics.bat.current_ma > 0 && !metrics.bat.charging) ? 1 : 0;
                    int fsm_rmax0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                    int fsm_rmax1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                    int gap0 = (fsm_rmax0 > 0) ? (fsm.current_caps.cpu_max[0] - fsm_rmax0) : 0;
                    int gap1 = (fsm_rmax1 > 0) ? (fsm.current_caps.cpu_max[1] - fsm_rmax1) : 0;
                    if (g_asb_cfg.log_level >= 1) asb_log("FSM: %s mA=%d(v=%d) gpu=%d%% load=%.2f "
                            "t=%ddegC gap0=%d gap1=%d writes=%d total=%d",
                            asb_state_names[fsm.state],
                            metrics.bat.current_ma, ma_v,
                            metrics.gpu.load_pct,
                            metrics.cpu.load1,
                            metrics.therm.cpu_max_c,
                            gap0, gap1,
                            writes, g_total_writes);
                    if (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                        g_last_reassert = 0;

                    if (fsm.state == ASB_STATE_SUSTAINED) {
                        if (fsm.sustained_reason == 1) {
                            fsm.ses_unreachable_entries++;
                            asb_log("enter_sustained: gaming_unreachable"
                                    " gap_ticks=%d gap_thresh=%d",
                                    g_asb_cfg.gaming_gap_ticks,
                                    g_asb_cfg.gaming_gap_thresh);
                            if (fsm.ses_unreachable_entries >= 3 &&
                                g_asb_cfg.sustained_level > 0.72f) {
                                float _old_sl = g_asb_cfg.sustained_level;
                                g_asb_cfg.sustained_level -= 0.02f;
                                if (g_asb_cfg.sustained_level < 0.72f)
                                    g_asb_cfg.sustained_level = 0.72f;
                                asb_log("mid_tune: gap_episodes=%d >=3 -> sustained_level %.2f->%.2f",
                                        fsm.ses_unreachable_entries, _old_sl, g_asb_cfg.sustained_level);
                                fsm.ses_mid_tune_count++;
                                fsm.ses_mid_tune_dir = -1;  /* downward adjustment */
                            }
                        }
                        else {
                            fsm.ses_thermal_entries++;
                            if (metrics.therm.headroom_pct > 0 && metrics.therm.headroom_pct < 50) {
                                asb_log("enter_sustained: headroom=%d%% (perf_cap p0=%d p6=%d) -- kernel thermal cap detected before temp threshold",
                                        metrics.therm.headroom_pct,
                                        metrics.therm.perf_cap_p0,
                                        metrics.therm.perf_cap_p6);
                            } else {
                                /*
                                 * explicit reason for every enter_sustained instead of
                                 * "unknown".
                                 */
                                const char *_sus_reason =
                                    metrics.therm.throttling       ? "thermal" :
                                    metrics.therm.hard_clamp       ? "hard_clamp" :
                                    fsm.perf_hot_guard_active      ? "perf_hot_guard" :
                                    (fsm.thermal_trend >= 6)       ? "thermal_trend" :
                                    (metrics.therm.cpu_max_c >= g_asb_cfg.sustained_temp_enter)
                                                                   ? "thermal_floor" :
                                                                     "other";
                                asb_log("enter_sustained: %s actual_t=%ddegC (thresh=%d) headroom=%d%% soft=%d hard=%d trend=%d hot_guard=%d",
                                        _sus_reason,
                                        metrics.therm.cpu_max_c,
                                        asb_config_profile_sustained_temp_enter(&g_asb_cfg, fsm.profile_idx),
                                        metrics.therm.headroom_pct,
                                        metrics.therm.soft_clamp,
                                        metrics.therm.hard_clamp,
                                        fsm.thermal_trend,
                                        fsm.perf_hot_guard_active);
                            }
                            if (fsm.ses_time_to_first_thermal == 0 && fsm.ses_start_ts > 0)
                                fsm.ses_time_to_first_thermal = time(NULL) - fsm.ses_start_ts;
                            if (fsm.ses_sustained_entries > 1)
                                fsm.ses_recovery_count++;
                        }
                    }
                    if (fsm.prev_state == ASB_STATE_SUSTAINED) {
                        /* sustained_reason=2 set by FSM time-based escape.
                         * When we see it on exit, surface it in the log so the
                         * new mechanism is visible in post-mortem analysis. */
                        const char *reason =
                            (fsm.sustained_reason == 2)                                      ? "time_based_escape" :
                            (metrics.therm.cpu_max_c < g_asb_cfg.sustained_temp_enter)       ? "temp_dropped" :
                                                                                               "no_longer_heavy";
                        int _avg_gap = (fsm.ses_gap_samples > 0)
                                       ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
                        int _gap_penalty  = (int)(_avg_gap / 15000);
                        if (_gap_penalty > 50) _gap_penalty = 50;
                        int _temp_penalty = (metrics.therm.cpu_max_c > 55)
                                            ? (metrics.therm.cpu_max_c - 55) * 2 : 0;
                        if (_temp_penalty > 50) _temp_penalty = 50;
                        int _eff = 100 - _gap_penalty - _temp_penalty;
                        if (_eff < 0) _eff = 0;
                        if (fsm.ses_sustained_efficiency < 0 || _eff < fsm.ses_sustained_efficiency)
                            fsm.ses_sustained_efficiency = _eff;
                        asb_log("exit_sustained: %s t=%ddegC (exit_thresh=%d) -> %s cooldown=%ds efficiency=%d/100",
                                reason, metrics.therm.cpu_max_c,
                                asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm.profile_idx),
                                asb_state_names[fsm.state],
                                g_asb_cfg.gaming_retry_cooldown_s, _eff);
                        /* Reset reason so the *next* enter_sustained classifies cleanly */
                        if (fsm.sustained_reason == 2) fsm.sustained_reason = 0;
                    }
                }
            }

            {
                int boost_want = (fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING)
                                 && !fsm.thermal_cap
                                 && (fsm.profile_idx == PROFILE_PERFORMANCE);
                if (boost_want && !g_msm_boost_active) {
                    if (g_asb_cfg.log_level >= 1) asb_log("boost_on: %s", asb_state_names[fsm.state]);
                } else if (!boost_want && g_msm_boost_active) {
                    const char *off_reason = fsm.thermal_cap           ? "thermal"
                                           : (fsm.state == ASB_STATE_SUSTAINED) ? "SUSTAINED"
                                           : (fsm.profile_idx != PROFILE_PERFORMANCE) ? "profile!=perf"
                                           : asb_state_names[fsm.state];
                    if (g_asb_cfg.log_level >= 1) asb_log("boost_off: %s", off_reason);
                }
                g_msm_boost_active = boost_want;
            }
            if ((fsm.state == ASB_STATE_HEAVY || fsm.state == ASB_STATE_GAMING
                 || fsm.state == ASB_STATE_SUSTAINED) && !fsm.thermal_cap &&
                /* Smart is an energy/heat profile. Its calculated caps remain applied by the
                 * normal writer, but it must never enter the anti-clamp reassert path that
                 * tries to lift a foreign vendor ceiling. This avoids wasted writes/backoff
                 * during vendor-held light-use caps and preserves anti-clamp for the explicit
                 * Performance/Balanced paths where the user requested performance. */
                fsm.profile_idx != PROFILE_SMART) {
                /* anti-clamp with cadence ladder
                 * Stages: IDLE -> BURST(2s,3 attempts) -> HOLD(4s) -> BACKOFF(30s)
                 * Detection: gap > 500kHz on either cluster + temp < 95 + headroom >= 60%
                 * Backoff: 5 ineffective attempts -> pause 30s */

                int vendor_clamping = 0;
                if (fsm.plan.ac_eligible && fsm.plan.ac_used < fsm.plan.ac_budget
                    && !g_ac_futile) {
                    time_t now_ac = time(NULL);
                    if (g_ac_stage == AC_STAGE_BACKOFF && now_ac < g_ac_backoff_until) {
                        /* In backoff -- skip */
                    } else {
                        if (g_ac_stage == AC_STAGE_BACKOFF) {
                            g_ac_stage = AC_STAGE_IDLE;
                            g_ac_fails = 0;
                        }
                        int actual_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                        int actual_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                        int desired_p0 = fsm.current_caps.cpu_max[0];
                        int desired_p1 = fsm.current_caps.cpu_max[1];
                        int gap0 = (desired_p0 > 0 && actual_p0 > 0) ? desired_p0 - actual_p0 : 0;
                        int gap1 = (desired_p1 > 0 && actual_p1 > 0) ? desired_p1 - actual_p1 : 0;
                        int max_gap = (gap0 > gap1) ? gap0 : gap1;
                        int headroom_ok = (!metrics.therm.headroom_valid || metrics.therm.headroom_pct >= 60);
                        if (max_gap > 500000 && metrics.therm.cpu_max_c < 95 && headroom_ok) {
                            vendor_clamping = 1;
                            if (g_ac_stage == AC_STAGE_IDLE) {
                                /*
                                 * budget counts anti-clamp WINDOWS, not individual writes.
                                 * budget=6 means 6 windows x ~3 writes = ~18 actual
                                 * dual-writes max, spread across the full session instead of
                                 * burning in 90 seconds.
                                 */
                                fsm.plan.ac_used++;
                                int is_last = (fsm.plan.ac_used >= fsm.plan.ac_budget);

                                g_ac_stage = AC_STAGE_BURST;
                                g_ac_burst_count = 0;
                                g_ac_fails = 0;

                                if (is_last) {
                                    asb_log("anti_clamp: last window %d/%d",
                                            fsm.plan.ac_used, fsm.plan.ac_budget);
                                } else if (fsm.plan.ac_prearm) {
                                    asb_log("anti_clamp: prearm -> BURST window %d/%d (streak=%d)",
                                            fsm.plan.ac_used, fsm.plan.ac_budget,
                                            g_pstats_per[PROFILE_PERFORMANCE].cause_streak);
                                }
                            }
                        } else if (g_ac_stage != AC_STAGE_IDLE) {
                            g_ac_stage = AC_STAGE_IDLE;
                            g_ac_burst_count = 0;
                            g_ac_fails = 0;
                        }
                    }
                }
                /* Cadence ladder */
                int reassert_interval;
                if (g_ac_futile) {
                    /* futility fallback -- vendor clamp won, reduce writes.
                     * Double the reassert interval since fighting is pointless. */
                    reassert_interval = (fsm.state == ASB_STATE_GAMING)
                                        ? g_asb_cfg.reassert_gaming_s * 2
                                        : g_asb_cfg.reassert_heavy_s * 2;
                } else if (g_ac_stage == AC_STAGE_BURST)
                    reassert_interval = 2;
                else if (g_ac_stage == AC_STAGE_HOLD)
                    reassert_interval = 4;
                else
                    reassert_interval = (fsm.state == ASB_STATE_GAMING)
                                        ? g_asb_cfg.reassert_gaming_s
                                        : g_asb_cfg.reassert_heavy_s;
                /* action cost economy -- wasted actions slow everything */
                if (g_action_waste >= g_asb_cfg.action_waste_threshold)
                    reassert_interval = reassert_interval * 2;

                time_t now = time(NULL);
                if (now - g_last_reassert >= reassert_interval) {
                    int pre_p0 = 0, pre_p1 = 0;
                    if (vendor_clamping) {
                        pre_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                        pre_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                    }
                    /* Write msm_performance */
                    int ok = msm_perf_write_all_max(
                                fsm.current_caps.cpu_max[0],
                                fsm.current_caps.cpu_max[1]);
                    /* Anti-clamp: force scaling_max_freq on both clusters */
                    if (vendor_clamping) {
                        for (int ci = 0; ci < 2; ci++) {
                            if (fsm.current_caps.cpu_max[ci] > 0)
                                sysfs_write_int(cpu_policy_path(ci, "scaling_max_freq"),
                                               fsm.current_caps.cpu_max[ci]);
                        }
                        /* Evaluate effectiveness on BOTH clusters */
                        int post_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                        int post_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                        int delta0 = (post_p0 > 0 && pre_p0 > 0) ? post_p0 - pre_p0 : 0;
                        int delta1 = (post_p1 > 0 && pre_p1 > 0) ? post_p1 - pre_p1 : 0;
                        int max_delta = (delta0 > delta1) ? delta0 : delta1;
                        if (max_delta < 100000) {
                            g_ac_fails++;
                            if (g_ac_fails >= 5) {
                                g_ac_stage = AC_STAGE_BACKOFF;
                                g_ac_backoff_until = now + 30;
                                g_ac_fails = 0;
                                g_ac_backoff_count++;
                                asb_log("anti_clamp: backoff 30s (5 ineffective, actual=[%d,%d]) backoffs=%d",
                                        post_p0, post_p1, g_ac_backoff_count);
                                g_action_waste++;
                                /* futility suspend -- if 2+ backoffs this session,
                                 * anti-clamp is clearly losing. Stop wasting writes. */
                                if (g_ac_backoff_count >= 2) {
                                    g_ac_futile = 1;
                                    fsm.clamp_hold = 1;
                                    fsm.had_clamp_hold = 1;
                                    fsm.had_futility = 1;
                                    g_clamp_hold_since = time(NULL);
                                    fsm.plan.plan_class = PLAN_CLASS_PERF_CLAMPED;
                                    asb_log("anti_clamp: futility suspend + clamp_hold "
                                            "(2+ backoffs, vendor wins, gap jitter suppressed)");
                                }
                            }
                        } else {
                            g_ac_fails = 0;
                            /* Action Waste Reward -- successful action reduces waste */
                            if (g_action_waste > 0) {
                                g_action_waste -= 2;
                                if (g_action_waste < 0) g_action_waste = 0;
                            }
                        }
                        /* Burst -> Hold transition after 3 burst attempts */
                        if (g_ac_stage == AC_STAGE_BURST) {
                            g_ac_burst_count++;
                            if (g_ac_burst_count >= 3)
                                g_ac_stage = AC_STAGE_HOLD;
                        }
                    }
                    g_last_reassert = now;
                    g_last_reassert_ok = (ok == 0) ? 1 : 0;
                    if (ok == 0 && g_asb_cfg.log_level >= 1) {
                        if (vendor_clamping) {
                            /* Same fix the reassert branch below already carries, applied
                             * here too.
                             *
                             * This printed fsm.current_caps raw - the ratio arithmetic
                             * before the writer snaps it to a step the cluster actually
                             * has. A field log shows
                             * "anti_clamp[burst]: cpu_max=[3551224,2322753]" two lines
                             * above "reassert: cpu_max=[3513600,2227200]", the same moment
                             * reported with and without snapping. The first pair are
                             * frequencies no device has.
                             *
                             * That is not cosmetic here: this line exists to show a VENDOR
                             * clamp, and the reader compares the two columns to judge how
                             * far apart they are. Part of that gap was our own rounding,
                             * so the log overstated the clamp - and I diagnosed exactly
                             * that wrongly once already from this output.
                             *
                             * Both columns now come from the same place: what was asked
                             * for after snapping, against what the device holds.
                             */
                            int _ac_want0 = fsm.current_caps.cpu_max[0];
                            int _ac_want1 = fsm.current_caps.cpu_max[1];
                            for (int _ac_i = 0; _ac_i < 2; _ac_i++) {
                                int _ac_slot = -1;
                                for (int _ac_k = 0; _ac_k < g_cpu_all_paths_n && _ac_k < 16; _ac_k++) {
                                    if (g_cpu_all_max_paths[_ac_k][0] && g_cpu_max_paths[_ac_i][0] &&
                                        strcmp(g_cpu_all_max_paths[_ac_k], g_cpu_max_paths[_ac_i]) == 0) {
                                        _ac_slot = _ac_k; break;
                                    }
                                }
                                if (_ac_slot < 0) continue;
                                if (_ac_i == 0 && _ac_want0 > 0)
                                    _ac_want0 = (int)cpu_snap_freq(_ac_slot, (long)_ac_want0);
                                if (_ac_i == 1 && _ac_want1 > 0)
                                    _ac_want1 = (int)cpu_snap_freq(_ac_slot, (long)_ac_want1);
                            }
                            asb_log("anti_clamp[%s]: %s cpu_max=[%d,%d] actual=[%d,%d] hr=%d%% t=%ddegC",
                                    (g_ac_stage == AC_STAGE_BURST) ? "burst" :
                                    (g_ac_stage == AC_STAGE_HOLD) ? "hold" : "?",
                                    asb_state_names[fsm.state],
                                    _ac_want0, _ac_want1,
                                    sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0),
                                    sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0),
                                    metrics.therm.headroom_pct, metrics.therm.cpu_max_c);
                        }
                        else
                            /* Log what the CPU will actually hold, not what was asked for.
                             *
                             * This printed fsm.current_caps - the value before the writer
                             * snaps it to a real frequency step. A whole day of logs read
                             * "cpu_max=[2128230,1925001]", numbers no chip has, and I spent
                             * a diagnosis concluding the caps were being written unsnapped
                             * when in fact only the log was wrong. A log that reports an
                             * intention while claiming to report an action is worse than no
                             * log: it sends the next person looking in the wrong place. */
                            asb_log("reassert: %s cpu_max=[%d,%d] t=%ddegC",
                                    asb_state_names[fsm.state],
                                    sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0),
                                    sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0),
                                    metrics.therm.cpu_max_c);
                    }
                }
            } else {
                if (fsm.state < ASB_STATE_HEAVY || fsm.thermal_cap) {
                    g_last_reassert = 0;
                    g_msm_boost_active = 0;
                    /* Light reset: stop reasserting but preserve session futility.
                     * Full anti_clamp_reset() would clear g_ac_futile, letting
                     * the module bang the wall again after a momentary load dip. */
                    g_ac_stage = AC_STAGE_IDLE;
                    g_ac_burst_count = 0;
                    g_ac_fails = 0;
                    g_ac_backoff_until = 0;
                }
            }

            /*
             * shell_overridden_up watchdog Anti-clamp above handles vendor DOWN-clamps (gap >
             * 0).
             */
            if (fsm.profile_idx != PROFILE_PERFORMANCE &&
                (fsm.state == ASB_STATE_DEEP_IDLE || fsm.state == ASB_STATE_LIGHT_IDLE ||
                 fsm.state == ASB_STATE_MODERATE  || fsm.state == ASB_STATE_HEAVY)) {
                int actual_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                int actual_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                int want_p0 = fsm.current_caps.cpu_max[0];
                int want_p1 = fsm.current_caps.cpu_max[1];
                int leak0 = (actual_p0 > 0 && want_p0 > 0 && actual_p0 > want_p0 + 100000) ? 1 : 0;
                int leak1 = (actual_p1 > 0 && want_p1 > 0 && actual_p1 > want_p1 + 100000) ? 1 : 0;

                g_leak_streak_p0 = leak0 ? (g_leak_streak_p0 + 1) : 0;
                g_leak_streak_p1 = leak1 ? (g_leak_streak_p1 + 1) : 0;

                /* Reporter: log when a streak crosses the old reassert threshold,
                 * so deploys still surface vendor-up-clamp events even though
                 * we no longer write here. Rate-limited to 1/minute to avoid
                 * log spam. */
                if ((g_leak_streak_p0 == 2 || g_leak_streak_p1 == 2) &&
                    g_asb_cfg.log_level >= 1) {
                    time_t leak_now = time(NULL);
                    if (leak_now - g_last_leak_reassert >= 60) {
                        asb_log("leak_observed[%s/%s]: p0=%d(want %d) p1=%d(want %d) — reconcile.sh handles",
                                asb_state_names[fsm.state],
                                asb_profile_name(fsm.profile_idx),
                                actual_p0, want_p0, actual_p1, want_p1);
                        g_last_leak_reassert = leak_now;
                        g_leak_reassert_count++;
                    }
                }
            } else {
                /* Reset streaks when we're in gaming/sustained or on perf profile */
                g_leak_streak_p0 = 0;
                g_leak_streak_p1 = 0;
            }

            /* check quarantine expiry (runs each idle tick = 5-10s) */
            if (g_user_quarantine_active) {
                if (user_quarantine_check(&fsm)) {
                    asb_log("user_quarantine: expired, resuming normal policy");
                    session_plan_build(&fsm, metrics.misc.screen_on);
                    session_plan_apply_prearm(&fsm);
                }
            }

            /*
             * periodic user ID check (~every 30s when screen on).
             */
            if (metrics.misc.screen_on && !g_user_quarantine_active) {
                static int g_user_poll_skip = 0;
                if (++g_user_poll_skip >= 6) {  /* ~30s at 5s ticks */
                    g_user_poll_skip = 0;
                    int cur_uid = get_current_user_id();
                    if (cur_uid >= 0 && g_last_user_id >= 0 && cur_uid != g_last_user_id) {
                        asb_log("user_quarantine: user switch %d -> %d (poll), active for %ds",
                                g_last_user_id, cur_uid, USER_QUARANTINE_SEC);
                        g_last_user_id = cur_uid;
                        g_user_quarantine_active = 1;
                        g_user_quarantine_until = time(NULL) + USER_QUARANTINE_SEC;
                        session_plan_build(&fsm, metrics.misc.screen_on);
                    } else if (cur_uid >= 0) {
                        g_last_user_id = cur_uid;
                    }
                }
            }

            /*
             * storm shield -- activate for noisy battery screen-off.
             */
            if (!g_storm_shield_active && fsm_profile_is_battery
                && !metrics.misc.screen_on
                && fsm.bat_wake_cycles >= 5) {
                long ses_age = fsm_elapsed_sec(&fsm);
                int rearm_ok = 1;
                if (g_shield_exit_wakes > 0) {
                    /* After smart exit: need 3+ NEW wakes AND 2min cooldown */
                    int new_wakes = fsm.bat_wake_cycles - g_shield_exit_wakes;
                    if (new_wakes < 3 || time(NULL) < g_shield_rearm_until)
                        rearm_ok = 0;
                }
                /* daytime-mixed gating */
                int daytime_mixed = (fsm.ses_intent == INTENT_MIXED);
                int daytime_gate_ok = 1;
                if (daytime_mixed) {
                    float wph = (ses_age > 0)
                              ? (float)fsm.bat_wake_cycles * 3600.0f / ses_age
                              : 0.0f;
                    if (wph < 12.0f || fsm.bat_wake_cycles < 8 || ses_age < 480)
                        daytime_gate_ok = 0;
                }
                if (ses_age >= 300 && rearm_ok && daytime_gate_ok) {
                    g_storm_shield_active = 1;
                    g_shield_exit_wakes = 0;  /* clear re-arm state on new activation */
                    g_shield_rearm_until = 0;
                    session_plan_build(&fsm, 0);
                    asb_log("storm_shield: activated (wakes=%d age=%lds intent=%d), ultra-light mode",
                            fsm.bat_wake_cycles, ses_age, fsm.ses_intent);
                }
            }
            /* storm shield smart exit -- if noise calmed down for ~10min,
             * exit shield and resume normal battery behavior */
            if (g_storm_shield_active && fsm_profile_is_battery
                && !metrics.misc.screen_on) {
                if (g_shield_last_wakes < 0)
                    g_shield_last_wakes = fsm.bat_wake_cycles;
                if (fsm.bat_wake_cycles == g_shield_last_wakes) {
                    g_shield_calm_ticks++;
                    if (g_shield_calm_ticks >= 60) {  /* ~10min at 10s deep ticks */
                        int exit_wakes = fsm.bat_wake_cycles;
                        storm_shield_reset();
                        /* re-arm hysteresis -- remember exit point */
                        g_shield_exit_wakes = exit_wakes;
                        g_shield_rearm_until = time(NULL) + 120;  /* 2min cooldown */
                        session_plan_build(&fsm, 0);
                        asb_log("storm_shield: exited (noise calmed for ~10min, wakes=%d, rearm after 2min+3 new wakes)",
                                exit_wakes);
                    }
                } else {
                    g_shield_last_wakes = fsm.bat_wake_cycles;
                    g_shield_calm_ticks = 0;
                }
            }

            /* adaptive tick reads from session plan */

            /*
             * clamp recovery probe -- periodically check if vendor clamp lifted.
             * Dual-cluster: both policy0 AND policy6 must be unclamped.
             */
            if (fsm.clamp_hold && metrics.misc.screen_on) {
                int probe_interval = 60;  /* ~5min default */
                if (g_clamp_hold_since > 0 &&
                    (time(NULL) - g_clamp_hold_since) >= 600)
                    probe_interval = 120;  /* ~10min economy after 10min hold */
                /* action cost economy -- more waste = longer between probes */
                if (g_action_waste >= g_asb_cfg.action_waste_threshold)
                    probe_interval = probe_interval * 2;
                if (++g_clamp_probe_skip >= probe_interval) {
                    g_clamp_probe_skip = 0;
                    int probe_p0 = sysfs_read_int(cpu_policy_path(0, "scaling_max_freq"), 0);
                    int probe_p1 = sysfs_read_int(cpu_policy_path(1, "scaling_max_freq"), 0);
                    int gap0 = (probe_p0 > 0 && fsm.current_caps.cpu_max[0] > 0)
                               ? fsm.current_caps.cpu_max[0] - probe_p0 : 0;
                    int gap1 = (probe_p1 > 0 && fsm.current_caps.cpu_max[1] > 0)
                               ? fsm.current_caps.cpu_max[1] - probe_p1 : 0;
                    if (gap0 < 0) gap0 = 0;  /* reject transient overshoot */
                    if (gap1 < 0) gap1 = 0;
                    int max_gap = (gap0 > gap1) ? gap0 : gap1;
                    if (max_gap < 500000) {
                        g_probe_good_hits++;
                        if (g_probe_good_hits >= 2) {
                            fsm.clamp_hold = 0;
                            g_ac_futile = 0;
                            g_ac_backoff_count = 0;
                            g_probe_good_hits = 0;
                            g_clamp_probe_skip = 0;
                            g_clamp_hold_since = 0;
                            /* recovery cautious -- don't immediately go full aggressive */
                            fsm.recovery_cautious_until = time(NULL) + 300;
                            session_plan_build(&fsm, metrics.misc.screen_on);
                            session_plan_apply_prearm(&fsm);
                            asb_log("clamp_probe: vendor clamp lifted (gap=%dkHz/%dkHz, 2+ good, waste=%d), plan rebuilt",
                                    gap0 / 1000, gap1 / 1000, g_action_waste);
                            action_waste_reset();
                        } else {
                            asb_log("clamp_probe: gap ok (gap=%dkHz/%dkHz), need %d more confirm",
                                    gap0 / 1000, gap1 / 1000, 2 - g_probe_good_hits);
                        }
                    } else {
                        g_probe_good_hits = 0;
                        g_action_waste++;
                        if (g_asb_cfg.log_level >= 1)
                            asb_log("clamp_probe: still clamped (gap=%dkHz/%dkHz), hold continues",
                                    gap0 / 1000, gap1 / 1000);
                    }
                }
            }
            {
                static int g_idle_interval = TIMER_IDLE_S;
                int want = fsm.plan.deep_sleep ? TIMER_DEEP_S
                         : fsm.plan.idle_noisy_slow ? TIMER_IDLE_NOISY_S
                         : TIMER_IDLE_S;
                /* Quiet Night Baseline -- even longer ticks in ultra-quiet */
                if (g_quiet_night_active) want = g_asb_cfg.quiet_tick_s;
                if (want != g_idle_interval) {
                    int old = g_idle_interval;
                    arm_timerfd(tfd_idle, want);
                    g_idle_interval = want;
                    if (g_asb_cfg.log_level >= 1)
                        asb_log("adaptive_tick: idle interval %ds->%ds", old, want);
                }
            }
        }
    }

    fsm_flush_state_time(&fsm);
    {
        long total_active = fsm.ses_time_heavy_sec + fsm.ses_time_gaming_sec
                           + fsm.ses_time_sustained_sec;
        int sus_pct = (total_active > 0)
                      ? (int)(fsm.ses_time_sustained_sec * 100 / total_active) : 0;
        int avg_gap = (fsm.ses_gap_samples > 0)
                      ? (int)(fsm.ses_gap_p0_sum / fsm.ses_gap_samples) : 0;
        asb_log("session_end gaming=%d sustained=%d thermal=%d unreachable=%d "
                "t_heavy=%lds t_gaming=%lds t_sustained=%lds "
                "avg_gap=%d max_temp=%d auto_degraded=%d "
                "t2s=%lds t2thermal=%lds t2g=%lds efficiency=%d recovery=%d "
                "bat_deep=%lds bat_light=%lds bat_mod=%lds bat_wake=%d bat_ttd=%lds "
                "sus_pct=%d%%",
                fsm.ses_gaming_entries, fsm.ses_sustained_entries,
                fsm.ses_thermal_entries, fsm.ses_unreachable_entries,
                fsm.ses_time_heavy_sec, fsm.ses_time_gaming_sec,
                fsm.ses_time_sustained_sec,
                avg_gap, fsm.ses_max_temp, fsm.ses_auto_degraded,
                fsm.ses_time_to_first_sus, fsm.ses_time_to_first_thermal,
                fsm.ses_time_to_first_gaming,
                fsm.ses_sustained_efficiency, fsm.ses_recovery_count,
                fsm.bat_time_deep_idle_sec, fsm.bat_time_light_idle_sec,
                fsm.bat_time_moderate_sec, fsm.bat_wake_cycles,
                fsm.bat_time_to_first_deep, sus_pct);
    }
    asb_log("governor stopping");
    close(tfd_active);
    close(tfd_idle);
    close(tfd_hourly);
    if (uefd  >= 0) close(uefd);
    if (sockfd >= 0) close(sockfd);
    close(epfd);
    session_end_self_tune(&fsm);
    fsm_flush_state_time(&fsm);
    persistent_stats_save(&fsm);
    session_history_append_ex(&fsm, "shutdown");
    asb_night_window_save();
    /* Flush what Smart learned before we go.
     *
     * The store is written on a 5-minute timer and nothing wrote it on shutdown, so every
     * restart threw away up to five minutes of learning - and a phone rebooted often
     * enough could stay near zero indefinitely. A user reported exactly that: "does smart
     * mode lose its memory when I restart". Everything else in this block persists on the
     * way out; the learner was the one thing that did not.
     */
    if (g_smart_store_loaded) {
        g_smart_store.last_update_ts = (uint32_t)time(NULL);
        if (asb_smart_store_save_atomic(&g_smart_store, ASB_SMART_STORE_FILE) == 0)
            asb_log("smart store flushed on shutdown");
        asb_smart_appheat_save();
    }
    asb_log("persistent stats saved: sessions=%d degrade=%d", g_pstats.session_count, g_pstats.degrade_count);
    unlink(ASB_SOCK_PATH);
    unlink(PID_FILE);
    if (g_logf) fclose(g_logf);
    return 0;
}
