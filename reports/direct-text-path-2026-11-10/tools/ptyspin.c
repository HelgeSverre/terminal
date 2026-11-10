// Null terminal with a nonblocking reader that spins briefly before sleeping in poll().
// usage: ptyspin <bufsize> <spin_ns> <work_ns_per_kib> driver args...
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
int main(int argc, char **argv) {
  if (argc < 5) return 2;
  size_t bufsize = (size_t)atol(argv[1]);
  uint64_t spin = (uint64_t)atoll(argv[2]), work = (uint64_t)atoll(argv[3]);
  struct winsize ws = {.ws_row = 30, .ws_col = 100, .ws_xpixel = 1700, .ws_ypixel = 1230};
  int master;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) return 1;
  if (pid == 0) { execv(argv[4], argv + 4); _exit(127); }
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
  if (getenv("PTY_KQUEUE")) {
    // Attach a level-triggered read knote that nobody services, as a dispatch source would.
    int kq = kqueue(); struct kevent ev; int flags = EV_ADD | (atoi(getenv("PTY_KQUEUE")) == 2 ? EV_CLEAR : 0);
    EV_SET(&ev, master, EVFILT_READ, flags, 0, 0, NULL); kevent(kq, &ev, 1, NULL, 0, NULL);
  }
  unsigned char *buf = malloc(bufsize);
  unsigned tail = 0;
  unsigned long long reads = 0, bytes = 0, sleeps = 0;
  volatile unsigned long long sink = 0;
  for (;;) {
    ssize_t n = read(master, buf, bufsize);
    if (n > 0) {
      reads++; bytes += (unsigned long long)n;
      for (ssize_t i = 0; i < n; ++i) { tail = (tail << 8) | buf[i]; if (tail == 0x1b5b366e) { const char r[] = "\033[1;1R"; (void)write(master, r, 6); } }
      if (work) { uint64_t until = now_ns() + work * (uint64_t)n / 1024; while (now_ns() < until) sink++; }
      continue;
    }
    if (n == 0 || (errno != EAGAIN && errno != EINTR)) break;
    uint64_t until = now_ns() + spin; int got = 0;
    while (spin && now_ns() < until) {
      struct pollfd p = {.fd = master, .events = POLLIN};
      if (poll(&p, 1, 0) > 0) { got = 1; break; }
    }
    if (got) continue;
    struct pollfd p = {.fd = master, .events = POLLIN};
    sleeps++;
    if (poll(&p, 1, -1) < 0 && errno != EINTR) break;
    if (p.revents & (POLLHUP | POLLERR) && !(p.revents & POLLIN)) break;
  }
  int status; waitpid(pid, &status, 0);
  fprintf(stderr, "reads %llu avg %.0f bytes sleeps %llu\n", reads, reads ? (double)bytes / reads : 0, sleeps);
  return 0;
}
