/*
 * libprobe: measures a GUI app from the inside, loaded with DYLD_INSERT_LIBRARIES.
 *
 * Main-thread latency: a watchdog thread posts a block to the main queue, and while the block
 * waits to run, the watchdog itself publishes how long it has waited, every millisecond. So a
 * stall shows while it lasts, and still shows if the app is killed before the main thread comes
 * back. When the block runs, the wait is counted in a histogram and, over PROBE_LOG_MS, logged
 * one per line. The watchdog then sleeps PROBE_PING_MS and posts again. Each ping costs the app
 * one main-queue wake-up, so leave it off (PROBE_PING_MS=0) when measuring idle wake-ups.
 *
 * Allocations: with PROBE_MALLOC=1, libmalloc's logging hook counts every allocation and free
 * in every zone. The hook takes libmalloc's slower logging path, so don't time runs with it on.
 *
 * Environment (read once at load, then removed so child processes don't inherit the probe):
 *   PROBE_OUT      prefix of the output files: <prefix>.bin (struct counters, mmap'd and shared,
 *                  so it outlives the process) and <prefix>.stalls (one "<start ns> <ms>" line
 *                  per finished wait over PROBE_LOG_MS, start in CLOCK_REALTIME)
 *   PROBE_PING_MS  milliseconds between pings, 0 to turn the watchdog off (default 4)
 *   PROBE_LOG_MS   finished waits longer than this are logged (default 16)
 *   PROBE_MALLOC   1 to count allocations
 */
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "probe.h"

static const double bucket_ms[PROBE_BUCKETS - 1] = {2, 4, 8.33, 16.7, 33.3, 50, 100, 250, 500, 1000, 2000};

static struct probe_counters *c;
static int stall_fd = -1;
static double ping_ms = 4, log_ms = 16;
static mach_timebase_info_data_t tb;

static uint64_t now_ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }

static uint64_t wall_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

#define LOG_ALLOC 2
#define LOG_DEALLOC 4

static void count_malloc(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip) {
    (void)arg1; (void)result; (void)skip;
    if (type & LOG_ALLOC) {
        atomic_fetch_add_explicit(&c->mallocs, 1, memory_order_relaxed);
        uintptr_t size = (type & LOG_DEALLOC) ? arg3 : arg2;
        atomic_fetch_add_explicit(&c->malloc_bytes, size, memory_order_relaxed);
    }
    if ((type & LOG_DEALLOC) && !(type & LOG_ALLOC)) atomic_fetch_add_explicit(&c->frees, 1, memory_order_relaxed);
}

static _Atomic int pending;
static _Atomic uint64_t posted_at;

static void raise_max(uint64_t waited) {
    uint64_t m = atomic_load(&c->max_wait_ns);
    while (waited > m && !atomic_compare_exchange_weak(&c->max_wait_ns, &m, waited)) {}
}

static void pong(void *ctx) {
    (void)ctx;
    uint64_t waited = now_ns() - atomic_load(&posted_at);
    atomic_fetch_add(&c->pings, 1);
    double ms = waited / 1e6;
    int b = 0;
    while (b < PROBE_BUCKETS - 1 && ms >= bucket_ms[b]) b++;
    atomic_fetch_add(&c->buckets[b], 1);
    raise_max(waited);
    if (ms > 8.33) atomic_fetch_add(&c->waited_over_frame_ns, waited);
    if (ms > log_ms && stall_fd >= 0) {
        char line[96];
        int n = snprintf(line, sizeof line, "%llu %.1f\n", (unsigned long long)(wall_ns() - waited), ms);
        write(stall_fd, line, n);
    }
    atomic_store(&c->inflight_ns, 0);
    atomic_store(&c->updated_ns, wall_ns());
    atomic_store(&pending, 0);
}

static void *watchdog(void *arg) {
    (void)arg;
    pthread_setname_np("probe.watchdog");
    for (;;) {
        atomic_store(&pending, 1);
        uint64_t posted = now_ns();
        atomic_store(&posted_at, posted);
        atomic_store(&c->inflight_start_ns, wall_ns());
        dispatch_async_f(dispatch_get_main_queue(), NULL, pong);
        while (atomic_load(&pending)) {
            usleep(1000);
            if (!atomic_load(&pending)) break;
            uint64_t waited = now_ns() - posted;
            atomic_store(&c->inflight_ns, waited);
            if (!atomic_load(&pending)) atomic_store(&c->inflight_ns, 0);
            raise_max(waited);
        }
        usleep((useconds_t)(ping_ms * 1000));
    }
    return NULL;
}

__attribute__((constructor)) static void probe_init(void) {
    mach_timebase_info(&tb);
    const char *out = getenv("PROBE_OUT");
    const char *ping = getenv("PROBE_PING_MS");
    const char *logms = getenv("PROBE_LOG_MS");
    const char *mal = getenv("PROBE_MALLOC");
    if (ping) ping_ms = atof(ping);
    if (logms) log_ms = atof(logms);
    char path[1024];
    if (out) {
        snprintf(path, sizeof path, "%s.bin", out);
        int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0 && ftruncate(fd, sizeof(struct probe_counters)) == 0) {
            c = mmap(NULL, sizeof(struct probe_counters), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (c == MAP_FAILED) c = NULL;
        }
        snprintf(path, sizeof path, "%s.stalls", out);
        stall_fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_TRUNC, 0644);
    }
    if (!c) c = calloc(1, sizeof(struct probe_counters));
    c->magic = PROBE_MAGIC;
    if (mal && atoi(mal)) malloc_logger = count_malloc;
    if (ping_ms > 0) {
        pthread_t t;
        pthread_create(&t, NULL, watchdog, NULL);
        pthread_detach(t);
    }
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("PROBE_OUT");
    unsetenv("PROBE_PING_MS");
    unsetenv("PROBE_LOG_MS");
    unsetenv("PROBE_MALLOC");
}
