#pragma once

#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>
#include <dirent.h>
#include <ctype.h>
#include <string.h>
#include "asb_fsm.h"
#include "asb_config.h"

extern asb_runtime_config_t g_asb_cfg;
#include <string.h>
#include "asb_fsm.h"

static inline int sysfs_write_int(const char *path, int val) {
    char buf[24];
    int len = snprintf(buf, sizeof(buf), "%d\n", val);
    int fd  = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int r = write(fd, buf, len);
    close(fd);
    return (r == len) ? 0 : -1;
}

static inline int sysfs_write_long(const char *path, long val) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%ld\n", val);
    int fd  = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int r = write(fd, buf, len);
    close(fd);
    return (r == len) ? 0 : -1;
}

static inline int sysfs_write_str(const char *path, const char *val) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t w = write(fd, val, strlen(val));
    close(fd);
    return (w > 0) ? 0 : -1;
}

/*
 * Readback-aware write health. A node that rejects a request or reports a
 * different applied value is not silently cached as success. It receives a
 * short exponential capability backoff so an unsupported vendor node cannot
 * generate a write/fork/log storm every governor tick. State is exported by
 * writer_write_health_dump() for the existing diagnostics/logkit contract.
 */
typedef enum {
    ASB_WRITE_CPU_MAX0 = 0,
    ASB_WRITE_CPU_MAX1,
    ASB_WRITE_CPU_MAX2,
    ASB_WRITE_CPU_MIN0,
    ASB_WRITE_CPU_MIN1,
    ASB_WRITE_CPU_MIN2,
    ASB_WRITE_WALT_RAVG,
    ASB_WRITE_WALT_IDLE,
    ASB_WRITE_UCL_TOP,
    ASB_WRITE_UCL_BG,
    ASB_WRITE_UCL_SYBG,
    ASB_WRITE_NODE_COUNT
} asb_write_node_t;

typedef struct {
    unsigned long attempts;
    unsigned long applied;
    unsigned long failures;
    unsigned long consecutive_failures;
    unsigned long skipped_backoff;
    time_t retry_at;
    int requested;
    int observed;
    char status[32];
    char path[96];
} asb_write_health_t;

static asb_write_health_t g_write_health[ASB_WRITE_NODE_COUNT];

static const char *writer_write_node_name(asb_write_node_t node) {
    static const char *const names[ASB_WRITE_NODE_COUNT] = {
        "cpu_max0", "cpu_max1", "cpu_max2", "cpu_min0", "cpu_min1", "cpu_min2",
        "walt_ravg", "walt_idle", "uclamp_top", "uclamp_bg", "uclamp_sybg"
    };
    return (node >= 0 && node < ASB_WRITE_NODE_COUNT) ? names[node] : "unknown";
}

static void writer_write_failure_event(asb_write_node_t node, const char *path,
                                       int requested, int observed, time_t retry_at) {
    FILE *ef = fopen("/dev/.asb/write_errors", "a");
    if (!ef) return;
    fprintf(ef, "FAIL node=%s path=%s requested=%d observed=%d retry_at=%ld\n",
            writer_write_node_name(node), path ? path : "(none)",
            requested, observed, (long)retry_at);
    fclose(ef);
}

static int writer_node_is_cpu(asb_write_node_t node) {
    return node >= ASB_WRITE_CPU_MAX0 && node <= ASB_WRITE_CPU_MIN2;
}

/* uclamp tier nodes report percent with decimals, or the word "max". */
static int writer_node_is_uclamp(asb_write_node_t n) {
    return n == ASB_WRITE_UCL_TOP || n == ASB_WRITE_UCL_BG;
}

static int writer_node_is_cpu_max(asb_write_node_t node) {
    return node >= ASB_WRITE_CPU_MAX0 && node <= ASB_WRITE_CPU_MAX2;
}

static int writer_write_int_confirmed(asb_write_node_t node, const char *path, int requested) {
    if (!path || !*path || node < 0 || node >= ASB_WRITE_NODE_COUNT) return -1;
    asb_write_health_t *h = &g_write_health[node];
    time_t now = time(NULL);
    if (h->retry_at > now) {
        h->skipped_backoff++;
        return 1; /* deferred: not an applied write */
    }
    h->attempts++;
    h->requested = requested;
    snprintf(h->path, sizeof(h->path), "%s", path);
    /* Skip the write when the node already holds the value.
     *
     * Every write is an open, a write and a close, and on a contended node it is also a
     * chance for the kernel or a vendor daemon to react to a change that is not a change.
     * A read costs one of those three, and most ticks ask for the same value they asked
     * for last time - the ladder only moves when the state moves.
     *
     * Counted as applied because the device IS in the requested state, which is what the
     * caller asked about. Reporting it as a skip would make the health line look like
     * something was refused.
     */
    /* The uclamp nodes are excluded from this shortcut.
     *
     * They answer in percent-with-decimals or with the literal word "max", and
     * sysfs_read_int turns "max" into 0. So a tier sitting at "max" reads back as 0, and a
     * tick that legitimately wants 0 there matched and skipped the write - after which the
     * cache said 0, the node still said "max", and nothing ever corrected it. A capture
     * shows the result: all four tiers at ROM stock with writer health reporting 192 of
     * 193 writes applied, because the skipped ones were counted as successes.
     *
     * The text-aware comparison further down handles these correctly; this fast path
     * cannot, so it does not try. */
    int pre = writer_node_is_uclamp(node) ? INT_MIN : sysfs_read_int(path, INT_MIN);
    if (pre != INT_MIN && pre == requested) {
        h->observed = pre;
        h->applied++;
        h->consecutive_failures = 0;
        h->retry_at = 0;
        snprintf(h->status, sizeof(h->status), "%s", "already_set");
        return 0;
    }

    int rc = sysfs_write_int(path, requested);
    int observed = (rc == 0) ? sysfs_read_int(path, INT_MIN) : INT_MIN;
    h->observed = observed;
    if (rc == 0 && observed == requested) {
        h->applied++;
        h->consecutive_failures = 0;
        h->retry_at = 0;
        snprintf(h->status, sizeof(h->status), "%s", "applied");
        return 0;
    }
    /* uclamp nodes answer in percent-with-decimals, or with the word "max".
     *
     * cgroup reports cpu.uclamp.max as "85.00", and as the literal string "max" when the
     * tier is unconstrained. sysfs_read_int truncates the first to 85 - which matches - but
     * cannot parse the second at all, so an unconstrained tier reads back as garbage and
     * every write to it is recorded as a failure.
     *
     * A device capture shows the consequence: writer health attempts=39 applied=21
     * failures=18 backoff_skips=15, with all four uclamp tiers sitting at ROM stock. The
     * writes were not refused by the kernel - they were judged failed by the confirmation
     * step, the node was backed off, and the tiers were never brought under ASB control.
     * That is an hour of the app on screen having no scheduler ceiling while background
     * work had none either.
     *
     * Confirmed by re-reading as text and comparing the integer part, which is the only
     * part ASB ever asks for.
     */
    if (rc == 0 && writer_node_is_uclamp(node)) {
        char _uc_buf[32] = {0};
        /* sysfs_read_str returns the LENGTH read, not a status code - it is > 0 on
         * success and -1 on failure. Comparing it to 0 meant this branch only ran for an
         * empty file, so the percent-format confirmation never executed and every uclamp
         * write still counted as a failure. The device kept reporting 0.00 with
         * writer health failures=8, which is what sent me looking here a second time. */
        if (sysfs_read_str(path, _uc_buf, sizeof(_uc_buf)) > 0) {
            int _uc_seen;
            if (strncmp(_uc_buf, "max", 3) == 0) {
                _uc_seen = 100;                    /* "max" is 100% by definition */
            } else {
                _uc_seen = atoi(_uc_buf);          /* "85.00" -> 85 */
            }
            if (_uc_seen == requested) {
                h->observed = _uc_seen;
                h->applied++;
                h->consecutive_failures = 0;
                h->retry_at = 0;
                snprintf(h->status, sizeof(h->status), "%s", "applied");
                return 0;
            }
            h->observed = _uc_seen;
        }
    }
    /* A smaller live CPU maximum still satisfies ASB's request: a ceiling is an
     * upper bound, and a vendor PowerHAL/thermal owner that holds a stricter bound
     * is already doing the energy/heat-safe thing. Treat it as cooperative success
     * instead of reopening a write fight every state transition. The caller keeps
     * watching for a later vendor raise above the requested ceiling. CPU minimums
     * are deliberately excluded: a higher floor consumes power and must retain the
     * existing readback/retry diagnostics. */
    /* A floor the kernel refuses to lower is the kernel's decision, not a write error.
     *
     * scaling_min_freq is clamped by the driver's own minimum: ask for 384000 on a policy
     * whose QoS floor is 787200 and the node reads back 787200 no matter how often you
     * write it. The same applies to a ceiling a vendor thermal engine is holding above our
     * request during an episode.
     *
     * Counted as failures, three of these in a row put the node into holddown - so the one
     * knob the vendor happens to disagree about took the whole cluster's management with
     * it. A device capture shows 384000->787200 and 768000->1747200 repeating: the module
     * fighting a bound it cannot move, and losing the ability to set anything else while
     * it did.
     *
     * Recorded with its own status so it stays visible in the report: this is information
     * about the device, not about a defect, and the reader should be able to tell them
     * apart.
     */
    if (rc == 0 && writer_node_is_cpu(node) && observed > 0 && observed > requested) {
        h->applied++;
        h->consecutive_failures = 0;
        h->retry_at = 0;
        snprintf(h->status, sizeof(h->status), "%s", "kernel_floor_higher");
        return 0;
    }
    if (rc == 0 && writer_node_is_cpu_max(node) && observed > 0 && observed < requested) {
        h->applied++;
        h->consecutive_failures = 0;
        h->retry_at = 0;
        snprintf(h->status, sizeof(h->status), "%s", "vendor_stricter_ceiling");
        return 0;
    }
    h->failures++;
    h->consecutive_failures++;
    /* A WALT readback of INT_MIN is the sysfs reader's invalid sentinel, not
     * an applied tuning. Fail closed for this daemon lifetime rather than
     * waking every few minutes to rewrite an unsupported node. */
    if (node == ASB_WRITE_WALT_RAVG && observed == INT_MIN) {
        h->retry_at = now + 86400;
        snprintf(h->status, sizeof(h->status), "%s", "unsupported_readback");
        writer_write_failure_event(node, path, requested, observed, h->retry_at);
        return -1;
    }
    /* If CPU policy repeatedly disagrees after a successful write, a vendor
     * PowerHAL/thermal owner is active. Back off for fifteen minutes instead
     * of entering a reassert fight that costs energy and can worsen heat. */
    if (writer_node_is_cpu(node) && rc == 0 && observed != INT_MIN && h->consecutive_failures >= 3) {
        /* Ninety seconds, not fifteen minutes.
         *
         * Avoiding a reassert fight with a vendor PowerHAL is right; 900 s is not. A diag
         * reads attempts=34 applied=23 failures=11 backoff_skips=25 - on a phone whose
         * vendor disagrees routinely, this holddown keeps the governor silent for most of
         * its life and every thermal decision is discarded before reaching sysfs. That is
         * why cap_owner reads vendor 92% / asb 0%.
         *
         * Fifteen minutes outlasts most thermal episodes, so by the time the node is
         * eligible again the situation is over. Ninety seconds still prevents a
         * tick-by-tick fight while letting the governor act within one heating episode. */
        h->retry_at = now + 90;
        snprintf(h->status, sizeof(h->status), "%s", "external_policy_holddown");
        writer_write_failure_event(node, path, requested, observed, h->retry_at);
        return -1;
    }
    /* 60, 120, 240, then cap at five minutes for ordinary transient errors. */
    /* 10, 20, 40, capped at 60 s - not 60, 120, 240, capped at 300.
     *
     * Sized for a permanently unsupported node, where waiting costs nothing. But the
     * same path catches a node that merely lost one write, and a five-minute lockout
     * there discards sixty ticks of governor decisions. The capability backoff below
     * still handles genuinely dead nodes; this one only has to stop a hot loop. */
    unsigned long step = h->failures > 3 ? 60UL : (10UL << (h->failures - 1));
    if (step > 300UL) step = 300UL;
    h->retry_at = now + (time_t)step;
    snprintf(h->status, sizeof(h->status), "%s", (rc == 0) ? "readback_mismatch" : "write_failed");
    writer_write_failure_event(node, path, requested, observed, h->retry_at);
    return -1;
}

