#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/types.h>
#include "asb_config.h"
extern asb_runtime_config_t g_asb_cfg;

#define PATH_BATT_CURRENT   "/sys/class/power_supply/battery/current_now"
#define PATH_BATT_VOLTAGE   "/sys/class/power_supply/battery/voltage_now"
#define PATH_BATT_CAPACITY  "/sys/class/power_supply/battery/capacity"
#define PATH_BATT_STATUS    "/sys/class/power_supply/battery/status"
#define PATH_BATT_TEMP      "/sys/class/power_supply/battery/temp"

#define PATH_GPU_LOAD       "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
#define PATH_GPU_FREQ       "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq"
#define PATH_GPU_MAXFREQ    "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"

#define PATH_LOADAVG        "/proc/loadavg"
#define PATH_MEMINFO        "/proc/meminfo"

#define PATH_SCREEN_STATUS  "/sys/kernel/oplus_display/panel_power_status"
#define PATH_SCREEN_STATUS2 "/sys/kernel/oplus_display/disp_on_notify"
#define PATH_BACKLIGHT      "/sys/class/backlight/panel0-backlight/brightness"

#define PATH_CPU_POLICY0    "/sys/devices/system/cpu/cpufreq/policy0"
#define PATH_CPU_POLICY4    "/sys/devices/system/cpu/cpufreq/policy4"
#define PATH_CPU_POLICY6    "/sys/devices/system/cpu/cpufreq/policy6"
#define PATH_CPU_POLICY7    "/sys/devices/system/cpu/cpufreq/policy7"

#define PATH_CPU_POLICIES_DEFAULT "0,6"

/* Host fixtures may override only the base directory at compile time; device builds retain
 * the Android thermal sysfs default unchanged. */
#ifndef THERMAL_BASE
#define THERMAL_BASE        "/sys/class/thermal"
#endif
#define THERMAL_MAX_ZONES   128

#define PATH_WALT_RAVG      "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define PATH_WALT_IDLE      "/proc/sys/walt/sched_idle_enough"

#define PATH_WLAN_TX        "/sys/class/net/wlan0/statistics/tx_bytes"
#define PATH_WLAN_RX        "/sys/class/net/wlan0/statistics/rx_bytes"
static long sysfs_read_long(const char *path, long def);

static long rmnet_read_total(const char *direction) {
    /* direction = "tx_bytes" or "rx_bytes" */
    long total = 0;
    char path[128];
    const char *ifaces[] = {"rmnet_data0", "rmnet_data1", "rmnet_data2", "rmnet_ipa0", NULL};
    for (int i = 0; ifaces[i]; i++) {
        snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/%s", ifaces[i], direction);
        long v = sysfs_read_long(path, 0);
        if (v > 0) total += v;
    }
    return total;
}

typedef struct {
    int     current_ua;
    int     voltage_uv;
    int     capacity_pct;
    int     temp_dC;
    int     charging;
    int     current_ma;
} asb_battery_t;

typedef struct {
    int     load_pct;
    int     load_valid;          /* 1 only when a backend reports a 0..100 utilisation value */
    long    cur_freq_hz;
    long    max_freq_hz;
} asb_gpu_t;

typedef struct {
    float   load1;
    float   load5;
    int     cur_freq[3];
    int     max_freq[3];
} asb_cpu_t;

typedef struct {
    int     cpu_max_c;
    int     gpu_temp_c;
    int     skin_temp_c;           /* literal shell (front/frame/back) */
    int     surface_hotspot_c;     /* hottest body-adjacent zone (sys-therm-6 etc) */
    int     board_temp_c;          /* explicit board_temp for long-gaming heat analysis */
    int     throttling;     /* real thermal: temp >= threshold */
    int     soft_clamp;     /* vendor advisory: headroom < soft_pct */
    int     hard_clamp;     /* vendor actionable: headroom < hard_pct */
    int     temp_valid;     /* 1=fresh read, 0=stale/skipped */
    int     temp_age_s;     /* seconds since last real thermal read */
    /* when temp_valid=0, this records WHY for diagnostic clarity.
     * Values: "ok", "no_zone", "read_fail", "stale", "raw_too_low", "init", "fb_used" */
    char    temp_invalid_reason[16];
    int     perf_cap_p0;    /* kernel-allowed max freq for policy0 (kHz) */
    int     perf_cap_p6;    /* kernel-allowed max freq for policy6 (kHz) */
    int     headroom_pct;   /* thermal headroom: 100=full, 0=fully throttled */
    int     headroom_valid; /* 1=real read, 0=skipped or failed */
    char    headroom_invalid_reason[16];  /* "ok","stuck_100","read_fail","no_iface" */
    int     used_fallback;  /* 1 if this tick used fallback CPU zone instead of primary */
    int     fallback_just_flipped; /* 1 for one tick when used_fallback state flips */
    /*
     * GPU vendor thermal cap (KGSL pwrlevel).
     */
    int     gpu_thermal_pwrlevel;
    int     gpu_thermal_pwrlevel_active;  /* 1 = vendor capping above our write */
} asb_thermal_t;

typedef struct {
    int     screen_on;
    long    wlan_tx_bps;
    long    wlan_rx_bps;
    /* radio-aware -- mobile data activity */
    long    rmnet_tx_bps;
    long    rmnet_rx_bps;
    /* 1 = the camera pipeline is streaming (preview, capture or video).
     * Derived from the camera HAL provider's own CPU time, so it covers every
     * camera app rather than a package list, and it needs no permissions. */
    int     camera_active;
} asb_misc_t;

typedef struct {
    asb_battery_t   bat;
    asb_gpu_t       gpu;
    asb_cpu_t       cpu;
    asb_thermal_t   therm;
    asb_misc_t      misc;
    struct timespec ts;
} asb_metrics_t;

static inline int sysfs_read_int(const char *path, int def) {
    char buf[32];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return def;
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return def;
    buf[n] = '\0';
    return (int)strtol(buf, NULL, 10);
}

static inline long sysfs_read_long(const char *path, long def) {
    char buf[32];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return def;
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return def;
    buf[n] = '\0';
    return strtol(buf, NULL, 10);
}

static inline int sysfs_read_str(const char *path, char *out, int maxlen) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int n = read(fd, out, maxlen - 1);
    close(fd);
    if (n > 0) {
        out[n] = '\0';
        /* strip trailing newline/CR/space. sysfs text nodes almost
         * always end with '\n' which breaks JSON embedding downstream. */
        while (n > 0 && (out[n-1] == '\n' || out[n-1] == '\r' || out[n-1] == ' ')) {
            out[--n] = '\0';
        }
        return n;
    }
    return -1;
}

static const char *g_batt_current_paths[] = {
    "/sys/class/power_supply/battery/current_now",
    "/sys/class/power_supply/bms/current_now",
    "/sys/class/power_supply/Battery/current_now",
    NULL
};
static int g_batt_current_path_idx = -1;

static int metrics_find_batt_current_path(void) {
    if (g_batt_current_path_idx >= 0) return g_batt_current_path_idx;
    for (int i = 0; g_batt_current_paths[i]; i++) {
        int fd = open(g_batt_current_paths[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); g_batt_current_path_idx = i; return i; }
    }
    return -1;
}

static int g_batt_cur_unit = 0;
static int g_batt_cur_samples = 0;
static long g_batt_cur_peak = 0;

static int asb_batt_current_to_ma(long raw) {
    long a = labs(raw);
    if (g_batt_cur_unit == 0) {
        if (a > g_batt_cur_peak) g_batt_cur_peak = a;
        if (a >= 100000) g_batt_cur_unit = 1;
        else {
            g_batt_cur_samples++;
            /* A low peak is not proof of milliamps.
             *
             * 50000 was chosen as "no phone draws less than 50 mA", and that is true of a
             * phone in use - but not of one asleep, which sits at 10-30 mA. A module that
             * starts while the phone is idle sees thirty samples under the threshold and
             * concludes the node reports milliamps. From then on 20000 uA is read as
             * 20000 mA: three battery capacities per hour, on a device drawing 20.
             *
             * The extra condition is a sanity check on the CONCLUSION rather than on the
             * samples. If these really were milliamps, the peak would be a plausible
             * current for a phone - tens to hundreds. A peak of 20000 in milliamps is
             * 20 amps, which no phone draws, so the milliamp reading must be wrong.
             *
             * 5000 as the ceiling: a phone can pull 5 A while fast-charging, and nothing
             * legitimate goes above that. */
            if (g_batt_cur_samples >= 30 && g_batt_cur_peak > 0 &&
                g_batt_cur_peak < 50000 && g_batt_cur_peak <= 5000) {
                g_batt_cur_unit = 2;
            }
        }
    }
    if (g_batt_cur_unit == 2) return (int)(a > 100000 ? 0 : a);
    return (int)(a / 1000);
}

/* Set by the governor while Quiet Night is economising a tick. Declared here because the
 * probes it guards live in this header; defined in asb_governor.c. */
extern int g_qn_skip_this_tick;

/* Which power_supply node supplied the current reading this tick. */
static char g_batt_current_source[24] = "unknown";

