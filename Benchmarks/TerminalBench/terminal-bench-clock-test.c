#define main terminal_bench_driver_main
#include "terminal-bench.c"
#undef main

#include <mach/mach_time.h>

static double process_cpu_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) {
        perror("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)");
        exit(1);
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

int main(void) {
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        fputs("mach_timebase_info unavailable\n", stderr);
        return 1;
    }
    uint64_t footprint = 0;
    const double cpu_before = cpu(getpid(), &footprint);
    const double clock_before = process_cpu_seconds();
    volatile uint64_t accumulator = 0;
    while (process_cpu_seconds() - clock_before < 0.15) {
        accumulator = accumulator * 1664525U + 1013904223U;
    }
    const double cpu_elapsed = cpu(getpid(), &footprint) - cpu_before;
    const double clock_elapsed = process_cpu_seconds() - clock_before;
    if (accumulator == 0 || !resource_available || cpu_elapsed < clock_elapsed * 0.5
        || cpu_elapsed > clock_elapsed * 1.5) {
        fprintf(stderr, "cpu clock mismatch: benchmark=%.9f clock=%.9f timebase=%u/%u\n",
                cpu_elapsed, clock_elapsed, timebase.numer, timebase.denom);
        return 1;
    }
    return 0;
}
