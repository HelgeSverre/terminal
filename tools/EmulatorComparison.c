// Shared, headless C-ABI benchmark for frozen Rust and Swift terminal cores.
//
// This links against exactly one implementation at a time. It does not start
// the native app, create a PTY, or touch the renderer. The timed interval is:
// feed + reply drain + pending-work drain + finish + reply drain + invariant
// validation + ABI JSON snapshot creation/copy/free. Setup and file I/O are
// deliberately outside that interval.

#include "Bridge.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

enum { columns = 160, rows = 50, default_bytes = 32 * 1024 * 1024 };

typedef struct { uint64_t bytes; uint64_t hash; } Drain;

static void drain_reply(void *context, const uint8_t *bytes, size_t count) {
  Drain *drain = context;
  for (size_t index = 0; index < count; index++) {
    drain->hash ^= bytes[index];
    drain->hash *= UINT64_C(1099511628211);
  }
  drain->bytes += count;
}

static uint64_t fnv1a(const uint8_t *bytes, size_t count) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (size_t index = 0; index < count; index++) {
    hash ^= bytes[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static uint64_t monotonic_ns(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) { perror("clock_gettime"); exit(70); }
  return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static void usage(const char *program) {
  fprintf(stderr, "usage: %s --workload ascii|mixed --bytes N --snapshot PATH\n"
      "  Geometry is fixed at 160 columns x 50 rows; history is fixed at zero.\n", program);
}

static int parse_bytes(const char *text, size_t *result) {
  char *end = NULL;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value == 0 || value > SIZE_MAX) return 0;
  *result = (size_t)value;
  return 1;
}

static uint8_t *make_corpus(const char *workload, size_t requested, size_t *actual) {
  // Every unit ends at a parser boundary. The final state is therefore
  // deterministic for every valid corpus size while each replay includes ANSI,
  // replies, combining marks, CJK and multi-scalar emoji.
  static const uint8_t ascii[] =
      "plain ASCII: 0123456789 the quick brown fox "
      "\033[31mred\033[0m \033[4munderlined\033[0m \033[6n\r\n";
  static const uint8_t mixed[] =
      "e\314\201  \347\214\253 \346\227\245\346\234\254\350\252\236 "
      "\360\237\221\251\360\237\217\275\342\200\215\360\237\222\273 "
      "\360\237\207\263\360\237\207\264 \033[38;2;18;52;86mcolour\033[0m "
      "\033]2;swift-rust-comparison\007\033[6n\r\n";
  const uint8_t *unit = NULL;
  size_t unit_size = 0;
  if (strcmp(workload, "ascii") == 0) { unit = ascii; unit_size = sizeof(ascii) - 1; }
  else if (strcmp(workload, "mixed") == 0) { unit = mixed; unit_size = sizeof(mixed) - 1; }
  else return NULL;
  if (requested > SIZE_MAX - unit_size) return NULL;
  const size_t repeats = (requested + unit_size - 1) / unit_size;
  if (repeats > SIZE_MAX / unit_size) return NULL;
  *actual = repeats * unit_size;
  uint8_t *corpus = malloc(*actual);
  if (corpus == NULL) return NULL;
  for (size_t index = 0; index < repeats; index++) memcpy(corpus + index * unit_size, unit, unit_size);
  return corpus;
}

static int write_snapshot(const char *path, const uint8_t *snapshot, size_t snapshot_size) {
  FILE *output = fopen(path, "wb");
  if (output == NULL) return 0;
  const int wrote = fwrite(snapshot, 1, snapshot_size, output) == snapshot_size;
  const int closed = fclose(output) == 0;
  return wrote && closed;
}

int main(int argc, char **argv) {
  const char *workload = NULL;
  const char *snapshot_path = NULL;
  size_t requested = default_bytes;
  for (int index = 1; index < argc; index++) {
    if (strcmp(argv[index], "--workload") == 0 && index + 1 < argc) workload = argv[++index];
    else if (strcmp(argv[index], "--bytes") == 0 && index + 1 < argc && parse_bytes(argv[++index], &requested)) {}
    else if (strcmp(argv[index], "--snapshot") == 0 && index + 1 < argc) snapshot_path = argv[++index];
    else { usage(argv[0]); return 64; }
  }
  if (workload == NULL || snapshot_path == NULL || terminal_abi_version() != 1) { usage(argv[0]); return 64; }

  size_t payload_size = 0;
  uint8_t *payload = make_corpus(workload, requested, &payload_size);
  if (payload == NULL) { fprintf(stderr, "unable to allocate a valid %s corpus\n", workload); return 70; }
  const uint64_t payload_hash = fnv1a(payload, payload_size);
  Terminal *terminal = terminal_create(columns, rows);
  if (terminal == NULL) { fprintf(stderr, "terminal_create failed\n"); free(payload); return 70; }
  terminal_set_history_limit(terminal, 0);
  Drain drain = { .bytes = 0, .hash = UINT64_C(1469598103934665603) };
  uint8_t *snapshot_copy = NULL;
  size_t snapshot_size = 0;
  int failed = 0;

  const uint64_t start = monotonic_ns();
  size_t offset = 0;
  while (offset < payload_size || terminal_has_work(terminal)) {
    const size_t consumed = terminal_feed(terminal, payload + offset, payload_size - offset, 0);
    terminal_replies(terminal, &drain, drain_reply);
    if (consumed == 0 && offset < payload_size && !terminal_has_work(terminal)) {
      fprintf(stderr, "terminal_feed made no progress\n"); failed = 1; break;
    }
    offset += consumed;
  }
  terminal_finish(terminal);
  terminal_replies(terminal, &drain, drain_reply);
  if (!failed && !terminal_validate(terminal)) { fprintf(stderr, "terminal_validate failed\n"); failed = 1; }
  char *snapshot = failed ? NULL : terminal_snapshot(terminal, 0, 0);
  if (snapshot == NULL && !failed) { fprintf(stderr, "terminal_snapshot failed\n"); failed = 1; }
  if (!failed) {
    snapshot_size = strlen(snapshot);
    snapshot_copy = malloc(snapshot_size);
    if (snapshot_copy == NULL) { fprintf(stderr, "unable to copy final snapshot\n"); failed = 1; }
    else memcpy(snapshot_copy, snapshot, snapshot_size);
    terminal_string_free(snapshot);
  }
  const uint64_t elapsed = monotonic_ns() - start;
  struct rusage resource_usage;
  const long max_rss_bytes = getrusage(RUSAGE_SELF, &resource_usage) == 0
      ? resource_usage.ru_maxrss : -1;

  terminal_destroy(terminal);
  free(payload);
  if (failed) { free(snapshot_copy); return 70; }
  if (!write_snapshot(snapshot_path, snapshot_copy, snapshot_size)) {
    fprintf(stderr, "unable to write snapshot %s: %s\n", snapshot_path, strerror(errno));
    free(snapshot_copy); return 74;
  }
  printf("{\"protocol\":1,\"workload\":\"%s\",\"columns\":160,\"rows\":50,\"history_rows\":0,\"requested_bytes\":%zu,\"payload_bytes\":%zu,\"payload_fnv1a64\":\"%016" PRIx64 "\",\"elapsed_ns\":%" PRIu64 ",\"reply_bytes\":%" PRIu64 ",\"reply_fnv1a64\":\"%016" PRIx64 "\",\"snapshot_bytes\":%zu,\"snapshot_fnv1a64\":\"%016" PRIx64 "\",\"rusage_max_rss_bytes\":%ld}\n",
      workload, requested, payload_size, payload_hash, elapsed, drain.bytes, drain.hash, snapshot_size,
      fnv1a(snapshot_copy, snapshot_size), max_rss_bytes);
  free(snapshot_copy);
  return 0;
}
