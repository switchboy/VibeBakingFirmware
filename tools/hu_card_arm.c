/* hu_card_arm.c - arm the SD-boot card's BCB, then hand off to Android's init (D103).
 *
 * This is the fast-iteration lever for the Android 14 attempts on the card (D101). It runs as PID 1
 * from the Android 14 ramdisk, writes the recovery Boot Control Block into the CARD's `misc`, and
 * execs /init.real. Measured on Nov 23: the BCB is a SIGNAL, not a reboot path - a reset issued from
 * Android 10 boots the card, and the owner's button reset boots the eMMC even while the card's BCB is
 * armed, so u-boot does not read the card's misc to choose the next boot. Armed therefore proves the
 * chain u-boot -> kernel -> initramfs -> this wrapper -> Android 14 init ran; clear proves it did not.
 * The reporting that makes a failed attempt readable is the watchdog child, not the BCB.
 *
 * Why it is not tools/hu_wrap.c. That one resolves `misc` by walking /sys/block, but sysfs is NOT
 * mounted when PID 1 starts, so the lookup cannot succeed in a first-stage ramdisk; it also mounts
 * devtmpfs to get at /dev/kmsg, and its watchdog forks. Measured on Nov 22: neither its arm nor its
 * watchdog was ever observed on the unit (**D97**). This one mounts `proc` and `sysfs` on its own private
 * directories, reads /proc/partitions, mknods only the nodes it needs, and hands its fds to a watchdog
 * child through clone. Every fd it opens is O_CLOEXEC, so none of them survives into /init.real: Android's
 * init and every service it starts inherits no writable fd to the raw card and no fd to sysrq-trigger.
 *
 * Device resolution follows the same rule as every other write in this repo (**D76**): never a
 * partition number alone and never by-name. The parent device must report the boot card's whole-device
 * block count, and the partition must report the misc block count; both come from /proc/partitions,
 * which also supplies the major:minor to mknod. The log sink is the parent device itself, in space that
 * belongs to no partition, and its bounds are measured from sysfs rather than trusted (**D107**).
 *
 * Fail-open everywhere: every failure path still execs /init.real, because refusing to boot is worse
 * than not arming. Each step is logged to /dev/kmsg, so the console record carries the outcome, and the
 * BCB state read in the next boot is itself the signal that this code ran at all.
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
#include <linux/reboot.h>
#include <signal.h>
#include <errno.h>

/* Seconds the flight recorder runs before it dumps task backtraces and crashes the boot, unless the boot
 * reached /data or the BCB was cleared first. The recorder writes the kernel log to the card every second
 * from the start (see start_watchdog), so this only bounds how long a hung boot is left hanging; 90 s is
 * well past the point where a healthy Android 14 boot mounts /data. */
#ifndef HU_WDT_SECS
#define HU_WDT_SECS 180   /* recorder seconds; it never crashes anything */
#endif
/* Seconds before the crasher fires. It does no block I/O at all (attempt 5 measured the recorder's card
 * heartbeat stopping one second after Android 14's init started, so card I/O may be what hangs); a healthy
 * boot that mounted /data by then is left alone. */
#ifndef HU_TEST_CONTROL_SECS
#define HU_TEST_CONTROL_SECS 4
#endif
#ifndef HU_CRASH_SECS
#define HU_CRASH_SECS 90
#endif

#define HU_BCB_LEN 2048
/* /proc/partitions counts 1024-byte blocks. Measured on the unit: the SD-boot card is 7,948,206,080 B
 * and its misc is 4,194,304 B. The eMMC (61,341,696 blocks) and the second card (30,533,632 blocks)
 * can never match the parent test, so neither can ever be armed by this code. */
#define HU_CARD_BLOCKS 7761920
#define HU_MISC_BLOCKS 4096
#define HU_MISC_PART   3

/* Where the log copy goes: the unpartitioned space at the start of the boot card, before its first
 * partition. Measured on the unit from /sys/block/mmcblk1/mmcblk1p1/start: p1 begins at sector 16384,
 * i.e. byte 8,388,608, so the sectors before it are not part of any partition. Mapping the first 8 MiB in
 * 64 KiB blocks found data only at 0..262,144 (the partition table and vendor blobs) and at
 * 1,245,184..1,310,720 (one 64 KiB vendor block); every other block in that space reads as zero. The log
 * sits at 2 MiB for 5 MiB - clear of both data areas by about 787 KiB, 1 MiB short of p1, and invisible to
 * anything that reads a partition. The boot partition's own tail is NOT usable: it carries about 2 MB of
 * vendor data past the declared image (measured in card-p7-a14.img, non-zero from 28,537,216 to
 * 32,093,450), and the misc partition beyond the BCB is full of data too.
 * The next boot reads the copy with dd if=/dev/block/mmcblk1 bs=1024 skip=2048 count=5120. */
