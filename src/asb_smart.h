#ifndef ASB_SMART_H
#define ASB_SMART_H

#include "asb_config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <ctype.h>
#include <dirent.h>

#include "asb_smart_defs.h"

typedef struct {
    uint32_t bucket_id;
    uint32_t observations_raw;
    uint32_t last_seen_ts;

    uint16_t eff_obs_x100;
    uint16_t conf_x1000;

    uint16_t alpha_battery_x1000;
    int16_t  interactive_bonus_x1000;
    int16_t  idle_bias_x1000;
    uint16_t sleep_bias_x1000;
    uint16_t net_conservative_x1000;

    uint16_t avg_idle_q_x10;
    uint16_t avg_wph_x10;
    uint16_t avg_drain_pctph_x10;
    uint16_t avg_max_temp_x10;
} asb_smart_bucket_t;

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t bucket_count;
    uint32_t last_update_ts;
    uint32_t reserved;
    asb_smart_bucket_t buckets[ASB_SMART_BUCKETS];
} asb_smart_store_t;

typedef struct {
    int enabled;
    int fresh_install_default;

    int bucket_id;
    int prev_bucket_id;
    int is_weekend;
    int daypart;
    int prev_daypart;
    int fallback_level;

    int app_hint;
    uint64_t app_hash;
    uint64_t app_hash_session_top;
    int app_hint_session_top;
    time_t app_cache_last_refresh;
    char app_pkg_cached[64];

    int night_safe_override;
    int thermal_veto;
    int low_battery_override;
    int thermal_trend_bump;
    int budget_severity;
    int budget_pred_h_x10;

    /* V50 charge-aware layer outputs */
    int charge_assist;        /* 1 = leaning toward performance because plugged + cool */
    int charge_cool_guard;    /* 1 = leaning toward battery because pack is hot while charging */
    int charge_power_class;   /* ASB_CHARGE_CLASS_* */
    int charge_power_w_x10;   /* estimated charge power, W x10, observability only */

    int conf_x1000;
    int alpha_battery_x1000;
    /* Echo of the learned history that shaped this decision. Not used for control - it
     * exists so a report can say why alpha moved instead of only that it did. */
    int bucket_temp_x10;
    int bucket_drain_x10;
    /* The thresholds actually in force - learned from this device, or the fallback while
     * it is still gathering. Printing them is the only way to tell one from the other. */
    int therm_warm_x10;
    int therm_cool_x10;
    int interactive_bonus_x1000;
    int idle_bias_x1000;
    int sleep_bias_x1000;
    int net_conservative_x1000;

    time_t last_slot_update_ts;
    int last_conf_tier;
    int last_charging;
    int last_app_hint_tier;
    int last_night_override;
    int last_thermal_veto;

    time_t smoothing_start_ts;
    int smoothing_active;
    uint16_t smoothing_from_alpha_x1000;
    uint16_t smoothing_to_alpha_x1000;
    int exact_bucket_hits;
    int fallback_hits;
} asb_smart_runtime_t;

static inline int asb_clamp_int(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline uint16_t asb_clamp_u16(int v, int lo, int hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (uint16_t)v;
}

static inline int16_t asb_clamp_i16(int v, int lo, int hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (int16_t)v;
}

static int asb_smart_daypart_now(time_t now) {
    struct tm tmv;
    struct tm *tmp;
#if defined(_GNU_SOURCE) || defined(_POSIX_C_SOURCE)
    tmp = localtime_r(&now, &tmv);
#else
    tmp = localtime(&now);
    if (tmp) tmv = *tmp;
#endif
    if (!tmp) return ASB_DAYPART_DAY;
    int h = tmv.tm_hour;
    if (h <  ASB_SMART_DAYPART_WAKE_START) return ASB_DAYPART_SLEEP;
    if (h <  ASB_SMART_DAYPART_MORN_START) return ASB_DAYPART_WAKE;
    if (h <  ASB_SMART_DAYPART_DAY_START)  return ASB_DAYPART_MORN;
    if (h <  ASB_SMART_DAYPART_EVE_START)  return ASB_DAYPART_DAY;
    if (h <  ASB_SMART_DAYPART_LATE_START) return ASB_DAYPART_EVE;
    return ASB_DAYPART_LATE;
}

static int asb_smart_is_weekend(time_t now) {
    struct tm tmv;
    struct tm *tmp;
#if defined(_GNU_SOURCE) || defined(_POSIX_C_SOURCE)
    tmp = localtime_r(&now, &tmv);
#else
    tmp = localtime(&now);
    if (tmp) tmv = *tmp;
#endif
    if (!tmp) return 0;
    return (tmv.tm_wday == 0 || tmv.tm_wday == 6) ? 1 : 0;
}

static uint32_t asb_smart_bucket_id(int daypart, int is_weekend) {
    if (daypart < 0 || daypart >= ASB_SMART_DAYPARTS) daypart = ASB_DAYPART_DAY;
    if (is_weekend != 0 && is_weekend != 1) is_weekend = 0;
    return (uint32_t)(daypart * 2 + is_weekend);
}

__attribute__((unused))
static uint64_t asb_smart_pkg_hash64(const char *pkg) {
    if (!pkg || !*pkg) return 0ull;
    /* FNV-1a 64-bit */
    uint64_t h = 0xcbf29ce484222325ull;
    while (*pkg) {
        h ^= (uint64_t)(unsigned char)(*pkg++);
        h *= 0x100000001b3ull;
    }
    return h;
}

__attribute__((unused))
static int asb_smart_app_hint_from_pkg(const char *pkg) {
    if (!pkg || !*pkg) return ASB_APP_IDLE;

    /* Prefix table — most specific matches first. */
    struct map_entry { const char *prefix; int hint; };
    static const struct map_entry T[] = {
        /* Known game publishers + popular titles. */
        { "com.activision.callofduty", ASB_APP_GAMING },
        { "com.activision.",           ASB_APP_GAMING },
        { "com.tencent.tmgp.",         ASB_APP_GAMING },
        { "com.tencent.ig",            ASB_APP_GAMING },
        { "com.tencent.cod",           ASB_APP_GAMING },
        { "com.pubg.",                 ASB_APP_GAMING },
        { "com.miHoYo.",               ASB_APP_GAMING },
        { "com.HoYoverse.",            ASB_APP_GAMING },
        { "com.dts.freefire",          ASB_APP_GAMING },
        { "com.garena.",               ASB_APP_GAMING },
        { "com.gameloft.",             ASB_APP_GAMING },
        { "com.supercell.",            ASB_APP_GAMING },
        { "com.epicgames.",            ASB_APP_GAMING },
        { "com.ea.gp.",                ASB_APP_GAMING },
        { "com.ea.game.",              ASB_APP_GAMING },
        { "com.king.candycrush",       ASB_APP_HEAVY  },
        { "com.king.",                 ASB_APP_HEAVY  },
        { "com.axlebolt.standoff",     ASB_APP_GAMING },
        { "com.netease.",              ASB_APP_GAMING },
        { "com.riotgames.",            ASB_APP_GAMING },
        { "com.mobile.legends",        ASB_APP_GAMING },
        { "com.callofduty.",           ASB_APP_GAMING },
        { "com.codm.",                 ASB_APP_GAMING },
        { "com.warzone.",              ASB_APP_GAMING },
        { "com.adobe.lrmobile",        ASB_APP_HEAVY  },
        { "com.adobe.psmobile",        ASB_APP_HEAVY  },
        { "com.adobe.premiere",        ASB_APP_HEAVY  },
        { "com.google.android.apps.maps", ASB_APP_HEAVY },
        { "com.google.earth",          ASB_APP_HEAVY  },
        { "com.google.android.youtube",ASB_APP_MEDIUM },
        { "com.netflix.mediaclient",   ASB_APP_MEDIUM },
        { "com.spotify.music",         ASB_APP_MEDIUM },
        { "com.amazon.avod",           ASB_APP_MEDIUM },
        { "com.android.chrome",        ASB_APP_MEDIUM },
        { "com.brave.browser",         ASB_APP_MEDIUM },
        { "com.opera.browser",         ASB_APP_MEDIUM },
        { "org.mozilla.firefox",       ASB_APP_MEDIUM },
        { "com.yandex.browser",        ASB_APP_MEDIUM },
        { "com.microsoft.emmx",        ASB_APP_MEDIUM },
        { "com.zhiliaoapp.musically",  ASB_APP_MEDIUM },
        { "com.ss.android.ugc.trill",  ASB_APP_MEDIUM },
        { "tv.danmaku.bili",           ASB_APP_MEDIUM },
        { "com.google.android.gm",     ASB_APP_LIGHT  },
        { "org.telegram.",             ASB_APP_LIGHT  },
        { "org.thunderdog.",           ASB_APP_LIGHT  },
        { "com.whatsapp",              ASB_APP_LIGHT  },
        { "com.discord",               ASB_APP_LIGHT  },
        { "com.facebook.katana",       ASB_APP_LIGHT  },
        { "com.instagram.android",     ASB_APP_LIGHT  },
        { "com.twitter.android",       ASB_APP_LIGHT  },
        { "com.viber.voip",            ASB_APP_LIGHT  },
        { "com.google.android.apps.messaging", ASB_APP_LIGHT },
        { "ru.ok.android",             ASB_APP_LIGHT  },
        { "com.vkontakte.android",     ASB_APP_LIGHT  },
        { NULL, 0 }
    };
    for (int i = 0; T[i].prefix; i++) {
        size_t pl = strlen(T[i].prefix);
        if (strncmp(pkg, T[i].prefix, pl) == 0) return T[i].hint;
    }

    /* Substring fallback — covers regional variants, beta builds, repackaged
     * games. Searches anywhere in the package id (not just prefix). */
    static const struct map_entry SUB[] = {
        { "callofduty",   ASB_APP_GAMING },
        { ".shooter",     ASB_APP_GAMING },
        { ".cod",         ASB_APP_GAMING },
        { ".codm",        ASB_APP_GAMING },
        { ".pubg",        ASB_APP_GAMING },
        { ".battlefield", ASB_APP_GAMING },
        { "freefire",     ASB_APP_GAMING },
        { "genshin",      ASB_APP_GAMING },
        { "fortnite",     ASB_APP_GAMING },
        { "warzone",      ASB_APP_GAMING },
        { "minecraft",    ASB_APP_HEAVY  },
        { "roblox",       ASB_APP_HEAVY  },
        { ".browser",     ASB_APP_MEDIUM },
        { NULL, 0 }
    };
    for (int i = 0; SUB[i].prefix; i++) {
        if (strstr(pkg, SUB[i].prefix)) return SUB[i].hint;
    }
    return ASB_APP_MEDIUM;
}

/* A deliberately narrow, affirmative media list for the opt-in Smart Media Guard.
 * Unknown packages are NOT treated as media: reducing a new game's GPU headroom from a
 * generic name would violate the guard's safety contract. This only identifies apps whose
 * known purpose matches stream/feed/browser playback; package detection remains local. */
static int asb_smart_pkg_is_media_candidate(const char *pkg) {
    static const char *const P[] = {
        "com.google.android.youtube", "com.netflix.mediaclient", "com.spotify.music",
        "com.amazon.avod", "com.android.chrome", "com.brave.browser", "com.opera.browser",
        "org.mozilla.firefox", "com.yandex.browser", "com.microsoft.emmx",
        "com.zhiliaoapp.musically", "com.ss.android.ugc.trill", "tv.danmaku.bili",
        "com.instagram.android", "com.facebook.katana", "com.twitter.android",
        "com.vkontakte.android", "ru.ok.android", NULL
    };
    if (!pkg || !*pkg) return 0;
    for (int i = 0; P[i]; i++) {
        size_t n = strlen(P[i]);
        if (strncmp(pkg, P[i], n) == 0) return 1;
    }
    return 0;
}

typedef enum {
    ASB_PKG_OK = 0,
    ASB_PKG_MISSING = 1,
    ASB_PKG_STALE = 2,
    ASB_PKG_SYS_UI = 3,
} asb_pkg_status_t;

/* Cache for last known good package — used as fallback if all sources fail.
 * 60s TTL: long enough to ride out transient deny/hang, short enough that
 * stale data is bounded. */
typedef struct {
    char     pkg[128];
    uint64_t hash;
    int      hint;
    time_t   last_seen_ts;
    int      last_source;   /* 1=cmd, 2=activity, 3=window */
} asb_pkg_cache_t;

static asb_pkg_cache_t g_pkg_cache = {0};

/* Filter: known system UI/launcher packages should not be treated as
 * "user is doing X" — they're background scaffold. */
static int asb_smart_is_system_ui(const char *pkg) {
    if (!pkg || !*pkg) return 0;
    static const char *sys_pkgs[] = {
        "com.android.systemui",
        "com.oplus.launcher",
        "com.oneplus.launcher",
        "com.android.launcher",
        "com.google.android.apps.nexuslauncher",
        "com.miui.home",
        "com.sec.android.app.launcher",
        "android",
        NULL
    };
    for (int i = 0; sys_pkgs[i]; i++) {
        if (strncmp(pkg, sys_pkgs[i], strlen(sys_pkgs[i])) == 0) return 1;
    }
    return 0;
}

/*
 * Strip activity component suffix from "com.foo/.MainActivity" → "com.foo"
 */
static void asb_smart_strip_activity(char *s) {
    if (!s) return;
    char *slash = strchr(s, '/');
    if (slash) *slash = '\0';
    /* Strip whitespace */
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r')) {
        *--e = '\0';
    }
}