static void writer_write_health_dump(FILE *f) {
    if (!f) return;
    unsigned long attempts = 0, applied = 0, failures = 0, skipped = 0;
    time_t next_retry = 0;
    for (int i = 0; i < ASB_WRITE_NODE_COUNT; i++) {
        attempts += g_write_health[i].attempts;
        applied += g_write_health[i].applied;
        failures += g_write_health[i].failures;
        skipped += g_write_health[i].skipped_backoff;
        if (g_write_health[i].retry_at > next_retry) next_retry = g_write_health[i].retry_at;
    }
    fprintf(f, "writer_attempts=%lu\nwriter_applied=%lu\nwriter_failures=%lu\n"
               "writer_backoff_skips=%lu\nwriter_next_retry=%ld\n",
            attempts, applied, failures, skipped, (long)next_retry);
    for (int i = 0; i < ASB_WRITE_NODE_COUNT; i++) {
        asb_write_health_t *h = &g_write_health[i];
        if (!h->attempts && !h->failures && !h->skipped_backoff) continue;
        fprintf(f, "writer_node_%s=requested:%d,observed:%d,attempts:%lu,applied:%lu,failures:%lu,consecutive_failures:%lu,retry_at:%ld,status:%s\n",
                writer_write_node_name((asb_write_node_t)i), h->requested, h->observed,
                h->attempts, h->applied, h->failures, h->consecutive_failures, (long)h->retry_at,
                h->status[0] ? h->status : "unknown");
    }
}

/* Shadow records are emitted only when desired caps change, so shadow mode does
 * not turn an observation run into an I/O workload. It is intentionally a
 * separate JSONL file: state stays the live applied contract. */
static asb_profile_caps_t g_shadow_last_caps;
static int g_shadow_last_valid = 0;

static void writer_shadow_record(const asb_profile_caps_t *caps, asb_state_t state, int thermal_cap) {
    if (!caps) return;
    if (g_shadow_last_valid &&
        !memcmp(&g_shadow_last_caps, caps, sizeof(*caps))) return;
    g_shadow_last_caps = *caps;
    g_shadow_last_valid = 1;
    FILE *f = fopen("/data/adb/asb/shadow_policy.jsonl", "a");
    if (!f) return;
    fprintf(f, "{\"ts\":%ld,\"state\":\"%s\",\"thermal_cap\":%d,"
               "\"cpu_max\":[%d,%d,%d],\"cpu_min\":[%d,%d,%d],"
               "\"gpu_max_pct\":%d,\"gpu_min_pct\":%d}\n",
            (long)time(NULL), asb_state_names[state], thermal_cap,
            caps->cpu_max[0], caps->cpu_max[1], caps->cpu_max[2],
            caps->cpu_min[0], caps->cpu_min[1], caps->cpu_min[2],
            caps->gpu_max_pct, caps->gpu_min_pct);
    fclose(f);
}

static char g_cpu_max_paths[3][128];
static char g_cpu_min_paths[3][128];
/* Per-physical-cluster paths (OP12 = 4). Each entry knows which slot's cap to
 * use, so every cluster is governed even when there are more clusters than the
 * 3 logical slots. */
static char g_cpu_all_max_paths[16][128];
static char g_cpu_all_min_paths[16][128];
static int  g_cpu_all_paths_slot[16];
static int  g_cpu_all_paths_n = 0;
static int  g_writer_paths_ready = 0;

/* Per-cluster frequency tables, and snapping to them.
 *
 * cpufreq accepts any number written to scaling_max_freq and then rounds it to whatever
 * the OPP table actually has - upwards, in the kernels this runs on. So a cap computed by
 * ratio lands higher than intended, and the amount is invisible: the module believes it
 * asked for one thing while the silicon runs another.
 *
 * A field capture on a OnePlus 15 showed exactly that: asb_declared=3124881 on policy0 and
 * 2232876 on policy6. Neither is a frequency any device has - both are ratio arithmetic
 * written straight to sysfs. The shell path already snaps (asb_synthesize_bounds.sh does
 * it when generating device_bounds.env); the governor computing its own caps at runtime
 * did not, so on Smart - where caps are synthesised per tick from alpha - nothing was
 * snapped at all.
 *
 * Snapping DOWN, not to the nearest. A cap is a ceiling: rounding it up hands back
 * headroom the profile deliberately withheld, which is the wrong direction for the one
 * setting whose entire job is restraint. */
static long g_cpu_freq_tables[16][32];
static int  g_cpu_freq_table_len[16];
static int  g_cpu_freq_tables_ready = 0;

static void cpu_read_freq_tables(void) {
    if (g_cpu_freq_tables_ready) return;
    /* Topology first: this builds g_cpu_all_ids, and without it every path below is
     * assembled from a zeroed array - "policy0/..." for all three slots.
     *
     * cpu_snap_freq calls this function lazily, and on the first tick it can run before
     * writer_init_paths has discovered anything. The loop then reads policy0 three times,
     * or nothing at all when g_cpu_all_paths_n is still zero, and the table stays empty.
     * cpu_snap_freq returns want unchanged, ceilings reach the kernel unrounded, the
     * kernel rounds each one up to the next real OPP, and the confirmation step records a
     * mismatch.
     *
     * That is the whole failure the device reported: requested=1440000 observed=1785600,
     * requested=384000 observed=998400 - values no OPP table contains, blamed on a vendor
     * override for three rounds. The diagnostic line "OPP table not enumerable" is what
     * finally made it visible.
     *
     * The call is idempotent and returns immediately once discovery has run. */
    cpu_topology_discover();
    /* Enumerate from the topology directly, not from g_cpu_all_paths_n.
     *
     * That counter is filled by writer_init_paths, which is defined further down this file
     * and may not have run when cpu_snap_freq calls us on the first tick. Reading it here
     * gave a loop count of zero, so the table stayed empty no matter which sysfs node
     * existed. cpu_topology_discover above fills g_cpu_all_ids and g_cpu_all_count, and
     * those are the facts this loop actually needs.
     */
    int _n_pol = g_cpu_all_count;
    if (_n_pol > 16) _n_pol = 16;
    for (int i = 0; i < _n_pol; i++) {
        g_cpu_freq_table_len[i] = 0;
        char path[256];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpufreq/policy%d/scaling_available_frequencies",
                 g_cpu_all_ids[i]);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            /* scaling_available_frequencies is optional.
             *
             * It exists only for the "table" cpufreq drivers. Recent Qualcomm kernels use
             * the EPSS/OSM driver, where the node is simply absent - and then this
             * function left the table empty, cpu_snap_freq returned the raw value
             * untouched, and every ceiling written was a number no OPP has.
             *
             * A device capture shows the result: requested=1440000 observed=1785600,
             * requested=1555200 observed=1996800 - the kernel rounding each unsnapped
             * request up to the next real step, the confirmation seeing a mismatch, and
             * the node being backed off. Eight rejected writes on cpu_max0 alone, which is
             * the little cluster ceiling failing to hold at all.
             *
             * stats/time_in_state lists exactly the frequencies the driver will accept and
             * is present on every driver, because cpufreq-stats is built from the OPP
             * table itself. Falling back to it costs one extra open on devices that need
             * it and nothing on devices that do not.
             */
            snprintf(path, sizeof(path),
                     "/sys/devices/system/cpu/cpufreq/policy%d/stats/time_in_state",
                     g_cpu_all_ids[i]);
            fd = open(path, O_RDONLY | O_CLOEXEC);
            if (fd < 0) continue;
        }
        char buf[4096] = {0};
        ssize_t rd = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (rd <= 0) continue;
        /* Two formats, one parser.
         *
         * scaling_available_frequencies is a single space-separated line of frequencies.
         * time_in_state is one "freq jiffies" pair per line - so taking every number would
         * fill the table with residency counters and snap requests to nonsense.
         *
         * Reading the FIRST number of each line handles both: the flat list has one line
         * and would lose everything after the first entry, so the flat case is detected by
         * the absence of a newline before the second number.
         */
        int _tis = (strchr(buf, '\n') != NULL &&
                    strstr(path, "time_in_state") != NULL);
        char *q = buf;
        int idx = 0;
        while (*q && idx < 32) {
            long v = strtol(q, &q, 10);
            if (v > 0) g_cpu_freq_tables[i][idx++] = v;
            if (_tis) {
                /* Skip the rest of this line: it is the residency counter. */
                while (*q && *q != '\n') q++;
            }
            while (*q == ' ' || *q == '\n' || *q == '\t' || *q == '\r') q++;
        }
        g_cpu_freq_table_len[i] = idx;
    }
    /* Only latch success.
     *
     * This flag was set unconditionally at the end, so a single early call - before the
     * cpufreq nodes are readable, or before topology discovery had run - permanently
     * recorded "tables read" with every length at zero. cpu_snap_freq then returned every
     * request untouched for the rest of the session, the kernel rounded each one up to the
     * next real OPP, and the confirmation step logged a mismatch that looked exactly like a
     * vendor override.
     *
     * The device reported "OPP table not enumerable" twice in a row across a rebuild, which
     * is what a permanently latched empty table looks like from the outside.
     *
     * Latching only when at least one cluster produced entries means a later tick can still
     * succeed once the driver is up, and costs one directory read per tick until it does.
     */
    int _got = 0;
    for (int k = 0; k < 16; k++) if (g_cpu_freq_table_len[k] > 0) { _got = 1; break; }
    if (_got) g_cpu_freq_tables_ready = 1;
}

