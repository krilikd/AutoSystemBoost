#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>

/* Foreground app has a history of running this device hot.
 *
 * Written by the smart layer each tick, read by the FSM's thermal path. It lives here
 * because asb_config.h is the one header both of them already include - asb_fsm.h is
 * pulled in before asb_smart.h, so the FSM cannot call the scorer directly, and the unit
 * tests compile asb_smart.h with no FSM at all. Zero when the learner has no opinion, so
 * an unknown app and a freshly installed module both behave exactly as before.
 */
static int g_asb_appheat_hot = 0;


typedef struct {
    int   heavy_gpu_enter;
    float heavy_load_enter;
    float moderate_load_enter;
    int   gpu_idle_trim_pct;    /* trim GPU ceiling by this % in light non-video states (0=off) */
    int   device_bounds_override; /* 1 = apply per-device synthesised bounds from device_bounds.env (0=off, compiled defaults) */
    int   gpu_idle_trim_floor;  /* never trim GPU ceiling below this % (0=default 55) */
    int   gpu_video_busy_min;   /* GPU busy%% that counts as media-heavy/video (0=default 40) */
    /* GPU ceiling (% of max) while video playback is detected. 0 = leave alone.
     * Playback was the highest-drain phase in field captures - higher than gaming - and
     * was the one high-GPU case with no ceiling of its own. */
    int   gpu_video_max_pct;
    /* Opt-in Smart-only guard for a known non-game app that is classified as
     * game-like by sustained CPU+GPU work. It only narrows a GPU ceiling. */
    int   smart_media_guard;
    int   gaming_gpu_enter;
    int   gaming_confirm_ticks;
    int   sustained_gpu_min;
    float sustained_load_min;
    int   sustained_temp_enter;
    /*
     * The value the CONFIG asked for, kept separate from the live one.
     * self_tune raises sustained_temp_enter by 2 (up to 68) whenever a session hits SUSTAINED
     * quickly - sensible when nobody has an opinion, but it silently walks over a user who
     * deliberately chose a LOWER throttle point in the WebUI: they ask to throttle at 50 and
     * the module pushes it back to 52, 54, ...
     */
    int   sustained_temp_enter_user;   /* normalized ceiling consumed by self-tuning */
    int   sustained_temp_ceiling;      /* raw configured ceiling; independent of line order */
    int   sustained_temp_user_override;/* 1 = slider beats the per-profile presets */
    int   sustained_temp_exit;
    float sustained_level;
    /* Set when governor.conf actually contained sustained_level.
     *
     * highload_mode is a preset: it exists to move several related knobs together for
     * someone who has not tuned them. But it overwrote sustained_level unconditionally,
     * so a user who typed 0.62 got 0.78 or 0.85 - in SUSTAINED, the cooling state, the
     * controller then allowed more than the config promised and more than the user asked
     * for. An explicit value must outrank a preset; that is what makes it explicit. */
    int   sustained_level_user_set;
    int   perf_sustained_temp_enter;
    int   perf_sustained_temp_exit;
    float perf_sustained_level;
    int   perf_hot_guard_temp;
    int   perf_hot_guard_ticks;
    int   perf_skin_hot_thresh;
    /* balanced-specific thermal ceiling (softer than perf) */
    int   balanced_sustained_temp_enter;
    int   balanced_sustained_temp_exit;
    int   heavy_gpu_exit;
    int   gaming_gpu_exit;
    int   sustained_gpu_exit;
    int   heavy_min_dwell_s;
    int   sustained_min_dwell_s;
    int   gaming_min_dwell_s;
    int   reassert_heavy_s;
    int   reassert_gaming_s;
    int   msm_perf_boost_only;
    int   thermal_overlay_pct;
    int   thermal_throttle_temp;
    int   thermal_skin_gate;       /* 1=base throttle/veto on skin(shell) temp when present */
    int   thermal_skin_c;          /* skin temp (C) that engages the comfort throttle/veto */
    int   thermal_junction_hard_c; /* junction hard-limit (C) that always throttles (silicon guard) */
    /* Adaptive thermal budget: act before hard throttle when available thermal
     * headroom is shrinking. It only trims ceilings; vendor Thermal HAL keeps
     * precedence and hard guards remain non-optional. */
    int   thermal_budget_enable;
    int   thermal_budget_light_headroom_pct;
    int   thermal_budget_moderate_headroom_pct;
    int   thermal_budget_severe_headroom_pct;
    int   thermal_budget_light_trim_pct;
    int   thermal_budget_moderate_trim_pct;
    int   thermal_budget_severe_trim_pct;
    int   thermal_budget_dwell_s;
    /* Shadow mode calculates/logs policy but never mutates hardware nodes. */
    int   shadow_mode;
    int   gaming_cpu_max_ceiling_khz; /* cap declared scaling_max in GAMING (vendor clamps anyway); 0=off */
    int   camera_hold_enable;      /* 1=hold interactive caps while the camera streams */
    int   camera_busy_pct;         /* camera HAL CPU%% of one core that counts as streaming */
    int   camera_hold_grace_s;   /* keep the hold this long after the pipeline goes quiet */
    /* Longest a camera stream may FORCE the heavy state. 0 = unbounded (old behaviour).
     * A burst is seconds and 4K60 is minutes; a video call is tens of minutes and was
     * pinning interactive caps for all of it. */
    int   camera_hold_max_s;
    /* Percentage of the profile's own ceilings the governor may use, 60..100.
     * The shell path honours this when it writes the uclamp tiers; without it here the
     * governor recomputed caps from the profile bounds every tick and put the full value
     * straight back - so on Smart, where caps ARE recomputed every tick, the setting did
     * nothing at all. Reported as: set to 75, no change in heat. */
    int   perf_ceiling_pct;
    int   gaming_gap_thresh;
    int   gaming_gap_ticks;
    int   gaming_retry_cooldown_s;
    int   gaming_retry_temp_max;
    int   sustained_reentry_cooldown_s;
    int   highload_mode;
    int   auto_degrade_gap_thresh;
    int   auto_degrade_sus_ratio;
    int   auto_degrade_thermal_pct;

    int   bat_fast_idle_s;
    int   bat_light_idle_gpu;
    int   bat_suppress_gaming;
    float bat_heavy_load_enter;
    float bat_moderate_load_enter;
    int   log_level;

    /*
     * thermal_pwrlevel monitoring rate control.
     */
    int   thermal_pwrlevel_div_idle;
    int   thermal_pwrlevel_audit_log_s;

    /* configurable thresholds (previously hardcoded) */
    int   env_iq_quiet;            /* idle quality threshold for quiet env */
    int   env_iq_hostile;          /* idle quality threshold for hostile env */
    float env_wph_noisy;           /* wakes/hour threshold for noisy env */
    float env_wph_hostile;         /* wakes/hour threshold for hostile env */
    int   quiet_entry_ticks;       /* ticks of DEEP_IDLE before quiet mode */
    int   quiet_fast_ticks;        /* ticks with clean-night reward */
    int   quiet_tick_s;            /* tick interval in ultra-quiet mode */
    int   quiet_exit_grace;        /* consecutive noise ticks to exit quiet */
    int   bat_comfort_temp;        /* CPU temp to cap HEAVY in battery */
    int   clamp_economy_after_s;   /* seconds of clamp before economy kicks in */
    int   clamp_thermal_every_n;   /* thermal read frequency under clamp */
    int   action_waste_threshold;  /* waste level that doubles intervals */
    int   virtual_ceiling_alpha;   /* EMA weight for virtual ceiling (0-100, /8) */

    /* balanced-specific thresholds */
    float balanced_heavy_load_enter;    /* load threshold for HEAVY in balanced */
    float balanced_moderate_load_enter; /* load threshold for MODERATE in balanced */
    int   balanced_warmup_grace_s;      /* seconds to suppress sustained after start */
    int   balanced_warmup_bypass_temp;  /* bypass grace if temp already above this */
    int   balanced_warmup_bypass_headroom; /* bypass grace if headroom below this */
    int   thermal_stale_after_s;        /* seconds before temp is considered stale */
    int   soft_clamp_headroom_pct;      /* advisory headroom threshold */
    int   hard_clamp_headroom_pct;      /* actionable headroom threshold */

    /*
     * low-battery auto-switch.
     */
    int   auto_battery_enable;     /* 1=enable feature, 0=disable */
    int   auto_battery_low_pct;    /* trigger threshold (default 20) */
    int   auto_battery_high_pct;   /* restore threshold (default 30) */
    int   auto_battery_min_gap_s;  /* min seconds between auto-switches (default 300) */

    /*
     * night-window quiet_night acceleration.
     */
    int   night_quiet_enable;      /* 1=enable feature, 0=disable */
    int   night_quiet_hour_start;  /* hour 0-23 when night-fast starts (default 23) */
    int   night_quiet_hour_end;    /* hour 0-23 when night-fast ends (default 6) */

    /*
     * V50: per-user night window learning.
     * When night_quiet_auto=1 the governor observes when the screen goes off for the night and
     * when the first sustained morning screen-on happens, EWMA-learns both as minutes-of-day
     * with circular wrap, and (after night_quiet_auto_min_samples nights) replaces the static
     * hour_start/hour_end pair with the learned window.
     */
    int   night_quiet_auto;             /* 1=learn window per user (default 1) */
    /* Deep radio idling inside the learned sleep window. Separate from night_quiet so a
     * user can keep the governor's night behaviour without the modem timing change - the
     * two answer different questions and one of them can delay a poll-based app. */
    int   night_modem_idle;
    int   night_quiet_auto_min_samples; /* nights required before learned window is used (default 3) */

    /*
     * V50: charge-aware layer.
     * While charging, Smart Mode may lean toward performance (screen on, battery cool) and
     * must lean away from it the moment battery temperature says the charger is already
     * heating the pack.
     */
    int   charge_aware_enable;       /* 1=enable feature (default 1) */
    int   cool_gaming;               /* 1=earlier/stronger thermal lean in games, default 1 */
    int   charge_assist_alpha_max;   /* alpha_battery ceiling while assisting, x1000 (default 450) */
    int   charge_temp_warn_dC;       /* batt temp where assist is dropped (default 390 = 39.0C) */
    int   charge_temp_hot_dC;        /* batt temp where cool-charge guard engages (default 415 = 41.5C) */

    /* Smart Mode — additive adaptive layer on top of the profile envelopes.
     * Master on/off lives in /data/adb/asb/smart_mode_enabled (file flag);
     * this field is the runtime mirror of that flag. */
    int   smart_mode_enabled;
    int   smart_conf_low;             /* low threshold x1000, default 350 */
    int   smart_conf_high;            /* high threshold x1000, default 650 */
    int   smart_eff_obs_full;         /* full-confidence eff_obs x100, default 2000 */
    int   smart_pkg_plaintext;        /* 0=hash, 1=plaintext (default 0; debug build forces 1) */
    int   smart_night_start_hour;     /* night override start hour, default 0 */
    int   smart_night_end_hour;       /* night override end hour, default 6 */
    int   smart_interactive_max;      /* bias clamp max x1000, default 150 */
    int   smart_idle_bias_min;        /* bias clamp min x1000, default -200 */
    int   smart_idle_bias_max;        /* bias clamp max x1000, default 200 */
    int   smart_sleep_bias_max;       /* bias clamp max x1000, default 1000 */
    int   smart_net_conservative_max; /* bias clamp max x1000, default 1000 */
    int   smart_battery_bias;         /* extra battery lean added to effective alpha, x1000, default 0 */
    int   smart_debug_log;            /* extra logging for alpha, default 0 */
} asb_runtime_config_t;