/*
 * Source 1: cmd activity get-current-user-id (Android 10+).
 */
static int asb_smart_pkg_via_activity_top(char *out_pkg, size_t outsz) {
    if (!out_pkg || outsz == 0) return 0;
    out_pkg[0] = '\0';
    FILE *p = popen("timeout 1 dumpsys activity top 2>/dev/null | grep -m1 'ACTIVITY '", "r");
    if (!p) return 0;
    char line[512];
    int got = 0;
    if (fgets(line, sizeof(line), p)) {
        /*
         * line: " ACTIVITY com.activision.callofduty.shooter/.ui...
         */
        char *act = strstr(line, "ACTIVITY ");
        if (act) {
            act += 9;
            /* copy up to first space */
            int i = 0;
            while (*act && *act != ' ' && *act != '\t' && i < (int)outsz - 1) {
                out_pkg[i++] = *act++;
            }
            out_pkg[i] = '\0';
            asb_smart_strip_activity(out_pkg);
            if (out_pkg[0]) got = 1;
        }
    }
    pclose(p);
    return got;
}

/* Source 2: dumpsys activity activities | mResumedActivity */
static int asb_smart_pkg_via_resumed(char *out_pkg, size_t outsz) {
    if (!out_pkg || outsz == 0) return 0;
    out_pkg[0] = '\0';
    FILE *p = popen("timeout 1 dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity", "r");
    if (!p) return 0;
    char line[512];
    int got = 0;
    if (fgets(line, sizeof(line), p)) {
        /*
         * line: " mResumedActivity: ActivityRecord{...
         */
        char *u0 = strstr(line, " u0 ");
        if (!u0) u0 = strstr(line, " u10 ");
        if (u0) {
            char *start = strchr(u0 + 1, ' ');
            if (start) {
                start++;
                int i = 0;
                while (*start && *start != ' ' && *start != '\t' && *start != '}' && i < (int)outsz - 1) {
                    out_pkg[i++] = *start++;
                }
                out_pkg[i] = '\0';
                asb_smart_strip_activity(out_pkg);
                if (out_pkg[0]) got = 1;
            }
        }
    }
    pclose(p);
    return got;
}

/* Source 3: dumpsys window | mCurrentFocus */
static int asb_smart_pkg_via_window_focus(char *out_pkg, size_t outsz) {
    if (!out_pkg || outsz == 0) return 0;
    out_pkg[0] = '\0';
    FILE *p = popen("timeout 1 dumpsys window windows 2>/dev/null | grep -m1 mCurrentFocus", "r");
    if (!p) return 0;
    char line[512];
    int got = 0;
    if (fgets(line, sizeof(line), p)) {
        /* line: "  mCurrentFocus=Window{abcdef u0 com.foo/.Bar}" */
        char *u0 = strstr(line, " u0 ");
        if (!u0) u0 = strstr(line, " u10 ");
        if (u0) {
            char *start = strchr(u0 + 1, ' ');
            if (start) {
                start++;
                int i = 0;
                while (*start && *start != ' ' && *start != '\t' && *start != '}' && i < (int)outsz - 1) {
                    out_pkg[i++] = *start++;
                }
                out_pkg[i] = '\0';
                asb_smart_strip_activity(out_pkg);
                if (out_pkg[0]) got = 1;
            }
        }
    }
    pclose(p);
    return got;
}

/* Master detection: try sources in order, validate, cache.
 * Returns status code; out_pkg/out_hash/out_hint populated. */
static asb_pkg_status_t asb_smart_detect_foreground_pkg(
        char *out_pkg, size_t outsz,
        uint64_t *out_hash, int *out_hint, int *out_source)
{
    char pkg[128];
    int source = 0;
    time_t now = time(NULL);

    if (asb_smart_pkg_via_activity_top(pkg, sizeof(pkg))) source = 1;
    else if (asb_smart_pkg_via_resumed(pkg, sizeof(pkg))) source = 2;
    else if (asb_smart_pkg_via_window_focus(pkg, sizeof(pkg))) source = 3;
    else pkg[0] = '\0';

    asb_pkg_status_t st;
    if (!pkg[0]) {
        /*
         * All sources failed.
         */
        if (g_pkg_cache.pkg[0] && (now - g_pkg_cache.last_seen_ts) < 20) {
            if (out_pkg && outsz > 0) {
                strncpy(out_pkg, g_pkg_cache.pkg, outsz - 1);
                out_pkg[outsz - 1] = '\0';
            }
            if (out_hash) *out_hash = g_pkg_cache.hash;
            if (out_hint) {
                int h = g_pkg_cache.hint;
                if (h >= ASB_APP_HEAVY) h -= 1;
                *out_hint = h;
            }
            if (out_source) *out_source = g_pkg_cache.last_source;
            return ASB_PKG_STALE;
        }
        if (out_pkg && outsz > 0) out_pkg[0] = '\0';
        if (out_hash) *out_hash = 0;
        if (out_hint) *out_hint = ASB_APP_MEDIUM;
        if (out_source) *out_source = 0;
        return ASB_PKG_MISSING;
    }

    /* Got a real package. Filter system UI. */
    if (asb_smart_is_system_ui(pkg)) {
        if (g_pkg_cache.pkg[0] && (now - g_pkg_cache.last_seen_ts) < 20) {
            if (out_pkg && outsz > 0) {
                strncpy(out_pkg, g_pkg_cache.pkg, outsz - 1);
                out_pkg[outsz - 1] = '\0';
            }
            if (out_hash) *out_hash = g_pkg_cache.hash;
            if (out_hint) *out_hint = g_pkg_cache.hint;
            if (out_source) *out_source = g_pkg_cache.last_source;
            return ASB_PKG_SYS_UI;
        }
        if (out_pkg && outsz > 0) {
            strncpy(out_pkg, pkg, outsz - 1);
            out_pkg[outsz - 1] = '\0';
        }
        if (out_hash) *out_hash = 0;  /* sys UI doesn't get a hash */
        if (out_hint) *out_hint = ASB_APP_LIGHT;
        if (out_source) *out_source = source;
        return ASB_PKG_SYS_UI;
    }

    /* Valid user package — hash + classify + cache */
    uint64_t h = asb_smart_pkg_hash64(pkg);
    int hint = asb_smart_app_hint_from_pkg(pkg);

    /* Update cache */
    strncpy(g_pkg_cache.pkg, pkg, sizeof(g_pkg_cache.pkg) - 1);
    g_pkg_cache.pkg[sizeof(g_pkg_cache.pkg) - 1] = '\0';
    g_pkg_cache.hash = h;
    g_pkg_cache.hint = hint;
    g_pkg_cache.last_seen_ts = now;
    g_pkg_cache.last_source = source;

    if (out_pkg && outsz > 0) {
        strncpy(out_pkg, pkg, outsz - 1);
        out_pkg[outsz - 1] = '\0';
    }
    if (out_hash) *out_hash = h;
    if (out_hint) *out_hint = hint;
    if (out_source) *out_source = source;
    st = ASB_PKG_OK;
    return st;
}

static void asb_smart_store_seed_defaults(asb_smart_store_t *st) {
    if (!st) return;
    memset(st, 0, sizeof(*st));
    st->magic = ASB_SMART_MAGIC;
    st->version = ASB_SMART_VER;
    st->bucket_count = ASB_SMART_BUCKETS;
    st->last_update_ts = (uint32_t)time(NULL);
    for (int dp = 0; dp < ASB_SMART_DAYPARTS; dp++) {
        for (int we = 0; we < 2; we++) {
            uint32_t bid = (uint32_t)(dp * 2 + we);
            asb_smart_bucket_t *b = &st->buckets[bid];
            b->bucket_id = bid;
            b->observations_raw = 0;
            b->last_seen_ts = 0;
            b->eff_obs_x100 = 0;
            b->conf_x1000 = 0;
            uint16_t alpha_seed;
            int16_t inter_seed;
            uint16_t sleep_seed;
            uint16_t net_seed;
            switch (dp) {
                case ASB_DAYPART_SLEEP:
                    alpha_seed = 950; inter_seed = 0;   sleep_seed = 900; net_seed = 800; break;
                case ASB_DAYPART_LATE:
                    alpha_seed = 750; inter_seed = 20;  sleep_seed = 500; net_seed = 500; break;
                case ASB_DAYPART_WAKE:
                    alpha_seed = 650; inter_seed = 40;  sleep_seed = 300; net_seed = 400; break;
                case ASB_DAYPART_MORN:
                case ASB_DAYPART_DAY:
                    alpha_seed = 300; inter_seed = 100; sleep_seed = 0;   net_seed = 100; break;
                case ASB_DAYPART_EVE:
                    alpha_seed = 400; inter_seed = 80;  sleep_seed = 50;  net_seed = 200; break;
                default:
                    alpha_seed = 500; inter_seed = 50;  sleep_seed = 100; net_seed = 300; break;
            }
            b->alpha_battery_x1000  = alpha_seed;
            b->interactive_bonus_x1000 = inter_seed;
            b->idle_bias_x1000         = 0;
            b->sleep_bias_x1000        = sleep_seed;
            b->net_conservative_x1000  = net_seed;
            b->avg_idle_q_x10 = 0;
            b->avg_wph_x10 = 0;
            b->avg_drain_pctph_x10 = 0;
            b->avg_max_temp_x10 = 0;
        }
    }
}

