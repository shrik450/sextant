/*
 * psample: samples a process's resource use over time, with what libprobe and the app's
 * automation log report, until the process exits.
 *
 * Usage: psample <pid> <interval-ms> [automation-log] [probe-prefix]
 *
 * Prints one line per tick to stdout, 31 fields:
 *    1 t_ms                 milliseconds since the sampler started
 *    2 cpu_user_ms          the process's own CPU
 *    3 cpu_sys_ms
 *    4 idle_wakeups         package idle exits
 *    5 interrupt_wakeups
 *    6 footprint_mb         physical footprint now
 *    7 threads
 *    8 live_children
 *    9 child_user_ms        reaped children plus the children still running, so a long-lived
 *   10 child_sys_ms         helper such as cat-file --batch counts as it works
 *   11 peak_footprint_mb    the process's lifetime peak, from the kernel
 *   12 mallocs              then libprobe's counters, or "-" when there is no probe
 *   13 malloc_mb
 *   14 pings
 *   15 max_wait_ms          the longest main-thread wait so far, including one still in flight
 *   16 over_frame_ms
 *   17 inflight_ms          how long the main thread has been stuck so far, 0 if it isn't
 *   18-29                   main-thread wait buckets: <2, <4, <8.3, <16.7, <33, <50, <100, <250,
 *                           <500, <1000, <2000, >=2000 ms
 *   30 bytes_read_mb        the process's disk reads
 *   31 raised_window        1 if a window of it is above the normal level, over every app
 * and, for each new automation log line, "# <t_ms> <line>". After the process exits, it prints
 * "# probe-final <max_wait_ms> <inflight_ms> <inflight_start_ns>" from the probe's shared file,
 * which records a stall the app died in.
 *
 * Counters are cumulative since the process started; subtract two lines to get what happened
 * between them.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include "probe.h"

static mach_timebase_info_data_t tb;
static double abs_to_ms(uint64_t t) { return (double)t * tb.numer / tb.denom / 1e6; }

static uint64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static struct probe_counters *map_probe(const char *prefix) {
    char p[1024];
    snprintf(p, sizeof p, "%s.bin", prefix);
    int fd = open(p, O_RDONLY);
    if (fd < 0) return NULL;
    void *m = mmap(NULL, sizeof(struct probe_counters), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return m == MAP_FAILED ? NULL : m;
}

/*
 * Says whether a process has a window on screen above the normal level, such as a floating
 * panel, which covers every app's windows whether or not the process is active.
 */
static int raised_window(pid_t pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 0;
    int raised = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && !raised; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        int owner = 0, layer = 0;
        CFNumberRef n = CFDictionaryGetValue(w, kCGWindowOwnerPID);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &owner);
        n = CFDictionaryGetValue(w, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &layer);
        raised = owner == pid && layer > 0 && layer < 20;
    }
    CFRelease(list);
    return raised;
}

static void copy_log(FILE *log, double t) {
    static char buf[65536];
    clearerr(log);
    while (fgets(buf, sizeof buf, log)) {
        size_t n = strlen(buf);
        if (n && buf[n - 1] == '\n') buf[n - 1] = 0;
        printf("# %.0f %s\n", t, buf);
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: psample <pid> <interval-ms> [automation-log] [probe-prefix]\n");
        return 2;
    }
    mach_timebase_info(&tb);
    pid_t pid = atoi(argv[1]);
    int interval = atoi(argv[2]);
    const char *logpath = argc > 3 && argv[3][0] ? argv[3] : NULL;
    const char *probe = argc > 4 && argv[4][0] ? argv[4] : NULL;
    struct probe_counters *c = NULL;
    FILE *log = NULL;
    uint64_t start = mono_ns();
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct timespec rt;
    clock_gettime(CLOCK_REALTIME, &rt);
    printf("# start_realtime_ns %lld\n", (long long)rt.tv_sec * 1000000000LL + rt.tv_nsec);
    for (;;) {
        struct rusage_info_v6 ri;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) break;
        struct proc_taskinfo ti;
        int threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == sizeof ti ? ti.pti_threadnum : -1;
        pid_t kids[512];
        int nkids = proc_listchildpids(pid, kids, sizeof kids);
        uint64_t live_user = 0, live_sys = 0;
        for (int k = 0; k < nkids && k < 512; k++) {
            struct rusage_info_v2 kr;
            if (proc_pid_rusage(kids[k], RUSAGE_INFO_V2, (rusage_info_t *)&kr) == 0) {
                live_user += kr.ri_user_time + kr.ri_child_user_time;
                live_sys += kr.ri_system_time + kr.ri_child_system_time;
            }
        }
        if (probe && !c) c = map_probe(probe);
        if (logpath && !log) log = fopen(logpath, "r");
        double t = (mono_ns() - start) / 1e6;
        if (log) copy_log(log, t);
        printf("%.0f %.1f %.1f %llu %llu %.1f %d %d %.1f %.1f %.1f", t, abs_to_ms(ri.ri_user_time), abs_to_ms(ri.ri_system_time),
               (unsigned long long)ri.ri_pkg_idle_wkups, (unsigned long long)ri.ri_interrupt_wkups, ri.ri_phys_footprint / 1048576.0,
               threads, nkids < 0 ? -1 : nkids, abs_to_ms(ri.ri_child_user_time + live_user), abs_to_ms(ri.ri_child_system_time + live_sys),
               ri.ri_lifetime_max_phys_footprint / 1048576.0);
        if (c && c->magic == PROBE_MAGIC) {
            printf(" %llu %.1f %llu %.1f %.1f %.1f", (unsigned long long)c->mallocs, c->malloc_bytes / 1048576.0, (unsigned long long)c->pings,
                   c->max_wait_ns / 1e6, c->waited_over_frame_ns / 1e6, c->inflight_ns / 1e6);
            for (int b = 0; b < PROBE_BUCKETS; b++) printf(" %llu", (unsigned long long)c->buckets[b]);
        } else {
            for (int f = 12; f <= 29; f++) printf(" -");
        }
        printf(" %.1f %d\n", ri.ri_diskio_bytesread / 1048576.0, raised_window(pid));
        usleep(interval * 1000);
    }
    if (log) copy_log(log, (mono_ns() - start) / 1e6);
    if (probe && !c) c = map_probe(probe);
    if (c && c->magic == PROBE_MAGIC) {
        printf("# probe-final %.1f %.1f %llu\n", c->max_wait_ns / 1e6, c->inflight_ns / 1e6, (unsigned long long)c->inflight_start_ns);
    }
    printf("# exited\n");
    return 0;
}