static void metrics_read_battery(asb_battery_t *b) {
    /* Quiet Night: reuse last tick's numbers instead of touching power_supply.
     *
     * Four sysfs reads per tick, on a phone that is asleep and whose battery state cannot
     * have moved meaningfully in five seconds. The previous values stay in *b because the
     * caller keeps the struct between ticks, so consumers see a slightly stale figure
     * rather than a zeroed one - which matters, since zero here reads as "on charger".
     */
    if (g_qn_skip_this_tick) return;

    int idx = metrics_find_batt_current_path();
    if (idx >= 0) {
        b->current_ua = sysfs_read_int(g_batt_current_paths[idx], 0);
        /* P0-4: remember WHICH source answered.
         *
         * The paths are tried in order and differ in meaning: current_now is instantaneous
         * and noisy, current_avg is already smoothed by the gauge, and a vendor bms node
         * may be either. A %/h figure derived from one is not the same claim as the same
         * figure derived from another, and the report presented them identically. */
        snprintf(g_batt_current_source, sizeof(g_batt_current_source), "%s",
                 strstr(g_batt_current_paths[idx], "current_avg") ? "current_avg" :
                 strstr(g_batt_current_paths[idx], "bms")         ? "vendor_bms"  :
                                                                    "current_now");
    } else {
        b->current_ua = 0;
    }
    b->voltage_uv   = sysfs_read_int(PATH_BATT_VOLTAGE, 3800000);
    b->capacity_pct = sysfs_read_int(PATH_BATT_CAPACITY, 50);
    b->temp_dC      = sysfs_read_int(PATH_BATT_TEMP, 250);
    b->current_ma   = asb_batt_current_to_ma(b->current_ua);

    char st[16] = {0};
    sysfs_read_str(PATH_BATT_STATUS, st, sizeof(st));
    b->charging = (st[0] == 'C') ? 1 : 0;
}

static char g_metrics_gpu_freq_path[160]    = {0};
static char g_metrics_gpu_maxfreq_path[160] = {0};
static char g_metrics_gpu_load_path[160]    = {0};
static int  g_metrics_gpu_paths_ready       = 0;

/* Only inspect generic devfreq directories whose own name identifies a graphics device.
 * Never guess from an arbitrary devfreq node: memory, ISP and NPU nodes expose the same
 * max_freq filenames but must not be reported as GPU telemetry. */
static int metrics_gpu_devfreq_name_is_graphics(const char *name) {
    if (!name || !*name) return 0;
    char lower[128]; size_t n = strlen(name);
    if (n >= sizeof(lower)) n = sizeof(lower) - 1;
    for (size_t i = 0; i < n; i++) lower[i] = (char)tolower((unsigned char)name[i]);
    lower[n] = '\0';
    return strstr(lower, "gpu") || strstr(lower, "mali") ||
           strstr(lower, "kgsl") || strstr(lower, "adreno") ||
           strstr(lower, "powervr") || strstr(lower, "xclipse");
}

static void metrics_discover_generic_gpu_devfreq(void) {
    DIR *dir = opendir("/sys/class/devfreq");
    if (!dir) return;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (de->d_name[0] == '.' || !metrics_gpu_devfreq_name_is_graphics(de->d_name)) continue;
        char cur[160], max[160], load[160];
        snprintf(cur, sizeof(cur), "/sys/class/devfreq/%s/cur_freq", de->d_name);
        snprintf(max, sizeof(max), "/sys/class/devfreq/%s/max_freq", de->d_name);
        snprintf(load, sizeof(load), "/sys/class/devfreq/%s/load", de->d_name);
        if (!g_metrics_gpu_freq_path[0] && access(cur, R_OK) == 0)
            snprintf(g_metrics_gpu_freq_path, sizeof(g_metrics_gpu_freq_path), "%s", cur);
        if (!g_metrics_gpu_maxfreq_path[0] && access(max, R_OK) == 0)
            snprintf(g_metrics_gpu_maxfreq_path, sizeof(g_metrics_gpu_maxfreq_path), "%s", max);
        if (!g_metrics_gpu_load_path[0] && access(load, R_OK) == 0)
            snprintf(g_metrics_gpu_load_path, sizeof(g_metrics_gpu_load_path), "%s", load);
        if (g_metrics_gpu_freq_path[0] && g_metrics_gpu_maxfreq_path[0]) break;
    }
    closedir(dir);
}

static void metrics_discover_gpu_paths(void) {
    if (g_metrics_gpu_paths_ready) return;

    static const char *load_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
        NULL
    };
    static const char *cur_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/cur_freq",
        "/sys/class/kgsl/kgsl-3d0/gpuclk",
        NULL
    };
    static const char *max_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/max_freq",
        "/sys/class/kgsl/kgsl-3d0/max_gpuclk",
        NULL
    };

    for (int i = 0; load_candidates[i]; i++) {
        if (access(load_candidates[i], R_OK) == 0) {
            snprintf(g_metrics_gpu_load_path, sizeof(g_metrics_gpu_load_path),
                     "%s", load_candidates[i]);
            break;
        }
    }
    for (int i = 0; cur_freq_candidates[i]; i++) {
        int fd = open(cur_freq_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            snprintf(g_metrics_gpu_freq_path, sizeof(g_metrics_gpu_freq_path),
                     "%s", cur_freq_candidates[i]);
            break;
        }
    }
    for (int i = 0; max_freq_candidates[i]; i++) {
        int fd = open(max_freq_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            snprintf(g_metrics_gpu_maxfreq_path, sizeof(g_metrics_gpu_maxfreq_path),
                     "%s", max_freq_candidates[i]);
            break;
        }
    }
    /* Standard devfreq GPUs (Mali, PowerVR, Xclipse and vendor-neutral nodes) are
     * discovered only by an explicit graphics name. KGSL stays preferred above. */
    if (!g_metrics_gpu_freq_path[0] || !g_metrics_gpu_maxfreq_path[0])
        metrics_discover_generic_gpu_devfreq();
    g_metrics_gpu_paths_ready = 1;
}

static void metrics_read_gpu(asb_gpu_t *g) {
    metrics_discover_gpu_paths();
    int load = g_metrics_gpu_load_path[0]
               ? sysfs_read_int(g_metrics_gpu_load_path, -1) : -1;
    g->load_valid = (load >= 0 && load <= 100) ? 1 : 0;
    g->load_pct = g->load_valid ? load : 0;
    g->cur_freq_hz = g_metrics_gpu_freq_path[0]
                     ? sysfs_read_long(g_metrics_gpu_freq_path, 0) : 0;
    g->max_freq_hz = g_metrics_gpu_maxfreq_path[0]
                     ? sysfs_read_long(g_metrics_gpu_maxfreq_path, 0) : 0;
    if (g->cur_freq_hz < 0) g->cur_freq_hz = 0;
    if (g->max_freq_hz < 0) g->max_freq_hz = 0;
}

static int g_cpu_policy_ids[3]   = {0, 6, -1};
/*
 * Every physical cpufreq policy id discovered (OP12 has 4: 0,2,5,7), plus the slot
 * (0=little,1=big,2=prime) each one is governed by.
 * Lets the writer apply a slot's cap to ALL clusters that belong to it, not just the
 * representative one — without this, OP12's second big cluster (policy2 or policy5) stays
 * unmanaged and pinned low in battery mode.
 */
static int g_cpu_all_ids[16];
static int g_cpu_all_slot[16];
static int g_cpu_all_count = 0;
static int g_cpu_policy_count    = 0;
/*
 * Real cpuinfo_max_freq (kHz) for each of the 3 logical slots, captured during topology
 * discovery.
 * the battery FLOOR of 921600 is 21% of OP13's prime, so when smart mode or the thermal net
 * pulls to the floor the UI freezes.
 */
static int g_cpu_slot_hwmax[3] = {0, 0, 0};
#define ASB_BOUNDS_REF_HWMAX_LITTLE 2035200  /* SM8650 policy0 reference */
#define ASB_BOUNDS_REF_HWMAX_BIG    3302400  /* SM8650 policy7 reference */
static void cpu_capture_slot_hwmax(void);