static int asb_smart_store_validate(const asb_smart_store_t *st) {
    if (!st) return -1;
    if (st->magic != ASB_SMART_MAGIC) return -2;
    /* Accept the previous schema: the loader migrates it in place. */
    if (st->version != ASB_SMART_VER && st->version != ASB_SMART_VER_LEGACY) return -3;
    if (st->bucket_count != ASB_SMART_BUCKETS) return -4;
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        if (st->buckets[i].bucket_id != (uint32_t)i) return -5;
        if (st->buckets[i].alpha_battery_x1000 > ASB_SMART_ALPHA_BATTERY_MAX_X1000) return -6;
        if (st->buckets[i].interactive_bonus_x1000 > ASB_SMART_INTERACTIVE_MAX_X1000) return -7;
        if (st->buckets[i].interactive_bonus_x1000 < ASB_SMART_INTERACTIVE_MIN_X1000) return -8;
        if (st->buckets[i].idle_bias_x1000 > ASB_SMART_IDLE_BIAS_MAX_X1000) return -9;
        if (st->buckets[i].idle_bias_x1000 < ASB_SMART_IDLE_BIAS_MIN_X1000) return -10;
        if (st->buckets[i].sleep_bias_x1000 > ASB_SMART_SLEEP_BIAS_MAX_X1000) return -11;
        if (st->buckets[i].net_conservative_x1000 > ASB_SMART_NET_CONSERV_MAX_X1000) return -12;
    }
    return 0;
}

static int asb_smart_store_load_from(const char *path, asb_smart_store_t *out) {
    if (!path || !out) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -2;
    size_t n = fread(out, 1, sizeof(*out), f);
    fclose(f);
    if (n != sizeof(*out)) return -3;
    return asb_smart_store_validate(out);
}

static int asb_smart_store_save_atomic(const asb_smart_store_t *st, const char *path) {
    if (!st || !path) return -1;
    if (asb_smart_store_validate(st) != 0) return -2;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -3;
    size_t n = fwrite(st, 1, sizeof(*st), f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (n != sizeof(*st)) {
        unlink(tmp);
        return -4;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -5;
    }
    return 0;
}

static int asb_smart_store_backup(const char *src, const char *bak) {
    if (!src || !bak) return -1;
    FILE *fi = fopen(src, "rb");
    if (!fi) return -2;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", bak);
    FILE *fo = fopen(tmp, "wb");
    if (!fo) { fclose(fi); return -3; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fi)) > 0) {
        if (fwrite(buf, 1, n, fo) != n) {
            fclose(fi); fclose(fo); unlink(tmp);
            return -4;
        }
    }
    fflush(fo);
    fsync(fileno(fo));
    fclose(fo);
    fclose(fi);
    if (rename(tmp, bak) != 0) {
        unlink(tmp);
        return -5;
    }
    return 0;
}

typedef struct {
    int reset_reason;
    int loaded_from_main;
    int loaded_from_backup;
    int seeded;
} asb_smart_load_outcome_t;

/* Carry a V63 store forward: keep what was measured, drop what was concluded.
 *
 * Only the three learned outputs are reset. Their neutral values are the same ones a
 * fresh bucket starts with, so a migrated bucket behaves exactly like an unlearned one
 * of the same age - and re-learns from its own history rather than from zero.
 *
 * eff_obs is kept deliberately: those observations were real, and requiring them to be
 * earned again would leave every existing user on cold-start ceilings for days.
 */
static void asb_smart_store_migrate(asb_smart_store_t *st) {
    if (!st || st->version == ASB_SMART_VER) return;
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        /* The same neutral values a fresh runtime starts with - taken from the
         * initialiser rather than guessed, so a migrated bucket and a new one behave
         * identically before either has learned anything. */
        st->buckets[i].alpha_battery_x1000    = 500;
        st->buckets[i].sleep_bias_x1000       = 100;
        st->buckets[i].net_conservative_x1000 = 300;
    }
    st->version = ASB_SMART_VER;
}

static int asb_smart_store_load(asb_smart_store_t *st, asb_smart_load_outcome_t *out) {
    if (!st) return -1;
    asb_smart_load_outcome_t local = {0,0,0,0};
    int rc = asb_smart_store_load_from(ASB_SMART_STORE_FILE, st);
    if (rc == 0) {
        asb_smart_store_migrate(st);
        local.loaded_from_main = 1;
        if (out) *out = local;
        return 0;
    }
    local.reset_reason = rc;
    int rc2 = asb_smart_store_load_from(ASB_SMART_STORE_BAK, st);
    if (rc2 == 0) {
        local.loaded_from_backup = 1;
        if (out) *out = local;
        asb_smart_store_save_atomic(st, ASB_SMART_STORE_FILE);
        return 0;
    }
    asb_smart_store_seed_defaults(st);
    local.seeded = 1;
    if (out) *out = local;
    asb_smart_store_save_atomic(st, ASB_SMART_STORE_FILE);
    return 1;
}

static int asb_smart_flag_read(void) {
    FILE *f = fopen(ASB_SMART_FLAG_FILE, "r");
    if (!f) return -1;
    int v = -1;
    int got = fscanf(f, "%d", &v);
    fclose(f);
    if (got != 1) return -1;
    return (v != 0) ? 1 : 0;
}

__attribute__((unused))
static int asb_smart_flag_write(int enabled) {
    FILE *f = fopen(ASB_SMART_FLAG_FILE, "w");
    if (!f) return -1;
    fprintf(f, "%d\n", enabled ? 1 : 0);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return 0;
}

