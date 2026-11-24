/* hu-mtc-param: send HCT CarService-style parameter strings to the car MCU driver.
 *
 * Android 10's com.android.server.microntek.CarService reported its state to the MCU through
 * native_setParameters (libandroid_servers.so, disassembled on 2026-11-24): open("/dev/mtc-car", O_RDWR),
 * ioctl(fd, strlen(s), s), close(fd). It sends "rpt_service_ready=true" when the service starts and
 * "rpt_boot_complete=true" from its BOOT_COMPLETED receiver. Android 14 on the card has no HCT
 * framework, so nothing sends them; on warm boots the MCU then never reports "@ usb on" and the
 * USB hub with the ethernet dongle stays unpowered (attempt 25). This tool sends the strings itself.
 *
 * Usage: hu-mtc-param [--delay SECONDS] STRING...
 * Every result goes to /dev/kmsg ("hu-mtc: ...") so it lands in the console ring and pstore.
 * Build: zig cc -target aarch64-linux-musl -static -Os -Wall -o hu-mtc-param tools/hu_mtc_param.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#ifndef HU_MTC_DEV
#define HU_MTC_DEV "/dev/mtc-car"
#endif

static void klog(const char *msg) {
  int k = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (k >= 0) { (void)write(k, msg, strlen(msg)); close(k); }
  fputs(msg, stderr);
}

int main(int argc, char **argv) {
  char line[512];
  int i = 1, fails = 0;
  if (i + 1 < argc && strcmp(argv[i], "--delay") == 0) {
    struct timespec ts = { atoi(argv[i + 1]), 0 };
    i += 2;
    snprintf(line, sizeof line, "hu-mtc: waiting %ld s\n", (long)ts.tv_sec);
    klog(line);
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {}
  }
  if (i >= argc) { klog("hu-mtc: usage: hu-mtc-param [--delay S] STRING...\n"); return 2; }
  for (; i < argc; i++) {
    const char *s = argv[i];
    int fd = open(HU_MTC_DEV, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      snprintf(line, sizeof line, "hu-mtc: open %s failed: %s\n", HU_MTC_DEV, strerror(errno));
      klog(line); fails++; continue;
    }
    int r = ioctl(fd, (unsigned long)strlen(s), s);
    int e = errno;
    close(fd);
    snprintf(line, sizeof line, "hu-mtc: sent '%s' ret=%d%s%s\n", s, r, r < 0 ? " errno=" : "",
             r < 0 ? strerror(e) : "");
    klog(line);
    if (r < 0) fails++;
  }
  return fails ? 1 : 0;
}
