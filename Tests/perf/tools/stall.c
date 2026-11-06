/*
 * stall: blocks its main queue on a schedule, for checking that libprobe sees main-thread
 * stalls, including one the process is killed in.
 *
 * Usage: stall <ms>...
 *
 * After 200 ms, and between stalls, it sleeps on the main queue for each duration in turn,
 * writing "stall <ms>" to stdout as each one starts, then exits. Kill it during the last stall
 * to check the in-flight report.
 */
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int count;
static char **durations;
static int next;

static void step(void *ctx) {
    (void)ctx;
    if (next == count) exit(0);
    int ms = atoi(durations[next++]);
    printf("stall %d\n", ms);
    fflush(stdout);
    usleep((useconds_t)ms * 1000);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL, step);
}

int main(int argc, char **argv) {
    count = argc - 1;
    durations = argv + 1;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL, step);
    dispatch_main();
}