/* Number of OPP steps enumerated for a slot, for diagnostics. 0 means snapping is
 * inactive on this device and ceilings reach the kernel unrounded. */
static int writer_freq_table_len(int slot) {
    if (slot < 0 || slot > 2) return 0;
    cpu_read_freq_tables();
    for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++)
        if (g_cpu_all_max_paths[k][0] && g_cpu_max_paths[slot][0] &&
            strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[slot]) == 0)
            return g_cpu_freq_table_len[k];
    return 0;
}

/* Largest table entry <= want. Returns want unchanged when the table is unreadable -
 * a device whose frequencies we cannot enumerate is no worse off than before. */
static long cpu_snap_freq(int path_idx, long want) {
    if (want <= 0) return want;
    if (path_idx < 0 || path_idx >= 16) return want;
    cpu_read_freq_tables();
    int n = g_cpu_freq_table_len[path_idx];
    if (n <= 0) return want;
    long best = 0;
    long lowest = 0;
    for (int i = 0; i < n; i++) {
        long v = g_cpu_freq_tables[path_idx][i];
        if (v <= 0) continue;
        if (lowest == 0 || v < lowest) lowest = v;
        if (v <= want && v > best) best = v;
    }
    /* Below every step: the lowest one is the closest thing to the request that exists,
     * and returning 0 would be read as "no cap". */
    if (best == 0) return lowest > 0 ? lowest : want;
    return best;
}

/* Exact hardware floor for a physical policy. Unlike cpu_snap_freq(), this never accepts
 * a profile-derived kHz target: it returns the first real OPP only when the policy exposed a
 * complete readable table. A missing/empty table returns 0 so callers preserve their existing
 * profile floor rather than guessing a universal frequency. */
static long cpu_lowest_opp(int path_idx) {
    if (path_idx < 0 || path_idx >= 16) return 0;
    cpu_read_freq_tables();
    int n = g_cpu_freq_table_len[path_idx];
    if (n <= 0) return 0;
    long lowest = 0;
    for (int i = 0; i < n; i++) {
        long v = g_cpu_freq_tables[path_idx][i];
        if (v > 0 && (lowest == 0 || v < lowest)) lowest = v;
    }
    return lowest;
}

/* Native Smart caps do not pass through the shell profile wrapper. Record each writable
 * path once in the same profile-only snapshot used by Stock, before the native writer makes
 * its first change. If the file cannot be created, fail closed: never invent a ROM default. */
static void writer_profile_baseline_record_path(const char *path) {
    if (!path || !*path) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char value[160] = {0};
    ssize_t n = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (n <= 0) return;
    for (ssize_t i = 0; i < n; i++) if (value[i] == '\n' || value[i] == '\r' || value[i] == '|') value[i] = '_';

    FILE *f = fopen("/data/adb/asb/profile_runtime_baseline.v1", "a+");
    if (!f) return;
    char line[384]; size_t plen = strlen(path); int found = 0;
    rewind(f);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "path|", 5) == 0 && strncmp(line + 5, path, plen) == 0 && line[5 + plen] == '|') {
            found = 1; break;
        }
    }
    if (!found) fprintf(f, "path|%s|%s\n", path, value);
    fclose(f);
}

/* Absolute floor under every ceiling ASB writes.
 *
 * Eight independent places multiply cpu_max: ladder interpolation, hardware scaling,
 * perf_ceiling_pct, the thermal overlay, the thermal budget, gaming ceiling, anti-clamp
 * backoff and the shell profile path. Each factor is defensible on its own. Nothing was
 * looking at the product.
 *
 * A field capture shows where that ends: policy6 held at 1382400 on a 4.6 GHz part, below
 * the profile's OWN floor ceiling of 1881600 - a value the profile already considers the
 * least that state should ever get. The phone then spent 7-19%/h scrolling a feed with
 * the GPU at 4-8%, because work that should take 100 ms took three times longer with every
 * core, the panel and the radio awake for the whole stretch.
 *
 * This is race-to-idle and it is measurable, not theoretical: below roughly a third of
 * peak, finishing later costs more energy than running slower saves. So the writer - the
 * one place every path funnels through - refuses to publish a ceiling under a hard
 * fraction of what the cluster can do.
 *
 * Deliberately a fraction of hardware, not of the profile: the profile bounds are what the
 * multipliers already chewed through, and a guard expressed in the same currency as the
 * thing it guards can be argued down by the next factor. Hardware capability cannot.
 *
 * 40% is taken from the profiles themselves rather than picked. BALANCED_FLOOR_CPU_MAX is
 * 1190400 of 3628800 on the little cluster (32%) and 1881600 of 4608000 on the big one
 * (41%) - those are the numbers the profile already calls the least a resting state should
 * get. A guard below them would permit a ceiling the profile itself considers too low, so
 * the floor is set at the upper end of that observed range.
 *
 * Thermal emergencies are exempt: a vendor hard clamp or the junction guard must still be
 * able to take the phone below this, because there the alternative is damage rather than
 * slowness.
 */
#define ASB_MIN_CEILING_PCT_OF_HW 40

static int cpu_floor_ceiling(int path_idx, int want, int thermal_emergency) {
    if (want <= 0 || thermal_emergency) return want;
    if (path_idx < 0 || path_idx >= 16) return want;
    cpu_read_freq_tables();
    int n = g_cpu_freq_table_len[path_idx];
    if (n <= 0) return want;
    long hw = 0;
    for (int i = 0; i < n; i++)
        if (g_cpu_freq_tables[path_idx][i] > hw) hw = g_cpu_freq_tables[path_idx][i];
    if (hw <= 0) return want;
    long guard = hw * ASB_MIN_CEILING_PCT_OF_HW / 100;
    if ((long)want >= guard) return want;
    /* Snap the guard itself to a real step, otherwise the kernel rounds it up and the
     * floor ends up higher than intended. */
    return (int)cpu_snap_freq(path_idx, guard);
}