__attribute__((unused))
static int asb_smart_prev_profile_read(char *out, size_t outsz) {
    if (!out || outsz < 2) return -1;
    FILE *f = fopen(ASB_SMART_PREV_PROF, "r");
    if (!f) return -1;
    if (!fgets(out, (int)outsz, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    size_t L = strlen(out);
    while (L > 0 && (out[L-1] == '\n' || out[L-1] == '\r' || out[L-1] == ' ')) {
        out[--L] = '\0';
    }
    return (L > 0) ? 0 : -1;
}

__attribute__((unused))
static int asb_smart_prev_profile_write(const char *prof) {
    if (!prof || !*prof) return -1;
    FILE *f = fopen(ASB_SMART_PREV_PROF, "w");
    if (!f) return -1;
    fprintf(f, "%s\n", prof);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    return 0;
}

__attribute__((unused))
static int asb_smart_app_hash_to_hex(uint64_t h, char *out, size_t outsz) {
    if (!out || outsz < 17) return -1;
    snprintf(out, outsz, "%016llx", (unsigned long long)h);
    return 0;
}

/* ============================================================
 * Part 2: Math, blend, overrides, learning (Session 3)
 * ============================================================ */

/*
 * Map duration in seconds to weight × 100.
 */
static uint16_t asb_smart_duration_weight_x100(int dur_s) {
    if (dur_s < 0) dur_s = 0;
    if (dur_s <  ASB_SMART_DUR_W_SHORT_MAX_S) return ASB_SMART_DUR_W_SHORT_X100;
    if (dur_s <  ASB_SMART_DUR_W_MED_MAX_S)   return ASB_SMART_DUR_W_MED_X100;
    if (dur_s <  ASB_SMART_DUR_W_LONG_MAX_S)  return ASB_SMART_DUR_W_LONG_X100;
    return ASB_SMART_DUR_W_VLONG_X100;
}

static uint16_t asb_smart_trust_weight_x100(int trust) {
    switch (trust) {
        case ASB_TRUST_CLEAN:   return ASB_SMART_TRUST_W_CLEAN_X100;
        case ASB_TRUST_PARTIAL: return ASB_SMART_TRUST_W_PARTIAL_X100;
        case ASB_TRUST_NOISY:   return ASB_SMART_TRUST_W_NOISY_X100;
        case ASB_TRUST_DIRTY:   return ASB_SMART_TRUST_W_DIRTY_X100;
        default:                return ASB_SMART_TRUST_W_PARTIAL_X100;
    }
}

/* eff_obs increment for one session = (dur_weight × trust_weight) / 100
 * (since both are _x100, product is _x10000, we want _x100 result) */
static uint16_t asb_smart_eff_obs_add_x100(int dur_s, int trust) {
    uint32_t dw = asb_smart_duration_weight_x100(dur_s);
    uint32_t tw = asb_smart_trust_weight_x100(trust);
    uint32_t prod = (dw * tw) / 100;
    if (prod > 0xffffu) prod = 0xffffu;
    return (uint16_t)prod;
}

/*
 * Decay factor × 100 based on time since last_seen.
 */
static int asb_smart_decay_x100(uint32_t last_seen_ts, time_t now) {
    if (last_seen_ts == 0) return 100;
    if ((uint32_t)now <= last_seen_ts) return 100;
    int days = (int)((uint32_t)now - last_seen_ts) / (24 * 3600);
    if (days <  ASB_SMART_DECAY_FRESH_DAYS) return 100;
    if (days >= ASB_SMART_DECAY_STALE_DAYS) return 0;
    /* Linear from 100 at FRESH_DAYS down to FLOOR (30) at STALE_DAYS */
    int span = ASB_SMART_DECAY_STALE_DAYS - ASB_SMART_DECAY_FRESH_DAYS;  /* 30 */
    int into = days - ASB_SMART_DECAY_FRESH_DAYS;                         /* 0..30 */
    int from_full = 100 - ASB_SMART_DECAY_FLOOR_X100;                     /* 70 */
    int dec = (from_full * into) / span;
    return 100 - dec;
}

/* Confidence × 1000 from current eff_obs and time decay.
 * conf = min(1.0, eff_obs / EFF_OBS_FULL) × decay */
static uint16_t asb_smart_confidence_x1000(const asb_smart_bucket_t *b, time_t now) {
    if (!b || b->eff_obs_x100 == 0) return 0;
    /* Ratio = eff_obs_x100 / EFF_OBS_FULL_x100. Both in same scale. */
    uint32_t ratio_x1000 = ((uint32_t)b->eff_obs_x100 * 1000u) / ASB_SMART_EFF_OBS_FULL_X100;
    if (ratio_x1000 > 1000u) ratio_x1000 = 1000u;
    int decay = asb_smart_decay_x100(b->last_seen_ts, now);
    uint32_t conf = (ratio_x1000 * (uint32_t)decay) / 100u;
    if (conf > ASB_SMART_CONF_MAX_X1000) conf = ASB_SMART_CONF_MAX_X1000;
    return (uint16_t)conf;
}

/* Confidence tier from conf_x1000: 0=ignore, 1=mild, 2=strong */
static int asb_smart_confidence_tier(int conf_x1000) {
    if (conf_x1000 < ASB_SMART_CONF_LOW_X1000)  return 0;
    if (conf_x1000 < ASB_SMART_CONF_HIGH_X1000) return 1;
    return 2;
}

/* Daypart class: SLEEP/LATE → "night", WAKE/MORN/DAY → "day", EVE → "evening" */
static int asb_smart_daypart_class(int daypart) {
    switch (daypart) {
        case ASB_DAYPART_SLEEP:
        case ASB_DAYPART_LATE:
            return 0; /* night */
        case ASB_DAYPART_WAKE:
        case ASB_DAYPART_MORN:
        case ASB_DAYPART_DAY:
            return 1; /* day */
        case ASB_DAYPART_EVE:
            return 2; /* evening */
        default:
            return 1;
    }
}

/*
 * Lookup bucket with hierarchical fallback.
 * Safe default bucket is a static synthesized fallback (never NULL).
 */
static asb_smart_bucket_t* asb_smart_lookup_bucket(
        asb_smart_store_t *st,
        int daypart, int is_weekend,
        time_t now,
        int *fallback_level)
{
    static asb_smart_bucket_t safe_default;
    static int safe_default_initialized = 0;
    if (!safe_default_initialized) {
        memset(&safe_default, 0, sizeof(safe_default));
        safe_default.alpha_battery_x1000      = 500;  /* mid */
        safe_default.interactive_bonus_x1000  = 0;
        safe_default.idle_bias_x1000          = 0;
        safe_default.sleep_bias_x1000         = 100;
        safe_default.net_conservative_x1000   = 300;
        safe_default.conf_x1000               = 0;
        safe_default_initialized = 1;
    }

    if (!st || !fallback_level) {
        if (fallback_level) *fallback_level = ASB_SMART_FALLBACK_SAFE;
        return &safe_default;
    }

    if (daypart < 0 || daypart >= ASB_SMART_DAYPARTS) daypart = ASB_DAYPART_DAY;
    if (is_weekend != 0 && is_weekend != 1) is_weekend = 0;

    /* Level 0: EXACT */
    int exact_bid = (int)asb_smart_bucket_id(daypart, is_weekend);
    asb_smart_bucket_t *bx = &st->buckets[exact_bid];
    int conf_x = asb_smart_confidence_x1000(bx, now);
    if (conf_x >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_EXACT;
        bx->conf_x1000 = (uint16_t)conf_x;
        return bx;
    }

    /* Level 1: DAYPART_ONLY — pick higher-confidence variant within same daypart */
    int alt_bid = (int)asb_smart_bucket_id(daypart, is_weekend ^ 1);
    asb_smart_bucket_t *ba = &st->buckets[alt_bid];
    int conf_a = asb_smart_confidence_x1000(ba, now);
    if (conf_a >= ASB_SMART_CONF_LOW_X1000 && conf_a > conf_x) {
        *fallback_level = ASB_SMART_FALLBACK_DAYPART_ONLY;
        ba->conf_x1000 = (uint16_t)conf_a;
        return ba;
    }
    /* If exact has any nonzero conf below low threshold but better than alt, still try it weakly */
    if (conf_x > 0 && conf_x >= conf_a) {
        *fallback_level = ASB_SMART_FALLBACK_EXACT;
        bx->conf_x1000 = (uint16_t)conf_x;
        return bx;
    }

    /* Level 2: CLASS — best confidence within daypart class */
    int my_class = asb_smart_daypart_class(daypart);
    asb_smart_bucket_t *best_class = NULL;
    int best_class_conf = -1;
    for (int dp = 0; dp < ASB_SMART_DAYPARTS; dp++) {
        if (asb_smart_daypart_class(dp) != my_class) continue;
        for (int we = 0; we < 2; we++) {
            int bid = (int)asb_smart_bucket_id(dp, we);
            asb_smart_bucket_t *b = &st->buckets[bid];
            int c = asb_smart_confidence_x1000(b, now);
            if (c > best_class_conf) {
                best_class_conf = c;
                best_class = b;
            }
        }
    }
    if (best_class && best_class_conf >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_CLASS;
        best_class->conf_x1000 = (uint16_t)best_class_conf;
        return best_class;
    }

    /* Level 3: GLOBAL — best bucket anywhere */
    asb_smart_bucket_t *best_global = NULL;
    int best_global_conf = -1;
    for (int i = 0; i < ASB_SMART_BUCKETS; i++) {
        asb_smart_bucket_t *b = &st->buckets[i];
        int c = asb_smart_confidence_x1000(b, now);
        if (c > best_global_conf) {
            best_global_conf = c;
            best_global = b;
        }
    }
    if (best_global && best_global_conf >= ASB_SMART_CONF_LOW_X1000) {
        *fallback_level = ASB_SMART_FALLBACK_GLOBAL;
        best_global->conf_x1000 = (uint16_t)best_global_conf;
        return best_global;
    }

    /* Level 4: SAFE — synthesized conservative defaults */
    *fallback_level = ASB_SMART_FALLBACK_SAFE;
    return &safe_default;
}

/* Compute effective runtime smart params from a chosen bucket + confidence.
 * Applies confidence gating per locked rules. */
/* st is needed for the device-relative thermal median: the decision depends not only on
 * this bucket but on how it compares to the rest of this phone's history. */
static void asb_smart_compute_effective(
        const asb_smart_bucket_t *b,
        int conf_x1000,
        const asb_smart_store_t *st,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    if (!b) {
        rt->conf_x1000 = 0;
        rt->alpha_battery_x1000 = 500;
        rt->bucket_temp_x10 = 0;
        rt->bucket_drain_x10 = 0;
        rt->therm_warm_x10 = ASB_SMART_THERM_WARM_X10;
        rt->therm_cool_x10 = ASB_SMART_THERM_COOL_X10;
        rt->interactive_bonus_x1000 = 0;
        rt->idle_bias_x1000 = 0;
        rt->sleep_bias_x1000 = 100;
        rt->net_conservative_x1000 = 300;
        return;
    }
    rt->conf_x1000 = conf_x1000;

    /*
     * effective scale: NEVER zero out the seed/learned bias.
     * Rationale: sleep daypart seeds alpha=950 for good reason (battery-lean at night);
     * dropping to neutral 500 means the user gets no benefit until weeks of learning.
     */
    int eff_scale_x1000;
    if (conf_x1000 < ASB_SMART_CONF_LOW_X1000) {
        /* was 0. Now 250 — always honor seeded priors. */
        eff_scale_x1000 = 250;
    } else if (conf_x1000 < ASB_SMART_CONF_HIGH_X1000) {
        /* Linear: low→250, high→600 */
        int span = ASB_SMART_CONF_HIGH_X1000 - ASB_SMART_CONF_LOW_X1000;
        int into = conf_x1000 - ASB_SMART_CONF_LOW_X1000;
        eff_scale_x1000 = 250 + (350 * into) / span;
    } else {
        /* Strong tier: linear from 600 at high→1000 at full conf */
        int span = ASB_SMART_CONF_MAX_X1000 - ASB_SMART_CONF_HIGH_X1000;
        int into = conf_x1000 - ASB_SMART_CONF_HIGH_X1000;
        eff_scale_x1000 = 600 + ((1000 - 600) * into) / span;
        if (eff_scale_x1000 > 1000) eff_scale_x1000 = 1000;
    }

    /* Blend bucket value with neutral baseline using eff_scale.
     * Neutral baseline for alpha_battery: 500 (mid between battery and balanced).
     * Effective = neutral + (bucket - neutral) × eff_scale */
    int alpha = 500 + ((b->alpha_battery_x1000 - 500) * eff_scale_x1000) / 1000;

    /* Learned thermal history, finally used.
     *
     * avg_max_temp_x10 and avg_drain_pctph_x10 have been collected per bucket since the
     * feature existed and were never read by anything - the learner was keeping a diary
     * nobody opened. That is the whole gap in "Smart is not smart enough": it knew this
     * time of day runs hot, or drains fast, and did nothing differently because of it.
     *
     * Both nudges are small and bounded. A bucket is an average over many sessions, so
     * acting hard on it would fight the live thermal loop, which sees the actual sensor
     * and is always right about NOW. This shifts the starting point; the live loop still
     * has the final word.
     */
    /* Thresholds relative to THIS device, not to the one the numbers came from.
     *
     * The first version of this used 42.0/38.0 C, measured on a OnePlus 15. That is a
     * fact about one phone: a 12 on SD8Gen3 idles and loads at different temperatures,
     * and an older model with a smaller thermal envelope different again. Hardcoding
     * either set makes the feature right for one device and wrong for the rest, which
     * for a module aimed at OnePlus generally is the same as wrong.
     *
     * So the device tells us its own normal. The buckets already hold a temperature
     * average per time-of-day slot; the median across the populated ones IS this phone's
     * ordinary operating temperature, whatever silicon it has. Warm and cool are then
     * offsets from that median rather than absolute degrees.
     *
     * Fallback to the measured OP15 numbers only while too few buckets have history -
     * a defined starting point beats no lean at all, and it self-corrects within days.
     */
    int warm_x10 = ASB_SMART_THERM_WARM_X10;
    int cool_x10 = ASB_SMART_THERM_COOL_X10;
    {
        int temps[ASB_SMART_BUCKETS];
        int n = 0;
        for (int i = 0; st && i < ASB_SMART_BUCKETS; i++) {
            int t = (int)st->buckets[i].avg_max_temp_x10;
            if (t > 0 && st->buckets[i].eff_obs_x100 >= ASB_SMART_THERM_MIN_OBS_X100)
                temps[n++] = t;
        }
        if (st && n >= ASB_SMART_THERM_MIN_BUCKETS) {
            /* Insertion sort: n <= 12, and a median needs the middle element only. */
            for (int i = 1; i < n; i++) {
                int v = temps[i], j = i - 1;
                while (j >= 0 && temps[j] > v) { temps[j + 1] = temps[j]; j--; }
                temps[j + 1] = v;
            }
            int median = temps[n / 2];
            warm_x10 = median + ASB_SMART_THERM_WARM_OFFSET_X10;
            cool_x10 = median - ASB_SMART_THERM_COOL_OFFSET_X10;
        }
    }

    /* A cold start still has a thermometer.
     *
     * The learned lean needs three effective observations in this bucket and four
     * populated buckets before it does anything, which is a dozen sessions. Until then
     * alpha sits at its 500 default and the phone runs close to Balanced ceilings - a
     * capture after a learning reset shows exactly that: "no learned thermal history for
     * this bucket yet - lean inactive", with current up from 210 to 313 mA on the same
     * kind of workload.
     *
     * Waiting is right for the LEARNED thresholds, which are about this device's own
     * normal. It is not right for an absolute reading: 60 C is warm on any phone, and no
     * amount of history will make it otherwise. So a small fixed lean applies from the
     * first tick, and the learned one takes over once it has evidence.
     *
     * Deliberately smaller than the learned lean can grow to: this is a floor to stop the
     * cold-start case running hot, not a substitute for measuring the device. */
    if (b->eff_obs_x100 < ASB_SMART_THERM_MIN_OBS_X100) {
        int t_cold = (int)b->avg_max_temp_x10;
        if (t_cold >= 600)      alpha += 60;   /* 60 C+: warm on any device  */
        else if (t_cold >= 550) alpha += 30;
        else if (t_cold > 0 && t_cold <= 400) alpha -= 20;  /* genuinely cool */
    }

    if (b->eff_obs_x100 >= ASB_SMART_THERM_MIN_OBS_X100) {
        int t_c10 = (int)b->avg_max_temp_x10;
        if (t_c10 > 0) {
            /* Above the warm mark, lean toward battery in proportion to the overshoot,
             * capped so a consistently hot bucket cannot pin alpha at the floor. */
            if (t_c10 > warm_x10) {
                int over = t_c10 - warm_x10;              /* tenths of a degree */
                int lean = (over * ASB_SMART_THERM_LEAN_PER_DEG) / 10;
                if (lean > ASB_SMART_THERM_LEAN_MAX) lean = ASB_SMART_THERM_LEAN_MAX;
                /* Warmer means lean HARDER toward Battery, so alpha goes up.
                 *
                 * The blend is (battery*alpha + balanced*(1000-alpha))/1000, and the
                 * Battery bounds are the lower ones - so a bigger alpha is a lower ceiling.
                 * Subtracting here moved the phone toward Balanced every time it ran warm:
                 * a bucket at 500 dropped to 440 and the ceiling ROSE, which is the
                 * opposite of what a thermal lean is for.
                 *
                 * The variable is still called lean because that is what it measures - how
                 * far over the warm threshold this bucket sits. Only the direction it is
                 * applied in was wrong. */
                alpha += lean;
            /* A bucket that has never run warm has headroom the generic tuning does not
             * know about - give a little of it back rather than staying cautious out of
             * habit. Deliberately smaller than the penalty: being wrong about cool costs
             * heat, being wrong about hot costs a little speed. */
            } else if (t_c10 < cool_x10) {
                int under = cool_x10 - t_c10;
                int gain  = (under * ASB_SMART_THERM_GAIN_PER_DEG) / 10;
                if (gain > ASB_SMART_THERM_GAIN_MAX) gain = ASB_SMART_THERM_GAIN_MAX;
                /* Cooler means the phone can afford Balanced: alpha down, ceiling up. */
                alpha -= gain;
            }
        }
        /* Drain history: a bucket that historically burns battery fast gets a nudge the
         * same way. This is what makes "the phone learns your evening Netflix hour" mean
         * something instead of being a slogan. */
        int d_x10 = (int)b->avg_drain_pctph_x10;
        if (d_x10 > ASB_SMART_DRAIN_HEAVY_X10) {
            int over = d_x10 - ASB_SMART_DRAIN_HEAVY_X10;
            int lean = (over * ASB_SMART_DRAIN_LEAN_PER_PCT) / 10;
            if (lean > ASB_SMART_DRAIN_LEAN_MAX) lean = ASB_SMART_DRAIN_LEAN_MAX;
            /* Heavy drain means lean toward Battery: alpha up, ceiling down.
             * Same inversion as the thermal branch above - a bucket that was draining hard
             * had its ceiling raised, which makes the next sample worse and the one after
             * that worse still. */
            alpha += lean;
        }
    }

    rt->therm_warm_x10   = warm_x10;
    rt->therm_cool_x10   = cool_x10;
    rt->bucket_temp_x10  = (int)b->avg_max_temp_x10;
    rt->bucket_drain_x10 = (int)b->avg_drain_pctph_x10;
    rt->alpha_battery_x1000 = asb_clamp_int(alpha,
        ASB_SMART_ALPHA_BATTERY_MIN_X1000, ASB_SMART_ALPHA_BATTERY_MAX_X1000);

    /* For bias values neutral is 0 */
    int inter = (b->interactive_bonus_x1000 * eff_scale_x1000) / 1000;
    rt->interactive_bonus_x1000 = asb_clamp_int(inter,
        ASB_SMART_INTERACTIVE_MIN_X1000, ASB_SMART_INTERACTIVE_MAX_X1000);

    int idle = (b->idle_bias_x1000 * eff_scale_x1000) / 1000;
    rt->idle_bias_x1000 = asb_clamp_int(idle,
        ASB_SMART_IDLE_BIAS_MIN_X1000, ASB_SMART_IDLE_BIAS_MAX_X1000);

    int sleep = (b->sleep_bias_x1000 * eff_scale_x1000) / 1000;
    rt->sleep_bias_x1000 = asb_clamp_int(sleep,
        ASB_SMART_SLEEP_BIAS_MIN_X1000, ASB_SMART_SLEEP_BIAS_MAX_X1000);

    int net = (b->net_conservative_x1000 * eff_scale_x1000) / 1000;
    rt->net_conservative_x1000 = asb_clamp_int(net,
        ASB_SMART_NET_CONSERV_MIN_X1000, ASB_SMART_NET_CONSERV_MAX_X1000);
}

static void asb_smart_apply_night_override(
        int daypart,
        int learned_night,
        int screen_on,
        int charging,
        int app_hint,
        int battery_pct,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->night_safe_override = 0;

    int is_night_part = (daypart == ASB_DAYPART_SLEEP ||
                         daypart == ASB_DAYPART_LATE ||
                         daypart == ASB_DAYPART_WAKE ||
                         learned_night);
    int idle_screen = (screen_on == 0);
    int not_charging = (charging == 0);
    int no_heavy = (app_hint < ASB_APP_HEAVY);
    int low_or_normal_bat = (battery_pct <= ASB_SMART_NIGHT_BAT_PCT_MAX);

    if (is_night_part && idle_screen && not_charging && no_heavy && low_or_normal_bat) {
        rt->night_safe_override = 1;
        if (rt->alpha_battery_x1000 < 900) rt->alpha_battery_x1000 = 900;
        if (rt->sleep_bias_x1000 < 800)    rt->sleep_bias_x1000 = 800;
        if (rt->net_conservative_x1000 < 700) rt->net_conservative_x1000 = 700;
        rt->interactive_bonus_x1000 = 0;
    }
}

/*
 * V50 charge-aware layer.
 * Runs after night/idle/lowbat overrides and before the thermal veto, so: - the assist
 * (performance lean) is suppressed whenever a safety override already fired, and the veto can
 * still undo it afterwards; - the cool-charge guard only raises floors, never lowers them.
 */
static void asb_smart_apply_charge_aware(
        int enable,
        int charging,
        int screen_on,
        int batt_temp_dC,
        int power_class,
        int assist_alpha_max_x1000,
        int soc_temp_c,          /* CPU/SoC temperature, not the pack */
        int temp_warn_dC,
        int temp_hot_dC,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->charge_assist = 0;
    rt->charge_cool_guard = 0;
    if (!enable || !charging) return;

    int warn = temp_warn_dC;
    if (power_class >= ASB_CHARGE_CLASS_SUPER)
        warn -= ASB_CHARGE_SUPER_WARN_BIAS_DC;

    if (batt_temp_dC >= temp_hot_dC) {
        /* Pack is hot while charging: protect charge speed and longevity.
         * Floors only — never below what other overrides demanded. */
        rt->charge_cool_guard = 1;
        if (rt->alpha_battery_x1000 < ASB_CHARGE_HOT_ALPHA_X1000)
            rt->alpha_battery_x1000 = ASB_CHARGE_HOT_ALPHA_X1000;
        if (rt->interactive_bonus_x1000 > 20) rt->interactive_bonus_x1000 = 20;
        return;
    }

    if (!screen_on) {
        /* Plugged, screen off: there is nothing to be fast for. Lean cool
         * so the pack charges at full vendor-negotiated rate. */
        rt->charge_cool_guard = 1;
        if (rt->alpha_battery_x1000 < ASB_CHARGE_COOL_ALPHA_X1000)
            rt->alpha_battery_x1000 = ASB_CHARGE_COOL_ALPHA_X1000;
        if (rt->interactive_bonus_x1000 > 20) rt->interactive_bonus_x1000 = 20;
        return;
    }

    /* Screen on, plugged, pack below warn: drain does not matter, so the
     * learner's battery lean is pure latency for free. Cap alpha toward
     * the balanced end — a ceiling, applied only when no safety override
     * holds a floor above it. */
    if (batt_temp_dC < warn &&
        !rt->night_safe_override &&
        !rt->low_battery_override &&
        !rt->thermal_veto) {
        /* The pack temperature is not the one that gets hot here.
         *
         * This branch checked batt_temp_dC only - the battery - and then pulled alpha down
         * to 450, i.e. leaned toward performance, on the reasoning that drain does not
         * matter while plugged in. True for the battery; not true for the SoC, which is
         * being warmed by the charger and by the workload at the same time. A OP13 user
         * reported the phone running hot specifically while charging, and this is the only
         * place that deliberately raises clocks because a charger is attached.
         *
         * A hot chip means the extra speed is being spent on heat rather than on work, so
         * skip the assist entirely and let the learner's own decision stand.
         */
        if (soc_temp_c > 0 && soc_temp_c >= ASB_CHARGE_SOC_SKIP_C) {
            /* Leave alpha alone: whatever Smart concluded already accounts for the heat. */
        } else if (rt->alpha_battery_x1000 > assist_alpha_max_x1000) {
            rt->alpha_battery_x1000 = assist_alpha_max_x1000;
            rt->charge_assist = 1;
        }
    }
}

static void asb_smart_apply_idle_screen_override(
        int screen_on,
        int charging,
        int app_hint,
        long screen_off_seconds,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    if (rt->night_safe_override) return;
    if (screen_on) return;
    if (charging) return;
    if (app_hint >= ASB_APP_HEAVY) return;
    if (screen_off_seconds < 30) return;

    /*
     * Short screen-off (30-120s): the common "glance and put down" window.
     * The data showed Smart sitting at its low learned daytime alpha (~400) through these gaps
     * because the only floor kicked in at 120s — leaving easy economy on the table with zero
     * UX cost (the screen is off).
     */
    if (screen_off_seconds < 120) {
        if (rt->alpha_battery_x1000 < 600) rt->alpha_battery_x1000 = 600;
        if (rt->sleep_bias_x1000 < 150)    rt->sleep_bias_x1000 = 150;
        if (rt->interactive_bonus_x1000 > 90) rt->interactive_bonus_x1000 = 90;
        return;
    }

    if (screen_off_seconds < 1800) {
        if (rt->alpha_battery_x1000 < 700) rt->alpha_battery_x1000 = 700;
        if (rt->sleep_bias_x1000 < 300)    rt->sleep_bias_x1000 = 300;
        if (rt->net_conservative_x1000 < 400) rt->net_conservative_x1000 = 400;
        if (rt->interactive_bonus_x1000 > 60) rt->interactive_bonus_x1000 = 60;
        return;
    }

    if (rt->alpha_battery_x1000 < 850) rt->alpha_battery_x1000 = 850;
    if (rt->sleep_bias_x1000 < 600)    rt->sleep_bias_x1000 = 600;
    if (rt->net_conservative_x1000 < 600) rt->net_conservative_x1000 = 600;
    if (rt->interactive_bonus_x1000 > 20) rt->interactive_bonus_x1000 = 20;
}

static int g_smart_lowbat_engaged = 0;

static void asb_smart_apply_low_battery_override(
        int battery_pct,
        int charging,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->low_battery_override = 0;

    if (battery_pct >= 0) {
        if (!g_smart_lowbat_engaged) {
            if (battery_pct <= ASB_SMART_LOWBAT_ENGAGE_PCT && !charging) {
                g_smart_lowbat_engaged = 1;
            }
        } else {
            if (battery_pct >= ASB_SMART_LOWBAT_RESTORE_PCT || charging) {
                g_smart_lowbat_engaged = 0;
            }
        }
    }

    if (g_smart_lowbat_engaged) {
        rt->low_battery_override = 1;
        int force = ASB_SMART_LOWBAT_FORCE_ALPHA_X1000;
        int crit = (battery_pct >= 0 &&
                    battery_pct <= ASB_SMART_LOWBAT_CRIT_PCT && !charging);
        if (crit) force = ASB_SMART_LOWBAT_CRIT_ALPHA_X1000;
        if (rt->alpha_battery_x1000 < force) {
            rt->alpha_battery_x1000 = force;
        }
        if (rt->net_conservative_x1000 < (crit ? 600 : 500))
            rt->net_conservative_x1000 = (crit ? 600 : 500);
        if (rt->interactive_bonus_x1000 > (crit ? 20 : 40))
            rt->interactive_bonus_x1000 = (crit ? 20 : 40);
    }
}

static void asb_smart_apply_thermal_veto(
        int cpu_max_c,
        int skin_temp_c,
        const asb_runtime_config_t *cfg,
        int vendor_clamp_1h,
        int recovery_active,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->thermal_veto = 0;

    /*
     * Decision sensor: prefer user-facing skin (shell) heat.
     */
    int se = asb_therm_skin_engage(cfg, cpu_max_c, skin_temp_c);
    int dtemp, dlo, dhi;
    if (se >= 0) {                          /* skin sensor usable */
        dtemp = skin_temp_c;
        dhi   = cfg->thermal_skin_c;
        dlo   = cfg->thermal_skin_c - 8;    /* soft pre-lean band ~8 C below veto */
    } else {                                /* no skin sensor -> original behaviour */
        dtemp = cpu_max_c;
        dhi   = ASB_SMART_VETO_CPU_TEMP_C;
        dlo   = 50;
    }

    int veto = 0;
    if (se == 1) veto = 1;                          /* skin hot OR junction hard-limit */
    else if (se < 0 && dtemp >= dhi) veto = 1;      /* junction fallback (original) */
    if (vendor_clamp_1h >= ASB_SMART_VETO_VENDOR_CLAMP_1H) veto = 1;
    if (recovery_active) veto = 1;

    if (veto) {
        rt->thermal_veto = 1;
        /* Effective confidence × 0.3 */
        rt->conf_x1000 = (rt->conf_x1000 * ASB_SMART_VETO_CONF_SCALE_X100) / 100;
        /* Force alpha_battery ≥ 700 */
        if (rt->alpha_battery_x1000 < ASB_SMART_VETO_FORCE_ALPHA_X1000) {
            rt->alpha_battery_x1000 = ASB_SMART_VETO_FORCE_ALPHA_X1000;
        }
        /* Trim interactive bonus */
        rt->interactive_bonus_x1000 /= 2;
        return;
    }

    /* Soft pre-lean band — on the SAME sensor the veto used, so it never leans on
     * a junction reading the veto itself would ignore. */
    int soft_lo = dlo;
    int soft_hi = dhi;
    if (dtemp > soft_lo && soft_hi > soft_lo) {
        int span = soft_hi - soft_lo;
        int over = dtemp - soft_lo;
        if (over > span) over = span;
        int bump = (150 * over) / span;
        int target = rt->alpha_battery_x1000 + bump;
        if (target > 1000) target = 1000;
        if (target > rt->alpha_battery_x1000) rt->alpha_battery_x1000 = target;
    }
}

static int asb_smart_thermal_trend_bump_calc(int cpu_max_c, int slope_mc_per_min, int hot_app)
{
    /* hot_app: 0=normal, 1=hot/cool-gaming engage, 2=charge-aware (earlier still) */
    int min_temp, min_slope;
    if (hot_app >= 2) {
        min_temp = ASB_SMART_TREND_CHARGE_MIN_TEMP_C;
        min_slope = ASB_SMART_TREND_CHARGE_MIN_SLOPE_MC_MIN;
    } else if (hot_app == 1) {
        min_temp = ASB_SMART_TREND_HOT_MIN_TEMP_C;
        min_slope = ASB_SMART_TREND_HOT_MIN_SLOPE_MC_MIN;
    } else {
        min_temp = ASB_SMART_TREND_MIN_TEMP_C;
        min_slope = ASB_SMART_TREND_MIN_SLOPE_MC_MIN;
    }
    if (cpu_max_c < min_temp) return 0;
    if (slope_mc_per_min <= min_slope) return 0;
    int span = ASB_SMART_TREND_MAX_SLOPE_MC_MIN - min_slope;
    int over = slope_mc_per_min - min_slope;
    if (over > span) over = span;
    if (span <= 0) return 0;
    return (ASB_SMART_TREND_MAX_BUMP_X1000 * over) / span;
}

typedef struct {
    uint64_t hash;
    uint16_t score;
    uint16_t drain_score;
    uint32_t last_ts;
} asb_smart_appheat_entry_t;

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t count;
    asb_smart_appheat_entry_t entries[ASB_SMART_APPHEAT_N];
} asb_smart_appheat_t;

static asb_smart_appheat_t g_smart_appheat;
static int g_smart_appheat_dirty = 0;

static asb_smart_appheat_entry_t *asb_smart_appheat_find(uint64_t hash) {
    if (hash == 0) return NULL;
    for (int i = 0; i < ASB_SMART_APPHEAT_N; i++) {
        if (g_smart_appheat.entries[i].hash == hash)
            return &g_smart_appheat.entries[i];
    }
    return NULL;
}

static void asb_smart_appheat_decay(asb_smart_appheat_entry_t *e, time_t now) {
    if (!e || e->last_ts == 0) return;
    long days = ((long)now - (long)e->last_ts) / 86400L;
    if (days <= 0) return;
    long dec = days * ASB_SMART_APPHEAT_DECAY_PER_DAY;
    if (dec >= e->score) e->score = 0;
    else e->score = (uint16_t)(e->score - dec);
    if (dec >= e->drain_score) e->drain_score = 0;
    else e->drain_score = (uint16_t)(e->drain_score - dec);
}

static int asb_smart_appheat_drain(uint64_t hash, time_t now) {
    asb_smart_appheat_entry_t *e = asb_smart_appheat_find(hash);
    if (!e) return 0;
    asb_smart_appheat_decay(e, now);
    return (int)e->drain_score;
}

static int asb_smart_appheat_score(uint64_t hash, time_t now) {
    asb_smart_appheat_entry_t *e = asb_smart_appheat_find(hash);
    if (!e) return 0;
    asb_smart_appheat_decay(e, now);
    return (int)e->score;
}

static void asb_smart_appheat_bump(uint64_t hash, time_t now) {
    if (hash == 0) return;
    asb_smart_appheat_entry_t *e = asb_smart_appheat_find(hash);
    if (!e) {
        asb_smart_appheat_entry_t *oldest = &g_smart_appheat.entries[0];
        for (int i = 0; i < ASB_SMART_APPHEAT_N; i++) {
            asb_smart_appheat_entry_t *c = &g_smart_appheat.entries[i];
            if (c->hash == 0) { oldest = c; break; }
            if (c->last_ts < oldest->last_ts) oldest = c;
        }
        oldest->hash = hash;
        oldest->score = 0;
        oldest->last_ts = (uint32_t)now;
        e = oldest;
    }
    asb_smart_appheat_decay(e, now);
    int ns = (int)e->score + ASB_SMART_APPHEAT_BUMP;
    if (ns > ASB_SMART_APPHEAT_MAX) ns = ASB_SMART_APPHEAT_MAX;
    e->score = (uint16_t)ns;
    e->last_ts = (uint32_t)now;
    g_smart_appheat_dirty = 1;
}

static void asb_smart_appheat_drain_bump(uint64_t hash, time_t now) {
    if (hash == 0) return;
    asb_smart_appheat_entry_t *e = asb_smart_appheat_find(hash);
    if (!e) {
        asb_smart_appheat_bump(hash, now);
        e = asb_smart_appheat_find(hash);
        if (!e) return;
        e->score = 0;
    }
    asb_smart_appheat_decay(e, now);
    int ns = (int)e->drain_score + ASB_SMART_APPHEAT_DRAIN_BUMP;
    if (ns > ASB_SMART_APPHEAT_MAX) ns = ASB_SMART_APPHEAT_MAX;
    e->drain_score = (uint16_t)ns;
    e->last_ts = (uint32_t)now;
    g_smart_appheat_dirty = 1;
}

static void asb_smart_appheat_load(void) {
    memset(&g_smart_appheat, 0, sizeof(g_smart_appheat));
    g_smart_appheat.magic = ASB_SMART_APPHEAT_MAGIC;
    g_smart_appheat.version = ASB_SMART_APPHEAT_VERSION;
    FILE *f = fopen(ASB_SMART_APPHEAT_FILE, "rb");
    if (!f) return;
    asb_smart_appheat_t tmp;
    size_t n = fread(&tmp, 1, sizeof(tmp), f);
    fclose(f);
    if (n != sizeof(tmp)) return;
    if (tmp.magic != ASB_SMART_APPHEAT_MAGIC) return;
    if (tmp.version != ASB_SMART_APPHEAT_VERSION) return;
    g_smart_appheat = tmp;
}

static void asb_smart_appheat_save(void) {
    if (!g_smart_appheat_dirty) return;
    char tmp_path[160];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", ASB_SMART_APPHEAT_FILE);
    FILE *f = fopen(tmp_path, "wb");
    if (!f) return;
    size_t n = fwrite(&g_smart_appheat, 1, sizeof(g_smart_appheat), f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (n == sizeof(g_smart_appheat)) rename(tmp_path, ASB_SMART_APPHEAT_FILE);
    else unlink(tmp_path);
    g_smart_appheat_dirty = 0;
}

static int g_smart_trend_prev_c = 0;
static time_t g_smart_trend_prev_ts = 0;
static int g_smart_trend_slope_mc_min = 0;

static int g_smart_budget_sev = 0;
static time_t g_smart_budget_since = 0;

static void asb_smart_apply_energy_budget(
        int battery_pct,
        int charging,
        int drain_ewma_x10,
        time_t now,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->budget_severity = 0;
    rt->budget_pred_h_x10 = -1;

    if (charging || battery_pct <= 0 || battery_pct > 100 || drain_ewma_x10 <= 0) {
        g_smart_budget_sev = 0;
        g_smart_budget_since = now;
        return;
    }

    long pred = ((long)battery_pct * 100L) / drain_ewma_x10;
    if (pred > 999) pred = 999;
    rt->budget_pred_h_x10 = (int)pred;

    int want = 0;
    if (battery_pct <= ASB_SMART_BUDGET_MAX_PCT) {
        if (pred < ASB_SMART_BUDGET_EMERG_H_X10) want = 2;
        else if (pred < ASB_SMART_BUDGET_WARN_H_X10) want = 1;
    }

    if (want > g_smart_budget_sev) {
        g_smart_budget_sev = want;
        g_smart_budget_since = now;
    } else if (want < g_smart_budget_sev) {
        if ((long)(now - g_smart_budget_since) >= ASB_SMART_BUDGET_DWELL_S) {
            g_smart_budget_sev = want;
            g_smart_budget_since = now;
        }
    }

    rt->budget_severity = g_smart_budget_sev;
    if (g_smart_budget_sev == 2) {
        if (rt->alpha_battery_x1000 < ASB_SMART_BUDGET_EMERG_ALPHA_X1000)
            rt->alpha_battery_x1000 = ASB_SMART_BUDGET_EMERG_ALPHA_X1000;
        if (rt->net_conservative_x1000 < 500) rt->net_conservative_x1000 = 500;
    } else if (g_smart_budget_sev == 1) {
        if (rt->alpha_battery_x1000 < ASB_SMART_BUDGET_WARN_ALPHA_X1000)
            rt->alpha_battery_x1000 = ASB_SMART_BUDGET_WARN_ALPHA_X1000;
        if (rt->net_conservative_x1000 < 400) rt->net_conservative_x1000 = 400;
    }
}

static int asb_cap_detente_check(
        int screen_on,
        int state_is_deep_idle,
        int owner_is_foreign,
        long owner_age_s,
        int cpu_max_c,
        int thermal_cap)
{
    if (screen_on) return 0;
    if (!state_is_deep_idle) return 0;
    if (!owner_is_foreign) return 0;
    if (owner_age_s < 120) return 0;
    if (cpu_max_c <= 0 || cpu_max_c >= 45) return 0;
    if (thermal_cap) return 0;
    return 1;
}

typedef struct {
    int q_battery;
    int q_heat;
    int q_stability;
    int q_vendor;
    int primary_failure;
} asb_smart_quality_t;

#define ASB_QFAIL_NONE 0
#define ASB_QFAIL_BATTERY 1
#define ASB_QFAIL_HEAT 2
#define ASB_QFAIL_STABILITY 3
#define ASB_QFAIL_VENDOR_WAR 4

static int asb_smart_session_quality_ex(
        int drain_pctph_x10,
        int drain_valid,
        int max_temp_c,
        int thermal_entries,
        int recovery_count,
        int vendor_clamps_per_h,
        int device_median_c,   /* 0 = not learned yet, use the absolute fallbacks */
        asb_smart_quality_t *out)
{
    /* Heat scored against THIS device's own normal.
     *
     * The fixed 45/75 C pair scored a OnePlus 15 sitting idle at 100 and a device whose
     * silicon simply runs warmer at 83 - for doing nothing. That is not a quality
     * difference, it is a difference in thermal design being recorded as one, and every
     * bucket on the warmer phone inherits the penalty permanently.
     *
     * Anchoring to the learned median fixes that: "good" is at or below your own normal,
     * "bad" is 30 degrees above it, which is the same span the absolutes used. Devices
     * with no learned median yet keep the old numbers.
     */
    int heat_good = ASB_SMART_QUALITY_HEAT_GOOD_C;
    int heat_bad  = ASB_SMART_QUALITY_HEAT_BAD_C;
    if (device_median_c > 0) {
        heat_good = device_median_c + ASB_SMART_QUALITY_HEAT_GOOD_OFFSET_C;
        heat_bad  = heat_good + ASB_SMART_QUALITY_HEAT_SPAN_C;
    }

    int heat;
    if (max_temp_c <= heat_good) heat = 100;
    else if (max_temp_c >= heat_bad) heat = 0;
    else heat = ((heat_bad - max_temp_c) * 100) / (heat_bad - heat_good);

    int stab = 100 - 20 * thermal_entries - 10 * recovery_count;
    if (stab < 0) stab = 0;

    int vendor;
    if (vendor_clamps_per_h < 0) vendor = -1;
    else if (vendor_clamps_per_h <= 5) vendor = 100;
    else if (vendor_clamps_per_h >= 60) vendor = 0;
    else vendor = ((60 - vendor_clamps_per_h) * 100) / 55;

    int bat = -1;
    if (drain_valid) {
        if (drain_pctph_x10 <= ASB_SMART_QUALITY_BAT_GOOD_X10) bat = 100;
        else if (drain_pctph_x10 >= ASB_SMART_QUALITY_BAT_BAD_X10) bat = 0;
        else bat = ((ASB_SMART_QUALITY_BAT_BAD_X10 - drain_pctph_x10) * 100) /
                   (ASB_SMART_QUALITY_BAT_BAD_X10 - ASB_SMART_QUALITY_BAT_GOOD_X10);
    }

    int overall;
    if (bat >= 0 && vendor >= 0)
        overall = (30 * bat + 30 * heat + 25 * stab + 15 * vendor) / 100;
    else if (bat >= 0)
        overall = (35 * bat + 35 * heat + 30 * stab) / 100;
    else if (vendor >= 0)
        overall = (45 * heat + 35 * stab + 20 * vendor) / 100;
    else
        overall = (55 * heat + 45 * stab) / 100;

    if (out) {
        out->q_battery = bat;
        out->q_heat = heat;
        out->q_stability = stab;
        out->q_vendor = vendor;
        int worst = 101, code = ASB_QFAIL_NONE;
        if (bat >= 0 && bat < worst)    { worst = bat;    code = ASB_QFAIL_BATTERY; }
        if (heat < worst)               { worst = heat;   code = ASB_QFAIL_HEAT; }
        if (stab < worst)               { worst = stab;   code = ASB_QFAIL_STABILITY; }
        /*
         * Vendor-war is named the primary failure only when it is the dominant cause by a
         * clear margin.
         */
        if (vendor >= 0 && vendor < worst - 15) { worst = vendor; code = ASB_QFAIL_VENDOR_WAR; }
        out->primary_failure = (worst < 70) ? code : ASB_QFAIL_NONE;
    }
    return overall;
}

static int __attribute__((unused)) asb_smart_session_quality(
        int drain_pctph_x10,
        int drain_valid,
        int max_temp_c,
        int thermal_entries,
        int recovery_count)
{
    /* device_median_c = 0: this thin wrapper has no access to the learned median, so it
     * keeps the absolute fallback thresholds. The argument order matters - the median
     * goes BEFORE out, and appending it blindly put it in out's place. */
    return asb_smart_session_quality_ex(drain_pctph_x10, drain_valid,
                                        max_temp_c, thermal_entries,
                                        recovery_count, -1,
                                        0, NULL);
}

static void asb_smart_apply_thermal_trend(
        int cpu_max_c,
        time_t now,
        uint64_t app_hash,
        int early_engage,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    rt->thermal_trend_bump = 0;

    if (cpu_max_c <= 0) {
        g_smart_trend_prev_ts = 0;
        g_smart_trend_slope_mc_min = 0;
        return;
    }
    if (g_smart_trend_prev_ts == 0 ||
        (long)(now - g_smart_trend_prev_ts) > ASB_SMART_TREND_STALE_S ||
        now < g_smart_trend_prev_ts) {
        g_smart_trend_prev_c = cpu_max_c;
        g_smart_trend_prev_ts = now;
        g_smart_trend_slope_mc_min = 0;
        return;
    }
    long dt = (long)(now - g_smart_trend_prev_ts);
    if (dt >= ASB_SMART_TREND_WINDOW_S) {
        long raw = ((long)(cpu_max_c - g_smart_trend_prev_c) * 60000L) / dt;
        if (raw > 60000L) raw = 60000L;
        if (raw < -60000L) raw = -60000L;
        g_smart_trend_slope_mc_min = (g_smart_trend_slope_mc_min + (int)raw) / 2;
        g_smart_trend_prev_c = cpu_max_c;
        g_smart_trend_prev_ts = now;
        if (g_smart_trend_slope_mc_min >= ASB_SMART_APPHEAT_LEARN_SLOPE_MC_MIN &&
            cpu_max_c >= ASB_SMART_TREND_MIN_TEMP_C) {
            asb_smart_appheat_bump(app_hash, now);
        }
    }

    if (rt->thermal_veto) return;

    int appheat_hot = (asb_smart_appheat_score(app_hash, now) >= ASB_SMART_APPHEAT_HOT_SCORE);
    /* Publish it for the FSM's thermal path, which runs in a header included earlier and
       so cannot ask the question itself. */
    g_asb_appheat_hot = appheat_hot;
    /* early_engage carries the level: 0=none, 1=cool-gaming/known-hot,
       2=charge-aware cool gaming. A known-hot app maps to level 1. */
    int hot_app = early_engage;
    if (hot_app < 1 && appheat_hot) hot_app = 1;
    int bump = asb_smart_thermal_trend_bump_calc(cpu_max_c, g_smart_trend_slope_mc_min, hot_app);
    if (bump > 0) {
        rt->thermal_trend_bump = bump;
        int target = rt->alpha_battery_x1000 + bump;
        if (target > 1000) target = 1000;
        if (target > rt->alpha_battery_x1000) rt->alpha_battery_x1000 = target;
    }
}

/*
 * — Memory pressure adaptation.
 */
static int asb_smart_memory_pressure_shift(void) {
    FILE *f = fopen("/proc/pressure/memory", "r");
    if (!f) return 0;
    char line[256];
    int shift = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "some ", 5) != 0) continue;
        /* Parse avg10=X.YZ */
        char *p = strstr(line, "avg10=");
        if (!p) break;
        p += 6;
        int whole = 0, frac = 0;
        if (sscanf(p, "%d.%d", &whole, &frac) >= 1) {
            /* avg10 ≥ 20.0 → high pressure → +100 to alpha (more battery-lean)
             * avg10 ≥ 5.0  → mild pressure → +50
             * else no-op */
            if (whole >= 20) shift = 100;
            else if (whole >= 5) shift = 50;
        }
        break;
    }
    fclose(f);
    return shift;
}