#define HU_LOG_RAW           2097152
#define HU_LOG_LEN           4194304   /* recorder: 2 MiB..6 MiB */
/* The previous boot's pstore records, copied by the parent before Android 14 starts: 6 MiB..7 MiB. */
#define HU_PREV_RAW          6291456
#define HU_PREV_LEN          1048576
#define HU_LOG_HDR           64
#define HU_FIRST_PART_START  8388608   /* byte offset of mmcblk1p1, measured */

#define HU_PROC   "/hu-proc"
#define HU_SYS    "/hu-sys"
#define HU_PARTS  "/hu-proc/partitions"
#define HU_MOUNTS "/hu-proc/mounts"
#define HU_SYSRQ  "/hu-proc/sysrq-trigger"
#define HU_KMSG   "/hu-kmsg"
#define HU_PSTORE "/hu-pstore"
#define HU_MISC   "/hu-misc"
#define HU_CARD   "/hu-card"
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
static void hu_put_char(char c) { if (logfd >= 0) (void)syscall(SYS_write, logfd, &c, 1); }

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

/* Find a partition of the boot card: the parent device must report HU_CARD_BLOCKS, and the partition
 * must be that parent's p<part> with the expected block count. Both names and both block counts must
 * agree, so a different card or the eMMC cannot be selected. The parent's own major:minor is returned
 * too, because the log sink is the raw card device, not a partition. `label` only names it in the log. */
static int find_card_partition(const char *parts_path, int part, long want_blocks, const char *label,
                               long *pmajor, long *pminor, long *major, long *minor,
                               char *parent_out, unsigned parent_cap) {
  char buf[8192];
  int fd = (int)syscall(SYS_openat, AT_FDCWD, parts_path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { hu_put("hu-card-arm: cannot read partitions\n"); return -1; }
  long n = syscall(SYS_read, fd, buf, sizeof(buf) - 1);
  syscall(SYS_close, fd);
  if (n <= 0) { hu_put("hu-card-arm: partitions empty\n"); return -1; }
  buf[n] = 0;

  char parent[64]; parent[0] = 0;
  long pa = 0, pi = 0;
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
        pa = ma; pi = mi;
        for (unsigned i = 0; i < sizeof(parent) - 1 && nm[i]; i++) { parent[i] = nm[i]; parent[i + 1] = 0; }
      }
    }
    p = nl < e ? nl + 1 : e;
  }
  if (!parent[0]) { hu_put("hu-card-arm: no device of the card's size present\n"); return -1; }
  hu_put("hu-card-arm: card device "); hu_put(parent); hu_put("\n");
  *pmajor = pa; *pminor = pi;
  if (parent_out && parent_cap) {
    for (unsigned i = 0; i < parent_cap - 1 && parent[i]; i++) { parent_out[i] = parent[i]; parent_out[i + 1] = 0; }
  }

  /* pass 2: that device's partition */
  char want[72]; unsigned w = 0;
  for (unsigned i = 0; parent[i]; i++) want[w++] = parent[i];
  want[w++] = 'p';
  want[w++] = (char)('0' + part);
  want[w] = 0;
  p = buf;
  while (p < e) {
    const char *nl = p; while (nl < e && *nl != '\n') nl++;
    long ma, mi, bl; char nm[64];
    if (parse_line(p, nl, &ma, &mi, &bl, nm, sizeof(nm)) && hu_streq(nm, want)) {
      if (bl != want_blocks) {
        hu_put("hu-card-arm: wrong block count for "); hu_put(label); hu_put("\n");
        hu_line("hu-card-arm: expected ", want_blocks);
        hu_line("hu-card-arm: found ", bl);
        return -1;
      }
      *major = ma; *minor = mi;
      hu_put("hu-card-arm: "); hu_put(label); hu_put(" node "); hu_put(nm); hu_put("\n");
      return 0;
    }
    p = nl < e ? nl + 1 : e;
  }
  hu_put("hu-card-arm: "); hu_put(label); hu_put(" partition not found on the card\n");
  return -1;
}

static int find_card_misc(const char *parts_path, long *pmajor, long *pminor, long *major, long *minor,
                          char *parent_out, unsigned parent_cap) {
  return find_card_partition(parts_path, HU_MISC_PART, HU_MISC_BLOCKS, "misc", pmajor, pminor, major,
                             minor, parent_out, parent_cap);
}