/*
 * Skin-anchored thermal decision.
 */
static inline int asb_therm_skin_engage(const asb_runtime_config_t *cfg,
                                        int junction_c, int skin_c) {
    if (!cfg || !cfg->thermal_skin_gate || skin_c <= 20 || skin_c >= 70) return -1;
    return (skin_c >= cfg->thermal_skin_c ||
            junction_c >= cfg->thermal_junction_hard_c) ? 1 : 0;
}

static inline void asb_config_defaults(asb_runtime_config_t *c) {
    memset(c, 0, sizeof(*c));
    c->heavy_gpu_enter     = 35;
    /*
     * HEAVY/MODERATE load thresholds raised for Snapdragon 8 Elite Gen 5.
     */
    c->heavy_load_enter    = 20.0f;
    c->moderate_load_enter = 14.0f;
    c->gpu_idle_trim_pct = 8;
    c->device_bounds_override = 0;
    c->gpu_idle_trim_floor = 55;
    c->gpu_video_busy_min = 40;
    c->gpu_video_max_pct   = 70;
    c->smart_media_guard   = 0;  /* explicit opt-in; legacy behaviour stays unchanged */
    c->gaming_gpu_enter    = 65;
    c->gaming_confirm_ticks = 6;
    c->sustained_gpu_min   = 45;
    c->sustained_load_min  = 4.0f;
    c->sustained_temp_enter= 65;
    c->sustained_temp_enter_user = 65;
    c->sustained_temp_ceiling = 65;
    c->sustained_temp_user_override = 0;
    c->sustained_temp_exit = 55;
    c->perf_sustained_temp_enter = 0;
    c->perf_sustained_temp_exit  = 0;
    c->perf_sustained_level      = 0.0f;
    c->perf_hot_guard_temp       = 0;
    c->perf_hot_guard_ticks      = 0;
    c->perf_skin_hot_thresh      = 0;
    c->balanced_sustained_temp_enter = 0;  /* 0 = use global sustained_temp_enter */
    c->balanced_sustained_temp_exit  = 0;  /* 0 = use global sustained_temp_exit */
    c->heavy_gpu_exit      = 25;
    c->gaming_gpu_exit     = 55;
    c->sustained_gpu_exit  = 35;
    c->heavy_min_dwell_s   = 8;
    c->sustained_min_dwell_s = 24;
    c->gaming_min_dwell_s  = 25;
    c->reassert_heavy_s    = 12;
    c->reassert_gaming_s   = 6;
    c->msm_perf_boost_only = 1;
    c->thermal_overlay_pct   = 20;
    c->thermal_throttle_temp = 60;
    c->thermal_skin_gate = 1;
    c->thermal_skin_c = 47;
    c->thermal_junction_hard_c = 95;
    c->thermal_budget_enable = 1;
    c->thermal_budget_light_headroom_pct = 70;
    c->thermal_budget_moderate_headroom_pct = 45;
    c->thermal_budget_severe_headroom_pct = 25;
    c->thermal_budget_light_trim_pct = 8;
    c->thermal_budget_moderate_trim_pct = 18;
    c->thermal_budget_severe_trim_pct = 32;
    c->thermal_budget_dwell_s = 30;
    c->shadow_mode = 0;
    c->gaming_cpu_max_ceiling_khz = 2400000;
    c->camera_hold_enable   = 1;
    c->camera_busy_pct      = 15;
    c->camera_hold_grace_s  = 20;
    c->camera_hold_max_s   = 180;
    c->perf_ceiling_pct    = 100;
    /*
     * Below HEAVY (0.72), not above it.
     * The device sat there for 24% of all screen-on time and the vendor thermal HAL never
     * clamped once, so nothing external was correcting it.
     */
    c->sustained_level       = 0.62f;
    c->sustained_level_user_set = 0;
    c->gaming_gap_thresh        = 1500000;
    c->gaming_gap_ticks         = 4;
    c->gaming_retry_cooldown_s  = 20;
    c->gaming_retry_temp_max    = 50;
    c->sustained_reentry_cooldown_s = 20;
    c->highload_mode = 0;
    c->auto_degrade_gap_thresh  = 800000;
    c->auto_degrade_sus_ratio   = 2;
    c->auto_degrade_thermal_pct = 45;

    c->bat_fast_idle_s     = 12;
    c->bat_light_idle_gpu  = 10;
    c->bat_suppress_gaming = 1;
    /* same recalibration for battery profile */
    c->bat_heavy_load_enter = 20.0f;     /* was 15 */
    c->bat_moderate_load_enter = 14.0f;  /* was 10 */
    c->log_level = 0;

    /* thermal_pwrlevel monitoring */
    c->thermal_pwrlevel_div_idle      = 3;     /* every 3rd tick in LIGHT_IDLE/MODERATE */
    c->thermal_pwrlevel_audit_log_s   = 3600;  /* hourly audit summary */

    /* defaults */
    c->env_iq_quiet         = 25;
    c->env_iq_hostile       = 10;
    c->env_wph_noisy        = 6.0f;
    c->env_wph_hostile      = 12.0f;
    c->quiet_entry_ticks    = 60;   /* ~10min at 10s ticks */
    c->quiet_fast_ticks     = 30;   /* ~5min with clean-night reward */
    c->quiet_tick_s         = 30;
    c->quiet_exit_grace     = 3;
    c->bat_comfort_temp     = 48;
    c->clamp_economy_after_s = 120;
    c->clamp_thermal_every_n = 3;
    c->action_waste_threshold = 5;
    c->virtual_ceiling_alpha = 7;   /* EMA: (old*7 + new*1)/8 */

    /* balanced-specific */
    c->balanced_heavy_load_enter    = 0;  /* 0 = use global heavy_load_enter */
    c->balanced_moderate_load_enter = 0;  /* 0 = use global moderate_load_enter */
    c->balanced_warmup_grace_s      = 45;
    c->balanced_warmup_bypass_temp  = 60;
    c->balanced_warmup_bypass_headroom = 40;
    c->thermal_stale_after_s        = 60;
    c->soft_clamp_headroom_pct      = 70;
    c->hard_clamp_headroom_pct      = 45;
    c->auto_battery_enable          = 1;
    c->auto_battery_low_pct         = 20;
    c->auto_battery_high_pct        = 30;
    c->auto_battery_min_gap_s       = 300;
    c->night_quiet_enable           = 1;
    c->night_quiet_hour_start       = 23;
    c->night_quiet_hour_end         = 6;
    c->night_quiet_auto             = 1;
    c->night_modem_idle    = 0;
    c->night_quiet_auto_min_samples = 3;
    c->charge_aware_enable          = 1;
    c->cool_gaming                  = 1;
    c->charge_assist_alpha_max      = 450;
    c->charge_temp_warn_dC          = 390;
    c->charge_temp_hot_dC           = 415;

    /* Smart Mode defaults — actual on/off comes from /data/adb/asb/smart_mode_enabled */
    c->smart_mode_enabled           = 0;     /* file flag overrides at boot */
    c->smart_conf_low               = 350;
    c->smart_conf_high              = 650;
    c->smart_eff_obs_full           = 2000;
    c->smart_pkg_plaintext          = 0;
    c->smart_night_start_hour       = 0;
    c->smart_night_end_hour         = 6;
    c->smart_interactive_max        = 150;
    c->smart_idle_bias_min          = -200;
    c->smart_idle_bias_max          = 200;
    c->smart_sleep_bias_max         = 1000;
    c->smart_net_conservative_max   = 1000;
    c->smart_battery_bias           = 0;
    c->smart_debug_log              = 0;
}