static void asb_smart_apply_memory_pressure(asb_smart_runtime_t *rt) {
    if (!rt) return;
    if (rt->night_safe_override || rt->thermal_veto) return;  /* higher prio wins */
    int shift = asb_smart_memory_pressure_shift();
    if (shift > 0) {
        int a = rt->alpha_battery_x1000 + shift;
        if (a > ASB_SMART_ALPHA_BATTERY_MAX_X1000) a = ASB_SMART_ALPHA_BATTERY_MAX_X1000;
        rt->alpha_battery_x1000 = a;
    }
}

/*
 * — Signal-aware net_conservative adjustment.
 */
static int asb_smart_radio_weak_signal(void) {
    DIR *d = opendir("/sys/class/net");
    if (!d) return 0;
    struct dirent *e;
    int rmnet_up = 0, rmnet_total = 0;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "rmnet", 5) != 0) continue;
        rmnet_total++;
        char path[256];
        snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char state[32] = {0};
        if (fgets(state, sizeof(state), f)) {
            if (strncmp(state, "up", 2) == 0) rmnet_up++;
        }
        fclose(f);
    }
    closedir(d);
    /* If 0 rmnet interfaces, we can't tell — return 0 (no signal info) */
    if (rmnet_total == 0) return 0;
    /* "Weak" heuristic: less than half of rmnet interfaces are up */
    return (rmnet_up * 2 < rmnet_total) ? 1 : 0;
}