static void writer_init_paths(void) {
    if (g_writer_paths_ready) return;
    cpu_topology_discover();
    for (int i = 0; i < 3; i++) {
        if (g_cpu_policy_ids[i] >= 0) {
            snprintf(g_cpu_max_paths[i], sizeof(g_cpu_max_paths[i]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq",
                g_cpu_policy_ids[i]);
            snprintf(g_cpu_min_paths[i], sizeof(g_cpu_min_paths[i]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_min_freq",
                g_cpu_policy_ids[i]);
        } else {
            g_cpu_max_paths[i][0] = '\0';
            g_cpu_min_paths[i][0] = '\0';
        }
    }
    /*
     * Build the full per-cluster path list (falls back to the 3 slots if the discover step
     * didn't populate the all-list, e.g.
     */
    g_cpu_all_paths_n = 0;
    if (g_cpu_all_count > 0) {
        for (int i = 0; i < g_cpu_all_count && g_cpu_all_paths_n < 16; i++) {
            snprintf(g_cpu_all_max_paths[g_cpu_all_paths_n],
                sizeof(g_cpu_all_max_paths[g_cpu_all_paths_n]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq",
                g_cpu_all_ids[i]);
            snprintf(g_cpu_all_min_paths[g_cpu_all_paths_n],
                sizeof(g_cpu_all_min_paths[g_cpu_all_paths_n]),
                "/sys/devices/system/cpu/cpufreq/policy%d/scaling_min_freq",
                g_cpu_all_ids[i]);
            g_cpu_all_paths_slot[g_cpu_all_paths_n] = g_cpu_all_slot[i];
            g_cpu_all_paths_n++;
        }
    }
    for (int i = 0; i < g_cpu_all_paths_n && i < 16; i++) {
        writer_profile_baseline_record_path(g_cpu_all_max_paths[i]);
        writer_profile_baseline_record_path(g_cpu_all_min_paths[i]);
    }
    g_writer_paths_ready = 1;
}

#define GPU_PATH_CANDIDATES_MAX 6
static char g_gpu_max_path[160]      = {0};   /* either pwrlevel or max_freq */
static char g_gpu_min_path[160]      = {0};
static char g_gpu_avail_path[160]    = {0};
static int  g_gpu_paths_ready        = 0;
static int  g_gpu_uses_pwrlevel      = 0;     /* 1 = integer pwrlevel; 0 = Hz */
static int  g_gpu_num_pwrlevels      = 0;     /* count of levels if pwrlevel mode */
static long g_gpu_freq_table[32]     = {0};   /* frequencies in descending order */
static int  g_gpu_freq_table_len     = 0;

static char g_gpu_thermal_pwrlevel_path[160] = {0};
static int  g_gpu_thermal_pwrlevel_fd        = -1;   /* cached read fd, -1 if absent */
static int  g_gpu_thermal_pwrlevel_last      = -1;   /* last read value */

static unsigned long g_thermal_pl_reads_count   = 0;  /* total successful reads */
static unsigned long g_thermal_pl_skip_count    = 0;  /* gated skips */
static unsigned long g_thermal_pl_us_total      = 0;  /* total microseconds spent reading */

static int gpu_try_readable(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

static int gpu_try_probe_write(const char *path) {
    int rfd = open(path, O_RDONLY | O_CLOEXEC);
    if (rfd < 0) return 0;
    char buf[64] = {0};
    ssize_t n = read(rfd, buf, sizeof(buf) - 1);
    close(rfd);
    if (n <= 0) return 0;

    int wfd = open(path, O_WRONLY | O_CLOEXEC);
    if (wfd < 0) return 0;
    /* Strip trailing newline; write exactly what we read back. */
    size_t len = (size_t)n;
    while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r' || buf[len-1] == ' '))
        len--;
    ssize_t w = write(wfd, buf, len);
    close(wfd);
    return (w == (ssize_t)len) ? 1 : 0;
}

static void gpu_read_freq_table(void) {
    if (!g_gpu_avail_path[0]) return;
    int fd = open(g_gpu_avail_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char abuf[512] = {0};
    ssize_t _rd = read(fd, abuf, sizeof(abuf) - 1);
    (void)_rd;
    close(fd);

    /*
     * Parse space-separated frequencies (Qualcomm format: descending order "1100000000
     * 1000000000 900000000 ...").
     */
    char *p = abuf;
    int idx = 0;
    while (*p && idx < 32) {
        long v = strtol(p, &p, 10);
        if (v > 0) g_gpu_freq_table[idx++] = v;
        while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
    }
    g_gpu_freq_table_len = idx;

    /* Ensure descending: Qualcomm normally outputs descending but some
     * kernels sort ascending. Bubble-sort descending if needed. */
    for (int i = 0; i < g_gpu_freq_table_len - 1; i++) {
        for (int j = 0; j < g_gpu_freq_table_len - 1 - i; j++) {
            if (g_gpu_freq_table[j] < g_gpu_freq_table[j+1]) {
                long t = g_gpu_freq_table[j];
                g_gpu_freq_table[j] = g_gpu_freq_table[j+1];
                g_gpu_freq_table[j+1] = t;
            }
        }
    }
}

static int writer_gpu_devfreq_name_is_graphics(const char *name) {
    if (!name || !*name) return 0;
    char lower[128]; size_t n = strlen(name);
    if (n >= sizeof(lower)) n = sizeof(lower) - 1;
    for (size_t i = 0; i < n; i++) lower[i] = (char)tolower((unsigned char)name[i]);
    lower[n] = '\0';
    return strstr(lower, "gpu") || strstr(lower, "mali") ||
           strstr(lower, "kgsl") || strstr(lower, "adreno") ||
           strstr(lower, "powervr") || strstr(lower, "xclipse");
}

/* Standard devfreq uses the same Hz max/min semantics across GPU drivers. Scan only
 * directories with an explicit graphics identity: writing a generic devfreq node selected
 * by filename alone could otherwise cap DDR, NPU or ISP and is deliberately forbidden. */
static void writer_discover_generic_gpu_devfreq(void) {
    DIR *dir = opendir("/sys/class/devfreq");
    if (!dir) return;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (de->d_name[0] == '.' || !writer_gpu_devfreq_name_is_graphics(de->d_name)) continue;
        char max[160], min[160], avail[160];
        snprintf(max, sizeof(max), "/sys/class/devfreq/%s/max_freq", de->d_name);
        snprintf(min, sizeof(min), "/sys/class/devfreq/%s/min_freq", de->d_name);
        snprintf(avail, sizeof(avail), "/sys/class/devfreq/%s/available_frequencies", de->d_name);
        if (!gpu_try_probe_write(max)) continue;
        snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", max);
        g_gpu_uses_pwrlevel = 0;
        if (gpu_try_probe_write(min))
            snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", min);
        if (gpu_try_readable(avail))
            snprintf(g_gpu_avail_path, sizeof(g_gpu_avail_path), "%s", avail);
        break;
    }
    closedir(dir);
}

static void writer_discover_gpu_paths(void) {
    if (g_gpu_paths_ready) return;

    /* Prefer Hz-based max_freq nodes (traditional devfreq devices). */
    static const char *max_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/max_freq",
        NULL
    };
    static const char *min_freq_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/min_freq",
        "/sys/class/devfreq/3d00000.qcom,gpu/min_freq",
        NULL
    };
    /* Fallback: KGSL-native pwrlevel interface (present on SM8850). */
    static const char *pwrlevel_max_path = "/sys/class/kgsl/kgsl-3d0/max_pwrlevel";
    static const char *pwrlevel_min_path = "/sys/class/kgsl/kgsl-3d0/min_pwrlevel";
    static const char *num_pwrlevels_path = "/sys/class/kgsl/kgsl-3d0/num_pwrlevels";

    static const char *avail_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/available_frequencies",
        "/sys/class/devfreq/3d00000.qcom,gpu/available_frequencies",
        "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies",
        NULL
    };

    /* Try Hz path first; require actual write success, not just open. */
    for (int i = 0; max_freq_candidates[i]; i++) {
        if (gpu_try_probe_write(max_freq_candidates[i])) {
            snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", max_freq_candidates[i]);
            g_gpu_uses_pwrlevel = 0;
            break;
        }
    }
    if (g_gpu_max_path[0]) {
        for (int i = 0; min_freq_candidates[i]; i++) {
            if (gpu_try_probe_write(min_freq_candidates[i])) {
                snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", min_freq_candidates[i]);
                break;
            }
        }
    } else {
        writer_discover_generic_gpu_devfreq();
    }
    if (!g_gpu_max_path[0]) {
        /* No Hz control — try KGSL-native pwrlevel interface. */
        if (gpu_try_probe_write(pwrlevel_max_path)) {
            snprintf(g_gpu_max_path, sizeof(g_gpu_max_path), "%s", pwrlevel_max_path);
            g_gpu_uses_pwrlevel = 1;
            if (gpu_try_probe_write(pwrlevel_min_path)) {
                snprintf(g_gpu_min_path, sizeof(g_gpu_min_path), "%s", pwrlevel_min_path);
            }
            /* Read num_pwrlevels if available */
            int fd = open(num_pwrlevels_path, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                char nbuf[16] = {0};
                ssize_t _r = read(fd, nbuf, sizeof(nbuf) - 1);
                (void)_r;
                close(fd);
                g_gpu_num_pwrlevels = atoi(nbuf);
            }
        }
    }

    /* Available frequencies (read-only, used for hw_max + pwrlevel translation) */
    if (!g_gpu_avail_path[0]) {
        for (int i = 0; avail_candidates[i]; i++) {
            if (gpu_try_readable(avail_candidates[i])) {
                snprintf(g_gpu_avail_path, sizeof(g_gpu_avail_path), "%s", avail_candidates[i]);
                break;
            }
        }
    }

    /*
     * thermal_pwrlevel discovery — vendor thermal cap, read-only for us but kernel writes to
     * it dynamically.
     */
    static const char *thermal_pl_candidates[] = {
        "/sys/class/kgsl/kgsl-3d0/thermal_pwrlevel",
        "/sys/class/devfreq/3d00000.qcom,kgsl-3d0/thermal_pwrlevel",
        NULL
    };
    for (int i = 0; thermal_pl_candidates[i]; i++) {
        int fd = open(thermal_pl_candidates[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            snprintf(g_gpu_thermal_pwrlevel_path, sizeof(g_gpu_thermal_pwrlevel_path),
                     "%s", thermal_pl_candidates[i]);
            g_gpu_thermal_pwrlevel_fd = fd;
            break;
        }
    }

    /* Populate freq_table early — needed for pwrlevel translation */
    gpu_read_freq_table();

    /* Observability */
#if ASB_DEBUG_BUILD
    FILE *lf = fopen("/dev/.asb/gpu_path_discovery", "w");
    if (lf) {
        fprintf(lf, "max=%s\nmin=%s\navail=%s\nthermal=%s\nmode=%s\nnum_pwrlevels=%d\nfreq_table_len=%d\n",
                g_gpu_max_path[0]   ? g_gpu_max_path   : "(none)",
                g_gpu_min_path[0]   ? g_gpu_min_path   : "(none)",
                g_gpu_avail_path[0] ? g_gpu_avail_path : "(none)",
                g_gpu_thermal_pwrlevel_path[0] ? g_gpu_thermal_pwrlevel_path : "(none)",
                g_gpu_uses_pwrlevel ? "pwrlevel" : "hz",
                g_gpu_num_pwrlevels,
                g_gpu_freq_table_len);
        for (int i = 0; i < g_gpu_freq_table_len; i++)
            fprintf(lf, "freq[%d]=%ld\n", i, g_gpu_freq_table[i]);
        fclose(lf);
    }
#endif

    writer_profile_baseline_record_path(g_gpu_max_path);
    writer_profile_baseline_record_path(g_gpu_min_path);
    g_gpu_paths_ready = 1;
}

static int gpu_read_thermal_pwrlevel(void) {
    if (g_gpu_thermal_pwrlevel_fd < 0) return -1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    char buf[16] = {0};
    ssize_t n = pread(g_gpu_thermal_pwrlevel_fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return g_gpu_thermal_pwrlevel_last;  /* keep last known */

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long elapsed_us = (t1.tv_sec - t0.tv_sec) * 1000000L
                    + (t1.tv_nsec - t0.tv_nsec) / 1000L;
    g_thermal_pl_us_total += (unsigned long)elapsed_us;
    g_thermal_pl_reads_count++;

    int v = atoi(buf);
    if (v >= 0 && v < 32) g_gpu_thermal_pwrlevel_last = v;
    return g_gpu_thermal_pwrlevel_last;
}

static int gpu_thermal_pwrlevel_last(void) {
    return g_gpu_thermal_pwrlevel_last;
}

static void gpu_thermal_pl_record_skip(void) {
    g_thermal_pl_skip_count++;
}

static int gpu_thermal_pl_audit_path(char *out, size_t outlen) {
    return snprintf(out, outlen,
        "{\"reads\":%lu,\"skips\":%lu,\"total_us\":%lu,\"last_level\":%d,\"path\":\"%s\"}",
        g_thermal_pl_reads_count,
        g_thermal_pl_skip_count,
        g_thermal_pl_us_total,
        g_gpu_thermal_pwrlevel_last,
        g_gpu_thermal_pwrlevel_path[0] ? g_gpu_thermal_pwrlevel_path : "(none)");
}

static int gpu_hz_to_pwrlevel_max(long target_hz) {
    if (g_gpu_freq_table_len <= 0) return 0;
    for (int i = 0; i < g_gpu_freq_table_len; i++) {
        if (g_gpu_freq_table[i] <= target_hz) return i;
    }
    /* All frequencies exceed target — clamp to lowest (last index) */
    return g_gpu_freq_table_len - 1;
}

static int gpu_hz_to_pwrlevel_min(long target_hz) {
    if (g_gpu_freq_table_len <= 0) return 0;
    for (int i = g_gpu_freq_table_len - 1; i >= 0; i--) {
        if (g_gpu_freq_table[i] >= target_hz) return i;
    }
    return 0;
}

#define WALT_RAVG_PATH  "/proc/sys/walt/sched_ravg_window_nr_ticks"
#define WALT_IDLE_PATH  "/proc/sys/walt/sched_idle_enough"

#define UCLAMP_TOP_MAX  "/dev/cpuctl/top-app/cpu.uclamp.max"
#define UCLAMP_BG_MAX   "/dev/cpuctl/background/cpu.uclamp.max"
#define UCLAMP_SYBG_MAX "/dev/cpuctl/system-background/cpu.uclamp.max"
/*
 * foreground was never managed here, and that is exactly where the camera HAL and the media
 * codec threads live -- neither is top-app.
 * With the profile scripts leaving cpu.uclamp.max at 55-70 there, the scheduler could not ask
 * for the frequency the pipeline needed no matter how high the caps went.
 */
#define UCLAMP_FG_MAX   "/dev/cpuctl/foreground/cpu.uclamp.max"
#define CPUSET_FG_CPUS  "/dev/cpuset/foreground/cpus"
#define CPUSET_TOP_CPUS "/dev/cpuset/top-app/cpus"
#define PATH_CPU_PRESENT   "/sys/devices/system/cpu/present"
#define PATH_VM_SWAPPINESS "/proc/sys/vm/swappiness"

static int  g_cam_guard_on = 0;
/* When the guard was raised, and whether it has already been stood down for this session.
 *
 * The guard lifts every uclamp ceiling to 100% and pins cpusets to all cores. That is the
 * right answer for a 4K60 recording, which is what it was built for: the ISP and encoder
 * do the work while HAL threads need the CPU on a 16.6 ms deadline, and the usual load
 * signals stay low so nothing else would raise the clocks.
 *
 * It is the wrong answer for an hour-long video call, which presents identically - camera
 * streaming, same HAL threads - but runs long enough that "hold nothing back" becomes the
 * steady state. A user reported the phone getting hot on video calls; camera_hold_max_s
 * existed in the config for exactly this and was never read by anything.
 *
 * After the limit the guard releases and normal state selection resumes. A call keeps
 * working - it just stops being treated as a burst. */
static time_t g_cam_guard_since = 0;
static int    g_cam_guard_expired = 0;
static char g_cam_saved_fg_cpus[64]  = {0};
static char g_cam_saved_top_cpus[64] = {0};
static int  g_cam_saved_uc_top = -1;
static int  g_cam_saved_uc_fg  = -1;
static int  g_cam_saved_uc_bg  = -1;
static int  g_cam_saved_swappiness = -1;

/*
 * The guard raises ceilings and then owns the job of putting them back.
 * /dev is tmpfs on purpose: this must survive a governor restart and must NOT survive a
 * reboot, where service.sh sets every one of these itself.
 */
#define CAM_GUARD_STATE "/dev/.asb/camera_guard"

typedef struct {
    int cpu_max[3];
    int cpu_min[3];
    int gpu_max_pct;
    int gpu_min_pct;
    /* The raw value last written to the GPU min path, or -1. Compared against sysfs to
     * detect a vendor override; gpu_min_pct cannot do that job because it is our request,
     * not what ended up on the device. */
    int gpu_min_written;
    int ravg_ticks;
    int idle_enough;
    int uclamp_top_max;
    int uclamp_bg_max;
    long gpu_hw_max_freq;
    int  initialized;
    /* last actual pwrlevel values we wrote, for vendor-override detection */
    int last_max_pwrlevel_written;
    int last_min_pwrlevel_written;
} asb_writer_cache_t;

/* gpu_min_written starts at -1, not 0: zero is a legitimate pwrlevel (the fastest step),
 * so a zeroed cache would claim we had written it and mask a real vendor override on the
 * very first comparison. */
static asb_writer_cache_t g_wcache = { .gpu_min_written = -1 };

/* Last uclamp values the writer was asked to apply, for diagnostics. Read from the
 * cache rather than the node: the point is to compare intent against reality, and the
 * report already prints reality. */
static int g_ucl_want_top = -1;
static int g_ucl_want_bg  = -1;
static int writer_last_uclamp_top(void) { return g_ucl_want_top; }
static int writer_last_uclamp_bg(void)  { return g_ucl_want_bg; }


static unsigned long g_vendor_override_max = 0;
static unsigned long g_vendor_override_min = 0;
static unsigned long g_vendor_override_backoffs = 0;
static time_t g_vendor_override_backoff_until = 0;
static int g_last_observed_max_pwrlevel = -1;
/* What we last wrote to the GPU min path, in the units that path uses. Needed to tell
 * "the vendor moved it" from "we changed our mind" - gpu_min_pct alone cannot, because
 * the same percentage maps to the same index and looks unchanged either way. */
static int g_last_observed_min_pwrlevel = -1;

static void gpu_check_vendor_override(int profile_idx, const char *state_name) {
    if (!g_gpu_paths_ready || !g_gpu_uses_pwrlevel) return;
    if (g_wcache.last_max_pwrlevel_written < 0 &&
        g_wcache.last_min_pwrlevel_written < 0) return;

    int cur_max = -1, cur_min = -1;
    if (g_gpu_max_path[0]) {
        int fd = open(g_gpu_max_path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            char b[8] = {0};
            ssize_t _n = read(fd, b, sizeof(b)-1);
            close(fd);
            if (_n > 0) cur_max = atoi(b);
        }
    }
    if (g_gpu_min_path[0]) {
        int fd = open(g_gpu_min_path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            char b[8] = {0};
            ssize_t _n = read(fd, b, sizeof(b)-1);
            close(fd);
            if (_n > 0) cur_min = atoi(b);
        }
    }

    int max_overridden = (cur_max >= 0 &&
                          g_wcache.last_max_pwrlevel_written >= 0 &&
                          cur_max != g_wcache.last_max_pwrlevel_written);
    int min_overridden = (cur_min >= 0 &&
                          g_wcache.last_min_pwrlevel_written >= 0 &&
                          cur_min != g_wcache.last_min_pwrlevel_written);

    if (max_overridden) g_vendor_override_max++;
    if (min_overridden) g_vendor_override_min++;
    if (max_overridden || min_overridden) {
        /* Vendor thermal/PowerHAL is authoritative for a short lease. Avoid
         * immediately writing the previous ASB request back and creating a
         * 2-second pwrlevel fight that adds sysfs churn, heat and log noise. */
        time_t now = time(NULL);
        time_t until = now + 15;
        if (until > g_vendor_override_backoff_until) {
            g_vendor_override_backoff_until = until;
            g_vendor_override_backoffs++;
        }
    }

#if ASB_DEBUG_BUILD
    if ((max_overridden && g_vendor_override_max <= 50) ||
        (min_overridden && g_vendor_override_min <= 50)) {
        FILE *ef = fopen("/dev/.asb/vendor_overrides", "a");
        if (ef) {
            time_t now = time(NULL);
            fprintf(ef, "ts=%ld profile=%d state=%s max_written=%d max_observed=%d "
                        "min_written=%d min_observed=%d max_overridden=%d min_overridden=%d\n",
                    (long)now, profile_idx, state_name ? state_name : "?",
                    g_wcache.last_max_pwrlevel_written, cur_max,
                    g_wcache.last_min_pwrlevel_written, cur_min,
                    max_overridden, min_overridden);
            fclose(ef);
        }
    }
#endif

    g_last_observed_max_pwrlevel = cur_max;
    g_last_observed_min_pwrlevel = cur_min;
}

static int gpu_vendor_override_backoff_active(void) {
    return time(NULL) < g_vendor_override_backoff_until;
}

static int gpu_vendor_override_audit_path(char *out, size_t outlen) {
    time_t now = time(NULL);
    long remaining = (g_vendor_override_backoff_until > now)
                   ? (long)(g_vendor_override_backoff_until - now) : 0;
    return snprintf(out, outlen,
        "{\"max_overrides\":%lu,\"min_overrides\":%lu,\"backoffs\":%lu,"
        "\"backoff_remaining_s\":%ld,\"last_max_written\":%d,\"last_max_observed\":%d,"
        "\"last_min_written\":%d,\"last_min_observed\":%d}",
        g_vendor_override_max, g_vendor_override_min, g_vendor_override_backoffs, remaining,
        g_wcache.last_max_pwrlevel_written, g_last_observed_max_pwrlevel,
        g_wcache.last_min_pwrlevel_written, g_last_observed_min_pwrlevel);
}

static long writer_gpu_hw_max(void) {
    if (g_wcache.gpu_hw_max_freq > 0) return g_wcache.gpu_hw_max_freq;
    writer_discover_gpu_paths();
    /* Freq table already populated by discovery. Index 0 = highest freq. */
    if (g_gpu_freq_table_len > 0) {
        g_wcache.gpu_hw_max_freq = g_gpu_freq_table[0];
        return g_wcache.gpu_hw_max_freq;
    }
    g_wcache.gpu_hw_max_freq = 1000000000L;
    return g_wcache.gpu_hw_max_freq;
}

#define PATH_MSM_PERF_CPU_MAX "/sys/kernel/msm_performance/parameters/cpu_max_freq"
#define PATH_MSM_PERF_CPU_MIN "/sys/kernel/msm_performance/parameters/cpu_min_freq"

static int g_msm_perf_available = -1;

static int msm_perf_check(void) {
    if (g_msm_perf_available >= 0) return g_msm_perf_available;
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd >= 0) { close(fd); g_msm_perf_available = 1; return 1; }
    g_msm_perf_available = 0;
    return 0;
}

static int g_msm_cur_max[2] = {0, 0};

static int msm_perf_write_all_max(int c0_freq, int c1_freq) {
    if (!msm_perf_check()) return -1;
    if (c0_freq > 0) g_msm_cur_max[0] = c0_freq;
    if (c1_freq > 0) g_msm_cur_max[1] = c1_freq;
    if (!g_msm_cur_max[0] || !g_msm_cur_max[1]) return -1;
    char buf[256] = {0};
    int pos = 0;
    for (int c = 0; c <= 5; c++)
        pos += snprintf(buf+pos, sizeof(buf)-pos, "%d:%d ", c, g_msm_cur_max[0]);
    for (int c = 6; c <= 7; c++)
        pos += snprintf(buf+pos, sizeof(buf)-pos, "%d:%d ", c, g_msm_cur_max[1]);
    if (pos > 0) buf[pos-1] = 0;
    int fd = open(PATH_MSM_PERF_CPU_MAX, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = write(fd, buf, strlen(buf));
    close(fd);
    return (r > 0) ? 0 : -1;
}

static const int g_cluster_first_cpu[3] = {0, 6, -1};
static const int g_cluster_n_cpus[3]   = {6, 2,  0};

static int writer_apply_caps(const asb_profile_caps_t *caps, int force, asb_state_t state, int thermal_cap) {
    int writes = 0;
    writer_init_paths();
    if (g_asb_cfg.shadow_mode) {
        writer_shadow_record(caps, state, thermal_cap);
        return 0;
    }

    /*
     * CAP OWNERSHIP: for MANUAL profiles (battery/balanced/performance) the shell layer
     * (service.sh apply_screen_aware_caps) is the sole owner of scaling_max/min — it has the
     * correct per-device, screen-aware, 4-cluster caps.
     * The governor must NOT also push its bounds-derived ceiling there, or the two race and
     * you get the contradictory diag values (performance prime stuck at 39-58%, OP12 battery
     * prime > balanced).
     */
    /*
     * manual_cap_skip: in MANUAL battery/balanced the shell owns caps, so the governor stays
     * out (only thermal net pulls down).
     */
    int manual_cap_skip = (!fsm_profile_is_smart && !fsm_profile_is_performance && !thermal_cap);
    if (manual_cap_skip) {
        /* still let GPU / non-cap writes proceed below; just skip CPU caps */
        goto skip_cpu_caps;
    }

    {
        /*
         * Gaming cool-clamp: the smart curve can declare up to ~3 GHz during the GAMING state,
         * but the vendor PowerHAL clamps the actual clock to ~2.2 GHz regardless — so the
         * higher request buys no FPS and only drives brief high-OPP voltage excursions (extra
         * heat + drain).
         * Cap the declared scaling_max at a sane gaming ceiling so we never ask higher than
         * the vendor will honour.
         */
        int cmax[3];
        for (int _k = 0; _k < 3; _k++) {
            cmax[_k] = caps->cpu_max[_k];
            if (state == ASB_STATE_GAMING && g_asb_cfg.gaming_cpu_max_ceiling_khz > 0
                && cmax[_k] > g_asb_cfg.gaming_cpu_max_ceiling_khz) {
                cmax[_k] = g_asb_cfg.gaming_cpu_max_ceiling_khz;
            }
        }
        /* Snap BEFORE anything is compared or written.
         *
         * The snap used to happen further down, inside the per-path loop, so the
         * msm_performance path below wrote the raw computed value: a full day of logs shows
         * every single cap landing off-table - 1925001, 2283401, 2128230. cpufreq rounds a
         * request UP to the next real step, so each of those caps came out weaker than the
         * one the governor decided on, by as much as 155 MHz. That is why the phone sat at
         * 82 degC through a 297-minute session while the log insisted it was capping.
         *
         * Snapping here also makes the cache honest: it stores the value the kernel will
         * actually hold, so the next tick compares like with like instead of seeing a
         * change that never happened. */
        for (int _s = 0; _s < 3; _s++) {
            if (cmax[_s] <= 0 || !g_cpu_max_paths[_s][0]) continue;
            int _si = -1;
            for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++) {
                if (g_cpu_all_max_paths[k][0] &&
                    strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[_s]) == 0) { _si = k; break; }
            }
            if (_si >= 0) cmax[_s] = (int)cpu_snap_freq(_si, (long)cmax[_s]);
        }

        int c0_target = -1, c1_target = -1;
        int c0_changed = 0, c1_changed = 0;
        if (g_cpu_max_paths[0][0] && (force || cmax[0] != g_wcache.cpu_max[0])) {
            c0_target = cmax[0]; c0_changed = 1;
        }
        if (g_cpu_max_paths[1][0] && (force || cmax[1] != g_wcache.cpu_max[1])) {
            c1_target = cmax[1]; c1_changed = 1;
        }
        if (c0_changed || c1_changed) {
            int use_msm = msm_perf_check() &&
                          (!g_asb_cfg.msm_perf_boost_only ||
                           ((state == ASB_STATE_HEAVY || state == ASB_STATE_GAMING) && !thermal_cap));
            if (use_msm) {
                int msm_c0 = (c0_target > 0) ? c0_target : g_msm_cur_max[0];
                int msm_c1 = (c1_target > 0) ? c1_target : g_msm_cur_max[1];
                msm_perf_write_all_max(msm_c0, msm_c1);
            }
        }
        for (int i = 0; i < 3; i++) {
            if (!g_cpu_max_paths[i][0]) continue;
            /* Snap to this cluster's own table before comparing against the cache: caching
             * the unsnapped value would make every tick look like a change, and the log
             * would show a write that the kernel then silently altered. */
            if (cmax[i] > 0) {
                int _snap_idx = -1;
                for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++) {
                    if (g_cpu_all_max_paths[k][0] &&
                        strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[i]) == 0) {
                        _snap_idx = k; break;
                    }
                }
                if (_snap_idx >= 0) {
                    cmax[i] = (int)cpu_snap_freq(_snap_idx, (long)cmax[i]);
                    cmax[i] = cpu_floor_ceiling(_snap_idx, cmax[i], thermal_cap);
                }
            }
            /* Reassert only when the live ceiling was raised above ASB's requested
             * bound. A lower vendor ceiling is already energy-safe and is accepted by
             * writer_write_int_confirmed() as cooperative ownership rather than conflict. */
            int live_max = sysfs_read_int(g_cpu_max_paths[i], 0);
            if (force || cmax[i] != g_wcache.cpu_max[i] ||
                (live_max > 0 && live_max > cmax[i])) {
                if (cmax[i] <= 0) continue;
                if (writer_write_int_confirmed((asb_write_node_t)(ASB_WRITE_CPU_MAX0 + i),
                                               g_cpu_max_paths[i], cmax[i]) == 0) {
                    g_wcache.cpu_max[i] = cmax[i];
                    writes++;
                }
            }
        }
    }
    /*
     * EXTRA CLUSTERS: on SoCs with more physical clusters than logical slots (OP12 pineapple:
     * 4 policies vs 3 slots), apply each slot's max-cap to every physical cluster that belongs
     * to that slot but isn't one of the 3 representative paths above.
     * Without this, OP12's second big cluster (policy2 or policy5 — whichever wasn't picked as
     * the slot-1 rep) keeps the stock/pinned max and the phone stays sluggish in battery mode.
     */
    for (int j = 0; j < g_cpu_all_paths_n; j++) {
        if (!g_cpu_all_max_paths[j][0]) continue;
        int slot = g_cpu_all_paths_slot[j];
        if (slot < 0 || slot > 2) continue;
        /* skip the 3 representative paths — already handled above */
        if (g_cpu_max_paths[slot][0] &&
            strcmp(g_cpu_all_max_paths[j], g_cpu_max_paths[slot]) == 0) continue;
        int target = caps->cpu_max[slot];
        /* same gaming cool-clamp as the representative paths above */
        if (state == ASB_STATE_GAMING && g_asb_cfg.gaming_cpu_max_ceiling_khz > 0
            && target > g_asb_cfg.gaming_cpu_max_ceiling_khz) {
            target = g_asb_cfg.gaming_cpu_max_ceiling_khz;
        }
        if (target <= 0) continue;
        /* Snap to a step this cluster actually has, downwards. Writing an arbitrary number
         * lets the kernel round it up, which quietly loosens the cap. */
        target = (int)cpu_snap_freq(j, (long)target);
        /* Last gate before the value reaches the kernel. */
        target = cpu_floor_ceiling(j, target, thermal_cap);
        int cur = sysfs_read_int(g_cpu_all_max_paths[j], 0);
        if (force || cur != target) {
            if (sysfs_write_int(g_cpu_all_max_paths[j], target) == 0)
                writes++;
        }
    }
    /* The minimum is maintained even while a thermal cap is active.
     *
     * This whole block used to be skipped when thermal_cap was set, on the reasoning that
     * the cap owns the frequencies. But skipping it leaves the PREVIOUS minimum in place -
     * so when the cap drops the maximum, the module is left asking for a floor above its
     * own ceiling. A field capture shows exactly that: min_written=17 against max_written=9
     * throughout SUSTAINED, with min_overridden=1 on every sample and 66 recorded
     * "vendor overrides" that were nothing of the kind - the kernel clamping an impossible
     * request, and the module logging its own contradiction as somebody else's doing.
     *
     * Two costs. The audit becomes noise, hiding the real overrides among the phantom
     * ones. And a floor left high during thermal throttling is a floor asking the phone to
     * stay fast in the one state whose entire job is to cool it down.
     */
    {
        for (int i = 0; i < 3; i++) {
            if (!g_cpu_min_paths[i][0]) continue;
            int want_min = caps->cpu_min[i];
            if (want_min <= 0) continue;
            /* Clamp against what WE are asking for, and against what is actually there.
             *
             * Reading only the current sysfs value has two holes. If the min is written
             * before the max in the same pass, the value read is last tick's. And if the
             * vendor has just clamped the max down, the min gets pinned to the vendor's
             * number rather than to ours - so the module ends up requesting a floor it
             * never chose.
             *
             * A field capture after the first fix still shows min_written=17 against
             * max_written=14: better than 66 phantom overrides, but the contradiction is
             * still there. Taking the lower of the two removes it in both directions.
             */
            int cur_max = sysfs_read_int(g_cpu_max_paths[i], 0);
            int own_max = caps->cpu_max[i];
            int lim = 0;
            if (own_max > 0) lim = own_max;
            if (cur_max > 0 && (lim == 0 || cur_max < lim)) lim = cur_max;
            if (lim > 0 && want_min > lim)
                want_min = lim;
            /* Snap after clamping, so the floor is a step this cluster actually has -
             * otherwise the kernel rounds it up and undoes the clamp we just applied. */
            {
                int _mi = -1;
                for (int k = 0; k < g_cpu_all_paths_n && k < 16; k++) {
                    if (g_cpu_all_max_paths[k][0] &&
                        strcmp(g_cpu_all_max_paths[k], g_cpu_max_paths[i]) == 0) { _mi = k; break; }
                }
                if (_mi >= 0) {
                    /* In Smart, a profile-derived minimum is an energy regression whenever
                     * the state is not HEAVY/GAMING: the scheduler can still request a high
                     * OPP immediately, while a 6-core little policy otherwise stays pinned at
                     * its Balanced floor during feeds, video decode and sustained cooldown.
                     * Use each physical policy's real lowest OPP; manual profiles and
                     * HEAVY/GAMING keep their requested floors unchanged. */
                    if (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED) {
                        long smart_opp = cpu_lowest_opp(_mi);
                        if (smart_opp > 0) want_min = (int)smart_opp;
                    } else {
                        want_min = (int)cpu_snap_freq(_mi, (long)want_min);
                    }
                }
            }
            /* Compare against what is ON THE DEVICE, not against our own cache.
             *
             * The max path a few lines up reads sysfs and rewrites whenever reality has
             * drifted. The min path only checked the cache: if our wanted value had not
             * changed, no write happened - so a floor raised by the vendor stayed raised
             * indefinitely, because from the cache's point of view nothing was wrong.
             *
             * A field capture shows policy0 at min=1785600 against a profile floor of
             * 307200 and a governor ceiling of 1190400. Six cores pinned near 1.8 GHz with
             * the screen off is not a cap failing to hold - it is a floor nobody put back,
             * and it costs more than any ceiling can save.
             */
            int cur_min = sysfs_read_int(g_cpu_min_paths[i], 0);
            if (force || want_min != g_wcache.cpu_min[i] ||
                (cur_min > 0 && cur_min != want_min)) {
                if (writer_write_int_confirmed((asb_write_node_t)(ASB_WRITE_CPU_MIN0 + i),
                                               g_cpu_min_paths[i], want_min) == 0) {
                    g_wcache.cpu_min[i] = want_min;
                    writes++;
                }
            }
        }
        /* EXTRA CLUSTERS min-freq: same idea for the min cap. */
        for (int j = 0; j < g_cpu_all_paths_n; j++) {
            if (!g_cpu_all_min_paths[j][0]) continue;
            int slot = g_cpu_all_paths_slot[j];
            if (slot < 0 || slot > 2) continue;
            if (g_cpu_min_paths[slot][0] &&
                strcmp(g_cpu_all_min_paths[j], g_cpu_min_paths[slot]) == 0) continue;
            int want_min = caps->cpu_min[slot];
            if (want_min <= 0) continue;
            int cur_max = sysfs_read_int(g_cpu_all_max_paths[j], 0);
            if (cur_max > 0 && want_min > cur_max) want_min = cur_max;
            if (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED) {
                long smart_opp = cpu_lowest_opp(j);
                if (smart_opp > 0) want_min = (int)smart_opp;
            } else {
                want_min = (int)cpu_snap_freq(j, (long)want_min);
            }
            if (force || sysfs_read_int(g_cpu_all_min_paths[j], 0) != want_min) {
                if (sysfs_write_int(g_cpu_all_min_paths[j], want_min) == 0)
                    writes++;
            }
        }
    }