static void cpu_topology_discover(void) {
    if (g_cpu_policy_count > 0) return;

    /*
     * Dynamically enumerate the real cpufreq policies instead of assuming a fixed layout.
     * The old code only knew policy6 (->{0,6}) or a {0,4,7} fallback — neither matches OP12,
     * so its big clusters policy2 and policy5 were never managed and stayed pinned near their
     * minimum in the battery profile, which is exactly the "phone is unusable in battery mode"
     * sluggishness.
     */
    int found[16]; int nf = 0;
    for (int p = 0; p < 16 && nf < 16; p++) {
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq", p);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); found[nf++] = p; }
    }

    /* Policy IDs are CPU-number based implementation details, not a portable little→prime
     * ordering contract. Classify the discovered policies by their actual hardware ceiling
     * before assigning logical ASB slots; this covers SoCs whose cpufreq policy directories
     * are exposed in a non-frequency order. */
    int found_hwmax[16] = {0};
    for (int i = 0; i < nf; i++) {
        char path[128], b[32] = {0};
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq", found[i]);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            ssize_t n = read(fd, b, sizeof(b) - 1);
            close(fd);
            if (n > 0) found_hwmax[i] = atoi(b);
        }
        if (found_hwmax[i] <= 0) {
            snprintf(path, sizeof(path),
                     "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq", found[i]);
            fd = open(path, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                ssize_t n = read(fd, b, sizeof(b) - 1);
                close(fd);
                if (n > 0) found_hwmax[i] = atoi(b);
            }
        }
    }
    for (int i = 0; i < nf - 1; i++) {
        for (int j = i + 1; j < nf; j++) {
            if (found_hwmax[j] < found_hwmax[i] ||
                (found_hwmax[j] == found_hwmax[i] && found[j] < found[i])) {
                int ti = found[i]; found[i] = found[j]; found[j] = ti;
                ti = found_hwmax[i]; found_hwmax[i] = found_hwmax[j]; found_hwmax[j] = ti;
            }
        }
    }

    if (nf <= 0) {
        /* nothing found — keep the old safe default */
        g_cpu_policy_ids[0] = 0;
        g_cpu_policy_ids[1] = 6;
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 2;
        cpu_capture_slot_hwmax();
        return;
    }
    if (nf == 1) {
        g_cpu_policy_ids[0] = found[0];
        g_cpu_policy_ids[1] = -1;
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 1;
        cpu_capture_slot_hwmax();
        return;
    }
    if (nf == 2) {
        g_cpu_policy_ids[0] = found[0];
        g_cpu_policy_ids[1] = found[1];
        g_cpu_policy_ids[2] = -1;
        g_cpu_policy_count  = 2;
        g_cpu_all_ids[0] = found[0]; g_cpu_all_slot[0] = 0;
        g_cpu_all_ids[1] = found[1]; g_cpu_all_slot[1] = 1;
        g_cpu_all_count = 2;
        cpu_capture_slot_hwmax();
        return;
    }
    /*
     * 3+ clusters (OP12 has 4): policies have already been ordered by hardware max, so
     * slot0=little(first), slot2=prime(last), slot1=the strongest middle cluster. This keeps
     * the logical mapping correct even when policy directory numbers are not ordered by OPP.
     */
    int first = found[0];
    int last  = found[nf - 1];
    int mid   = found[1];
    int mid_best = -1;
    for (int i = 1; i < nf - 1; i++) {
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq",
                 found[i]);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        char b[32] = {0};
        int n = read(fd, b, sizeof(b) - 1); close(fd);
        if (n > 0) { int v = atoi(b); if (v > mid_best) { mid_best = v; mid = found[i]; } }
    }
    g_cpu_policy_ids[0] = first;
    g_cpu_policy_ids[1] = mid;
    g_cpu_policy_ids[2] = last;
    g_cpu_policy_count  = 3;

    /*
     * Record EVERY physical policy and which slot governs it, so the writer can mirror a
     * slot's cap onto all clusters it represents.
     */
    g_cpu_all_count = 0;
    for (int i = 0; i < nf && g_cpu_all_count < 16; i++) {
        int slot;
        if (found[i] == first)      slot = 0;
        else if (found[i] == last)  slot = 2;
        else                        slot = 1;
        g_cpu_all_ids[g_cpu_all_count]  = found[i];
        g_cpu_all_slot[g_cpu_all_count] = slot;
        g_cpu_all_count++;
    }
    cpu_capture_slot_hwmax();
}

/* Fill g_cpu_slot_hwmax[] from each slot's representative policy. Safe to call
 * after g_cpu_policy_ids[] is set. */
static void cpu_capture_slot_hwmax(void) {
    for (int s = 0; s < 3; s++) {
        g_cpu_slot_hwmax[s] = 0;
        if (g_cpu_policy_ids[s] < 0) continue;
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq",
                 g_cpu_policy_ids[s]);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        char b[32] = {0};
        int n = read(fd, b, sizeof(b) - 1); close(fd);
        if (n > 0) g_cpu_slot_hwmax[s] = atoi(b);
    }
}

/* msm_performance reports caps by Linux CPU number, not logical ASB slot. Never
 * divide a CPU-0 cap by slot-0 max until the discovered policy confirms that CPU 0
 * actually belongs there; policy numbering is not a portable topology contract. */
static int cpu_slot_contains_cpu(int slot, int cpu) {
    if (slot < 0 || slot > 2 || cpu < 0 || g_cpu_policy_ids[slot] < 0) return 0;
    char path[128], buf[128] = {0};
    snprintf(path, sizeof(path),
             "/sys/devices/system/cpu/cpufreq/policy%d/related_cpus",
             g_cpu_policy_ids[slot]);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    char *p = buf;
    while (*p) {
        char *end = NULL;
        long id = strtol(p, &end, 10);
        if (end != p && id == cpu) return 1;
        if (end == p) p++;
        else p = end;
    }
    return 0;
}

static int metrics_headroom_pct_from_cap(int cap_khz, int hwmax_khz, int *out_pct) {
    if (!out_pct || cap_khz <= 0 || hwmax_khz <= 0) return -1;
    long pct = (long)cap_khz * 100L / hwmax_khz;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    *out_pct = (int)pct;
    return 0;
}

/*
 * Scale an absolute bound (authored against the SM8650 reference) to this device's real
 * silicon for the given slot.
 */
/* Clamp a floor into what this cluster can actually do, without scaling it.
 *
 * Counterpart to asb_bounds_scale: ceilings scale with the hardware, floors do not. The
 * only per-device adjustment a floor needs is "not below the lowest step that exists" -
 * and cpufreq would round it up anyway, so stating it here keeps the request honest. */
static int asb_bounds_clamp_floor(int slot, int kHz) {
    if (kHz <= 0 || slot < 0 || slot > 2) return kHz;
    int hw = g_cpu_slot_hwmax[slot];
    /* Never above the cluster ceiling: a floor that exceeds hw_max is meaningless and the
     * kernel would silently pin it there. */
    if (hw > 0 && kHz > hw) kHz = hw;
    return kHz;
}

static int asb_bounds_scale(int slot, int kHz) {
    if (kHz <= 0 || slot < 0 || slot > 2) return kHz;
    int hw = g_cpu_slot_hwmax[slot];
    if (hw <= 0) return kHz;
    int ref = (slot == 0) ? ASB_BOUNDS_REF_HWMAX_LITTLE : ASB_BOUNDS_REF_HWMAX_BIG;
    if (ref <= 0) return kHz;
    long scaled = (long)kHz * hw / ref;
    if (scaled > hw) scaled = hw;          /* never exceed the cluster ceiling */
    if (scaled < 300000) scaled = 300000;  /* never below a sane floor */
    return (int)scaled;
}

static const char *cpu_policy_path(int slot, const char *file) {
    /* Eight slots, not four.
     *
     * The caller gets a pointer into a rotating buffer, so every result stays valid only
     * until the ring wraps. With four slots, four calls in one expression fill it exactly -
     * and asb_governor.c:2318 does precisely that. One more call anywhere in the same
     * statement, on any device with more clusters than the one it was written for, and the
     * first pointer starts reading a path built for a different policy.
     *
     * Nothing about that fails loudly: it produces a valid path to the wrong node. Eight
     * gives room for the widest expression in the tree plus the same again. */
    static char buf[8][128];
    static int idx = 0;
    idx = (idx + 1) & 7;
    if (g_cpu_policy_ids[slot] < 0) { buf[idx][0] =  0;    return buf[idx]; }
    snprintf(buf[idx], sizeof(buf[idx]),
             "/sys/devices/system/cpu/cpufreq/policy%d/%s",
             g_cpu_policy_ids[slot], file);
    return buf[idx];
}

static void metrics_read_cpu(asb_cpu_t *c) {
    cpu_topology_discover();

    char buf[64] = {0};
    sysfs_read_str(PATH_LOADAVG, buf, sizeof(buf));
    sscanf(buf, "%f %f", &c->load1, &c->load5);

    const char *cur_paths[3] = {
        cpu_policy_path(0, "scaling_cur_freq"),
        cpu_policy_path(1, "scaling_cur_freq"),
        (g_cpu_policy_ids[2] >= 0) ? cpu_policy_path(2, "scaling_cur_freq") : "",
    };
    const char *max_paths[3] = {
        cpu_policy_path(0, "scaling_max_freq"),
        cpu_policy_path(1, "scaling_max_freq"),
        (g_cpu_policy_ids[2] >= 0) ? cpu_policy_path(2, "scaling_max_freq") : "",
    };
    for (int i = 0; i < 3; i++) {
        int v = sysfs_read_int(cur_paths[i], 0);
        c->cur_freq[i] = v / 1000;
        v = sysfs_read_int(max_paths[i], 0);
        c->max_freq[i] = v / 1000;
    }
}

/* How far above the per-core median socd may read before it is treated as a scale
 * mismatch rather than a hotspot.
 *
 * A die sensor legitimately runs hotter than the cores around it - 10-15C under sustained
 * load is normal, and rejecting that would throw away the earliest warning the phone has.
 * 25C sits above any plausible hotspot delta and far below the 55C gap seen in the capture
 * that prompted this, so a real hotspot is never mistaken for a broken sensor.
 */