static void asb_smart_apply_signal_aware(asb_smart_runtime_t *rt) {
    if (!rt) return;
    if (rt->night_safe_override || rt->thermal_veto) return;
    if (asb_smart_radio_weak_signal()) {
        /* Weak signal — bump net_conservative by +200 (clamped to max) */
        int nc = rt->net_conservative_x1000 + 200;
        if (nc > ASB_SMART_NET_CONSERV_MAX_X1000) nc = ASB_SMART_NET_CONSERV_MAX_X1000;
        rt->net_conservative_x1000 = nc;
    }
}

/*
 * — Refresh-rate-aware interactive_bonus shift.
 * Lower panel refresh rate (60 Hz vs 144 Hz) inherently means less GPU/CPU frame work per
 * second.
 */
static int asb_smart_refresh_rate_hz(void) {
    static const char *paths[] = {
        "/sys/class/drm/sde-crtc-0/measured_fps",
        "/sys/class/graphics/fb0/measured_fps",
        "/sys/class/drm/card0-DSI-1/measured_fps",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        int fps = 0;
        if (fscanf(f, "%d", &fps) == 1) {
            fclose(f);
            if (fps > 0) return fps;
        } else {
            fclose(f);
        }
    }
    return 0;
}

static void asb_smart_apply_refresh_rate(asb_smart_runtime_t *rt) {
    if (!rt) return;
    if (rt->night_safe_override || rt->thermal_veto) return;
    int hz = asb_smart_refresh_rate_hz();
    if (hz <= 0) return;
    /*
     * At 60 Hz, reduce interactive_bonus by ~30% (save more without UX hit).
     */
    int scale_x100;
    if (hz <= 65) scale_x100 = 70;          /* 60 Hz */
    else if (hz <= 95) scale_x100 = 85;     /* 90 Hz */
    else return;                            /* ≥ 120 Hz: full bonus */

    int reduced = (rt->interactive_bonus_x1000 * scale_x100) / 100;
    if (reduced < ASB_SMART_INTERACTIVE_MIN_X1000) reduced = ASB_SMART_INTERACTIVE_MIN_X1000;
    rt->interactive_bonus_x1000 = reduced;
}

