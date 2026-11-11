// The child that `dev compare-input-latency` runs inside each terminal.
//
// usage: keyecho OUTPUT idle|flood
//
// Puts the terminal in raw mode and appends "ready <ns>", then "key <ns>" for
// every byte typed at it. In flood mode it writes text as fast as the terminal
// takes it between looks at its input. It ends on the byte `q` or after 60 s.
// Times are CLOCK_UPTIME_RAW nanoseconds, the clock the dev tool reads.
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static unsigned long long now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  int flood = strcmp(argv[2], "flood") == 0;
  int log = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (log < 0) return 3;
  struct termios saved, raw;
  if (tcgetattr(STDIN_FILENO, &saved) != 0) return 4;
  raw = saved;
  cfmakeraw(&raw);
  tcsetattr(STDIN_FILENO, TCSANOW, &raw);

  // One screenful of mixed text per write, like a build log with some Unicode.
  char block[4096];
  size_t size = 0;
  const char *line = "\033[36m| 004239 |\033[0m SELECT account_id, display_name FROM customers WHERE active; | \xe4\xb8\xad\xe6\x96\x87 |\r\n";
  while (size + strlen(line) <= sizeof block) { memcpy(block + size, line, strlen(line)); size += strlen(line); }

  dprintf(log, "ready %llu\n", now());
  unsigned long long end = now() + 60ull * 1000000000ull;
  struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
  int done = 0;
  while (!done && now() < end) {
    if (poll(&input, 1, flood ? 0 : 100) > 0) {
      char bytes[64];
      ssize_t count = read(STDIN_FILENO, bytes, sizeof bytes);
      unsigned long long at = now();
      if (count <= 0) break;
      for (ssize_t index = 0; index < count; index++) {
        if (bytes[index] == 'q') done = 1; else dprintf(log, "key %llu\n", at);
      }
    }
    if (flood && !done) (void)write(STDOUT_FILENO, block, size);
  }
  tcsetattr(STDIN_FILENO, TCSANOW, &saved);
  dprintf(log, "done %llu\n", now());
  return 0;
}