#define ASB_SOCD_MAX_ABOVE_PEERS_C 25

/* Confidence in the current thermal control source: 0 unknown, 1 low (derived or
 * unvalidated), 2 cross-checked against peers. */
static int g_thermal_source_confidence = 0;

static int g_thermal_cpu_zone     = -1;
static int g_thermal_skin_zone    = -1;  /* literal shell_front/frame/back only */
static int g_thermal_surface_zone = -1;  /* hottest body-adjacent zone (sys-therm-6 etc) */
static int g_thermal_board_zone  = -1;
static int g_thermal_cpu_fallback_zone = -1;
static char g_thermal_cpu_fallback_type[64] = "";
static char g_thermal_cpu_type[64] = "";
static char g_thermal_cpu_reason[256] = "uninitialized";

/* P0-2 provenance: what was rejected, and what it actually read.
 *
 * The report used to show one temperature with no indication of where it came from or
 * what was discarded to get it. When socd is thrown out for reading 92 against a 36C peer
 * median, that 92 is still evidence - it says the sensor exists and is broken - but it
 * must never appear next to a degree sign, because it is not degrees.
 *
 * Kept as a raw integer with a separate type field so every consumer has to decide how to
 * present it, rather than inheriting a formatted string that looks like a temperature.
 */
static char g_thermal_rejected_type[64] = "";
static int  g_thermal_rejected_raw = 0;      /* raw sysfs value, NOT degrees */

/* Consensus v2 state.
 *
 * Thresholds are asymmetric on purpose. A die sensor sitting 20C above the shell is
 * normal under load; one sitting 12C BELOW a peer that reads hot means it is blind to
 * something, and that is the direction that burns the user. */
#define ASB_CONSENSUS_MAX_ABOVE_C 30
#define ASB_CONSENSUS_MAX_BELOW_C 12
static char g_thermal_consensus_note[192] = "";
static int  g_thermal_peer_hi = 0;
static int  g_thermal_peer_lo = 0;
static int  g_thermal_peer_n  = 0;

static inline int thermal_raw_to_c(int raw) {
    if (raw <= 0) return 0;
    return (raw > 200) ? (raw / 1000) : raw;
}

static int thermal_sensor_validate(int zone) {
    char path[128];
    snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", zone);
    int v1 = sysfs_read_int(path, -999);
    if (v1 <= 0 || v1 == -999) return 0;          /* dead or unreadable */
    int c = thermal_raw_to_c(v1);
    if (c <= 0 || c > 120) return 0;               /* out of sane range */
    /* Quick flat check: read again, if identical raw value = suspicious */
    int v2 = sysfs_read_int(path, -999);
    int v3 = sysfs_read_int(path, -999);
    if (v1 == v2 && v2 == v3 && (c > 90 || c < 5)) return 0;  /* flat + extreme = dead */
    return 1;  /* sensor is alive */
}