/*
 * — Gaming app cap relaxation.
 */
static void asb_smart_apply_gaming_relax(int app_hint, int cpu_max_c,
                                          asb_smart_runtime_t *rt) {
    if (!rt) return;
    if (rt->night_safe_override || rt->thermal_veto) return;
    if (app_hint < ASB_APP_GAMING) return;
    if (cpu_max_c >= ASB_SMART_GAMING_RELAX_TEMP_C) return;
    if (rt->alpha_battery_x1000 > 400) {
        rt->alpha_battery_x1000 = 400;
    }
}

/*
 * - Camera relax.
 * Smart mode's battery lean is the second half of the 4K60 stutter: the FSM can be held at
 * HEAVY and still be handed battery-shaped rails, because the blend between the battery and
 * balanced bounds is driven by alpha.
 */
static void asb_smart_apply_camera_relax(int camera_active,
                                         asb_smart_runtime_t *rt) {
    if (!rt) return;
    if (!camera_active) return;
    if (rt->night_safe_override) return;
    if (rt->alpha_battery_x1000 > 200)
        rt->alpha_battery_x1000 = 200;
    if (rt->interactive_bonus_x1000 < 200)
        rt->interactive_bonus_x1000 = 200;
}

/* ============================================================
 * modifiers: combined apply. Call after night_override+thermal_veto. */
static void asb_smart_apply_v48_modifiers(
        int app_hint,
        int cpu_max_c,
        asb_smart_runtime_t *rt)
{
    if (!rt) return;
    asb_smart_apply_memory_pressure(rt);
    asb_smart_apply_signal_aware(rt);
    asb_smart_apply_refresh_rate(rt);
    asb_smart_apply_gaming_relax(app_hint, cpu_max_c, rt);
}