/* The kernel encodes dev_t as (major << 8) | minor only for majors and minors up to 255; larger values
 * decode to a different device. Measured on this unit: major 179, minors 0/32/35/39, so it is fine here,
 * but a mknod of an out-of-range pair could point at the eMMC or the second card - the devices this
 * project must never write - so it is refused rather than trusted. */
static int hu_dev_encodable(long major, long minor) { return major >= 0 && minor >= 0 && major <= 255 && minor <= 255; }

/* Where the card's first partition starts, in bytes, read from sysfs. sysfs is not mounted when PID 1
 * starts, so the caller mounts it on a private directory first. A test run reads a fixture directory.
 * Returns -1 when the value cannot be measured, which the caller treats as "fall back to the recorded
 * value" - the recorded value is a measurement from this unit, but a repartitioned card would make it
 * wrong, and the log region must never overlap a partition. */
static long p1_start_bytes(const char *parent, const char *sys_dir) {
  char path[192];
  unsigned n = 0;
  for (unsigned i = 0; sys_dir[i]; i++) path[n++] = sys_dir[i];
  path[n++] = '/';
  for (unsigned i = 0; parent[i]; i++) path[n++] = parent[i];
  path[n++] = 'p'; path[n++] = '1'; path[n++] = '/'; path[n++] = 's'; path[n++] = 't'; path[n++] = 'a';
  path[n++] = 'r'; path[n++] = 't'; path[n++] = 0;
  int fd = (int)syscall(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { hu_put("hu-card-arm: p1 start unreadable\n"); return -1; }
  char b[32]; long r = syscall(SYS_read, fd, b, sizeof(b) - 1);
  syscall(SYS_close, fd);
  if (r <= 0) return -1;
  b[r] = 0;
  long v = 0;
  for (long i = 0; i < r && b[i] >= '0' && b[i] <= '9'; i++) v = v * 10 + (b[i] - '0');
  if (v <= 0) return -1;
  return v * 512;   /* sysfs reports sectors of 512 B */
}

/* One character to /proc/sysrq-trigger, and the number of bytes the kernel accepted. The fd is opened by
 * the parent while proc is still mounted, so the child can use it after the parent detaches proc for
 * init.real. A write that the kernel refuses (kernel.sysrq=0) returns 0, which the caller treats as
 * "sysrq did not happen" and falls back to the reboot syscall. */
static long hu_sysrq(int fd, char c) {
  if (fd < 0) { hu_put("hu-card-arm: sysrq unavailable\n"); return -1; }
  long r = syscall(SYS_write, fd, &c, 1);
  hu_put("hu-card-arm: sysrq "); hu_put_char(c); hu_put(r == 1 ? " accepted\n" : " refused\n");
  return r;
}

static long hu_fmt(char *d, long v) {
  char nb[24]; int k = 0; long n = 0;
  if (v < 0) v = 0;
  do { nb[k++] = (char)('0' + (v % 10)); v /= 10; } while (v);
  while (k) d[n++] = nb[--k];
  return n;
}
static long hu_cat(char *d, long n, const char *s) { while (*s) d[n++] = *s++; return n; }

static long hu_uptime_ms(void) {
  struct { long tv_sec; long tv_nsec; } t = { 0, 0 };
  syscall(SYS_clock_gettime, 7 /* CLOCK_BOOTTIME */, &t);
  return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* The 64-byte heartbeat at the start of the log region, rewritten every tick:
 *   HULOG2 tick=<n> up_ms=<boot time> bytes=<log bytes after the header> state=<word>
 * state is start, rec, cleared, alive, dumped or crash. After a cold reset the last heartbeat says how
 * long the recorder kept running, which separates "the whole system froze" (heartbeat stops at the same
 * time as the log) from "userspace hung but the kernel ran" (heartbeat keeps going). */
static void write_hb(int cardfd, long tick, long bytes, const char *state) {
  if (cardfd < 0) return;
  char hd[HU_LOG_HDR];
  for (int i = 0; i < HU_LOG_HDR; i++) hd[i] = ' ';
  char t[128]; long n = 0;
  n = hu_cat(t, n, "HULOG2 tick="); n += hu_fmt(t + n, tick);
  n = hu_cat(t, n, " up_ms="); n += hu_fmt(t + n, hu_uptime_ms());
  n = hu_cat(t, n, " bytes="); n += hu_fmt(t + n, bytes);
  n = hu_cat(t, n, " state="); n = hu_cat(t, n, state);
  if (n > HU_LOG_HDR - 1) n = HU_LOG_HDR - 1;
  for (long i = 0; i < n; i++) hd[i] = t[i];
  hd[HU_LOG_HDR - 1] = '\n';
  (void)syscall(SYS_pwrite64, cardfd, hd, HU_LOG_HDR, HU_LOG_RAW);
}

/* Append every kmsg record that is available now to the log region, and return the new fill level.
 * /dev/kmsg opened for reading starts at the oldest record still in the ring, so the first drain carries
 * the boot from time zero; EPIPE means records were overwritten before we read them and the next read
 * resumes, EAGAIN means nothing new. A test run reads a regular file, which ends in 0 (EOF). The region is
 * capped, so a long boot can never write past HU_LOG_RAW + HU_LOG_LEN. */
static long drain_kmsg(int kfd, int cardfd, long used, long cap, int *full) {
  if (kfd < 0 || cardfd < 0 || *full) return used;
  char rec[2048];
  for (int i = 0; i < 8192; i++) {
    long r = syscall(SYS_read, kfd, rec, sizeof(rec));
    if (r < 0) { if (errno == EPIPE) continue; break; }
    if (r == 0) break;
    if (used + r > cap) { *full = 1; break; }
    if (syscall(SYS_pwrite64, cardfd, rec, r, HU_LOG_RAW + HU_LOG_HDR + used) != r) break;
    used += r;
  }
  return used;
}

static int hu_contains(const char *s, const char *needle) {
  unsigned n = hu_len(needle);
  for (const char *p = s; *p; p++) {
    unsigned i = 0;
    while (i < n && p[i] == needle[i]) i++;
    if (i == n) return 1;
  }
  return 0;
}
/* Is the Android 14 boot alive? A boot that reached /data is a boot worth leaving alone, so the recorder
 * stands down instead of crashing it. */
static int boot_looks_alive(int mountsfd, const char *ok_path) {
  char b[4096];
  long r = mountsfd >= 0 ? syscall(SYS_pread64, mountsfd, b, sizeof(b) - 1, 0) : -1;
  if (r > 0) { b[r] = 0; if (hu_contains(b, " /data ")) return 1; }
  if (ok_path) {
    int fd = (int)syscall(SYS_openat, AT_FDCWD, ok_path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) { syscall(SYS_close, fd); return 1; }
  }
  return 0;
}
static int bcb_still_armed(int miscfd) {
  char back[HU_BCB_LEN];
  long r = syscall(SYS_pread64, miscfd, back, HU_BCB_LEN, 0);
  if (r != HU_BCB_LEN) return 0;
  for (int i = 0; i < HU_BCB_LEN; i++) if (back[i] != bcb[i]) return 0;
  return 1;
}
static void hu_sleep1(void) { struct { long s; long ns; } ts = { 1, 0 }; syscall(SYS_nanosleep, &ts, 0); }
/* The recorder ticks every 100 ms. Measured reason: attempt 5's 1 s tick caught nothing of Android 14's
 * own first-stage log, because the system stopped within a second of init starting; ten ticks a second
 * put every kmsg line printed more than ~100 ms before the stop onto the card, so the last line names
 * the first-stage step that stops the system. The heartbeat's tick= counts these 100 ms ticks. */
#define HU_TICKS_PER_SEC 10
static void hu_sleep_tick(void) { struct { long s; long ns; } ts = { 0, 1000000000L / HU_TICKS_PER_SEC }; syscall(SYS_nanosleep, &ts, 0); }

/* The crasher. Its only tools are a sleep, a pread of the already-open proc mount table, and writes to
 * the already-open /proc/sysrq-trigger - no block device, no filesystem write - so a hang in card I/O
 * cannot stop it. If the kernel and its timers are alive it dumps every task (t), the blocked tasks (w)
 * and every CPU (l) into the console ring, then panics (c); `panic=10` turns that into a warm reboot, so
 * the console record survives in ramoops (D105 only wipes it on a cold reset). If it never fires, the
 * kernel or its timers stopped - which is itself the answer. */
__attribute__((unused)) static void start_crasher(int mountsfd, int sysrqfd, const char *ok_path, long secs, int test, const char *mark) {
  long pid = syscall(SYS_clone, (unsigned long)SIGCHLD, 0UL, 0UL, 0UL, 0UL);
  if (pid < 0) { hu_put("hu-card-arm: clone failed - no crasher\n"); return; }
  if (pid != 0) { hu_line("hu-card-arm: crasher child pid=", pid); return; }
  struct { long s; long ns; } ts = { secs, 0 };
  syscall(SYS_nanosleep, &ts, 0);
  if (boot_looks_alive(mountsfd, ok_path)) {
    hu_put("hu-card-arm: crasher: the boot reached /data - standing down\n");
    syscall(SYS_exit_group, 0);
  }
  hu_put("hu-card-arm: crasher: no /data after the deadline - dumping and panicking\n");
  hu_sysrq(sysrqfd, 't');
  hu_sysrq(sysrqfd, 'w');
  hu_sysrq(sysrqfd, 'l');
  hu_sleep1();
  long crashed = hu_sysrq(sysrqfd, 'c');
  if (crashed != 1) {
    hu_put("hu-card-arm: crasher: falling back to the reboot syscall\n");
    if (!test) {
      syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART, 0);
      hu_put("hu-card-arm: crasher: reboot syscall returned - it was refused\n");
    }
  }
  if (test && mark) {
    int fd = (int)syscall(SYS_openat, AT_FDCWD, mark, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) { syscall(SYS_write, fd, "crash\n", 6); syscall(SYS_close, fd); }
  }
  syscall(SYS_exit_group, 0);
}

struct hu_dirent { unsigned long long d_ino; long long d_off; unsigned short d_reclen; unsigned char d_type; char d_name[256]; };

/* Copy the previous boot's pstore records into [HU_PREV_RAW, HU_PREV_RAW + HU_PREV_LEN) of the raw card,
 * synchronously, in the parent, before Android 14's init runs - the one moment card writes are measured
 * to work (attempt 5's tick 0). If the crasher's warm reboot lands on the card again, this is how the
 * crashed boot's console reaches the card. The filesystem type is "pstore": attempt 4 asked for
 * "pstorefs", which does not exist, so its copy could never have happened. Header:
 *   HUPREV1 bytes=<n> records=<n> up_ms=<when copied> */
static void copy_prev_pstore(int cardfd, const char *dir_path) {
  int dir = (int)syscall(SYS_openat, AT_FDCWD, dir_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (dir < 0) { hu_put("hu-card-arm: prev pstore: cannot open the record directory\n"); return; }
  const long cap = HU_PREV_LEN - HU_LOG_HDR;
  char dents[2048], rec[2048];
  long used = 0, records = 0;
  for (;;) {
    long n = syscall(SYS_getdents64, dir, dents, sizeof(dents));
    if (n <= 0) break;
    for (long off = 0; off < n;) {
      struct hu_dirent *de = (struct hu_dirent *)(dents + off);
      off += de->d_reclen;
      if (de->d_name[0] == '.') continue;
      int rf = (int)syscall(SYS_openat, dir, de->d_name, O_RDONLY | O_CLOEXEC);
      if (rf < 0) continue;
      char hd[160]; long h = 0;
      h = hu_cat(hd, h, "=== ");
      for (unsigned i = 0; de->d_name[i] && h < 150; i++) hd[h++] = de->d_name[i];
      hd[h++] = '\n';
      if (used + h > cap) { syscall(SYS_close, rf); break; }
      if (syscall(SYS_pwrite64, cardfd, hd, h, HU_PREV_RAW + HU_LOG_HDR + used) != h) { syscall(SYS_close, rf); continue; }
      used += h;
      for (;;) {
        long r = syscall(SYS_read, rf, rec, sizeof(rec));
        if (r <= 0) break;
        if (used + r > cap) r = cap - used;
        if (r <= 0) break;
        if (syscall(SYS_pwrite64, cardfd, rec, r, HU_PREV_RAW + HU_LOG_HDR + used) != r) break;
        used += r;
      }
      syscall(SYS_close, rf);
      records++;
    }
  }
  syscall(SYS_close, dir);
  char hd[HU_LOG_HDR]; for (int i = 0; i < HU_LOG_HDR; i++) hd[i] = ' ';
  char t[128]; long k = 0;
  k = hu_cat(t, k, "HUPREV1 bytes="); k += hu_fmt(t + k, used);
  k = hu_cat(t, k, " records="); k += hu_fmt(t + k, records);
  k = hu_cat(t, k, " up_ms="); k += hu_fmt(t + k, hu_uptime_ms());
  if (k > HU_LOG_HDR - 1) k = HU_LOG_HDR - 1;
  for (long i = 0; i < k; i++) hd[i] = t[i];
  hd[HU_LOG_HDR - 1] = '\n';
  (void)syscall(SYS_pwrite64, cardfd, hd, HU_LOG_HDR, HU_PREV_RAW);
  syscall(SYS_fsync, cardfd);
  hu_line("hu-card-arm: prev pstore records copied=", records);
  hu_line("hu-card-arm: prev pstore bytes=", used);
}

/* The flight recorder (attempt 5). Measured reason it replaced the sleep-then-act child: on attempts 3 and
 * 4 the child never acted - attempt 4's card region was still all zero after the owner's reset, so the
 * child did not even reach its first write after a 60 s sleep. Whether the system froze, timers stopped,
 * or the child was killed is unmeasured, and a child that only acts at the end cannot tell those apart.
 * This one writes immediately and then every second: it drains /dev/kmsg (the kernel log plus every line
 * Android's init writes there) into the card's unpartitioned head, rewrites the heartbeat, and fsyncs the
 * card, so everything up to the last second the system was alive survives the owner's cold reset (D105).
 *
 * It stands down - recording stops, nothing is crashed - when the BCB was cleared or the mount table shows
 * /data. When `secs` ticks pass with neither, it dumps every task's backtrace with sysrq 't', records three
 * more seconds so the backtraces reach the card, and crashes with sysrq 'c' so `panic=10` reboots in
 * software. If sysrq is unavailable or refused it falls back to the reboot syscall with the kernel's real
 * magics (tools/hu_wrap.c used 0x6a215546 and 0xd1d1f7e7, which is why **D97**'s watchdog was never seen).
 * Test mode never calls reboot(2) or sync(2): the gate runs on the workstation. */
static void start_recorder(int miscfd, int mountsfd, int cardfd, int kfd, const char *ok_path, long secs) {
  long pid = syscall(SYS_clone, (unsigned long)SIGCHLD, 0UL, 0UL, 0UL, 0UL);
  if (pid < 0) { hu_put("hu-card-arm: clone failed - no recorder\n"); return; }
  if (pid != 0) { hu_line("hu-card-arm: recorder child pid=", pid); return; }

  const long cap = HU_LOG_LEN - HU_LOG_HDR;
  long used = 0; int full = 0;
  hu_put("hu-card-arm: recorder started\n");
  used = drain_kmsg(kfd, cardfd, used, cap, &full);
  write_hb(cardfd, 0, used, "start");
  if (cardfd >= 0) syscall(SYS_fsync, cardfd);

  for (long tick = 1; tick <= secs * HU_TICKS_PER_SEC; tick++) {
    hu_sleep_tick();
    used = drain_kmsg(kfd, cardfd, used, cap, &full);
    if (!bcb_still_armed(miscfd)) {
      hu_put("hu-card-arm: recorder: BCB no longer armed, standing down\n");
      write_hb(cardfd, tick, used, "cleared");
      if (cardfd >= 0) syscall(SYS_fsync, cardfd);
      syscall(SYS_exit_group, 0);
    }
    if (boot_looks_alive(mountsfd, ok_path)) {
      hu_put("hu-card-arm: recorder: the boot reached /data - standing down, not crashing a working boot\n");
      used = drain_kmsg(kfd, cardfd, used, cap, &full);
      write_hb(cardfd, tick, used, "alive");
      if (cardfd >= 0) syscall(SYS_fsync, cardfd);
      syscall(SYS_exit_group, 0);
    }
    write_hb(cardfd, tick, used, "rec");
    if (cardfd >= 0) syscall(SYS_fsync, cardfd);
  }

  hu_put("hu-card-arm: recorder: done\n");
  write_hb(cardfd, secs * HU_TICKS_PER_SEC, used, "done");
  if (cardfd >= 0) syscall(SYS_fsync, cardfd);
  syscall(SYS_exit_group, 0);
}

int main(int argc, char **argv) {
  extern char **environ;
  int test = hu_getenv("HU_TEST") != 0;
  const char *init_real = test ? hu_getenv("HU_TEST_INIT") : HU_INIT;
  const char *parts = test ? hu_getenv("HU_TEST_PARTS") : HU_PARTS;
  int mounted = 0, sys_mounted = 0;

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
    long major = 0, minor = 0, pmajor = 0, pminor = 0;
    char parent[64]; parent[0] = 0;
    /* The device lookup runs in BOTH modes, so the offline gate exercises the rule that decides which
     * device may be written. Only the mount and the node differ: a test run reads a fake
     * /proc/partitions and writes a loopback file instead of a block node. */
    if (!test) {
      syscall(SYS_mkdirat, AT_FDCWD, HU_PROC, 0755);
      if (syscall(SYS_mount, "proc", HU_PROC, "proc", 0, 0) != 0) {
        hu_put("hu-card-arm: ARM FAILED: cannot mount proc\n");
        goto handoff;
      }
      mounted = 1;
    }
    if (find_card_misc(parts, &pmajor, &pminor, &major, &minor, parent, sizeof(parent)) != 0) {
      hu_put("hu-card-arm: ARM FAILED: no misc\n"); goto handoff;
    }
    hu_line("hu-card-arm: major=", major);
    hu_line("hu-card-arm: minor=", minor);
    hu_line("hu-card-arm: card major=", pmajor);
    hu_line("hu-card-arm: card minor=", pminor);
    if (!hu_dev_encodable(major, minor) || !hu_dev_encodable(pmajor, pminor)) {
      hu_put("hu-card-arm: ARM FAILED: dev_t out of range, mknod could name another device\n");
      goto handoff;
    }
    if (test) {
      const char *mp = hu_getenv("HU_TEST_MISC");
      fd = mp ? (int)syscall(SYS_openat, AT_FDCWD, mp, O_RDWR | O_CLOEXEC) : -1;
      if (!mp) hu_put("hu-card-arm: HU_TEST_MISC unset\n");
    } else {
      if (syscall(SYS_mknodat, AT_FDCWD, HU_MISC, S_IFBLK | 0600, (major << 8) | minor) != 0) {
        hu_put("hu-card-arm: ARM FAILED: mknod\n");
        goto handoff;
      }
      fd = (int)syscall(SYS_openat, AT_FDCWD, HU_MISC, O_RDWR | O_CLOEXEC);
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
    hu_put(same ? "hu-card-arm: BCB verified\n"
                : "hu-card-arm: ARM FAILED: readback mismatch\n");
    if (same) {
      /* The reporting channels are set up after the arm succeeds, and each one is optional: losing
       * sysrq or the log sink must still leave the crash, and losing all three must still leave the
       * armed BCB. Every fd here is opened with O_CLOEXEC so none of it survives into init.real - the
       * watchdog child gets its own copy of the table through clone, and Android's init and every
       * service it starts inherits nothing. */
      int sysrqfd = -1, cardfd = -1, mountsfd = -1, kfd = -1;
      const char *ok_path = test ? hu_getenv("HU_TEST_OK") : "/dev/socket/zygote";

      /* sysrq-trigger and the mount table come from proc, which the parent detaches after forking; an
       * open fd outlives the mount it came from, so the child can still use both. */
      if (test) {
        const char *sp = hu_getenv("HU_TEST_SYSRQ");
        sysrqfd = sp ? (int)syscall(SYS_openat, AT_FDCWD, sp, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644) : -1;
        const char *mt = hu_getenv("HU_TEST_MOUNTS");
        mountsfd = mt ? (int)syscall(SYS_openat, AT_FDCWD, mt, O_RDONLY | O_CLOEXEC) : -1;
        const char *km = hu_getenv("HU_TEST_KMSG");
        kfd = km ? (int)syscall(SYS_openat, AT_FDCWD, km, O_RDONLY | O_CLOEXEC) : -1;
      } else {
        /* A second open of the kmsg node, for reading: it starts at the oldest record in the ring. */
        kfd = (int)syscall(SYS_openat, AT_FDCWD, HU_KMSG, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        sysrqfd = (int)syscall(SYS_openat, AT_FDCWD, HU_SYSRQ, O_WRONLY | O_CLOEXEC);
        mountsfd = (int)syscall(SYS_openat, AT_FDCWD, HU_MOUNTS, O_RDONLY | O_CLOEXEC);
      }

      /* The log sink is the raw card device, resolved by the same rule as the misc (**D76**): the parent
       * must report the card's whole-device block count, so the eMMC and the second card cannot be
       * selected. Its region must not overlap the first partition, which is measured here rather than
       * trusted from the baked-in constant. */
      long p1 = -1;
      if (test) {
        const char *sd = hu_getenv("HU_TEST_SYS");
        if (sd) p1 = p1_start_bytes(parent, sd);
      } else {
        syscall(SYS_mkdirat, AT_FDCWD, HU_SYS, 0755);
        if (syscall(SYS_mount, "sysfs", HU_SYS, "sysfs", 0, 0) == 0) {
          sys_mounted = 1;
          p1 = p1_start_bytes(parent, HU_SYS);
        }
      }
      if (p1 < 0) {
        hu_line("hu-card-arm: p1 start not measured, using the recorded ", HU_FIRST_PART_START);
        p1 = HU_FIRST_PART_START;
      } else {
        hu_line("hu-card-arm: p1 starts at ", p1);
      }
      if (HU_PREV_RAW + HU_PREV_LEN > p1 || HU_LOG_RAW + HU_LOG_LEN > HU_PREV_RAW) {
        hu_put("hu-card-arm: log region would reach the first partition - sink disabled\n");
      } else if (test) {
        const char *bp = hu_getenv("HU_TEST_CARD");
        cardfd = bp ? (int)syscall(SYS_openat, AT_FDCWD, bp, O_RDWR | O_CLOEXEC) : -1;
      } else {
        if (syscall(SYS_mknodat, AT_FDCWD, HU_CARD, S_IFBLK | 0600, (pmajor << 8) | pminor) == 0) {
          cardfd = (int)syscall(SYS_openat, AT_FDCWD, HU_CARD, O_RDWR | O_CLOEXEC);
          syscall(SYS_unlinkat, AT_FDCWD, HU_CARD, 0);
        }
      }
      hu_line("hu-card-arm: sysrq fd=", sysrqfd);
      hu_line("hu-card-arm: log sink fd=", cardfd);
      hu_line("hu-card-arm: mounts fd=", mountsfd);
      hu_line("hu-card-arm: kmsg read fd=", kfd);
      hu_line("hu-card-arm: log region offset=", HU_LOG_RAW);
      if (cardfd >= 0) {
        const char *pd = HU_PSTORE;
        int pmounted = 0;
        if (test) pd = hu_getenv("HU_TEST_PSTORE");
        else {
          syscall(SYS_mkdirat, AT_FDCWD, HU_PSTORE, 0755);
          if (syscall(SYS_mount, "pstore", HU_PSTORE, "pstore", 0, 0) == 0) pmounted = 1;
          else hu_put("hu-card-arm: prev pstore: cannot mount pstore\n");
        }
        if (pd) copy_prev_pstore(cardfd, pd);
        if (pmounted) syscall(SYS_umount2, HU_PSTORE, MNT_DETACH);
      }
      long secs = HU_WDT_SECS, csecs = HU_CRASH_SECS;
      if (test) {
        const char *wd = hu_getenv("HU_TEST_WATCHDOG"), *cd = hu_getenv("HU_TEST_CRASH");
        if (wd) { secs = 0; for (const char *q = wd; *q >= '0' && *q <= '9'; q++) secs = secs * 10 + (*q - '0'); }
        if (cd) { csecs = 0; for (const char *q = cd; *q >= '0' && *q <= '9'; q++) csecs = csecs * 10 + (*q - '0'); }
      }
      hu_line("hu-card-arm: recorder ticks=", secs);
#ifndef HU_CONTROL
      hu_line("hu-card-arm: crasher delay=", csecs);
      start_crasher(mountsfd, sysrqfd, ok_path, csecs, test, test ? hu_getenv("HU_TEST_REBOOT_MARK") : 0);
#else
      (void)csecs;
      hu_put("hu-card-arm: CONTROL build - no crasher\n");
#endif
      start_recorder(fd, mountsfd, cardfd, kfd, ok_path, secs);
    }
    syscall(SYS_close, fd);
    if (!test) syscall(SYS_unlinkat, AT_FDCWD, HU_MISC, 0);
  }

handoff:
  if (mounted) syscall(SYS_umount2, HU_PROC, MNT_DETACH);
  if (sys_mounted) syscall(SYS_umount2, HU_SYS, MNT_DETACH);
#ifdef HU_CONTROL
  /* The step-0 control: everything above ran exactly as in a real attempt, but Android 14's init is never
   * executed. If the recorder's heartbeat still stops about a second in, the hang is in the kernel, the
   * card or this wrapper, and Android 14 is innocent; if it runs to tick 120, Android 14's first stage is
   * what kills card I/O. PID 1 must never exit (the kernel panics), so it sleeps; the recorder child is
   * reaped as it ends. A test run returns 9 after the recorder's ticks instead of sleeping forever. */
  (void)init_real; (void)argv; (void)environ;
  hu_put("hu-card-arm: CONTROL build - not executing init.real, idling\n");
  for (long n = 0;; n++) {
    struct { long s; long ns; } ts = { 1, 0 };
    syscall(SYS_nanosleep, &ts, 0);
    syscall(SYS_wait4, -1, 0, 1 /* WNOHANG */, 0);
    if (test && n > HU_TEST_CONTROL_SECS) return 9;
  }
#endif
  if (!init_real) { hu_put("hu-card-arm: exec FAILED: no init.real target\n"); return 1; }
  hu_put("hu-card-arm: execing init.real\n");
  argv[0] = (char *)"/init";
  syscall(SYS_execve, init_real, argv, environ);
  hu_put("hu-card-arm: exec FAILED: init.real missing\n");
  return 1;
}