skip_cpu_caps: ;
    writer_discover_gpu_paths();
    long hw_max = writer_gpu_hw_max();
    long gmax = hw_max * caps->gpu_max_pct / 100;
    long gmin = hw_max * caps->gpu_min_pct / 100;

    int gpu_vendor_backoff = gpu_vendor_override_backoff_active();
    if (!gpu_vendor_backoff && (force || caps->gpu_max_pct != g_wcache.gpu_max_pct)) {
        int gpu_ok = 0;
        if (g_gpu_max_path[0]) {
            if (g_gpu_uses_pwrlevel) {
                /*
                 * Translate target Hz into pwrlevel index.
                 */
                int pl = gpu_hz_to_pwrlevel_max(gmax);
                gpu_ok = (sysfs_write_int(g_gpu_max_path, pl) == 0);
                if (gpu_ok) g_wcache.last_max_pwrlevel_written = pl;
            } else {
                gpu_ok = (sysfs_write_long(g_gpu_max_path, gmax) == 0);
            }
        }
        if (!gpu_ok) {
            /* Log once per transition — helps diagnose stale paths without flooding */
            FILE *ef = fopen("/dev/.asb/write_errors", "a");
            if (ef) {
                fprintf(ef, "FAIL gpu_max path=%s val=%ld mode=%s discovered=%d\n",
                        g_gpu_max_path[0] ? g_gpu_max_path : "(none)", gmax,
                        g_gpu_uses_pwrlevel ? "pwrlevel" : "hz",
                        g_gpu_paths_ready);
                fclose(ef);
            }
        }
        /* Cache the value only when the write actually landed.
         *
         * This recorded the request unconditionally, so a failed write - stale sysfs path
         * after a GPU driver reload, a permission change, a node that moved between ROM
         * versions - was remembered as done. The next tick then compared equal and skipped
         * the write, and the module never tried again: one line in write_errors and silence
         * for the rest of the boot, with the GPU running uncapped while the state file
         * cheerfully reported the cap.
         *
         * Same rule the CPU path already follows, and the same rule that cost us three
         * rounds of diagnosis elsewhere: never record an intention as an outcome.
         */
        if (gpu_ok) {
            g_wcache.gpu_max_pct = caps->gpu_max_pct;
            writes++;
        }
    }
    /* Same fix as the CPU floor: check the device, not only the cache.
     *
     * On Adreno a HIGHER pwrlevel index is a LOWER frequency, so writing 17 asks for the
     * slowest step. A capture shows min_written=17 with min_observed=9 in 43 of 60
     * samples: the vendor raises the GPU floor and ASB never puts it back, because from
     * the cache's point of view its own wanted value never changed.
     *
     * A GPU floor stuck three steps too high is a constant power draw for work nobody
     * asked for - and unlike a ceiling it applies when the phone is doing nothing.
     */
    int _gpu_min_drifted = 0;
    if (g_gpu_min_path[0]) {
        int _cur_gmin = sysfs_read_int(g_gpu_min_path, -1);
        if (_cur_gmin >= 0 && g_wcache.gpu_min_written >= 0 &&
            _cur_gmin != g_wcache.gpu_min_written)
            _gpu_min_drifted = 1;
    }
    if (!gpu_vendor_backoff && (force || caps->gpu_min_pct != g_wcache.gpu_min_pct || _gpu_min_drifted)) {
        int _gmin_ok = 0;
        if (g_gpu_min_path[0]) {
            if (g_gpu_uses_pwrlevel) {
                /* min_pwrlevel is the LOWEST-frequency level allowed; larger index = lower freq.
                 * For a min Hz target, find the largest index whose freq >= target. */
                int pl = gpu_hz_to_pwrlevel_min(gmin);
                if (sysfs_write_int(g_gpu_min_path, pl) == 0) {
                    _gmin_ok = 1;
                    g_wcache.gpu_min_written = pl;
                    g_wcache.last_min_pwrlevel_written = pl;
                }
            } else {
                _gmin_ok = (sysfs_write_long(g_gpu_min_path, gmin) == 0);
            }
        }
        /* Same rule as the maximum above: a request that did not land must not be
           cached as done, or the comparison next tick skips the retry. */
        if (_gmin_ok) {
            g_wcache.gpu_min_pct = caps->gpu_min_pct;
            writes++;
        }
    }

    if (force || caps->ravg_ticks != g_wcache.ravg_ticks) {
        if (writer_write_int_confirmed(ASB_WRITE_WALT_RAVG, WALT_RAVG_PATH,
                                       caps->ravg_ticks) == 0) {
            g_wcache.ravg_ticks = caps->ravg_ticks;
            writes++;
        }
    }
    if (force || caps->idle_enough != g_wcache.idle_enough) {
        if (writer_write_int_confirmed(ASB_WRITE_WALT_IDLE, WALT_IDLE_PATH,
                                       caps->idle_enough) == 0) {
            g_wcache.idle_enough = caps->idle_enough;
            writes++;
        }
    }

    /* While the camera guard holds these open, a cap change must not write them
     * back down -- otherwise the very next tick undoes the guard. */
    if (!g_cam_guard_on) {
        /* Compare against the device, not only against our own cache.
         *
         * Same asymmetry that was fixed for the frequency floors: the cache only knows
         * what WE last decided, so anything that moves these behind our back stays moved
         * until our wanted value happens to change.
         *
         * The boot path makes that permanent rather than transient. Since the legacy shell
         * convergence became opt-in, nothing writes the uclamp tiers at boot except this
         * writer - and if its first tick computes the same value it already has cached, no
         * write is issued at all. A capture shows the result: top-app uclamp.max=0.00 with
         * foreground, background and system-background all at "max" - every tier at ROM
         * stock, an hour after boot, with the governor running and reporting the profile
         * applied. The scheduler was forbidden from asking for performance for the app on
         * screen while background work had no ceiling at all.
         *
         * Reading four sysfs files per tick is cheap next to being wrong for an hour.
         */
        /* Record the request itself, before anything can skip or fail it.
         *
         * The first version of this read g_wcache, which is only updated on a SUCCESSFUL
         * write - so a tier that never got written reported 0, which is exactly the case
         * the field was added to explain. It has to be captured on the way in. */
        g_ucl_want_top = caps->uclamp_top_max;
        g_ucl_want_bg  = caps->uclamp_bg_max;

        int _ucl_top_now = sysfs_read_int(UCLAMP_TOP_MAX, -1);
        int _ucl_drift = (_ucl_top_now >= 0 && _ucl_top_now != g_wcache.uclamp_top_max);
        if (force || _ucl_drift || caps->uclamp_top_max != g_wcache.uclamp_top_max) {
            if (writer_write_int_confirmed(ASB_WRITE_UCL_TOP, UCLAMP_TOP_MAX,
                                           caps->uclamp_top_max) == 0) {
                g_wcache.uclamp_top_max = caps->uclamp_top_max;
                writes++;
            }
        }
        int _ucl_bg_now = sysfs_read_int(UCLAMP_BG_MAX, -1);
        int _ucl_bg_drift = (_ucl_bg_now >= 0 && _ucl_bg_now != g_wcache.uclamp_bg_max);
        if (force || _ucl_bg_drift || caps->uclamp_bg_max != g_wcache.uclamp_bg_max) {
            int bg_ok = writer_write_int_confirmed(ASB_WRITE_UCL_BG, UCLAMP_BG_MAX,
                                                    caps->uclamp_bg_max) == 0;
            int sybg_ok = writer_write_int_confirmed(ASB_WRITE_UCL_SYBG, UCLAMP_SYBG_MAX,
                                                      caps->uclamp_bg_max) == 0;
            if (bg_ok && sybg_ok) {
                g_wcache.uclamp_bg_max = caps->uclamp_bg_max;
                writes += 2;
            }
        }
    }

    return writes;
}

