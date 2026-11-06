#!/usr/bin/awk -f
#
# Prints what a run cost between two times, as "key=value" words on one line.
#
# Usage: awk -v lo=<unix ns> -v hi=<unix ns> -v run=<run folder> -f cost.awk <run>/samples.txt
#
# The window covers the psample ticks from the last one at or before lo to the first one at or
# after hi, so counters are never cut short. Keys:
#   wall_ms cpu_ms git_cpu_ms total_cpu_ms wakeups wk_per_s fp_start_mb fp_end_mb fp_peak_mb
#   fp_growth_mb fp_lifetime_peak_mb threads_peak read_mb gits gits_<subcommand>
# and, when the probe ran:
#   waits_gt8 waits_gt16 waits_gt50 waits_gt100   finished main-thread waits, from the histogram
#   stalls_gt16 stalls_gt50 max_stall_ms          from the stall log, plus a stall still in flight
#                                                 when the window ended or the app died
#   unrecovered_ms                                the stall the app died in, if it began in the window
# Stalls that overlap a pause listed in <run>/pauses.txt ("<start ns> <end ns>" per line, for
# times a tool such as heap suspended the app) are left out.

function subcommand(line,   n, f, i) {
    n = split(line, f, " ")
    for (i = 5; i <= n; i++) {
        if (f[i] == "-c" || f[i] == "-C") { i++; continue }
        if (substr(f[i], 1, 1) == "-") continue
        return f[i]
    }
    return "?"
}

function paused(start, end,   k) {
    for (k = 1; k <= npause; k++) if (start < P1[k] && end > P0[k]) return 1
    return 0
}

BEGIN {
    npause = 0
    while ((getline line < (run "/pauses.txt")) > 0) { split(line, f, " "); npause++; P0[npause] = f[1]; P1[npause] = f[2] }
}

/^# start_realtime_ns/ { rt0 = $3; next }
/^# probe-final/ { final_max = $3; final_inflight = $4; final_start = $5; next }
/^#/ { next }
NF >= 30 {
    n++
    for (i = 1; i <= NF; i++) V[n, i] = $i
}

END {
    if (n == 0) { print "samples=0"; exit }
    lo_t = (lo - rt0) / 1e6; hi_t = (hi - rt0) / 1e6
    a = 1; for (k = 1; k <= n; k++) if (V[k, 1] <= lo_t) a = k
    b = n; for (k = n; k >= 1; k--) if (V[k, 1] >= hi_t) b = k
    if (b < a) b = a
    peak = 0; thr = 0
    for (k = a; k <= b; k++) { if (V[k, 6] > peak) peak = V[k, 6]; if (V[k, 7] > thr) thr = V[k, 7] }
    cpu = (V[b, 2] + V[b, 3]) - (V[a, 2] + V[a, 3])
    gcpu = (V[b, 9] + V[b, 10]) - (V[a, 9] + V[a, 10])
    wk = (V[b, 4] - V[a, 4]) + (V[b, 5] - V[a, 5])
    wall = (hi - lo) / 1e6
    printf "wall_ms=%.0f cpu_ms=%.0f git_cpu_ms=%.0f total_cpu_ms=%.0f wakeups=%d wk_per_s=%.2f", wall, cpu, gcpu, cpu + gcpu, wk, (wall > 0 ? wk * 1000 / wall : 0)
    printf " fp_start_mb=%.0f fp_end_mb=%.0f fp_peak_mb=%.0f fp_growth_mb=%.0f fp_lifetime_peak_mb=%.0f threads_peak=%d read_mb=%.1f", V[a, 6], V[b, 6], peak, V[b, 6] - V[a, 6], V[b, 11], thr, V[b, 30] - V[a, 30]

    gits = 0
    while ((getline g < (run "/git.log")) > 0) {
        split(g, f, " ")
        if (f[1] >= lo && f[1] <= hi) { gits++; sc[subcommand(g)]++ }
    }
    printf " gits=%d", gits
    for (s in sc) printf " gits_%s=%d", s, sc[s]

    if (V[b, 12] != "-") {
        o8 = 0; o16 = 0; o50 = 0; o100 = 0
        for (i = 21; i <= 29; i++) o8 += V[b, i] - V[a, i]
        for (i = 22; i <= 29; i++) o16 += V[b, i] - V[a, i]
        for (i = 24; i <= 29; i++) o50 += V[b, i] - V[a, i]
        for (i = 25; i <= 29; i++) o100 += V[b, i] - V[a, i]
        mx = 0; s16 = 0; s50 = 0
        while ((getline s < (run "/probe.stalls")) > 0) {
            split(s, f, " ")
            st = f[1]; ms = f[2]
            if (st < lo || st > hi || paused(st, st + ms * 1e6)) continue
            if (ms > 16.7) s16++
            if (ms > 50) s50++
            if (ms > mx) mx = ms
        }
        un = 0
        if (final_inflight > 16.7 && final_start >= lo && final_start <= hi && !paused(final_start, final_start + final_inflight * 1e6)) {
            un = final_inflight
            s16++
            if (un > 50) s50++
            if (un > mx) mx = un
        }
        if (V[b, 17] > mx && !(npause > 0)) mx = V[b, 17]
        printf " waits_gt8=%d waits_gt16=%d waits_gt50=%d waits_gt100=%d stalls_gt16=%d stalls_gt50=%d max_stall_ms=%.1f unrecovered_ms=%.0f", o8, o16, o50, o100, s16, s50, mx, un
    }
    printf "\n"
}