static inline char *asb_cfg_trim(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    if (!*s) return s;
    char *e = s + strlen(s) - 1;
    while (e >= s && isspace((unsigned char)*e)) *e-- = '\0';
    return s;
}

static inline int asb_cfg_parse_int_strict(const char *v, int *out) {
    char *end = NULL;
    long parsed;
    if (!v || !*v || !out) return -1;
    errno = 0;
    parsed = strtol(v, &end, 10);
    if (errno == ERANGE || end == v || *end != '\0' ||
        parsed < INT_MIN || parsed > INT_MAX) return -1;
    *out = (int)parsed;
    return 0;
}

static inline int asb_cfg_parse_float_strict(const char *v, float *out) {
    char *end = NULL;
    float parsed;
    if (!v || !*v || !out) return -1;
    errno = 0;
    parsed = strtof(v, &end);
    if (errno == ERANGE || end == v || *end != '\0' || !isfinite(parsed)) return -1;
    *out = parsed;
    return 0;
}

/* Values that directly affect thermal/FSM safety must be syntactically valid before
 * atoi/atof can turn malformed text into an accidental zero or NaN. */
static inline int asb_cfg_validate_critical_syntax(const char *k, const char *v) {
    int parsed_i;
    float parsed_f;
    if (!strcmp(k, "heavy_load_enter") || !strcmp(k, "sustained_load_min") ||
        !strcmp(k, "bat_heavy_load_enter") || !strcmp(k, "moderate_load_enter") ||
        !strcmp(k, "bat_moderate_load_enter") || !strcmp(k, "balanced_heavy_load_enter") ||
        !strcmp(k, "balanced_moderate_load_enter")) {
        return asb_cfg_parse_float_strict(v, &parsed_f);
    }
    if (!strcmp(k, "gaming_confirm_ticks") || !strcmp(k, "gpu_idle_trim_pct") ||
        !strcmp(k, "gpu_video_max_pct") || !strcmp(k, "smart_media_guard") ||
        !strcmp(k, "thermal_throttle_temp") ||
        !strcmp(k, "device_bounds_override") || !strcmp(k, "sustained_temp_enter") ||
        !strcmp(k, "sustained_temp_ceiling") || !strcmp(k, "sustained_temp_exit")) {
        return asb_cfg_parse_int_strict(v, &parsed_i);
    }
    return 0;
}