/*
 * --------------------------------------------------------------------------- Camera guard.
 * A 4K60 encode cannot meet its deadline on two little cores, whatever frequency they run at.
 */
static void writer_camera_guard_save(void) {
    FILE *f = fopen(CAM_GUARD_STATE, "w");
    if (!f) return;
    fprintf(f, "fg_cpus=%s\ntop_cpus=%s\nuc_top=%d\nuc_fg=%d\nuc_bg=%d\nswap=%d\n",
            g_cam_saved_fg_cpus[0]  ? g_cam_saved_fg_cpus  : "-",
            g_cam_saved_top_cpus[0] ? g_cam_saved_top_cpus : "-",
            g_cam_saved_uc_top, g_cam_saved_uc_fg,
            g_cam_saved_uc_bg, g_cam_saved_swappiness);
    fclose(f);
}

/*
 * The guard restores the values that were present when recording began. If the
 * user selected another profile while recording, those saved values are stale.
 * Re-apply the latest selected profile once after release instead of allowing
 * any writer to fight the camera while it is active. apply_profile.sh is run
 * asynchronously and only for a recognised profile token.
 */
static void writer_camera_guard_apply_current_profile(void) {
    static const char *cmd =
        "p=$(cat /data/adb/modules/AutoSystemBoost/current_profile 2>/dev/null); "
        "case \"$p\" in battery|balanced|performance|smart) "
        "sh /data/adb/modules/AutoSystemBoost/apply_profile.sh \"$p\" auto "
        ">/dev/null 2>&1 & ;; esac";
    int r = system(cmd);
    (void)r;
}

