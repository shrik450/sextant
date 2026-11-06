/*
 * The counters libprobe shares with psample through <prefix>.bin.
 *
 * Every field is written by the probed app and read by psample while the app runs, or after it
 * has died. Times are nanoseconds; *_start_ns fields are CLOCK_REALTIME, the rest durations.
 *   buckets            finished main-queue waits under 2, 4, 8.33, 16.7, 33.3, 50, 100, 250, 500,
 *                      1000 and 2000 ms, and at or over 2000 ms
 *   max_wait_ns        the longest wait, finished or still in flight
 *   inflight_ns        how long the current ping has waited so far, 0 once it has run
 *   inflight_start_ns  when the current ping was posted
 */
#ifndef PROBE_H
#define PROBE_H

#include <stdint.h>

#define PROBE_MAGIC 0x50524f4232ULL
#define PROBE_BUCKETS 12

struct probe_counters {
    uint64_t magic;
    _Atomic uint64_t mallocs;
    _Atomic uint64_t frees;
    _Atomic uint64_t malloc_bytes;
    _Atomic uint64_t pings;
    _Atomic uint64_t buckets[PROBE_BUCKETS];
    _Atomic uint64_t max_wait_ns;
    _Atomic uint64_t waited_over_frame_ns;
    _Atomic uint64_t updated_ns;
    _Atomic uint64_t inflight_ns;
    _Atomic uint64_t inflight_start_ns;
};

#endif
