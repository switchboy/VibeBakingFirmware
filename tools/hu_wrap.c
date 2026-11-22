/* hu_wrap.c - the arm-early wrapper installed as /init in a boot ramdisk (D92).
 *
 * Runs before Android's init. It arms the boot control block (BCB) in `misc` so a panic, a hang or
 * a fatal init death lands back in recovery, then hands off to the real init as /init.real with
 * argv[0]="/init". Arming happens only when we really are PID 1 invoked as "init"; anything else
 * (ueventd, an installer, a shell test) execs /init.real immediately with its own argv. Every
 * failure logs ARM FAILED and still execs /init.real: nothing here may block or abort a boot.
 * HU_TEST=1 makes paths, the delay and the reboot env-driven, so the same source is testable on
 * the workstation, under qemu-aarch64, and on the unit against a loopback file. Raw syscalls for
 * mount/mknod/pwrite/reboot; no stdio, no locale, no NSS.
 */
#include <sys/syscall.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define HU_MAGIC1    0xfee1dead
#define HU_MAGIC2    0x6a215546
#define HU_RESTART2  0xd1d1f7e7
#define HU_BCB_LEN   2048
#define HU_DEV_DIR   "/hu-dev"
#define HU_NODE_DIR  "/hu-wrap"
#define HU_NODE      "/hu-wrap/misc"
#define HU_EMMC_SECTORS 122683392   /* 62,813,896,704 B / 512, measured on the unit */

struct hu_dent { long ino; long off; short reclen; char type; char name[]; };

static char bcb[HU_BCB_LEN];
static int logfd = -1;

static unsigned hu_len(const char *s) { unsigned n = 0; while (s && s[n]) n++; return n; }
static void hu_put(const char *s) { if (logfd >= 0 && s) (void)syscall(SYS_write, logfd, s, hu_len(s)); }
static void hu_num(long v) {
  char b[24]; unsigned i = sizeof(b); unsigned neg = v < 0; long x = neg ? -v : v;
  if (x == 0) b[--i] = '0';
  while (x) { b[--i] = (char)('0' + (x % 10)); x /= 10; }
  if (neg) b[--i] = '-';
  if (logfd >= 0) (void)syscall(SYS_write, logfd, &b[i], sizeof(b) - i);
  hu_put("\n");
}
static void hu_line(const char *a, long v) { hu_put(a); hu_num(v); }
static const char *hu_getenv(const char *key) {
  extern char **environ; unsigned k = hu_len(key);
  for (char **e = environ; *e; e++) { unsigned i = 0;
    while (i < k && e[0][i] == key[i]) i++;
    if (i == k && e[0][i] == '=') return e[0] + k + 1; }
  return 0;
}
static const char *hu_basename(const char *p) {
  const char *b = p; for (const char *s = p; s && *s; s++) if (*s == '/') b = s + 1; return b;
}
static int hu_match(const char *hay, const char *needle) {
  unsigned n = hu_len(needle);
  for (const char *s = hay; s && *s; s++) { unsigned i = 0;
    while (i < n && s[i] == needle[i]) i++;
    if (i == n) return 1; }
  return 0;
}
static int hu_streq(const char *a, const char *b) {
  while (*a && *b) { if (*a != *b) return 0; a++; b++; }
  return *a == 0 && *b == 0;
}
static long hu_long(const char *s) {
  long v = 0; while (s && *s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; } return v;
}
static void hu_join(char *dst, unsigned cap, const char *a, const char *b) {
  unsigned i = 0;
  while (a && a[i] && i < cap - 1) { dst[i] = a[i]; i++; }
  unsigned j = 0;
  while (b && b[j] && i < cap - 1) { dst[i] = b[j]; j++; i++; }
  dst[i] = 0;
}

/* the AOSP bootloader_message head: command[32], zero status[32], recovery[768] */
static void fill_bcb(void) {
  const char cmd[] = "boot-recovery"; const char rec[] = "recovery\n";
  unsigned c = hu_len(cmd), r = hu_len(rec);
  for (int i = 0; i < HU_BCB_LEN; i++) bcb[i] = 0;
  for (unsigned i = 0; i < c; i++) bcb[i] = cmd[i];
  for (unsigned i = 0; i < r; i++) bcb[64 + i] = rec[i];
}