static inline void asb_cfg_apply_kv(asb_runtime_config_t *c, const char *k, const char *v) {
    if (!strcmp(k, "heavy_gpu_enter")) c->heavy_gpu_enter = atoi(v);
    else if (!strcmp(k, "heavy_load_enter")) c->heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "gaming_gpu_enter")) c->gaming_gpu_enter = atoi(v);
    else if (!strcmp(k, "gaming_confirm_ticks")) c->gaming_confirm_ticks = atoi(v);
    else if (!strcmp(k, "sustained_gpu_min")) c->sustained_gpu_min = atoi(v);
    else if (!strcmp(k, "sustained_load_min")) c->sustained_load_min = (float)atof(v);
    else if (!strcmp(k, "sustained_temp_enter")) c->sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "sustained_temp_user_override")) c->sustained_temp_user_override = atoi(v);
    else if (!strcmp(k, "sustained_temp_ceiling")) {
        /* Keep the raw request independent of line order. It is normalized only after
         * the complete file has been parsed, together with the runtime thermal floor. */
        c->sustained_temp_ceiling = atoi(v);
    }
    else if (!strcmp(k, "sustained_temp_exit"))  c->sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "perf_sustained_temp_enter")) c->perf_sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "perf_sustained_temp_exit"))  c->perf_sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "balanced_sustained_temp_enter")) c->balanced_sustained_temp_enter = atoi(v);
    else if (!strcmp(k, "balanced_sustained_temp_exit"))  c->balanced_sustained_temp_exit  = atoi(v);
    else if (!strcmp(k, "heavy_gpu_exit")) c->heavy_gpu_exit = atoi(v);
    else if (!strcmp(k, "gaming_gpu_exit")) c->gaming_gpu_exit = atoi(v);
    else if (!strcmp(k, "sustained_gpu_exit")) c->sustained_gpu_exit = atoi(v);
    else if (!strcmp(k, "heavy_min_dwell_s")) c->heavy_min_dwell_s = atoi(v);
    else if (!strcmp(k, "sustained_min_dwell_s")) c->sustained_min_dwell_s = atoi(v);
    else if (!strcmp(k, "gaming_min_dwell_s")) c->gaming_min_dwell_s = atoi(v);
    else if (!strcmp(k, "reassert_heavy_s")) c->reassert_heavy_s = atoi(v);
    else if (!strcmp(k, "reassert_gaming_s")) c->reassert_gaming_s = atoi(v);
    else if (!strcmp(k, "msm_perf_boost_only")) c->msm_perf_boost_only = atoi(v);
    else if (!strcmp(k, "thermal_overlay_pct")) c->thermal_overlay_pct = atoi(v);
    else if (!strcmp(k, "thermal_throttle_temp")) c->thermal_throttle_temp = atoi(v);
    else if (!strcmp(k, "thermal_skin_gate")) c->thermal_skin_gate = atoi(v);
    else if (!strcmp(k, "thermal_skin_c")) c->thermal_skin_c = atoi(v);
    else if (!strcmp(k, "thermal_junction_hard_c")) c->thermal_junction_hard_c = atoi(v);
    else if (!strcmp(k, "thermal_budget_enable")) c->thermal_budget_enable = atoi(v);
    else if (!strcmp(k, "thermal_budget_light_headroom_pct")) c->thermal_budget_light_headroom_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_moderate_headroom_pct")) c->thermal_budget_moderate_headroom_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_severe_headroom_pct")) c->thermal_budget_severe_headroom_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_light_trim_pct")) c->thermal_budget_light_trim_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_moderate_trim_pct")) c->thermal_budget_moderate_trim_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_severe_trim_pct")) c->thermal_budget_severe_trim_pct = atoi(v);
    else if (!strcmp(k, "thermal_budget_dwell_s")) c->thermal_budget_dwell_s = atoi(v);
    else if (!strcmp(k, "shadow_mode")) c->shadow_mode = atoi(v);
    else if (!strcmp(k, "gaming_cpu_max_ceiling_khz")) c->gaming_cpu_max_ceiling_khz = atoi(v);
    else if (!strcmp(k, "camera_hold_enable"))   c->camera_hold_enable   = atoi(v);
    else if (!strcmp(k, "camera_busy_pct"))      c->camera_busy_pct      = atoi(v);
    else if (!strcmp(k, "camera_hold_grace_s"))  c->camera_hold_grace_s  = atoi(v);
    else if (!strcmp(k, "camera_hold_max_s"))    c->camera_hold_max_s = atoi(v);
    else if (!strcmp(k, "perf_ceiling_pct")) {
        int _pc = atoi(v);
        /* 65, not 60: below that the weighted trim inverts the ladder.
         *
         * The trim grows with ladder position faster than the raw ceiling does, so at 60%
         * GAMING computes lower than HEAVY - the phone ends up slower under load than at
         * rest. Nobody moving this slider is asking for that, and the WebUI is not the only
         * way a value reaches this file. */
        if (_pc < 65)  _pc = 65;
        if (_pc > 100) _pc = 100;
        c->perf_ceiling_pct = _pc;
    }
    else if (!strcmp(k, "gaming_gap_thresh"))    c->gaming_gap_thresh = atoi(v);
    else if (!strcmp(k, "gaming_gap_ticks"))     c->gaming_gap_ticks  = atoi(v);
    else if (!strcmp(k, "gaming_retry_cooldown_s")) c->gaming_retry_cooldown_s = atoi(v);
    else if (!strcmp(k, "gaming_retry_temp_max"))   c->gaming_retry_temp_max   = atoi(v);
    else if (!strcmp(k, "auto_degrade_gap_thresh")) c->auto_degrade_gap_thresh = atoi(v);
    else if (!strcmp(k, "auto_degrade_sus_ratio"))  c->auto_degrade_sus_ratio  = atoi(v);
    else if (!strcmp(k, "auto_degrade_thermal_pct")) c->auto_degrade_thermal_pct = atoi(v);
    else if (!strcmp(k, "bat_fast_idle_s"))     c->bat_fast_idle_s     = atoi(v);
    else if (!strcmp(k, "bat_light_idle_gpu"))  c->bat_light_idle_gpu  = atoi(v);
    else if (!strcmp(k, "bat_suppress_gaming")) c->bat_suppress_gaming = atoi(v);
    else if (!strcmp(k, "thermal_pwrlevel_div_idle"))    c->thermal_pwrlevel_div_idle    = atoi(v);
    else if (!strcmp(k, "thermal_pwrlevel_audit_log_s")) c->thermal_pwrlevel_audit_log_s = atoi(v);
    else if (!strcmp(k, "bat_heavy_load_enter")) c->bat_heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "moderate_load_enter"))  c->moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "gpu_idle_trim_pct"))    c->gpu_idle_trim_pct = atoi(v);
    else if (!strcmp(k, "device_bounds_override")) c->device_bounds_override = atoi(v);
    else if (!strcmp(k, "gpu_idle_trim_floor"))  c->gpu_idle_trim_floor = atoi(v);
    else if (!strcmp(k, "gpu_video_busy_min"))   c->gpu_video_busy_min = atoi(v);
    else if (!strcmp(k, "gpu_video_max_pct"))    c->gpu_video_max_pct = atoi(v);
    else if (!strcmp(k, "smart_media_guard"))    c->smart_media_guard = atoi(v);
    else if (!strcmp(k, "bat_moderate_load_enter")) c->bat_moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "log_level")) {
        /* User-facing choice, kept readable: stock | 0 | 1 | 2 | 3.
         *
         * atoi() cannot express it - "stock" is not a number, and the digits were
         * renumbered so that 1 is what used to be 0. The shell resolves the choice into
         * log_verbosity below; this line only survives so an old config still parses. */
        c->log_level = atoi(v);
    }
    else if (!strcmp(k, "log_verbosity")) {
        /* What the governor actually uses, written by the shell from log_level. Comes
         * after it in the file, so it wins. */
        c->log_level = atoi(v);
    }
    /* configurable thresholds */
    else if (!strcmp(k, "env_iq_quiet"))          c->env_iq_quiet = atoi(v);
    else if (!strcmp(k, "env_iq_hostile"))        c->env_iq_hostile = atoi(v);
    else if (!strcmp(k, "env_wph_noisy"))         c->env_wph_noisy = (float)atof(v);
    else if (!strcmp(k, "env_wph_hostile"))       c->env_wph_hostile = (float)atof(v);
    else if (!strcmp(k, "quiet_entry_ticks"))     c->quiet_entry_ticks = atoi(v);
    else if (!strcmp(k, "quiet_fast_ticks"))      c->quiet_fast_ticks = atoi(v);
    else if (!strcmp(k, "quiet_tick_s"))          c->quiet_tick_s = atoi(v);
    else if (!strcmp(k, "quiet_exit_grace"))      c->quiet_exit_grace = atoi(v);
    else if (!strcmp(k, "bat_comfort_temp"))      c->bat_comfort_temp = atoi(v);
    else if (!strcmp(k, "clamp_economy_after_s")) c->clamp_economy_after_s = atoi(v);
    else if (!strcmp(k, "clamp_thermal_every_n")) {
        /* Clamped, because this value is used as a modulus.
         *
         * atoi("0") is 0, and the governor does `skip % clamp_thermal_every_n` - integer
         * division by zero, which is a crash, not a bad reading. Anyone editing the config
         * by hand can reach it, and a truncated or corrupt file reaches it by accident.
         *
         * 1 means "every tick", which is the safe end of this setting: it costs reads and
         * changes no behaviour. 60 is well past any useful skip interval. */
        int _cn = atoi(v);
        if (_cn < 1)  _cn = 1;
        if (_cn > 60) _cn = 60;
        c->clamp_thermal_every_n = _cn;
    }
    else if (!strcmp(k, "action_waste_threshold"))c->action_waste_threshold = atoi(v);
    else if (!strcmp(k, "virtual_ceiling_alpha")) c->virtual_ceiling_alpha = atoi(v);
    else if (!strcmp(k, "balanced_heavy_load_enter"))    c->balanced_heavy_load_enter = (float)atof(v);
    else if (!strcmp(k, "balanced_moderate_load_enter")) c->balanced_moderate_load_enter = (float)atof(v);
    else if (!strcmp(k, "balanced_warmup_grace_s"))      c->balanced_warmup_grace_s = atoi(v);
    else if (!strcmp(k, "balanced_warmup_bypass_temp"))  c->balanced_warmup_bypass_temp = atoi(v);
    else if (!strcmp(k, "balanced_warmup_bypass_headroom")) c->balanced_warmup_bypass_headroom = atoi(v);
    else if (!strcmp(k, "thermal_stale_after_s"))        c->thermal_stale_after_s = atoi(v);
    else if (!strcmp(k, "soft_clamp_headroom_pct"))      c->soft_clamp_headroom_pct = atoi(v);
    else if (!strcmp(k, "hard_clamp_headroom_pct"))      c->hard_clamp_headroom_pct = atoi(v);
    else if (!strcmp(k, "auto_battery_enable"))     c->auto_battery_enable     = atoi(v);
    else if (!strcmp(k, "auto_battery_low_pct"))    c->auto_battery_low_pct    = atoi(v);
    else if (!strcmp(k, "auto_battery_high_pct"))   c->auto_battery_high_pct   = atoi(v);
    else if (!strcmp(k, "auto_battery_min_gap_s"))  c->auto_battery_min_gap_s  = atoi(v);
    else if (!strcmp(k, "night_quiet_enable"))      c->night_quiet_enable      = atoi(v);
    else if (!strcmp(k, "night_quiet_hour_start"))  c->night_quiet_hour_start  = atoi(v);
    else if (!strcmp(k, "night_quiet_hour_end"))    c->night_quiet_hour_end    = atoi(v);
    else if (!strcmp(k, "night_quiet_auto"))             c->night_quiet_auto             = atoi(v);
    else if (!strcmp(k, "night_modem_idle"))     c->night_modem_idle = atoi(v);
    else if (!strcmp(k, "night_quiet_auto_min_samples")) c->night_quiet_auto_min_samples = atoi(v);
    else if (!strcmp(k, "charge_aware_enable"))     c->charge_aware_enable     = atoi(v);
    else if (!strcmp(k, "cool_gaming"))             c->cool_gaming             = atoi(v);
    else if (!strcmp(k, "charge_assist_alpha_max")) c->charge_assist_alpha_max = atoi(v);
    else if (!strcmp(k, "charge_temp_warn_dC"))     c->charge_temp_warn_dC     = atoi(v);
    else if (!strcmp(k, "charge_temp_hot_dC"))      c->charge_temp_hot_dC      = atoi(v);
    else if (!strcmp(k, "sustained_reentry_cooldown_s")) c->sustained_reentry_cooldown_s = atoi(v);
    else if (!strcmp(k, "highload_mode")) {
        if (!strcmp(v, "burst"))   c->highload_mode = 1;
        else if (!strcmp(v, "stable")) c->highload_mode = 2;
        else if (!strcmp(v, "auto"))   c->highload_mode = 3;
        else c->highload_mode = 0;
    }
    else if (!strcmp(k, "sustained_level")) {
        float v_f = (float)atof(v);
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->sustained_level = v_f;
        c->sustained_level_user_set = 1;
    }
    else if (!strcmp(k, "perf_sustained_level")) {
        float v_f = (float)atof(v);
        if (v_f < 0.50f) v_f = 0.50f;
        if (v_f > 0.95f) v_f = 0.95f;
        c->perf_sustained_level = v_f;
    }
    else if (!strcmp(k, "perf_hot_guard_temp")) c->perf_hot_guard_temp = atoi(v);
    else if (!strcmp(k, "perf_hot_guard_ticks")) c->perf_hot_guard_ticks = atoi(v);
    else if (!strcmp(k, "perf_skin_hot_thresh")) c->perf_skin_hot_thresh = atoi(v);

    /* Smart Mode */
    else if (!strcmp(k, "smart_mode_enabled"))      c->smart_mode_enabled = atoi(v);
    else if (!strcmp(k, "smart_conf_low"))          c->smart_conf_low = atoi(v);
    else if (!strcmp(k, "smart_conf_high"))         c->smart_conf_high = atoi(v);
    else if (!strcmp(k, "smart_eff_obs_full"))      c->smart_eff_obs_full = atoi(v);
    else if (!strcmp(k, "smart_pkg_plaintext"))     c->smart_pkg_plaintext = atoi(v);
    else if (!strcmp(k, "smart_night_start_hour"))  c->smart_night_start_hour = atoi(v);
    else if (!strcmp(k, "smart_night_end_hour"))    c->smart_night_end_hour = atoi(v);
    else if (!strcmp(k, "smart_interactive_max"))   c->smart_interactive_max = atoi(v);
    else if (!strcmp(k, "smart_idle_bias_min"))     c->smart_idle_bias_min = atoi(v);
    else if (!strcmp(k, "smart_idle_bias_max"))     c->smart_idle_bias_max = atoi(v);
    else if (!strcmp(k, "smart_sleep_bias_max"))    c->smart_sleep_bias_max = atoi(v);
    else if (!strcmp(k, "smart_net_conservative_max")) c->smart_net_conservative_max = atoi(v);
    else if (!strcmp(k, "smart_battery_bias"))      c->smart_battery_bias = atoi(v);
    else if (!strcmp(k, "smart_debug_log"))         c->smart_debug_log = atoi(v);
}

