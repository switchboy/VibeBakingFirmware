/* hu_card_arm.c - arm the SD-boot card's BCB, then hand off to Android's init (D103).
 *
 * This is the fast-iteration lever for the Android 14 attempts on the card (D101). It runs as PID 1
 * from the Android 14 ramdisk, writes the recovery Boot Control Block into the CARD's `misc`, and
 * execs /init.real. The consequence: whatever the Android 14 boot does next - panic, hang, or a
 * successful boot - the next reset lands in the networked recovery on the card's p8, where the log
 * can be read and the next image written over adb. With `panic=10` in the cmdline a kernel panic
 * reboots by itself, so a failed attempt needs no button press at all.
 *
 * Why it is not tools/hu_wrap.c. That one resolves `misc` by walking /sys/block, but sysfs is NOT
 * mounted when PID 1 starts, so the lookup cannot succeed in a first-stage ramdisk; it also mounts
 * devtmpfs to get at /dev/kmsg, and its watchdog forks. Measured on Nov 22: neither its arm nor its
 * watchdog was ever observed on the unit (**D97**). This one mounts `proc` on its own private
 * directory, reads /proc/partitions, mknods the two nodes it needs, and forks nothing.
 *
 * Device resolution follows the same rule as every other write in this repo (**D76**): never a
 * partition number alone and never by-name. The parent device must report the boot card's whole-device
 * block count, and the partition must report the misc block count; both come from /proc/partitions,
 * which also supplies the major:minor to mknod.
 *
 * Fail-open everywhere: every failure path still execs /init.real, because refusing to boot is worse
 * than not arming. Each step is logged to /dev/kmsg, so the pstore console record of the boot carries
 * the outcome - and the BCB state read in the next recovery boot is itself the signal that this code
 * ran at all.
 *
 * Build: scripts/build_hu_wrap.sh (zig cc -target aarch64-linux-musl -static -Os, stripped,
 * SOURCE_DATE_EPOCH pinned). Raw syscalls only. Offline scenarios: scripts/smoke_hu_card_arm.sh,
 * which drives it with HU_TEST against loopback files and a fake /proc/partitions.
 */
#include <sys/syscall.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>

#define HU_BCB_LEN 2048
/* /proc/partitions counts 1024-byte blocks. Measured on the unit: the SD-boot card is 7,948,206,080 B
 * and its misc is 4,194,304 B. The eMMC (61,341,696 blocks) and the second card (30,533,632 blocks)
 * can never match the parent test, so neither can ever be armed by this code. */
#define HU_CARD_BLOCKS 7761920
#define HU_MISC_BLOCKS 4096
#define HU_MISC_PART   3

#define HU_PROC   "/hu-proc"
#define HU_PARTS  "/hu-proc/partitions"
#define HU_KMSG   "/hu-kmsg"
#define HU_MISC   "/hu-misc"
#define HU_INIT   "/init.real"

static char bcb[HU_BCB_LEN];
static int logfd = -1;

static unsigned hu_len(const char *s) { unsigned n = 0; while (s && s[n]) n++; return n; }
static void hu_put(const char *s) { if (logfd >= 0 && s) (void)syscall(SYS_write, logfd, s, hu_len(s)); }
static void hu_num(long v) {
  char b[24]; int i = sizeof(b); int neg = v < 0; unsigned long u = neg ? (unsigned long)-v : (unsigned long)v;
  b[--i] = '\n';
  if (!u) b[--i] = '0';
  while (u) { b[--i] = (char)('0' + (u % 10)); u /= 10; }
  if (neg) b[--i] = '-';
  if (logfd >= 0) (void)syscall(SYS_write, logfd, &b[i], sizeof(b) - (unsigned)i);
}
static void hu_line(const char *a, long v) { hu_put(a); hu_num(v); }

static int hu_streq(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return *a == 0 && *b == 0;
}
static const char *hu_basename(const char *p) {
  const char *s = p; for (const char *q = p; q && *q; q++) if (*q == '/') s = q + 1; return s;
}
static const char *hu_getenv(const char *key) {
  extern char **environ;
  unsigned n = hu_len(key);
  for (char **e = environ; e && *e; e++) {
    unsigned i = 0; while (i < n && (*e)[i] == key[i]) i++;
    if (i == n && (*e)[i] == '=') return &(*e)[i + 1];
  }
  return 0;
}