static void thermal_discover(void) {
    char path[128], type[64];
    int best_cpu_prio = 99;
    int best_skin_prio = 99;
    int best_surface_prio = 99;
int preserve_cpu = (g_thermal_cpu_zone >= 0 && g_thermal_cpu_type[0] != '\0');
    if (!preserve_cpu) {
        g_thermal_cpu_zone = -1;
        g_thermal_cpu_type[0] = '\0';
        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source");
    } else {
        /* Keep current best_cpu_prio as high so no new candidate beats the
         * already-validated one just because it happens to read fine now. */
        best_cpu_prio = 0;
    }
    g_thermal_skin_zone = -1;
    g_thermal_surface_zone = -1;
    g_thermal_board_zone = -1;

    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        if (sysfs_read_str(path, type, sizeof(type)) < 0) continue;
        /* strip trailing newline. sysfs reads return "socd\n" not "socd",
         * and the embedded \n later breaks JSON parsing when thermal_cpu_type is
         * emitted into the status payload. */
        {
            int _tl = (int)strlen(type);
            while (_tl > 0 && (type[_tl-1] == '\n' || type[_tl-1] == '\r' || type[_tl-1] == ' ')) {
                type[--_tl] = '\0';
            }
        }
int cpu_prio = -1;
        const char *cpu_reason = NULL;
        if (strcmp(type, "socd") == 0) {
            cpu_prio = 1;
            cpu_reason = "priority=1 socd die hotspot (real peak)";
        } else if (strstr(type, "cpu-1-1-")) {
            cpu_prio = 2;
            cpu_reason = "priority=2 cpu-1-1-* prime core";
        } else if (strstr(type, "cpu-0-5-")) {
            cpu_prio = 3;
            cpu_reason = "priority=3 cpu-0-5-* top perf core";
        } else if (strstr(type, "cpuss-0") || strcmp(type, "cpu-1-1") == 0) {
            /* Legacy pre-OP15 fallback for other SoCs that do have these */
            cpu_prio = 4;
            cpu_reason = "priority=4 legacy cluster aggregate";
        } else if (strstr(type, "cpullc-0")) {
            cpu_prio = 5;
            cpu_reason = "priority=5 cpullc-0 little cluster fallback";
        } else if (strstr(type, "cpu-")) {
            cpu_prio = 6;
            cpu_reason = "priority=6 generic cpu-* last resort";
        }

        if (cpu_prio > 0 && cpu_prio <= best_cpu_prio) {
            /*
             * when same priority (e.g.
             */
            int dominated = 0;
            if (cpu_prio == best_cpu_prio && g_thermal_cpu_zone >= 0) {
                char cp1[128], cp2[128];
                snprintf(cp1, sizeof(cp1), THERMAL_BASE "/thermal_zone%d/temp", z);
                snprintf(cp2, sizeof(cp2), THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
                int c1 = thermal_raw_to_c(sysfs_read_int(cp1, 0));
                int c2 = thermal_raw_to_c(sysfs_read_int(cp2, 0));
                if (c1 <= c2) dominated = 1;  /* existing is hotter or equal, skip */
            }
            if (!dominated) {
            int sensor_ok = thermal_sensor_validate(z);
            /* first pass — accept socd tentatively if the basic sanity floor
             * (c > 10) passes. Cross-reference against peer CPU sensors
             * happens in a second pass after the whole zone table is scanned
             * so we can actually compare values. */
            if (sensor_ok && strcmp(type, "socd") == 0) {
                char vp[128];
                snprintf(vp, sizeof(vp), THERMAL_BASE "/thermal_zone%d/temp", z);
                int raw_now = sysfs_read_int(vp, 0);
                int c_now = thermal_raw_to_c(raw_now);
                if (c_now > 0 && c_now <= 10) {
                    sensor_ok = 0;
                    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                        "socd rejected: read %dC <= 10C sanity floor (firmware reports garbage)", c_now);
                }
            }
            if (sensor_ok) {
                g_thermal_cpu_zone = z;
                best_cpu_prio = cpu_prio;
                snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type), "%s", type);
                snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s validated at zone%d", cpu_reason, z);
            } else if (strcmp(type, "socd") == 0) {
                /* A static extreme socd can fail basic validation before the post-scan
                 * peer comparison runs. Preserve the same provenance contract for that
                 * path so a real CPU fallback is never reported as an unexplained primary. */
                char vp[128];
                snprintf(vp, sizeof(vp), THERMAL_BASE "/thermal_zone%d/temp", z);
                int raw_now = sysfs_read_int(vp, 0);
                int c_now = thermal_raw_to_c(raw_now);
                if (raw_now > 0) {
                    snprintf(g_thermal_rejected_type, sizeof(g_thermal_rejected_type), "socd");
                    g_thermal_rejected_raw = raw_now;
                    g_thermal_source_confidence = 1;
                    snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                             "socd rejected during basic validation (raw=%d, normalized=%dC)",
                             raw_now, c_now);
                }
            }
            } /* end if (!dominated) */
        }

        /*
         * skin_temp = LITERAL shell sensors only.
         */
        int skin_prio = -1;
        if (strcmp(type, "shell_frame") == 0)
            skin_prio = 1;
        else if (strcmp(type, "shell_front") == 0 || strcmp(type, "shell_back") == 0)
            skin_prio = 2;
        else if (strstr(type, "shell_"))
            skin_prio = 3;
        else if (strstr(type, "skin-virt") || strstr(type, "skin-msm"))
            skin_prio = 4;  /* legacy names for other SoCs */
        else if (strcmp(type, "skin") == 0 || strstr(type, "back-therm"))
            skin_prio = 5;

        if (skin_prio > 0 && skin_prio < best_skin_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_skin_zone = z;
                best_skin_prio = skin_prio;
            }
        }

        /*
         * SURFACE HOTSPOT priority (surface_hotspot_c channel).
         * We EXCLUDE pmic/pmih010x and svooc zones because those reflect power draw / charging
         * IC, not surface heat.
         */
        int surface_prio = -1;
        if (strcmp(type, "sys-therm-6") == 0)
            surface_prio = 1;
        else if (strcmp(type, "board_temp") == 0)
            surface_prio = 2;
        else if (strstr(type, "sys-therm-"))
            surface_prio = 3;  /* any sys-therm as fallback */

        if (surface_prio > 0 && surface_prio < best_surface_prio) {
            if (thermal_sensor_validate(z)) {
                g_thermal_surface_zone = z;
                best_surface_prio = surface_prio;
            }
        }
        /* track board_temp zone separately for surface_hotspot = max(sys-therm-6, board_temp) */
        if (strcmp(type, "board_temp") == 0 && thermal_sensor_validate(z)) {
            g_thermal_board_zone = z;
        }
    }

    /*
     * Post-scan socd validation. This runs only after every zone is known, so the
     * primary source is evaluated against a complete peer set rather than against
     * whichever zone happened to be visited first. A rejected socd is rebound to a
     * real validated CPU zone; it never becomes a synthetic "cpu-median" with no
     * sysfs path behind it.
     */
    {
        int peer_c[24], np = 0;
        int fallback_zone = -1;
        int fallback_prio = 99;
        char fallback_type[64] = "";

        for (int z = 0; z < THERMAL_MAX_ZONES && np < 24; z++) {
            char tp[128], tt[64], vp[128];
            snprintf(tp, sizeof(tp), THERMAL_BASE "/thermal_zone%d/type", z);
            if (sysfs_read_str(tp, tt, sizeof(tt)) < 0) continue;
            int tl = (int)strlen(tt);
            while (tl > 0 && (tt[tl - 1] == '\n' || tt[tl - 1] == '\r' || tt[tl - 1] == ' '))
                tt[--tl] = '\0';

            int prio = -1;
            if (strstr(tt, "cpu-1-1-")) prio = 2;
            else if (strstr(tt, "cpu-0-5-")) prio = 3;
            else if (strstr(tt, "cpuss-0")) prio = 4;
            else if (strstr(tt, "cpullc-0")) prio = 5;
            if (prio < 0) continue;

            snprintf(vp, sizeof(vp), THERMAL_BASE "/thermal_zone%d/temp", z);
            int raw = sysfs_read_int(vp, 0);
            int c = thermal_raw_to_c(raw);
            if (c <= 10 || c >= 120) continue;

            peer_c[np] = c;
            np++;
            if (prio < fallback_prio && thermal_sensor_validate(z)) {
                fallback_zone = z;
                fallback_prio = prio;
                snprintf(fallback_type, sizeof(fallback_type), "%s", tt);
            }
        }

        g_thermal_cpu_fallback_zone = fallback_zone;
        snprintf(g_thermal_cpu_fallback_type, sizeof(g_thermal_cpu_fallback_type),
                 "%s", fallback_type);

        if (g_thermal_cpu_zone >= 0 && strcmp(g_thermal_cpu_type, "socd") == 0) {
            char sp[128];
            snprintf(sp, sizeof(sp), THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
            int socd_raw = sysfs_read_int(sp, 0);
            int socd_c = thermal_raw_to_c(socd_raw);

            if (np < 3) {
                g_thermal_source_confidence = 1;
                snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                         "socd=%dC retained: only %d validated CPU peers for cross-check", socd_c, np);
            } else {
                int ordered[24];
                for (int i = 0; i < np; i++) ordered[i] = peer_c[i];
                for (int a = 0; a < np - 1; a++)
                    for (int b = a + 1; b < np; b++)
                        if (ordered[b] < ordered[a]) { int t = ordered[a]; ordered[a] = ordered[b]; ordered[b] = t; }
                int median = ordered[np / 2];
                int high_gap = socd_c - median;
                int low_gap = median - socd_c;

                if (high_gap > ASB_SOCD_MAX_ABOVE_PEERS_C || low_gap >= 12) {
                    const char *kind = (high_gap > ASB_SOCD_MAX_ABOVE_PEERS_C) ? "high" : "low";
                    int gap = (high_gap > ASB_SOCD_MAX_ABOVE_PEERS_C) ? high_gap : low_gap;
                    /* Publish rejection even when no validated fallback exists: the
                     * retained socd then has conservative semantics, not validation. */
                    snprintf(g_thermal_rejected_type, sizeof(g_thermal_rejected_type), "socd");
                    g_thermal_rejected_raw = socd_raw;
                    if (fallback_zone >= 0) {
                        int old_zone = g_thermal_cpu_zone;
                        g_thermal_cpu_zone = fallback_zone;
                        snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type), "%s", fallback_type);
                        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                                 "socd rejected (%s divergence: %dC vs CPU median %dC, gap=%dC); live fallback %s at zone%d",
                                 kind, socd_c, median, gap, fallback_type, fallback_zone);
                        g_thermal_source_confidence = 1;
                        /* The selected zone is now the control source; do not retain a
                         * self-fallback that would add needless reads or confuse spike logic. */
                        g_thermal_cpu_fallback_zone = -1;
                        g_thermal_cpu_fallback_type[0] = '\0';
                        (void)old_zone;
                    } else {
                        g_thermal_source_confidence = 1;
                        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                                 "socd %s divergence (%dC vs CPU median %dC, gap=%dC) but no validated CPU fallback",
                                 kind, socd_c, median, gap);
                    }
                } else {
                    /* A periodically revalidated socd can recover after a transient
                     * firmware-scale fault. Do not keep stale rejected provenance once
                     * the current source has passed the complete peer cross-check. */
                    g_thermal_source_confidence = 2;
                    g_thermal_rejected_type[0] = '\0';
                    g_thermal_rejected_raw = 0;
                }
            }
        } else if (g_thermal_cpu_zone >= 0) {
            /* A CPU peer selected after basic socd rejection is the control source;
             * do not leave a self-fallback that runtime drift logic could misread. */
            if (g_thermal_rejected_type[0]) {
                g_thermal_cpu_fallback_zone = -1;
                g_thermal_cpu_fallback_type[0] = '\0';
            }
            /* It is safe to use, but provenance remains low-confidence because socd
             * was unusable during this discovery pass. */
            g_thermal_source_confidence = g_thermal_rejected_type[0] ? 1 : 2;
        } else if (g_thermal_rejected_type[0]) {
            /* No fallback must never look like a validated source. The caller keeps
             * thermal behaviour conservative until a later rescan finds a real zone. */
            g_thermal_source_confidence = 1;
        }
    }

    if (g_thermal_cpu_zone < 0) {
        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason), "%s", "no validated cpu thermal source found");
    }
}

static time_t g_last_thermal_read_ts = 0;  /* when we last actually read temp */
static int    g_last_thermal_value = 0;     /* cached last real temp */
static time_t g_last_thermal_rescan = 0;    /* periodic rescan if skin zone missing */