/*
 * Validate fields that can destabilize the FSM or turn timerfds into a silent
 * no-op. The WebUI is not a trust boundary: imports, manual edits and an
 * interrupted write can all create a configuration the UI would never emit.
 */
static inline int asb_config_validate(const asb_runtime_config_t *c) {
    if (!c) return -1;
    if (c->sustained_temp_enter < 40 || c->sustained_temp_enter > 70 ||
        c->sustained_temp_ceiling < c->sustained_temp_enter ||
        c->sustained_temp_ceiling > 70 ||
        c->sustained_temp_exit < 30 ||
        c->sustained_temp_exit >= c->sustained_temp_enter) return -2;
    if (c->perf_sustained_temp_enter > 0 &&
        (c->perf_sustained_temp_enter < 40 || c->perf_sustained_temp_enter > 75 ||
         c->perf_sustained_temp_exit < 30 ||
         c->perf_sustained_temp_exit >= c->perf_sustained_temp_enter)) return -3;
    if (c->balanced_sustained_temp_enter > 0 &&
        (c->balanced_sustained_temp_enter < 40 || c->balanced_sustained_temp_enter > 75 ||
         c->balanced_sustained_temp_exit < 30 ||
         c->balanced_sustained_temp_exit >= c->balanced_sustained_temp_enter)) return -4;
    if (c->quiet_tick_s < 5 || c->quiet_tick_s > 3600 ||
        c->quiet_entry_ticks < 1 || c->quiet_entry_ticks > 720 ||
        c->quiet_exit_grace < 1 || c->quiet_exit_grace > 120) return -5;
    if (c->night_quiet_hour_start < 0 || c->night_quiet_hour_start > 23 ||
        c->night_quiet_hour_end < 0 || c->night_quiet_hour_end > 23) return -6;
    if (c->heavy_min_dwell_s < 1 || c->heavy_min_dwell_s > 3600 ||
        c->sustained_min_dwell_s < 1 || c->sustained_min_dwell_s > 3600 ||
        c->gaming_min_dwell_s < 1 || c->gaming_min_dwell_s > 3600 ||
        c->reassert_heavy_s < 1 || c->reassert_heavy_s > 3600 ||
        c->reassert_gaming_s < 1 || c->reassert_gaming_s > 3600) return -7;
    if (c->perf_hot_guard_ticks < 0 || c->perf_hot_guard_ticks > 120 ||
        c->camera_hold_max_s < 0 || c->camera_hold_max_s > 7200) return -8;
    if (c->auto_battery_low_pct < 1 || c->auto_battery_high_pct > 100 ||
        c->auto_battery_low_pct >= c->auto_battery_high_pct ||
        c->auto_battery_min_gap_s < 0 || c->auto_battery_min_gap_s > 86400) return -9;

    /* These values directly feed thermal caps. Never accept a configuration
     * that could turn a safety cap into zero/negative math or silently disable
     * the emergency guard. The shell writer has the same contract, but manual
     * edits and imports are not a trust boundary. */
    if (c->thermal_overlay_pct < 0 || c->thermal_overlay_pct > 80 ||
        (c->thermal_skin_gate != 0 && c->thermal_skin_gate != 1) ||
        c->thermal_skin_c < 30 || c->thermal_skin_c > 65 ||
        c->thermal_junction_hard_c < 70 || c->thermal_junction_hard_c > 110 ||
        c->thermal_junction_hard_c <= c->thermal_skin_c) return -10;
    if ((c->thermal_budget_enable != 0 && c->thermal_budget_enable != 1) ||
        c->thermal_budget_light_headroom_pct < 30 || c->thermal_budget_light_headroom_pct > 95 ||
        c->thermal_budget_moderate_headroom_pct < 20 || c->thermal_budget_moderate_headroom_pct >= c->thermal_budget_light_headroom_pct ||
        c->thermal_budget_severe_headroom_pct < 10 || c->thermal_budget_severe_headroom_pct >= c->thermal_budget_moderate_headroom_pct ||
        c->thermal_budget_light_trim_pct < 0 || c->thermal_budget_light_trim_pct > 30 ||
        c->thermal_budget_moderate_trim_pct < c->thermal_budget_light_trim_pct || c->thermal_budget_moderate_trim_pct > 45 ||
        c->thermal_budget_severe_trim_pct < c->thermal_budget_moderate_trim_pct || c->thermal_budget_severe_trim_pct > 60 ||
        c->thermal_budget_dwell_s < 5 || c->thermal_budget_dwell_s > 600 ||
        (c->shadow_mode != 0 && c->shadow_mode != 1)) return -11;
    if (c->gaming_cpu_max_ceiling_khz < 0 ||
        c->gaming_cpu_max_ceiling_khz > 5000000 ||
        (c->camera_hold_enable != 0 && c->camera_hold_enable != 1) ||
        c->camera_busy_pct < 1 || c->camera_busy_pct > 100 ||
        c->camera_hold_grace_s < 0 || c->camera_hold_grace_s > 600) return -12;
    if (c->sustained_temp_user_override != 0 &&
        c->sustained_temp_user_override != 1) return -13;
    if (c->smart_conf_low < 0 || c->smart_conf_low > 999 ||
        c->smart_conf_high < 1 || c->smart_conf_high > 1000 ||
        c->smart_conf_low >= c->smart_conf_high ||
        c->smart_eff_obs_full < 1 || c->smart_eff_obs_full > 10000) return -14;
    if (!isfinite(c->heavy_load_enter) || c->heavy_load_enter < 0.1f || c->heavy_load_enter > 1000.0f ||
        !isfinite(c->sustained_load_min) || c->sustained_load_min < 0.1f || c->sustained_load_min > 1000.0f ||
        c->gaming_confirm_ticks < 1 || c->gaming_confirm_ticks > 120 ||
        c->gpu_idle_trim_pct < 0 || c->gpu_idle_trim_pct > 90 ||
        c->gpu_video_max_pct < 0 || c->gpu_video_max_pct > 100 ||
        (c->smart_media_guard != 0 && c->smart_media_guard != 1) ||
        c->thermal_throttle_temp < 30 || c->thermal_throttle_temp > 110 ||
        (c->device_bounds_override != 0 && c->device_bounds_override != 1)) return -15;
    return 0;
}