/*
 * Blend two profile bounds structures using alpha_battery_x1000.
 * Output is clamped to never exceed balanced sustained envelope.
 */
static void asb_smart_blend_values_int(
        const int *battery_vals,
        const int *balanced_vals,
        int n,
        int alpha_battery_x1000,
        int *out_vals)
{
    if (!battery_vals || !balanced_vals || !out_vals || n <= 0) return;
    int a = asb_clamp_int(alpha_battery_x1000, 0, 1000);
    int inv = 1000 - a;
    for (int i = 0; i < n; i++) {
        int b_val = battery_vals[i];
        int x_val = balanced_vals[i];
        /* If both zero, output zero. If one is zero and other not, use non-zero. */
        if (b_val == 0 && x_val == 0) {
            out_vals[i] = 0;
            continue;
        }
        int blended = (b_val * a + x_val * inv) / 1000;
        /* Hard cap: never exceed balanced value */
        if (blended > x_val) blended = x_val;
        /* Hard floor: never go below battery value */
        if (blended < b_val) blended = b_val;
        out_vals[i] = blended;
    }
}

/* Apply interactive_bonus to a CPU cap value. Bonus is relative (×1000),
 * applied as small upward modifier, but never exceeds balanced ceiling. */
static int asb_smart_apply_interactive_bonus(
        int blended_val, int balanced_ceiling, int interactive_bonus_x1000)
{
    if (interactive_bonus_x1000 <= 0) return blended_val;
    int bonus = (blended_val * interactive_bonus_x1000) / 1000;
    int boosted = blended_val + bonus;
    if (boosted > balanced_ceiling) boosted = balanced_ceiling;
    return boosted;
}

/*
 * Update bucket bias values from one session outcome.
 */
typedef struct {
    int dur_s;
    int max_temp_c;
    int max_skin_c;
    int drain_pctph_x10;
    int drain_on_sec;
    int trust;            /* ASB_TRUST_* */
    int was_heavy;        /* 0/1 had heavy/gaming time */
    int was_thermal_hit;  /* 0/1 reached thermal_throttle */
    int sustained_pct;    /* 0-100 fraction of time in SUSTAINED */
    int idle_q_x10;       /* idle quality if applicable */
    int screen_on_pct;    /* 0-100 */
} asb_smart_session_input_t;

static void asb_smart_bucket_update_from_session(
        asb_smart_bucket_t *b,
        const asb_smart_session_input_t *s,
        time_t now)
{
    if (!b || !s) return;

    /* Reject DIRTY sessions entirely — don't pollute learning */
    if (s->trust == ASB_TRUST_DIRTY) return;

    int eff_add = (int)asb_smart_eff_obs_add_x100(s->dur_s, s->trust);
    if (eff_add <= 0) return;

    /* Accumulate eff_obs with cap at 2× full (40.0 × 100 = 4000) to allow
     * old buckets to still drift on new data without saturating instantly */
    int new_eff = (int)b->eff_obs_x100 + eff_add;
    if (new_eff > 4000) new_eff = 4000;
    b->eff_obs_x100 = (uint16_t)new_eff;
    b->observations_raw++;
    b->last_seen_ts = (uint32_t)now;

    int lr = ASB_SMART_LEARN_RATE_X1000;  /* 5% per session */

    /* Direction signals:
     *   was_hot     → bias toward battery (+alpha)
     *   was_drainy  → bias toward battery (+alpha)
     *   was_clean_cool → allow slight balanced (-alpha) and interactive (+bonus)
     *   was_thermal_hit → strong push to battery + suppress interactive
     */
    int dt_alpha = 0;
    int dt_inter = 0;
    int dt_sleep = 0;
    int dt_net   = 0;

    int hot = (s->max_temp_c >= 70);
    int very_hot = (s->max_temp_c >= 80);
    int drain_valid = (s->drain_on_sec >= ASB_SMART_DRAIN_MIN_ON_SEC &&
                       s->drain_pctph_x10 >= 0);
    int drainy = (drain_valid &&
                  s->drain_pctph_x10 >= ASB_SMART_DRAIN_HEAVY_PCTPH_X10);
    int sustained_heavy = (s->sustained_pct >= 30);
    int clean_cool = (s->max_temp_c < 55 && s->trust == ASB_TRUST_CLEAN);

    if (very_hot)  dt_alpha += 80;
    else if (hot)  dt_alpha += 40;
    if (drainy)    dt_alpha += 30;
    if (sustained_heavy) dt_alpha += 20;
    if (s->was_thermal_hit) {
        dt_alpha += 100;
        dt_inter -= 50;
    }
    if (clean_cool) {
        dt_alpha -= 60;
        dt_inter += 25;
    }

    /* Sleep/idle quality */
    if (s->screen_on_pct < 5 && s->dur_s > 1800) {
        /* Long screen-off session with clean idle */
        if (s->trust == ASB_TRUST_CLEAN && s->idle_q_x10 >= 50) {
            dt_sleep += 30;
            dt_net   += 20;
        } else if (s->trust == ASB_TRUST_NOISY) {
            /* Wake-noisy night session - reduce confidence in sleep behaviour */
            dt_sleep -= 20;
        }
    }

    /* Scale all deltas by learning rate */
    dt_alpha = (dt_alpha * lr) / 1000;
    dt_inter = (dt_inter * lr) / 1000;
    dt_sleep = (dt_sleep * lr) / 1000;
    dt_net   = (dt_net   * lr) / 1000;

    /* Apply with clamps */
    int new_alpha = (int)b->alpha_battery_x1000 + dt_alpha;
    b->alpha_battery_x1000 = asb_clamp_u16(new_alpha,
        ASB_SMART_ALPHA_BATTERY_MIN_X1000, ASB_SMART_ALPHA_BATTERY_MAX_X1000);

    int new_inter = (int)b->interactive_bonus_x1000 + dt_inter;
    b->interactive_bonus_x1000 = asb_clamp_i16(new_inter,
        ASB_SMART_INTERACTIVE_MIN_X1000, ASB_SMART_INTERACTIVE_MAX_X1000);

    int new_sleep = (int)b->sleep_bias_x1000 + dt_sleep;
    b->sleep_bias_x1000 = asb_clamp_u16(new_sleep,
        ASB_SMART_SLEEP_BIAS_MIN_X1000, ASB_SMART_SLEEP_BIAS_MAX_X1000);

    int new_net = (int)b->net_conservative_x1000 + dt_net;
    b->net_conservative_x1000 = asb_clamp_u16(new_net,
        ASB_SMART_NET_CONSERV_MIN_X1000, ASB_SMART_NET_CONSERV_MAX_X1000);

    /* Update running averages with EMA (alpha = 0.2 = 1/5) */
    if (b->avg_max_temp_x10 == 0) b->avg_max_temp_x10 = (uint16_t)(s->max_temp_c * 10);
    else b->avg_max_temp_x10 = (uint16_t)((b->avg_max_temp_x10 * 4 + s->max_temp_c * 10) / 5);

    if (drain_valid) {
        int sample = s->drain_pctph_x10;
        if (sample > 6000) sample = 6000;
        int ewma = (int)b->avg_drain_pctph_x10;
        if (ewma == 0) {
            b->avg_drain_pctph_x10 = (uint16_t)sample;
        } else {
            int hi = (ewma * ASB_SMART_DRAIN_HI_NUM) / ASB_SMART_DRAIN_HI_DEN;
            int lo = (ewma * ASB_SMART_DRAIN_LO_NUM) / ASB_SMART_DRAIN_LO_DEN;
            int feedback = 0;
            if (sample > hi && !s->was_thermal_hit) feedback = 60;
            else if (sample < lo && s->trust == ASB_TRUST_CLEAN) feedback = -30;
            if (feedback != 0) {
                feedback = (feedback * lr) / 1000;
                int na = (int)b->alpha_battery_x1000 + feedback;
                b->alpha_battery_x1000 = asb_clamp_u16(na,
                    ASB_SMART_ALPHA_BATTERY_MIN_X1000,
                    ASB_SMART_ALPHA_BATTERY_MAX_X1000);
            }
            b->avg_drain_pctph_x10 = (uint16_t)((ewma * 3 + sample) / 4);
        }
    }

    if (s->idle_q_x10 > 0) {
        if (b->avg_idle_q_x10 == 0) b->avg_idle_q_x10 = (uint16_t)s->idle_q_x10;
        else b->avg_idle_q_x10 = (uint16_t)((b->avg_idle_q_x10 * 4 + s->idle_q_x10) / 5);
    }

    /* Refresh cached confidence */
    b->conf_x1000 = asb_smart_confidence_x1000(b, now);
}

/*
 * Slot-update gating: returns 1 if PROFILE_SMART bounds should be recomputed this tick, 0 if
 * cached values are still valid.
 */
static int asb_smart_should_update_slot(
        const asb_smart_runtime_t *rt,
        time_t now,
        int charging,
        int app_hint)
{
    if (!rt) return 1;
    if (rt->last_slot_update_ts == 0) return 1;

    /* Bucket / fallback / daypart changed */
    if (rt->bucket_id != rt->prev_bucket_id) return 1;
    if (rt->daypart  != rt->prev_daypart)  return 1;

    /* Confidence tier crossed a boundary */
    int cur_tier = asb_smart_confidence_tier(rt->conf_x1000);
    if (cur_tier != rt->last_conf_tier) return 1;

    /* Night override or thermal veto state changed */
    if (rt->night_safe_override != rt->last_night_override) return 1;
    if (rt->thermal_veto != rt->last_thermal_veto) return 1;

    /* Charging state changed */
    if (charging != rt->last_charging) return 1;

    /* App hint tier changed (group app hints into 3 tiers for fewer churn:
     * 0=idle/light, 1=medium, 2=heavy/gaming) */
    int cur_app_tier = (app_hint <= ASB_APP_LIGHT) ? 0 :
                       (app_hint == ASB_APP_MEDIUM) ? 1 : 2;
    if (cur_app_tier != rt->last_app_hint_tier) return 1;

    /* Otherwise, no update needed */
    return 0;
}

/* Mark slot updated; remember current gating state */
static void asb_smart_mark_slot_updated(
        asb_smart_runtime_t *rt,
        time_t now,
        int charging,
        int app_hint)
{
    if (!rt) return;
    rt->last_slot_update_ts = now;
    rt->last_conf_tier = asb_smart_confidence_tier(rt->conf_x1000);
    rt->last_charging = charging;
    rt->last_app_hint_tier = (app_hint <= ASB_APP_LIGHT) ? 0 :
                             (app_hint == ASB_APP_MEDIUM) ? 1 : 2;
    rt->last_night_override = rt->night_safe_override;
    rt->last_thermal_veto = rt->thermal_veto;
    rt->prev_bucket_id = rt->bucket_id;
    rt->prev_daypart   = rt->daypart;
}

/*
 * Daypart transition smoothing helper.
 * Otherwise returns 100 (full new bucket, hard switch).
 */
static int asb_smart_daypart_smoothing_factor_x100(
        time_t smoothing_start,
        time_t now,
        int prev_conf_x1000,
        int cur_conf_x1000)
{
    if (smoothing_start == 0) return 100;
    if (prev_conf_x1000 < ASB_SMART_CONF_LOW_X1000) return 100;
    if (cur_conf_x1000  < ASB_SMART_CONF_LOW_X1000) return 100;
    int elapsed = (int)(now - smoothing_start);
    if (elapsed >= ASB_SMART_SMOOTH_S) return 100;
    if (elapsed <  0) return 0;
    return (elapsed * 100) / ASB_SMART_SMOOTH_S;
}

#endif