static void metrics_read_thermal(asb_thermal_t *t, int need_headroom) {
    char path[128];

    /*
     * if any of the three thermal zones (cpu / skin / surface) wasn't found at startup
     * (validate failed on a transient read), retry every 60 seconds.
     */
    /* Revalidate tentative socd periodically even when all zones exist. A vendor
     * source can become implausible after boot; actual fallback zones remain stable. */
    {
        time_t now = time(NULL);
        int need_rescan = (g_thermal_skin_zone < 0 || g_thermal_cpu_zone < 0 ||
                           g_thermal_surface_zone < 0 ||
                           strcmp(g_thermal_cpu_type, "socd") == 0);
        if (need_rescan && now - g_last_thermal_rescan >= 60) {
            g_last_thermal_rescan = now;
            thermal_discover();
        }
    }

    t->cpu_max_c  = 0;
    t->gpu_temp_c = 0;
    t->skin_temp_c = 0;
    t->surface_hotspot_c = 0;
    t->board_temp_c = 0;
    t->throttling  = 0;
    t->soft_clamp  = 0;
    t->hard_clamp  = 0;
    t->temp_valid  = 0;
    t->temp_age_s  = 0;
    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "init");
    /* Keep the last known registration when a read fails.
     *
     * These were zeroed at the top of every tick and refilled only if the msm_performance
     * node opened and parsed cleanly. A single failed read - the node busy, a short read, a
     * transient EAGAIN - therefore published "governor registered no cap" for that tick,
     * and the classifier duly recorded cap_owner=shell. On one capture that was 173 samples
     * out of 301, which is not a governor losing ownership but a governor whose ownership
     * could not be read.
     *
     * A stale value is the honest answer here: the registration does not evaporate because
     * one read missed, and the next successful parse overwrites it anyway. */
    static int _last_perf_cap_p0 = 0, _last_perf_cap_p6 = 0;
    t->perf_cap_p0 = _last_perf_cap_p0;
    t->perf_cap_p6 = _last_perf_cap_p6;
    t->headroom_pct = 100;
    t->headroom_valid = 0;
    t->used_fallback = 0;
    t->fallback_just_flipped = 0;
    snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "no_iface");

    if (g_thermal_cpu_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_zone);
        int v = sysfs_read_int(path, 0);
        if (v > 0) {
            int c_now = thermal_raw_to_c(v);
            /*
             * runtime socd drift detection.
             */
            int used_fallback = 0;
            int fb_c = 0;
            if (strcmp(g_thermal_cpu_type, "socd") == 0 &&
                g_thermal_cpu_fallback_zone >= 0) {
                char fbp[128];
                snprintf(fbp, sizeof(fbp),
                    THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_fallback_zone);
                int fbv = sysfs_read_int(fbp, 0);
                if (fbv > 0) {
                    fb_c = thermal_raw_to_c(fbv);
                    if (fb_c > c_now && (fb_c - c_now) >= 10) {
                        /* Fallback is >=10C hotter — use it instead */
                        c_now = fb_c;
                        used_fallback = 1;
                    }
                }
            }
            /* expose flip detection to governor.c so it can log the
             * transition without needing asb_log linkage from this header. */
            t->used_fallback = used_fallback;
            {
                static int prev_used_fallback = -1;
                t->fallback_just_flipped = (prev_used_fallback != -1 &&
                                            prev_used_fallback != used_fallback) ? 1 : 0;
                prev_used_fallback = used_fallback;
            }

            /* explicit guard for "looks alive but reports nonsense" sensors
             * like socd on broken firmware. If validate accepted the zone but
             * a live read is now <=10C while the rest of the system is hot,
             * treat as invalid for THIS read but keep the zone bound. */
            static int raw_too_low_streak = 0;
            int rebound_this_tick = 0;
            if (c_now > 0 && c_now <= 10) {
                /*
                 * RC9: runtime socd rebind.
                 * New behavior: if primary is socd AND raw_too_low happens for >= 5
                 * consecutive ticks AND fallback is available AND fallback reads a plausible
                 * temperature, permanently rebind primary to fallback for the rest of this
                 * session.
                 */
                raw_too_low_streak++;
                if (raw_too_low_streak >= 5 &&
                    strcmp(g_thermal_cpu_type, "socd") == 0 &&
                    g_thermal_cpu_fallback_zone >= 0 &&
                    g_thermal_cpu_fallback_type[0] != '\0')
                {
                    /* Verify fallback is still plausible before rebinding. */
                    char fbp[128];
                    snprintf(fbp, sizeof(fbp), THERMAL_BASE "/thermal_zone%d/temp",
                             g_thermal_cpu_fallback_zone);
                    int fb_raw = sysfs_read_int(fbp, 0);
                    int fb_c = (fb_raw > 0) ? thermal_raw_to_c(fb_raw) : 0;
                    if (fb_c > 15 && fb_c < 120) {
                        int old_zone = g_thermal_cpu_zone;
                        g_thermal_cpu_zone = g_thermal_cpu_fallback_zone;
                        snprintf(g_thermal_cpu_type, sizeof(g_thermal_cpu_type),
                                 "%s", g_thermal_cpu_fallback_type);
                        snprintf(g_thermal_cpu_reason, sizeof(g_thermal_cpu_reason),
                                 "socd runtime rebind (streak=%d, old_zone=%d -> %s at zone%d, fb_now=%dC)",
                                 raw_too_low_streak, old_zone,
                                 g_thermal_cpu_type, g_thermal_cpu_zone, fb_c);
                        g_thermal_cpu_fallback_zone = -1;
                        g_thermal_cpu_fallback_type[0] = '\0';
                        c_now = fb_c;
                        t->cpu_max_c = c_now;
                        t->temp_valid = 1;
                        snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "rebind");
                        g_last_thermal_read_ts = time(NULL);
                        g_last_thermal_value = c_now;
                        if (c_now > g_asb_cfg.thermal_throttle_temp) t->throttling = 1;
                        raw_too_low_streak = 0;
                        rebound_this_tick = 1;
                    }
                }
                if (!rebound_this_tick) {
                    t->cpu_max_c = g_last_thermal_value;
                    t->temp_valid = 0;
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "raw_too_low");
                }
            } else {
                /* Plausible reading — reset the streak */
                raw_too_low_streak = 0;
int spike_detected = 0;
                if (g_last_thermal_value > 0 &&
                    c_now >= g_last_thermal_value + 25 &&
                    g_thermal_cpu_fallback_zone >= 0 &&
                    !used_fallback) {
                    char fbpath[128];
                    snprintf(fbpath, sizeof(fbpath),
                        THERMAL_BASE "/thermal_zone%d/temp", g_thermal_cpu_fallback_zone);
                    int fb_raw = sysfs_read_int(fbpath, 0);
                    int fb_cross = (fb_raw > 0) ? thermal_raw_to_c(fb_raw) : 0;
                    if (fb_cross > 0 && c_now >= fb_cross + 25) {
                        spike_detected = 1;
                    }
                }
                if (spike_detected) {
                    /* Hold last good value, don't advance throttling on this tick */
                    t->cpu_max_c = g_last_thermal_value;
                    t->temp_valid = 1;   /* still "valid" — we have a good cached number */
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "spike");
                    /* Don't update g_last_thermal_value or g_last_thermal_read_ts
                     * so next tick compares against the pre-spike baseline.
                     * Don't set throttling from the spike value. */
                } else {
                    t->cpu_max_c = c_now;
                    t->temp_valid = 1;
                    snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason),
                             used_fallback ? "fb_used" : "ok");
                    g_last_thermal_read_ts = time(NULL);
                    g_last_thermal_value = t->cpu_max_c;
                    /* throttling = ONLY real temperature exceeding threshold */
                    if (t->cpu_max_c > g_asb_cfg.thermal_throttle_temp) t->throttling = 1;
                }
            }
        } else {
            /* Read failed -- use cached value, mark as stale */
            t->cpu_max_c = g_last_thermal_value;
            t->temp_valid = 0;
            snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "read_fail");
        }
    } else {
        /* No thermal zone -- use cached */
        t->cpu_max_c = g_last_thermal_value;
        t->temp_valid = 0;
        snprintf(t->temp_invalid_reason, sizeof(t->temp_invalid_reason), "no_zone");
    }

    /* compute staleness */
    if (g_last_thermal_read_ts > 0) {
        t->temp_age_s = (int)(time(NULL) - g_last_thermal_read_ts);
        /* Mark stale if age exceeds configurable threshold */
        if (g_asb_cfg.thermal_stale_after_s > 0 &&
            t->temp_age_s > g_asb_cfg.thermal_stale_after_s) {
            t->temp_valid = 0;
        }
    }

    if (g_thermal_skin_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_skin_zone);
        int sv = sysfs_read_int(path, 0);
        t->skin_temp_c = thermal_raw_to_c(sv);
    }

    /*
     * Re-decide throttling on the skin-anchored gate now that the shell sensor has been read
     * this tick.
     */
    {
        int _se = asb_therm_skin_engage(&g_asb_cfg, t->cpu_max_c, t->skin_temp_c);
        if (_se >= 0) t->throttling = _se;
    }

    /*
     * surface_hotspot = max(sys-therm-6, board_temp).
     */
    if (g_thermal_surface_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_surface_zone);
        int sv = sysfs_read_int(path, 0);
        t->surface_hotspot_c = thermal_raw_to_c(sv);
    }

    /* Board must be read before consensus as well. Using last tick's board value in a
     * current-tick decision is exactly the kind of near-miss that makes a guard look like
     * it works while quietly using stale evidence. */
    if (g_thermal_board_zone >= 0) {
        snprintf(path, sizeof(path),
            THERMAL_BASE "/thermal_zone%d/temp", g_thermal_board_zone);
        int bv = sysfs_read_int(path, 0);
        int bc = thermal_raw_to_c(bv);
        t->board_temp_c = bc;
        if (bc > t->surface_hotspot_c) t->surface_hotspot_c = bc;
    }

    /* Consensus runs only after all current-tick non-CPU evidence is available. */
    /* Thermal consensus v2: cross-check the control temperature against the other
     * sources before anything acts on it.
     *
     * V63 closed the socd case - a sensor whose scale was wrong. This is the next class:
     * a sensor whose scale is fine but whose reading has drifted away from everything
     * else on the device. Firmware differs in what CPU, battery, skin and board zones
     * mean, and a control value that disagrees with all of them is not more accurate for
     * being more specific.
     *
     * The rule is deliberately one-directional and conservative:
     *   - a control temperature far ABOVE every peer causes throttling nobody needs, so
     *     confidence drops and the report says why
     *   - a control temperature far BELOW every peer is the dangerous direction: it hides
     *     real heat. There the more conservative peer wins outright.
     *
     * What this does NOT do, and the plan is explicit about it: no blind averaging of
     * incomparable zones, and no substituting a vendor trip point. Battery and skin are
     * compared as sanity peers, never promoted to control - they lag the die by minutes
     * and driving frequency off them would throttle late every time.
     */
    {
        /* Never report last tick's consensus as current evidence when a peer disappears.
         * These globals feed both state and JSON diagnostics. */
        g_thermal_peer_hi = 0;
        g_thermal_peer_lo = 0;
        g_thermal_peer_n  = 0;
        g_thermal_consensus_note[0] = '\0';

        /* Battery temperature is deliberately absent: it lives in asb_battery_t, which
         * this function does not receive, and reaching across for it would couple two
         * collectors that are otherwise independent. Skin, board and surface are evidence
         * of the wider thermal envelope, never replacement CPU sensors. */
        int peer[4], np = 0;
        if (t->skin_temp_c        > 10 && t->skin_temp_c        < 90) peer[np++] = t->skin_temp_c;
        if (t->board_temp_c       > 10 && t->board_temp_c       < 90) peer[np++] = t->board_temp_c;
        if (t->surface_hotspot_c  > 10 && t->surface_hotspot_c  < 90) peer[np++] = t->surface_hotspot_c;

        if (np >= 2 && t->cpu_max_c > 0) {
            int hi = peer[0], lo = peer[0];
            for (int i = 1; i < np; i++) {
                if (peer[i] > hi) hi = peer[i];
                if (peer[i] < lo) lo = peer[i];
            }
            /* A CPU die normally runs hotter than the shell/board. These peers can warn
             * that the wider device envelope is hot or that the CPU source is unusual, but
             * they are not interchangeable with a CPU die sensor and must never overwrite
             * cpu_max_c. Platform thermal mitigation remains the hard safety authority. */
            if (t->cpu_max_c > hi + ASB_CONSENSUS_MAX_ABOVE_C) {
                snprintf(g_thermal_consensus_note, sizeof(g_thermal_consensus_note),
                         "CPU control %dC is %dC above hottest non-CPU peer (%dC); source retained, review evidence",
                         t->cpu_max_c, t->cpu_max_c - hi, hi);
            } else if (hi > t->cpu_max_c + ASB_CONSENSUS_MAX_BELOW_C) {
                snprintf(g_thermal_consensus_note, sizeof(g_thermal_consensus_note),
                         "non-CPU peer is hot (%dC vs CPU control %dC); CPU source retained, platform safety may override",
                         hi, t->cpu_max_c);
            }
            g_thermal_peer_hi = hi;
            g_thermal_peer_lo = lo;
            g_thermal_peer_n  = np;
        }
    }

    /* Read the registered caps every tick, not only when headroom is wanted.
     *
     * This sat inside `if (need_headroom)`, and need_headroom follows the session plan -
     * it is 0 on most ticks and always 0 in deep-idle economy. But the cap-source
     * classifier runs EVERY tick and treats perf_cap == 0 as "the governor never
     * registered a ceiling", so on every skipped tick it published cap_owner=shell.
     *
     * That is the whole mystery: three devices reporting ASB ownership of 0-11%, a capture
     * where 173 of 301 samples said shell, and a diag where the kernel node plainly holds
     * 0:2117148 ... 6:2037688 while the module records perf_cap_p0=0. The governor was
     * registering its caps all along. Nobody was reading the answer.
     *
     * The read is one open, one 256-byte read, one close of a sysfs node - cheaper than the
     * thermal zone scan that already runs unconditionally beside it, and far cheaper than
     * the wrong decisions taken downstream from a false zero.
     */
    {
        char buf[256];
        int fd = open("/sys/kernel/msm_performance/parameters/cpu_max_freq",
                       O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            int n = read(fd, buf, sizeof(buf) - 1);
            close(fd);
            if (n > 0) {
                buf[n] = '\0';
                /* Two passes: find the highest CPU the node lists, then read its frequency.
                   _prime_cpu is cached because topology cannot change at runtime. */
                static int _prime_cpu = -1;
                int _seen_max_cpu = -1;
                char *p = buf;
                while (*p) {
                    int cpu = -1, freq = 0;
                    if (sscanf(p, "%d:%d", &cpu, &freq) == 2) {
                        /* Prime CPU by topology, not by the number 6.
                         *
                         * msm_performance lists every CPU. Hardcoding 6 works on a 6+2 like
                         * canoe or sun and fails on pineapple, whose clusters are numbered
                         * 0/2/5/7 - there is no cpu 6, so perf_cap_p6 stayed zero forever.
                         * Zero means "governor never registered a cap", which sends the
                         * classifier down its shell-only branch and makes every sample read
                         * as cap_owner=shell. Three devices reported ASB owning the ceiling
                         * 0-11% of the time; this is why.
                         *
                         * The prime is the highest-numbered CPU the node reports, which is
                         * true on every Qualcomm layout in use. */
                        if (cpu > _seen_max_cpu) _seen_max_cpu = cpu;
                        if (cpu == 0 && freq > 0) t->perf_cap_p0 = freq;
                        if (cpu == _prime_cpu && freq > 0) t->perf_cap_p6 = freq;
                    }
                    while (*p && *p != ' ' && *p != '\n' && *p != '\t') p++;
                    while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
                }
                /* First tick: learn the prime index, then re-parse so this tick already has a
                   value instead of publishing a zero the classifier reads as "no registration".
                
                   This block was previously spliced into an unrelated else-branch of the headroom
                   recovery logic, several levels away from the loop whose variables it uses. It
                   compiled - the names were still in scope - and simply never ran, so perf_cap_p6
                   stayed 0 on a device whose node plainly lists 6:1671109, and every sample kept
                   reporting cap_owner=shell. */
                if (_prime_cpu < 0 && _seen_max_cpu > 0) {
                    _prime_cpu = _seen_max_cpu;
                    p = buf;
                    while (*p) {
                        int cpu2 = -1, freq2 = 0;
                        if (sscanf(p, "%d:%d", &cpu2, &freq2) == 2) {
                            if (cpu2 == _prime_cpu && freq2 > 0) t->perf_cap_p6 = freq2;
                        }
                        while (*p && *p != ' ' && *p != '\n' && *p != '\t') p++;
                        while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
                    }
                }
                /* Remember what parsed, for a later tick that cannot read the node. */
                if (t->perf_cap_p0 > 0) _last_perf_cap_p0 = t->perf_cap_p0;
                if (t->perf_cap_p6 > 0) _last_perf_cap_p6 = t->perf_cap_p6;
                if (t->perf_cap_p0 > 0 && cpu_slot_contains_cpu(0, 0) &&
                    metrics_headroom_pct_from_cap(t->perf_cap_p0, g_cpu_slot_hwmax[0],
                                                  &t->headroom_pct) == 0) {
                    /* split into soft/hard clamp instead of blunt throttling.
                     * soft_clamp = advisory (reduce aggression, no SUSTAINED)
                     * hard_clamp = actionable (can lead to SUSTAINED if confirmed) */
                    int soft_pct = (g_asb_cfg.soft_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.soft_clamp_headroom_pct : 70;
                    int hard_pct = (g_asb_cfg.hard_clamp_headroom_pct > 0)
                                   ? g_asb_cfg.hard_clamp_headroom_pct : 45;
                    if (t->headroom_pct < soft_pct) t->soft_clamp = 1;
                    if (t->headroom_pct < hard_pct) t->hard_clamp = 1;
                    t->headroom_valid = 1;
                    snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "ok");
                    /*
                     * detect "dead" headroom signal on SoCs like SM8850 where msm_performance
                     * always reports max freq → headroom permanently 100%.
                     */
                    {
                        static int headroom_100_streak = 0;
                        static int headroom_dead_session = 0;
                        static int implausible_hot_streak = 0;
                        static int headroom_recover_streak = 0;
                        if (headroom_dead_session) {
                            /*
                             * Previously latched as a dead/stuck msm_performance interface.
                             */
                            if (t->headroom_pct < 100 &&
                                !(t->cpu_max_c >= 60 && t->headroom_pct >= 95)) {
                                headroom_recover_streak++;
                                if (headroom_recover_streak >= 5) {
                                    headroom_dead_session = 0;
                                    headroom_100_streak = 0;
                                    implausible_hot_streak = 0;
                                    headroom_recover_streak = 0;
                                    t->headroom_valid = 1;
                                    snprintf(t->headroom_invalid_reason,
                                             sizeof(t->headroom_invalid_reason), "ok");
                                } else {
                                    t->headroom_valid = 0;
                                    snprintf(t->headroom_invalid_reason,
                                             sizeof(t->headroom_invalid_reason), "dead_iface");
                                }
                            } else {
                                headroom_recover_streak = 0;
                                t->headroom_valid = 0;
                                snprintf(t->headroom_invalid_reason,
                                         sizeof(t->headroom_invalid_reason), "dead_iface");
                            }
                        } else if (t->headroom_pct >= 100) {
                            headroom_100_streak++;
                            /*
                             * implausible_hot_100 detector — chatgpt review flagged that
                             * headroom=100 while CPU=60-69°C is physically wrong.
                             */
                            if (t->cpu_max_c >= 60 && t->headroom_pct >= 95) {
                                implausible_hot_streak++;
                                if (implausible_hot_streak >= 3) {
                                    t->headroom_valid = 0;
                                    snprintf(t->headroom_invalid_reason,
                                             sizeof(t->headroom_invalid_reason),
                                             "implausible_hot");
                                    goto headroom_status_done;
                                }
                            } else {
                                implausible_hot_streak = 0;
                            }
                            if (headroom_100_streak >= 60) {
                                /* msm_performance is permanently broken on this device;
                                 * don't keep paying the cost of reads + don't keep
                                 * re-evaluating. */
                                headroom_dead_session = 1;
                                t->headroom_valid = 0;
                                snprintf(t->headroom_invalid_reason,
                                         sizeof(t->headroom_invalid_reason), "dead_iface");
                            } else if (headroom_100_streak >= 10) {
                                t->headroom_valid = 0;  /* advisory-only */
                                snprintf(t->headroom_invalid_reason,
                                         sizeof(t->headroom_invalid_reason), "stuck_100");
                            }
                        } else {
                            headroom_100_streak = 0;
                            implausible_hot_streak = 0;
                        }
                    headroom_status_done: ;
                    }
                } else if (t->perf_cap_p0 > 0) {
                    t->headroom_valid = 0;
                    if (g_cpu_slot_hwmax[0] <= 0)
                        snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "topology_absent");
                    else if (!cpu_slot_contains_cpu(0, 0))
                        snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "cpu0_not_slot0");
                    else
                        snprintf(t->headroom_invalid_reason, sizeof(t->headroom_invalid_reason), "invalid_cap");
                }
            }
        }
    }
}