/*
 * Every configuration key must appear once. Previously the native reader used
 * the final duplicate while shell readers used `grep | head -1`; a single
 * partially-written/imported file could therefore give the daemon and shell
 * mutually incompatible thermal and performance policies.
 */
static inline int asb_config_load_file(const char *path, asb_runtime_config_t *c) {
    enum { ASB_CFG_MAX_KEYS = 192, ASB_CFG_KEY_LEN = 64 };
    char seen[ASB_CFG_MAX_KEYS][ASB_CFG_KEY_LEN];
    int seen_n = 0;
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *s = asb_cfg_trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *k = asb_cfg_trim(s);
        char *v = asb_cfg_trim(eq + 1);
        char *hash = strchr(v, '#');
        if (hash) *hash = '\0';
        v = asb_cfg_trim(v);
        if (!*k) { fclose(f); return -2; }
        for (int i = 0; i < seen_n; i++) {
            if (!strcmp(seen[i], k)) { fclose(f); return -3; }
        }
        if (seen_n >= ASB_CFG_MAX_KEYS) { fclose(f); return -4; }
        snprintf(seen[seen_n], ASB_CFG_KEY_LEN, "%s", k);
        seen_n++;
        if (asb_cfg_validate_critical_syntax(k, v) != 0) { fclose(f); return -5; }
        asb_cfg_apply_kv(c, k, v);
    }
    fclose(f);
    /* Resolve the thermal contract after all keys are known. The floor is a runtime
     * safety fact, not a mutation of governor.conf; its interaction with the ceiling
     * must therefore be independent of key order in the persisted configuration. */
    {
        FILE *ff = fopen("/data/adb/asb/thermal_floor", "r");
        if (ff) {
            int floor_c = 0;
            if (fscanf(ff, "%d", &floor_c) == 1 && floor_c > 0 && floor_c <= 70 &&
                c->sustained_temp_enter < floor_c) c->sustained_temp_enter = floor_c;
            fclose(ff);
        }
    }
    if (c->sustained_temp_ceiling < 40 || c->sustained_temp_ceiling > 70) return -5;
    if (c->sustained_temp_ceiling < c->sustained_temp_enter)
        c->sustained_temp_ceiling = c->sustained_temp_enter;
    c->sustained_temp_enter_user = c->sustained_temp_ceiling;
    return asb_config_validate(c);
}