static void writer_camera_guard_recover(void) {
    FILE *f = fopen(CAM_GUARD_STATE, "r");
    if (!f) return;
    char line[128];
    char fg[64] = {0}, top[64] = {0};
    int uc_top = -1, uc_fg = -1, uc_bg = -1, swap = -1;
    while (fgets(line, sizeof(line), f)) {
        if      (!strncmp(line, "fg_cpus=", 8))  sscanf(line + 8,  "%63s", fg);
        else if (!strncmp(line, "top_cpus=", 9)) sscanf(line + 9,  "%63s", top);
        else if (!strncmp(line, "uc_top=", 7))   uc_top = atoi(line + 7);
        else if (!strncmp(line, "uc_fg=", 6))    uc_fg  = atoi(line + 6);
        else if (!strncmp(line, "uc_bg=", 6))    uc_bg  = atoi(line + 6);
        else if (!strncmp(line, "swap=", 5))     swap   = atoi(line + 5);
    }
    fclose(f);
    if (fg[0]  && strcmp(fg,  "-")) sysfs_write_str(CPUSET_FG_CPUS,  fg);
    if (top[0] && strcmp(top, "-")) sysfs_write_str(CPUSET_TOP_CPUS, top);
    if (uc_top >= 0) sysfs_write_int(UCLAMP_TOP_MAX, uc_top);
    if (uc_fg  >= 0) sysfs_write_int(UCLAMP_FG_MAX,  uc_fg);
    if (uc_bg  >= 0) { sysfs_write_int(UCLAMP_BG_MAX,   uc_bg);
                       sysfs_write_int(UCLAMP_SYBG_MAX, uc_bg); }
    if (swap   >= 0) sysfs_write_int(PATH_VM_SWAPPINESS, swap);
    unlink(CAM_GUARD_STATE);
    writer_camera_guard_apply_current_profile();
}