/* The exact 2048-byte BCB this project registers: "boot-recovery" at 0, "recovery\n" at 64, the rest
 * zero, no arguments and no --wipe_all. sha256 ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e */
static void fill_bcb(void) {
  const char *cmd = "boot-recovery";
  const char *rec = "recovery\n";
  for (int i = 0; i < HU_BCB_LEN; i++) bcb[i] = 0;
  for (unsigned i = 0; i < hu_len(cmd); i++) bcb[i] = cmd[i];
  for (unsigned i = 0; i < hu_len(rec); i++) bcb[64 + i] = rec[i];
}

/* One line of /proc/partitions: "  major  minor  blocks name". Returns 1 on a parsed line. */
static int parse_line(const char *p, const char *end, long *major, long *minor, long *blocks,
                      char *name, unsigned cap) {
  long v[3] = {0, 0, 0};
  int got = 0;
  while (p < end && got < 3) {
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p < '0' || *p > '9') return 0;
    long acc = 0;
    while (p < end && *p >= '0' && *p <= '9') { acc = acc * 10 + (*p - '0'); p++; }
    v[got++] = acc;
  }
  while (p < end && (*p == ' ' || *p == '\t')) p++;
  unsigned i = 0;
  while (p < end && *p != ' ' && *p != '\t' && i + 1 < cap) name[i++] = *p++;
  name[i] = 0;
  if (!i) return 0;
  *major = v[0]; *minor = v[1]; *blocks = v[2];
  return 1;
}

/* Find the boot card's misc partition: the parent device must report HU_CARD_BLOCKS, and the
 * partition must be that parent's p<HU_MISC_PART> with HU_MISC_BLOCKS. Both names and both block
 * counts must agree, so a different card or the eMMC cannot be selected. */