static inline void asb_config_apply_highload_mode(asb_runtime_config_t *c) {
    if (c->highload_mode == 1 || c->highload_mode == 3) {
        c->gaming_gap_ticks             = 3;
        c->gaming_retry_cooldown_s      = 20;
        c->gaming_retry_temp_max        = 50;
        /* Preset value only when the user has not set one of their own. */
        if (!c->sustained_level_user_set) c->sustained_level = 0.85f;
        c->sustained_reentry_cooldown_s = 10;
    } else if (c->highload_mode == 2) {
        c->gaming_gap_ticks             = 4;
        c->gaming_retry_cooldown_s      = 35;
        c->gaming_retry_temp_max        = 45;
        if (!c->sustained_level_user_set) c->sustained_level = 0.78f;
        c->sustained_reentry_cooldown_s = 25;
    }
}

static inline void asb_config_defaults_highload(asb_runtime_config_t *c) {
    c->highload_mode = 0;
}

static inline void asb_config_apply_burst_override(asb_runtime_config_t *c) {
    c->highload_mode             = 3;
    c->gaming_gap_ticks          = 3;
    c->gaming_retry_cooldown_s      = 20;
    c->gaming_retry_temp_max        = 47;
    if (!c->sustained_level_user_set) c->sustained_level = 0.82f;
    c->sustained_reentry_cooldown_s = 20;
}

