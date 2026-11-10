// Null terminal: read+discard PTY output, answer DSR. Measures the kernel PTY ceiling for terminal-bench.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
int main(int argc, char **argv) {
  if (argc < 3) return 2;
  size_t bufsize = (size_t)atol(argv[1]);
  struct winsize ws = {.ws_row = 30, .ws_col = 100, .ws_xpixel = 1700, .ws_ypixel = 1230};
  int master;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) return 1;
  if (pid == 0) { execv(argv[2], argv + 2); _exit(127); }
  unsigned char *buf = malloc(bufsize);
  unsigned tail = 0;
  for (;;) {
    ssize_t n = read(master, buf, bufsize);
    if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
    // DSR arrives as the final bytes of a write; scan only the last few bytes plus carry.
    ssize_t from = n > 8 ? n - 8 : 0;
    if (from > 0) tail = 0;
    for (ssize_t i = from; i < n; ++i) {
      tail = (tail << 8) | buf[i];
      if (tail == 0x1b5b366e) { const char r[] = "\033[1;1R"; (void)write(master, r, 6); }
    }
  }
  int status; waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