static long hu_read(const char *p, char *buf, unsigned cap) {
  int fd = (int)syscall(SYS_openat, AT_FDCWD, p, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  long n = syscall(SYS_read, fd, buf, cap - 1);
  if (n > 0) buf[n] = 0;
  syscall(SYS_close, fd);
  return n;
}

/* sysfs discovery: PARTNAME=misc on the MMC device sized HU_EMMC_SECTORS sectors */
static int hu_find_misc(int *major, int *minor) {
  int dir = (int)syscall(SYS_openat, AT_FDCWD, "/sys/block", O_RDONLY | O_CLOEXEC);
  if (dir < 0) return -1;
  char buf[2048];
  for (;;) {
    long n = syscall(SYS_getdents64, dir, buf, sizeof(buf));
    if (n <= 0) break;
    for (char *p = buf; p < buf + n; ) {
      struct hu_dent *de = (struct hu_dent *)p;
      if (de->name[0] != '.') {
        char part[64]; unsigned j = 0;
        while (de->name[j] && j < sizeof(part) - 1) { part[j] = de->name[j]; j++; }
        part[j] = 0;
        char path[256];
        hu_join(path, sizeof(path), "/sys/block/", part);
        char sz[64];
        if (hu_read(path, sz, sizeof(sz)) > 0 && hu_long(sz) == HU_EMMC_SECTORS) {
          char tpath[300];
          hu_join(tpath, sizeof(tpath), path, "/device/type");
          char typ[64];
          if (hu_read(tpath, typ, sizeof(typ)) > 0 && hu_match(typ, "MMC")) {
            int pdir = (int)syscall(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC);
            if (pdir >= 0) {
              char pb[2048];
              for (;;) {
                long pn = syscall(SYS_getdents64, pdir, pb, sizeof(pb));
                if (pn <= 0) break;
                for (char *pp = pb; pp < pb + pn; ) {
                  struct hu_dent *pde = (struct hu_dent *)pp;
                  if (pde->name[0] != '.') {
                    char pname[64]; unsigned j2 = 0;
                    while (pde->name[j2] && j2 < sizeof(pname) - 1) { pname[j2] = pde->name[j2]; j2++; }
                    pname[j2] = 0;
                    char mid[320]; hu_join(mid, sizeof(mid), path, "/");
                    char node[384]; hu_join(node, sizeof(node), mid, pname);
                    char uev[420]; hu_join(uev, sizeof(uev), node, "/uevent");
                    char ux[512];
                    if (hu_read(uev, ux, sizeof(ux)) > 0 && hu_match(ux, "PARTNAME=misc")) {
                      const char *s = ux;
                      while (*s && !(s[0] == 'M' && s[1] == 'A' && s[2] == 'J' && s[3] == 'O' && s[4] == 'R' && s[5] == '=')) s++;
                      if (*s) { s += 6; char dig[8]; unsigned d = 0;
                        while (*s >= '0' && *s <= '9' && d < 7) { dig[d] = *s; d++; s++; } dig[d] = 0;
                        *major = (int)hu_long(dig); }
                      while (*s && !(s[0] == 'M' && s[1] == 'I' && s[2] == 'N' && s[3] == 'O' && s[4] == 'R' && s[5] == '=')) s++;
                      if (*s) { s += 6; char dig[8]; unsigned d = 0;
                        while (*s >= '0' && *s <= '9' && d < 7) { dig[d] = *s; d++; s++; } dig[d] = 0;
                        *minor = (int)hu_long(dig); }
                      syscall(SYS_close, pdir); syscall(SYS_close, dir);
                      return (*major > 0) ? 0 : -1;
                    }
                  }
                  pp += pde->reclen;
                }
              }
              syscall(SYS_close, pdir);
            }
          }
        }
      }
      p += de->reclen;
    }
  }
  syscall(SYS_close, dir);
  return -1;
}

static void hu_watchdog(int fd, long delay, int test) {
  pid_t pid = fork();
  if (pid < 0) { hu_put("HU-WRAP watchdog fork FAILED\n"); return; }
  if (pid == 0) {
    struct timespec ts; ts.tv_sec = delay; ts.tv_nsec = 0;
    syscall(SYS_nanosleep, &ts, 0);
    char back[HU_BCB_LEN];
    long n = syscall(SYS_pread64, fd, back, HU_BCB_LEN, 0);
    const char cmd[] = "boot-recovery"; unsigned i = 0;
    if (n >= 13) while (i < 13 && back[i] == cmd[i]) i++;
    if (n >= 13 && i == 13) {
      hu_put("HU-WRAP watchdog: BCB still armed, rebooting into recovery\n");
      if (test) { hu_put("HU-WRAP test: reboot suppressed\n"); syscall(SYS_exit, 0); }
      syscall(SYS_reboot, HU_MAGIC1, HU_MAGIC2, HU_RESTART2, "recovery");
      hu_put("HU-WRAP watchdog: reboot syscall returned\n");
      syscall(SYS_exit, 1);
    }
    if (n >= 0) hu_put("HU-WRAP watchdog: BCB disarmed, no reboot\n");
    else hu_put("HU-WRAP watchdog: misc read FAILED, no reboot\n");
    syscall(SYS_exit, 0);
  }
  hu_line("HU-WRAP watchdog child pid=", pid);
}

int main(int argc, char **argv) {
  int test = hu_getenv("HU_TEST") != 0;
  const char *init_real = test ? hu_getenv("HU_TEST_INIT") : "/init.real";
  const char *wd = test ? hu_getenv("HU_TEST_WATCHDOG") : 0;
  long delay = wd ? hu_long(wd) : 300;
  extern char **environ;

  if (test) {
    const char *lp = hu_getenv("HU_TEST_LOG");
    logfd = (int)syscall(SYS_openat, AT_FDCWD, lp ? lp : "hu-wrap.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC);
  } else {
    syscall(SYS_mkdirat, AT_FDCWD, HU_DEV_DIR, 0755);
    if (syscall(SYS_mount, "devtmpfs", HU_DEV_DIR, "devtmpfs", 0, 0) == 0)
      logfd = (int)syscall(SYS_openat, AT_FDCWD, HU_DEV_DIR "/kmsg", O_WRONLY | O_NONBLOCK);
  }
  hu_put(test ? "HU-WRAP test begin\n" : "HU-WRAP begin\n");
  hu_line("HU-WRAP pid=", syscall(SYS_getpid));
  hu_line("HU-WRAP argc=", argc);
  hu_put("HU-WRAP argv0="); hu_put(argv[0]); hu_put("\n");

  int arm = syscall(SYS_getpid) == 1 && argc == 1 && hu_streq(hu_basename(argv[0]), "init");
  if (test && hu_getenv("HU_TEST_FORCE_ARM")) arm = 1;
  if (!init_real) hu_put("HU-WRAP ARM FAILED: no init.real target configured\n");

  if (!arm) {
    hu_put("HU-WRAP passthrough: not PID-1-as-init, execing init.real untouched\n");
    if (init_real) { argv[0] = (char *)init_real; syscall(SYS_execve, init_real, argv, environ); }
    hu_put("HU-WRAP exec FAILED: init.real missing\n");
    return 1;
  }

  fill_bcb();
  int fd = -1, mounted = 0;
  if (test) {
    const char *mp = hu_getenv("HU_TEST_MISC");
    hu_put("HU-WRAP test misc path="); hu_put(mp ? mp : "(unset)"); hu_put("\n");
    fd = mp ? (int)syscall(SYS_openat, AT_FDCWD, mp, O_RDWR) : -1;
  } else {
    int major = 0, minor = 0;
    if (hu_find_misc(&major, &minor) != 0) { hu_put("HU-WRAP ARM FAILED: misc not found by sysfs\n"); goto handoff; }
    hu_line("HU-WRAP misc major=", major);
    hu_line("HU-WRAP misc minor=", minor);
    syscall(SYS_mkdirat, AT_FDCWD, HU_NODE_DIR, 0755);
    if (syscall(SYS_mount, "tmpfs", HU_NODE_DIR, "tmpfs", 0, 0) != 0) { hu_put("HU-WRAP ARM FAILED: tmpfs mount failed\n"); goto handoff; }
    mounted = 1;
    if (syscall(SYS_mknodat, AT_FDCWD, HU_NODE, S_IFBLK | 0600, (major << 8) | minor) != 0) {
      hu_put("HU-WRAP ARM FAILED: mknod failed\n"); goto handoff;
    }
    fd = (int)syscall(SYS_openat, AT_FDCWD, HU_NODE, O_RDWR);
  }
  if (fd < 0) { hu_put("HU-WRAP ARM FAILED: misc open failed\n"); goto handoff; }

  long w = syscall(SYS_pwrite64, fd, bcb, HU_BCB_LEN, 0);
  hu_line("HU-WRAP bcb pwrite=", w);
  if (w != HU_BCB_LEN) { hu_put("HU-WRAP ARM FAILED: pwrite short\n"); goto handoff; }
  syscall(SYS_fsync, fd);
  char back[HU_BCB_LEN];
  long r = syscall(SYS_pread64, fd, back, HU_BCB_LEN, 0);
  int same = r == HU_BCB_LEN;
  for (int i = 0; same && i < HU_BCB_LEN; i++) if (back[i] != bcb[i]) same = 0;
  hu_line("HU-WRAP bcb readback=", r);
  hu_put(same ? "HU-WRAP bcb verified\n" : "HU-WRAP ARM FAILED: readback mismatch\n");

  hu_line("HU-WRAP watchdog delay=", delay);
  hu_watchdog(fd, delay, test);

handoff:
  if (mounted) hu_line("HU-WRAP umount=", syscall(SYS_umount2, HU_NODE_DIR, MNT_DETACH));
  if (!init_real) { hu_put("HU-WRAP exec FAILED: no init.real target\n"); return 1; }
  hu_put("HU-WRAP execing init.real with argv[0]=/init\n");
  argv[0] = (char *)"/init";
  syscall(SYS_execve, init_real, argv, environ);
  hu_put("HU-WRAP exec FAILED: init.real missing\n");
  return 1;
}