static inline void asb_config_apply_stable_override(asb_runtime_config_t *c) {
    c->highload_mode                = 2;
    c->gaming_gap_ticks             = 4;
    c->gaming_retry_cooldown_s      = 35;
    c->gaming_retry_temp_max        = 45;
    if (!c->sustained_level_user_set) c->sustained_level = 0.78f;
    c->sustained_reentry_cooldown_s = 25;
}

static inline int asb_config_profile_sustained_temp_enter(const asb_runtime_config_t *c, int profile_idx) {
    /*
     * An explicit user setting outranks every profile preset.
     */
    if (c->sustained_temp_user_override) return c->sustained_temp_enter;
    if (profile_idx == 2 && c->perf_sustained_temp_enter > 0) return c->perf_sustained_temp_enter;
    if (profile_idx == 1 && c->balanced_sustained_temp_enter > 0) return c->balanced_sustained_temp_enter;
    /* PROFILE_SMART (3): use balanced thresholds — Smart must never run
     * with thermal envelope hotter than balanced. */
    if (profile_idx == 3 && c->balanced_sustained_temp_enter > 0) return c->balanced_sustained_temp_enter;
    return c->sustained_temp_enter;
}

static inline int asb_config_profile_sustained_temp_exit(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_sustained_temp_exit > 0) return c->perf_sustained_temp_exit;
    if (profile_idx == 1 && c->balanced_sustained_temp_exit > 0) return c->balanced_sustained_temp_exit;
    if (profile_idx == 3 && c->balanced_sustained_temp_exit > 0) return c->balanced_sustained_temp_exit;
    return c->sustained_temp_exit;
}

static inline float asb_config_profile_sustained_level(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_sustained_level >= 0.50f) return c->perf_sustained_level;
    return c->sustained_level;
}

static inline int asb_config_profile_hot_guard_temp(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_hot_guard_temp > 0) return c->perf_hot_guard_temp;
    return 0;
}

static inline int asb_config_profile_hot_guard_ticks(const asb_runtime_config_t *c, int profile_idx) {
    if (profile_idx == 2 && c->perf_hot_guard_ticks > 0) return c->perf_hot_guard_ticks;
    return 0;
}

static inline int asb_config_auto_should_degrade(
        const asb_runtime_config_t *c,
        int avg_gap_p0, int gaming_entries, int sustained_entries,
        long time_heavy, long time_gaming, long time_sustained,
        int already_degraded)
{
    if (c->highload_mode != 3 || already_degraded) return 0;

    if (gaming_entries >= 2) {
        int gap_bad   = (c->auto_degrade_gap_thresh > 0 &&
                         avg_gap_p0 > c->auto_degrade_gap_thresh);
        int ratio_bad = (c->auto_degrade_sus_ratio  > 0 &&
                         sustained_entries >= gaming_entries * c->auto_degrade_sus_ratio);
        if (gap_bad && ratio_bad) return 1;
    }

    if (c->auto_degrade_thermal_pct > 0) {
        long total = time_heavy + time_gaming + time_sustained;
        if (total >= 120 && time_sustained > 0) {
            int sus_pct = (int)(time_sustained * 100 / total);
            if (sus_pct >= c->auto_degrade_thermal_pct) return 1;
        }
    }

    if (avg_gap_p0 > 2000000 && gaming_entries >= 3) return 1;

    return 0;
}