static int metrics_screen_on(void) {
    const char *paths[] = { PATH_SCREEN_STATUS, PATH_SCREEN_STATUS2, NULL };
    for (int i = 0; paths[i]; i++) {
        int v = sysfs_read_int(paths[i], -1);
        if (v == 1) return 1;
        if (v == 0) return 0;
    }
    int bl = sysfs_read_int(PATH_BACKLIGHT, -1);
    if (bl > 0) return 1;
    if (bl == 0) return 0;
    return 1;
}

static long g_wlan_tx_prev = 0, g_wlan_rx_prev = 0;
static long g_rmnet_tx_prev = 0, g_rmnet_rx_prev = 0;
static struct timespec g_wlan_ts_prev = {0};

static void metrics_read_network(asb_misc_t *m, const struct timespec *now) {
    long tx = sysfs_read_long(PATH_WLAN_TX, 0);
    long rx = sysfs_read_long(PATH_WLAN_RX, 0);
    long mtx = rmnet_read_total("tx_bytes");
    long mrx = rmnet_read_total("rx_bytes");
    if (g_wlan_ts_prev.tv_sec > 0) {
        double dt = (now->tv_sec - g_wlan_ts_prev.tv_sec) +
                    (now->tv_nsec - g_wlan_ts_prev.tv_nsec) * 1e-9;
        if (dt > 0.1) {
            m->wlan_tx_bps = (long)((tx - g_wlan_tx_prev) / dt);
            m->wlan_rx_bps = (long)((rx - g_wlan_rx_prev) / dt);
            m->rmnet_tx_bps = (long)((mtx - g_rmnet_tx_prev) / dt);
            m->rmnet_rx_bps = (long)((mrx - g_rmnet_rx_prev) / dt);
        }
    }
    g_wlan_tx_prev = tx;
    g_wlan_rx_prev = rx;
    g_rmnet_tx_prev = mtx;
    g_rmnet_rx_prev = mrx;
    g_wlan_ts_prev = *now;
}