static int find_card_misc(const char *parts_path, long *major, long *minor) {
  char buf[8192];
  int fd = (int)syscall(SYS_openat, AT_FDCWD, parts_path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { hu_put("hu-card-arm: cannot read partitions\n"); return -1; }
  long n = syscall(SYS_read, fd, buf, sizeof(buf) - 1);
  syscall(SYS_close, fd);
  if (n <= 0) { hu_put("hu-card-arm: partitions empty\n"); return -1; }
  buf[n] = 0;

  char parent[64]; parent[0] = 0;
  /* pass 1: the parent device */
  const char *p = buf, *e = buf + n;
  while (p < e) {
    const char *nl = p; while (nl < e && *nl != '\n') nl++;
    long ma, mi, bl; char nm[64];
    if (parse_line(p, nl, &ma, &mi, &bl, nm, sizeof(nm)) && bl == HU_CARD_BLOCKS) {
      int has_part_digit = 0;
      for (const char *q = nm; *q; q++) if (*q == 'p' && q[1] >= '0' && q[1] <= '9') has_part_digit = 1;
      if (!has_part_digit) {
        if (parent[0]) { hu_put("hu-card-arm: two devices match the card size, refusing\n"); return -1; }
        for (unsigned i = 0; i < sizeof(parent) - 1 && nm[i]; i++) { parent[i] = nm[i]; parent[i + 1] = 0; }
      }
    }
    p = nl < e ? nl + 1 : e;
  }
  if (!parent[0]) { hu_put("hu-card-arm: no device of the card's size present\n"); return -1; }
  hu_put("hu-card-arm: card device "); hu_put(parent); hu_put("\n");

  /* pass 2: that device's misc partition */
  char want[72]; unsigned w = 0;
  for (unsigned i = 0; parent[i]; i++) want[w++] = parent[i];
  want[w++] = 'p';
  want[w++] = (char)('0' + HU_MISC_PART);
  want[w] = 0;
  p = buf;
  while (p < e) {
    const char *nl = p; while (nl < e && *nl != '\n') nl++;
    long ma, mi, bl; char nm[64];
    if (parse_line(p, nl, &ma, &mi, &bl, nm, sizeof(nm)) && hu_streq(nm, want)) {
      if (bl != HU_MISC_BLOCKS) {
        hu_line("hu-card-arm: misc candidate has the wrong block count: ", bl);
        return -1;
      }
      *major = ma; *minor = mi;
      hu_put("hu-card-arm: misc node "); hu_put(nm); hu_put("\n");
      return 0;
    }
    p = nl < e ? nl + 1 : e;
  }
  hu_put("hu-card-arm: misc partition not found on the card\n");
  return -1;
}

int main(int argc, char **argv) {
  extern char **environ;
  int test = hu_getenv("HU_TEST") != 0;
  const char *init_real = test ? hu_getenv("HU_TEST_INIT") : HU_INIT;
  const char *parts = test ? hu_getenv("HU_TEST_PARTS") : HU_PARTS;
  int mounted = 0;

  if (test) {
    const char *lp = hu_getenv("HU_TEST_LOG");
    logfd = (int)syscall(SYS_openat, AT_FDCWD, lp ? lp : "hu-card-arm.log",
                         O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  } else {
    /* A character node costs nothing and avoids mounting devtmpfs: /dev/kmsg is 1:11. */
    syscall(SYS_mknodat, AT_FDCWD, HU_KMSG, S_IFCHR | 0600, (1 << 8) | 11);
    logfd = (int)syscall(SYS_openat, AT_FDCWD, HU_KMSG, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  }

  hu_put("hu-card-arm: begin\n");
  hu_line("hu-card-arm: pid=", syscall(SYS_getpid));
  hu_put("hu-card-arm: argv0="); hu_put(argv[0] ? argv[0] : "(null)"); hu_put("\n");

  int arm = syscall(SYS_getpid) == 1 && argc == 1 && hu_streq(hu_basename(argv[0]), "init");
  if (test && hu_getenv("HU_TEST_FORCE_ARM")) arm = 1;
  if (!arm) hu_put("hu-card-arm: not PID-1-as-init, passthrough without arming\n");

  if (arm) {
    fill_bcb();
    int fd = -1;
    if (test) {
      const char *mp = hu_getenv("HU_TEST_MISC");
      fd = mp ? (int)syscall(SYS_openat, AT_FDCWD, mp, O_RDWR) : -1;
      if (!mp) hu_put("hu-card-arm: HU_TEST_MISC unset\n");
    } else {
      syscall(SYS_mkdirat, AT_FDCWD, HU_PROC, 0755);
      if (syscall(SYS_mount, "proc", HU_PROC, "proc", 0, 0) != 0) {
        hu_put("hu-card-arm: ARM FAILED: cannot mount proc\n");
        goto handoff;
      }
      mounted = 1;
      long major = 0, minor = 0;
      if (find_card_misc(parts, &major, &minor) != 0) { hu_put("hu-card-arm: ARM FAILED: no misc\n"); goto handoff; }
      hu_line("hu-card-arm: major=", major);
      hu_line("hu-card-arm: minor=", minor);
      if (syscall(SYS_mknodat, AT_FDCWD, HU_MISC, S_IFBLK | 0600, (major << 8) | minor) != 0) {
        hu_put("hu-card-arm: ARM FAILED: mknod\n");
        goto handoff;
      }
      fd = (int)syscall(SYS_openat, AT_FDCWD, HU_MISC, O_RDWR);
    }
    if (fd < 0) { hu_put("hu-card-arm: ARM FAILED: open\n"); goto handoff; }

    long w = syscall(SYS_pwrite64, fd, bcb, HU_BCB_LEN, 0);
    hu_line("hu-card-arm: pwrite=", w);
    if (w != HU_BCB_LEN) { hu_put("hu-card-arm: ARM FAILED: short write\n"); syscall(SYS_close, fd); goto handoff; }
    syscall(SYS_fsync, fd);
    char back[HU_BCB_LEN];
    long r = syscall(SYS_pread64, fd, back, HU_BCB_LEN, 0);
    int same = r == HU_BCB_LEN;
    for (int i = 0; same && i < HU_BCB_LEN; i++) if (back[i] != bcb[i]) same = 0;
    hu_line("hu-card-arm: readback=", r);
    hu_put(same ? "hu-card-arm: BCB verified - the next reset boots recovery\n"
                : "hu-card-arm: ARM FAILED: readback mismatch\n");
    syscall(SYS_close, fd);
    if (!test) syscall(SYS_unlinkat, AT_FDCWD, HU_MISC, 0);
  }

handoff:
  if (mounted) syscall(SYS_umount2, HU_PROC, MNT_DETACH);
  if (!init_real) { hu_put("hu-card-arm: exec FAILED: no init.real target\n"); return 1; }
  hu_put("hu-card-arm: execing init.real\n");
  argv[0] = (char *)"/init";
  syscall(SYS_execve, init_real, argv, environ);
  hu_put("hu-card-arm: exec FAILED: init.real missing\n");
  return 1;
}
