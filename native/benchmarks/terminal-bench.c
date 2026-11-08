// A PTY write + ordered DSR drain benchmark. This does not measure presentation latency.
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios saved;
static bool raw;
static const char *report_path;
static bool completed;
static char failure_reason[512] = "Benchmark did not complete; inspect its launch log.";
static bool resource_available = true;
static int resource_error;
static mach_timebase_info_data_t cpu_timebase;
static bool cpu_timebase_attempted;
static bool cpu_timebase_available;
static volatile sig_atomic_t interrupted;
static const struct {
    const char *name;
    const char *pattern;
} workloads[] = {
    {"ascii_short_lines", "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n"},
    {"ascii_long_lines", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ "},
    {"ansi_truecolor", "\033[38;2;84;210;160mcolored\033[0m \033[48;2;18;35;70mbackground\033[0m\n"},
    {"unicode", "Unicode: 猫 é 👩🏽‍💻 🇳🇴 ∑─▁▂▃▄▅▆▇█\n"}
};
static double clock_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
static void restore(void) {
    if (raw) {
        // Stop generated output on the alternate screen; preserve the user's transcript.
        const char end[] = "\033[0m\033[?1049l";
        (void)write(STDOUT_FILENO, end, sizeof(end) - 1);
        tcsetattr(STDIN_FILENO, TCSANOW, &saved);
        raw = false;
    }
}
static void stop(int signo) { interrupted = signo; }
static void failure_marker(void) {
    if (!report_path || completed) return;
    char path[4096];
    if (snprintf(path, sizeof(path), "%s.failed", report_path) >= (int)sizeof(path)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd >= 0) {
        (void)write(fd, failure_reason, strlen(failure_reason));
        (void)write(fd, "\n", 1);
        close(fd);
    }
}
static void fail(const char *what) {
    int error = errno;
    snprintf(failure_reason, sizeof(failure_reason), "%s: %s", what, strerror(error));
    restore();
    fprintf(stderr, "terminal-bench: %s: %s\n", what, strerror(error));
    exit(1);
}
static void emit(const void *data, size_t count) {
    const unsigned char *p = data;
    while (count && !interrupted) {
        ssize_t n = write(STDOUT_FILENO, p, count);
        if (n > 0) { p += n; count -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else fail("write PTY");
    }
    if (interrupted) { errno = EINTR; fail("interrupted"); }
}
// Parse the exact CSI row;column R grammar, tolerating unrelated input.
static double barrier(void) {
    tcflush(STDIN_FILENO, TCIFLUSH);
    double started = clock_seconds();
    emit("\033[6n", 4);
    int state = 0;
    double deadline = started + 30;
    while (!interrupted && clock_seconds() < deadline) {
        struct pollfd fd = {.fd = STDIN_FILENO, .events = POLLIN};
        int result = poll(&fd, 1, 100);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (fd.revents & (POLLHUP | POLLERR))) fail("read DSR");
        if (!result) continue;
        unsigned char c;
        if (read(STDIN_FILENO, &c, 1) != 1) continue;
        if (c == 27) { state = 1; continue; }
        switch (state) {
        case 1: state = c == '[' ? 2 : 0; break;
        case 2: state = c >= '0' && c <= '9' ? 3 : 0; break;
        case 3: if (c == ';') state = 4; else if (c < '0' || c > '9') state = 0; break;
        case 4: state = c >= '0' && c <= '9' ? 5 : 0; break;
        case 5: if (c == 'R') return (clock_seconds() - started) * 1000;
                if (c < '0' || c > '9') state = 0;
                break;
        default: break;
        }
    }
    errno = interrupted ? EINTR : ETIMEDOUT;
    fail("ordered DSR drain");
    return 0;
}
static bool load_cpu_timebase(void) {
    if (cpu_timebase_attempted) return cpu_timebase_available;
    cpu_timebase_attempted = true;
    if (mach_timebase_info(&cpu_timebase) != KERN_SUCCESS || cpu_timebase.denom == 0) {
        resource_available = false;
        resource_error = EIO;
        return false;
    }
    cpu_timebase_available = true;
    return true;
}
static double cpu(pid_t pid, uint64_t *footprint) {
    if (!load_cpu_timebase()) {
        *footprint = 0;
        return 0;
    }
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        resource_available = false;
        resource_error = errno;
        *footprint = 0;
        return 0;
    }
    *footprint = usage.ri_phys_footprint;
    const long double ticks = (long double)usage.ri_user_time + (long double)usage.ri_system_time;
    return (double)(ticks * cpu_timebase.numer / cpu_timebase.denom / 1000000000.0L);
}
static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void distribution(FILE *out, double *values, size_t n) {
    qsort(values, n, sizeof(*values), compare);
    fprintf(out, "{\"samples\":%zu,\"p50\":%.6f,\"p95\":%.6f,\"p99\":%.6f,\"max\":%.6f}",
            n, values[(n-1)/2], values[(n-1)*95/100], values[(n-1)*99/100], values[n-1]);
}
static uint64_t number(const char *value) {
    char *end;
    errno = 0;
    unsigned long long n = strtoull(value, &end, 10);
    if (errno || *end || !*value || *value == '-' || n == 0) {
        fprintf(stderr, "terminal-bench: expected positive integer: %s\n", value);
        exit(2);
    }
    return n;
}
static void help(void) {
    puts("Usage: terminal-bench --output FILE --terminal NAME [--bytes N] [--runs N]\n"
         "                      [--columns N] [--rows N] [--idle-seconds N]\n"
         "                      [--workload ascii_short_lines|ascii_long_lines|ansi_truecolor|unicode]\n"
         "Run inside the terminal being measured. Defaults: 16 MiB/workload, 5 runs,\n"
         "100 columns, 30 rows, 3 idle seconds. Writes ANSI/Unicode to an alternate\n"
         "screen and saves JSON metadata, throughput, DSR RTT, CPU, and footprint.\n"
         "DSR drain measures parser completion, not GPU presentation or key latency.\n"
         "--help and --version do not require a terminal.");
}
int main(int argc, char **argv) {
    const char *output = NULL, *name = NULL, *selected_workload = NULL;
    uint64_t bytes = 16 * 1024 * 1024, runs = 5, columns = 100, rows = 30, idle = 3;
    static struct option options[] = {
        {"output", required_argument, NULL, 'o'}, {"terminal", required_argument, NULL, 't'},
        {"bytes", required_argument, NULL, 'b'}, {"runs", required_argument, NULL, 'r'},
        {"columns", required_argument, NULL, 'c'}, {"rows", required_argument, NULL, 'l'},
        {"idle-seconds", required_argument, NULL, 'i'}, {"help", no_argument, NULL, 'h'},
        {"workload", required_argument, NULL, 'w'},
        {"version", no_argument, NULL, 'v'}, {NULL, 0, NULL, 0}};
    int option;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        switch (option) {
        case 'o': output = optarg; break; case 't': name = optarg; break;
        case 'b': bytes = number(optarg); break; case 'r': runs = number(optarg); break;
        case 'c': columns = number(optarg); break; case 'l': rows = number(optarg); break;
        case 'i': idle = number(optarg); break;
        case 'w': selected_workload = optarg; break;
        case 'h': help(); return 0; case 'v': puts("terminal-bench 0.3.0"); return 0;
        default: return 2;
        }
    }
    if (!name || !output || optind != argc || runs > 100 || bytes > 1024ULL*1024*1024
        || columns > 4096 || rows > 4096 || idle > 60) { help(); return 2; }
    if (selected_workload) {
        bool found = false;
        for (size_t i = 0; i < sizeof(workloads) / sizeof(workloads[0]); ++i)
            if (strcmp(selected_workload, workloads[i].name) == 0) found = true;
        if (!found) {
            fprintf(stderr, "terminal-bench: unknown workload: %s\n", selected_workload);
            return 2;
        }
    }
    report_path = output;
    atexit(failure_marker);
    // Restrict label to safe JSON characters, avoiding arbitrary command/config interpolation.
    for (const char *p = name; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || strchr(" ._-", *p))) {
            fprintf(stderr, "terminal-bench: invalid terminal label\n"); return 2;
        }
    if (strlen(name) > 100 || !isatty(0) || !isatty(1)) {
        fprintf(stderr, "terminal-bench: requires a PTY and a label of at most 100 bytes\n"); return 2;
    }
    struct winsize size;
    // The host may publish its first backing-scale-aware resize just after spawn.
    for (int attempt = 0; attempt < 100; ++attempt) {
        if (ioctl(1, TIOCGWINSZ, &size) < 0) fail("PTY size");
        if (size.ws_col == columns && size.ws_row == rows) break;
        struct timespec settle = {.tv_sec = 0, .tv_nsec = 20000000};
        nanosleep(&settle, NULL);
    }
    if (size.ws_col != columns || size.ws_row != rows) {
        snprintf(failure_reason, sizeof(failure_reason), "geometry is %ux%u; expected %llux%llu",
                 size.ws_col, size.ws_row, columns, rows);
        fprintf(stderr, "terminal-bench: geometry is %ux%u; expected %llux%llu\n",
                size.ws_col, size.ws_row, columns, rows); return 2;
    }
    char temporary[4096];
    if (snprintf(temporary, sizeof(temporary), "%s.tmp.%d", output, getpid()) >= (int)sizeof(temporary)) {
        errno = ENAMETOOLONG; fail("report path");
    }
    int reportfd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (reportfd < 0) fail("create report");
    FILE *report = fdopen(reportfd, "w");
    if (!report) fail("open report stream");
    if (tcgetattr(0, &saved) < 0) fail("read termios");
    struct termios mode = saved;
    // Leave output processing identical to ordinary cat, disable echo and line buffering of replies.
    mode.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    mode.c_iflag &= (tcflag_t)~(IXON | ICRNL);
    mode.c_cc[VMIN] = 1; mode.c_cc[VTIME] = 0;
    if (tcsetattr(0, TCSANOW, &mode) < 0) fail("set termios");
    raw = true; atexit(restore);
    signal(SIGINT, stop); signal(SIGTERM, stop); signal(SIGHUP, stop);
    emit("\033[?1049h\033[2J\033[H", 15);
    barrier();
    pid_t terminal = getppid();
    uint64_t footprint = 0;
    double idle_cpu = cpu(terminal, &footprint), idle_start = clock_seconds();
    struct timespec delay = {.tv_sec = (time_t)idle, .tv_nsec = 0};
    while (nanosleep(&delay, &delay) && errno == EINTR && !interrupted) {}
    double idle_elapsed = clock_seconds() - idle_start;
    double idle_percent = (cpu(terminal, &footprint) - idle_cpu) / idle_elapsed * 100;
    fprintf(report, "{\"schema\":2,\"driver_version\":\"0.3.0\",\"terminal\":\"%s\",\"terminal_pid\":%d,"
            "\"columns\":%u,\"rows\":%u,\"pixel_width\":%u,\"pixel_height\":%u,"
            "\"output_post_processing\":%s,\"idle_seconds\":%.6f,", name, terminal,
            size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel,
            (mode.c_oflag & OPOST) ? "true" : "false", idle_elapsed);
    if (cpu_timebase_available)
        fprintf(report, "\"cpu_timebase\":{\"numer\":%u,\"denom\":%u},",
                cpu_timebase.numer, cpu_timebase.denom);
    else fputs("\"cpu_timebase\":null,", report);
    fprintf(report, "\"resource_usage_available\":%s,\"resource_usage_errno\":%d,",
            resource_available ? "true" : "false", resource_error);
    if (resource_available)
        fprintf(report, "\"idle_cpu_percent_one_core\":%.6f,\"idle_physical_bytes\":%llu,",
                idle_percent, (unsigned long long)footprint);
    else fputs("\"idle_cpu_percent_one_core\":null,\"idle_physical_bytes\":null,", report);
    fputs("\"workloads\":[", report);
    unsigned char block[32768];
    bool first_workload = true;
    for (size_t workload = 0; workload < sizeof(workloads) / sizeof(workloads[0]); ++workload) {
        if (selected_workload && strcmp(selected_workload, workloads[workload].name) != 0) continue;
        const char *pattern = workloads[workload].pattern;
        size_t length = strlen(pattern), used = 0;
        while (used + length <= sizeof(block)) {
            memcpy(block + used, pattern, length); used += length;
        }
        double rates[100], cpu_values[100], elapsed_values[100];
        uint64_t max_footprint = 0;
        for (size_t run = 0; run < runs; ++run) {
            emit("\033[0m\033[2J\033[H", 11); barrier();
            double start_cpu = cpu(terminal, &footprint), start = clock_seconds();
            uint64_t left = bytes;
            while (left) {
                size_t amount = left < used ? (size_t)left : used;
                emit(block, amount); left -= amount;
            }
            // End a potentially partial UTF-8/CSI run, then await its ordered response.
            emit("\030\033[0m", 5); barrier();
            double elapsed = clock_seconds() - start;
            cpu_values[run] = cpu(terminal, &footprint) - start_cpu;
            elapsed_values[run] = elapsed;
            rates[run] = (double)bytes / 1048576 / elapsed;
            if (footprint > max_footprint) max_footprint = footprint;
        }
        fprintf(report, "%s{\"name\":\"%s\",\"source_bytes_per_run\":%llu,\"mib_per_second\":",
                first_workload ? "" : ",", workloads[workload].name, (unsigned long long)bytes);
        first_workload = false;
        distribution(report, rates, (size_t)runs);
        fputs(",\"elapsed_seconds\":", report); distribution(report, elapsed_values, (size_t)runs);
        fputs(",\"terminal_cpu_seconds\":", report);
        if (resource_available) distribution(report, cpu_values, (size_t)runs);
        else fputs("null", report);
        if (resource_available)
            fprintf(report, ",\"max_run_end_physical_bytes\":%llu}", (unsigned long long)max_footprint);
        else fputs(",\"max_run_end_physical_bytes\":null}", report);
    }
    double rtt[100];
    for (size_t i = 0; i < 100; ++i) rtt[i] = barrier();
    fputs("],\"dsr_roundtrip_ms\":", report); distribution(report, rtt, 100);
    fputs(",\"note\":\"Same PTY payloads and ordered DSR drain; alternate screen excludes scrollback. "
          "CPU and footprint are terminal parent process only. Footprint is sampled at run ends, not peak. "
          "This measures parsing/backpressure, not display FPS or input-to-photon latency.\"}\n", report);
    if (fflush(report) || fsync(reportfd) || fclose(report)) fail("flush report");
    if (rename(temporary, output)) fail("publish report");
    completed = true;
    restore();
    return 0;
}
