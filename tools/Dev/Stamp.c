// The child that `dev compare-startup` runs inside each terminal.
//
// usage: stamp OUTPUT
//
// Appends "exec <ns>" as soon as it runs, asks the terminal for a cursor
// report, appends "reply <ns>" when the answer arrives and "done <ns>" last,
// then lingers briefly so the window can be observed. Times are
// CLOCK_UPTIME_RAW nanoseconds, the clock the dev tool reads. It is C so that
// its own startup adds nothing measurable.
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static void record(const char *path, const char *label, unsigned long long ns) {
  char line[64];
  int length = snprintf(line, sizeof line, "%s %llu\n", label, ns);
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) return;
  (void)write(fd, line, (size_t)length);
  close(fd);
}

int main(int argc, char **argv) {
  unsigned long long started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (argc != 2) return 2;
  record(argv[1], "exec", started);
  struct termios saved, raw;
  int tty = tcgetattr(STDIN_FILENO, &saved) == 0;
  if (tty) {
    raw = saved;
    cfmakeraw(&raw);
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    (void)write(STDOUT_FILENO, "\033[6n", 4);
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
    char reply[32];
    size_t length = 0;
    while (length < sizeof reply - 1 && poll(&input, 1, 5000) > 0) {
      ssize_t count = read(STDIN_FILENO, reply + length, sizeof reply - 1 - length);
      if (count <= 0) break;
      length += (size_t)count;
      if (memchr(reply, 'R', length)) {
        record(argv[1], "reply", clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        break;
      }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &saved);
  }
  record(argv[1], "done", clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
  usleep(400000);
  return 0;
}