static void writer_camera_guard(int active) {
    /* Time-limit an active guard. A burst is a burst; past camera_hold_max_s this is a
     * session, and a session does not get to run with every ceiling removed. */
    if (active && g_cam_guard_on && !g_cam_guard_expired &&
        g_asb_cfg.camera_hold_max_s > 0 && g_cam_guard_since > 0 &&
        (time(NULL) - g_cam_guard_since) >= g_asb_cfg.camera_hold_max_s) {
        /* No asb_log here: this header is included before the logger is declared, and
         * pulling the declaration forward for one line would tangle the include order.
         * The state file already publishes camera_hold, so the transition is observable. */
        g_cam_guard_expired = 1;
        active = 0;   /* fall into the release branch below */
    }
    /* Stay released until the camera actually stops, or the next stream would immediately
     * re-raise it and the limit would mean nothing. */
    if (active && g_cam_guard_expired) return;
    if (!active) g_cam_guard_expired = 0;

    if (active && !g_cam_guard_on) {
        char present[64] = {0};
        if (sysfs_read_str(PATH_CPU_PRESENT, present, (int)sizeof(present)) > 0 && present[0]) {
            if (sysfs_read_str(CPUSET_FG_CPUS, g_cam_saved_fg_cpus,
                               (int)sizeof(g_cam_saved_fg_cpus)) <= 0)
                g_cam_saved_fg_cpus[0] = '\0';
            if (sysfs_read_str(CPUSET_TOP_CPUS, g_cam_saved_top_cpus,
                               (int)sizeof(g_cam_saved_top_cpus)) <= 0)
                g_cam_saved_top_cpus[0] = '\0';
            sysfs_write_str(CPUSET_FG_CPUS,  present);
            sysfs_write_str(CPUSET_TOP_CPUS, present);
        }
        g_cam_saved_uc_top = sysfs_read_int(UCLAMP_TOP_MAX, -1);
        g_cam_saved_uc_fg  = sysfs_read_int(UCLAMP_FG_MAX,  -1);
        g_cam_saved_uc_bg  = sysfs_read_int(UCLAMP_BG_MAX,  -1);
        sysfs_write_int(UCLAMP_TOP_MAX,  100);
        sysfs_write_int(UCLAMP_FG_MAX,   100);
        sysfs_write_int(UCLAMP_BG_MAX,   100);
        sysfs_write_int(UCLAMP_SYBG_MAX, 100);
        g_cam_saved_swappiness = sysfs_read_int(PATH_VM_SWAPPINESS, -1);
        if (g_cam_saved_swappiness > 10)
            sysfs_write_int(PATH_VM_SWAPPINESS, 10);
        g_wcache.uclamp_top_max = 100;
        g_wcache.uclamp_bg_max  = 100;
        g_cam_guard_on = 1;
        g_cam_guard_since = time(NULL);
        g_cam_guard_expired = 0;
        writer_camera_guard_save();
        return;
    }
    if (!active && g_cam_guard_on) {
        if (g_cam_saved_fg_cpus[0])  sysfs_write_str(CPUSET_FG_CPUS,  g_cam_saved_fg_cpus);
        if (g_cam_saved_top_cpus[0]) sysfs_write_str(CPUSET_TOP_CPUS, g_cam_saved_top_cpus);
        if (g_cam_saved_uc_top >= 0) {
            sysfs_write_int(UCLAMP_TOP_MAX, g_cam_saved_uc_top);
            g_wcache.uclamp_top_max = g_cam_saved_uc_top;
        }
        if (g_cam_saved_uc_fg >= 0)
            sysfs_write_int(UCLAMP_FG_MAX, g_cam_saved_uc_fg);
        if (g_cam_saved_uc_bg >= 0) {
            sysfs_write_int(UCLAMP_BG_MAX,   g_cam_saved_uc_bg);
            sysfs_write_int(UCLAMP_SYBG_MAX, g_cam_saved_uc_bg);
            g_wcache.uclamp_bg_max = g_cam_saved_uc_bg;
        }
        if (g_cam_saved_swappiness >= 0)
            sysfs_write_int(PATH_VM_SWAPPINESS, g_cam_saved_swappiness);
        unlink(CAM_GUARD_STATE);
        g_cam_guard_on = 0;
        writer_camera_guard_apply_current_profile();
    }
}

static void writer_init_cache(void) {
    writer_init_paths();
    /* A leftover state file means the previous governor died mid-session: undo
     * what it raised before doing anything else. */
    writer_camera_guard_recover();
    for (int i = 0; i < 3; i++) {
        if (!g_cpu_max_paths[i][0]) { g_wcache.cpu_max[i] = 0; continue; }
        g_wcache.cpu_max[i] = sysfs_read_int(g_cpu_max_paths[i], 0);
        g_wcache.cpu_min[i] = sysfs_read_int(g_cpu_min_paths[i], 0);
    }
    g_wcache.last_max_pwrlevel_written = -1;
    g_wcache.last_min_pwrlevel_written = -1;
    g_wcache.initialized = 1;
}