/*
 * --------------------------------------------------------------------------- Camera activity.
 * Busy provider = camera streaming, and that is true for the OEM camera app, third-party apps
 * and any HAL client alike.
 */
#define ASB_CAM_RESCAN_COOLDOWN_S 30
/* Screen on: the camera can be opened at any moment, so the guard has to be able to
 * arrive within a few seconds rather than up to half a minute. */
#define ASB_CAM_RESCAN_SCREEN_ON_S 5

static pid_t             g_cam_pid = 0;
static time_t            g_cam_scan_ts = 0;
static unsigned long long g_cam_jif_prev = 0;
static struct timespec   g_cam_ts_prev = {0};
static time_t            g_cam_hold_until = 0;

static int cam_cmdline_matches(pid_t pid) {
    char path[64], buf[288];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    int n = (int)read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) if (buf[i] == '\0') buf[i] = ' ';
    buf[n] = '\0';
    if (strstr(buf, "camera.provider"))  return 1;
    if (strstr(buf, "camerahalserver"))  return 1;
    if (strstr(buf, "camerahalservice")) return 1;
    if (strstr(buf, "camerahalext"))     return 1;
    if (strstr(buf, "/cameraserver"))    return 1;
    return 0;
}

static pid_t cam_find_pid(void) {
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    pid_t found = 0;
    while ((e = readdir(d)) != NULL) {
        const char *nm = e->d_name;
        if (nm[0] < '1' || nm[0] > '9') continue;
        int numeric = 1;
        for (const char *q = nm; *q; q++) {
            if (*q < '0' || *q > '9') { numeric = 0; break; }
        }
        if (!numeric) continue;
        pid_t pid = (pid_t)atoi(nm);
        if (cam_cmdline_matches(pid)) { found = pid; break; }
    }
    closedir(d);
    return found;
}

static unsigned long long cam_read_jiffies(pid_t pid) {
    char path[64], buf[640];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0ULL;
    int n = (int)read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0ULL;
    buf[n] = '\0';
    /* comm can itself contain spaces and parentheses -- start after the LAST
     * ')' so the field walk below can never be thrown off by the process name. */
    char *rest = strrchr(buf, ')');
    if (!rest) return 0ULL;
    rest++;
    unsigned long long ut = 0ULL, st = 0ULL;
    int field = 2;
    char *save = NULL;
    for (char *tok = strtok_r(rest, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        field++;
        if (field == 14) ut = strtoull(tok, NULL, 10);
        else if (field == 15) { st = strtoull(tok, NULL, 10); break; }
    }
    return ut + st;
}

static int metrics_camera_active(const struct timespec *now) {
    if (!g_asb_cfg.camera_hold_enable) {
        g_cam_hold_until = 0;
        return 0;
    }
    time_t wall = time(NULL);
    if (g_cam_pid <= 0) {
        /* Rescan sooner while the screen is on.
         *
         * The /proc walk is throttled because it is expensive, and 30 s is a reasonable
         * price when nothing is happening. But it also means a camera opened one second
         * after the last scan runs unguarded for the next twenty-nine - and those are
         * exactly the seconds that matter: preview bring-up, autofocus, exposure
         * convergence, the first frames. Users report the camera as slow to open and
         * stuttery while shooting, which is what an unguarded bring-up looks like.
         *
         * Nobody opens the camera with the screen off, so the long interval is only ever
         * right in that case - and that is where the saving actually matters, since a
         * sleeping phone should not be walking /proc at all. With the screen on, five
         * seconds costs a few hundred directory entries and buys a guard that arrives
         * before the shot instead of after it.
         *
         * screen_on is read directly here rather than taken from the metrics struct,
         * because this function runs before that field is filled this tick.
         */
        int _cam_cooldown = ASB_CAM_RESCAN_COOLDOWN_S;
        if (metrics_screen_on()) _cam_cooldown = ASB_CAM_RESCAN_SCREEN_ON_S;
        if (wall - g_cam_scan_ts < _cam_cooldown)
            return (wall < g_cam_hold_until) ? 1 : 0;
        g_cam_scan_ts  = wall;
        g_cam_pid      = cam_find_pid();
        g_cam_jif_prev = 0ULL;
    }
    if (g_cam_pid <= 0) return 0;

    unsigned long long jif = cam_read_jiffies(g_cam_pid);
    if (jif == 0ULL) {
        g_cam_pid      = 0;
        g_cam_jif_prev = 0ULL;
        return (wall < g_cam_hold_until) ? 1 : 0;
    }

    int busy = 0;
    if (g_cam_jif_prev > 0ULL && g_cam_ts_prev.tv_sec > 0 && jif >= g_cam_jif_prev) {
        double dt = (now->tv_sec - g_cam_ts_prev.tv_sec) +
                    (now->tv_nsec - g_cam_ts_prev.tv_nsec) * 1e-9;
        if (dt > 0.2) {
            long hz = sysconf(_SC_CLK_TCK);
            if (hz <= 0) hz = 100;
            double pct = ((double)(jif - g_cam_jif_prev) / (double)hz) / dt * 100.0;
            if (pct >= (double)g_asb_cfg.camera_busy_pct) busy = 1;
        }
    }
    g_cam_jif_prev = jif;
    g_cam_ts_prev  = *now;

    if (busy) {
        int grace = g_asb_cfg.camera_hold_grace_s;
        if (grace < 0) grace = 0;
        g_cam_hold_until = wall + grace;
        return 1;
    }
    return (wall < g_cam_hold_until) ? 1 : 0;
}

static void metrics_read_all(asb_metrics_t *m, int need_headroom, int need_thermal) {
    clock_gettime(CLOCK_MONOTONIC, &m->ts);
    metrics_read_battery(&m->bat);
    metrics_read_gpu(&m->gpu);
    metrics_read_cpu(&m->cpu);
    if (need_thermal)
        metrics_read_thermal(&m->therm, need_headroom);
    m->misc.screen_on = metrics_screen_on();
    m->misc.camera_active = metrics_camera_active(&m->ts);
    metrics_read_network(&m->misc, &m->ts);
}
