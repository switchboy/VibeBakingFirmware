/* hu_netbpfload.c - run Android 14's netbpfload on a kernel without the BPF JIT (attempt 9).
 *
 * Measured on attempt 8 (docs/findings.md): the vendor kernel 4.19.111 has eBPF (BPF_SYSCALL,
 * CGROUP_BPF, NETFILTER_XT_MATCH_BPF, NET_CLS_BPF) but `# CONFIG_BPF_JIT is not set`, so the sysctl
 * file /proc/sys/net/core/bpf_jit_enable does not exist. NetBpfLoad (Tethering APEX 350090000) writes
 * "1" to it, gets ENOENT and exits 1; the bpfloader service carries reboot_on_failure, so init reboots
 * the unit. The kernel can still run BPF programs in its interpreter - only the switch is missing.
 *
 * This wrapper gives netbpfload, and only netbpfload, the switch it wants. It unshares its mount
 * namespace, makes every mount private (so nothing propagates back to the rest of the system), mounts a
 * tmpfs over /proc/sys/net/core and puts two writable files there: bpf_jit_enable and bpf_jit_kallsyms,
 * the two JIT knobs NetBpfLoad writes. Then it execs the real /system/bin/netbpfload. BPF programs and
 * maps it pins land in /sys/fs/bpf, which is the same bpffs instance as everyone else's - a private
 * copy of a mount still refers to the same filesystem - so netd sees them. Every other process keeps
 * the real /proc/sys/net/core.
 *
 * Fail-open: if any step fails it still execs netbpfload, which then fails exactly as it did without
 * the wrapper. Each step is logged to /dev/kmsg, so the console record shows what happened.
 *
 * Which netbpfload (measured on attempt 9): the Tethering APEX's own /etc/netbpfload.33rc redefines the
 * `bpfloader` service with `override`, pointing at /apex/com.android.tethering/bin/netbpfload, so editing
 * the /system rc's service line changed nothing - the APEX binary ran and the wrapper never did. The
 * /system rc therefore starts this wrapper under its own service name (hu_bpfloader), and the wrapper execs
 * the APEX binary - the one Android 14 actually runs - falling back to /system/bin/netbpfload only if the
 * APEX one is missing.
 *
 * bpffs labels (measured on attempt 12): the programs and maps loaded, but system_server aborted in
 * libservice-connectivity's ClatCoordinator check `context of '/sys/fs/bpf/net_shared/...' is
 * 'u:object_r:fs_bpf:s0' != 'u:object_r:fs_bpf_net_shared:s0'`. Android 14 labels bpffs subdirectories by
 * path (`genfscon bpf "/net_shared" ...`), which this vendor 4.19 kernel does not do, so every object gets
 * the root's fs_bpf. So before anything else, in the SHARED mount namespace, the wrapper mounts a separate
 * bpffs on /sys/fs/bpf/net_shared with SELinux's `context=` option (see label_bpffs for why only that one).
 * A mount that fails is logged and the loader runs on the original bpffs.
 *
 * HU_NB_DIR (test only) replaces /proc/sys/net/core, and HU_NB_REAL replaces the exec target, so the
 * offline gate can run it without touching the workstation's /proc.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static int kfd = -1;
static void say(const char *s) {
  if (kfd < 0) return;
  char b[256]; size_t n = 0;
  const char *p = "hu-netbpfload: ";
  while (*p && n < sizeof(b) - 2) b[n++] = *p++;
  while (*s && n < sizeof(b) - 2) b[n++] = *s++;
  b[n++] = '\n';
  (void)!write(kfd, b, n);
}

static int put(const char *dir, const char *name, const char *val) {
  char path[256];
  size_t dl = strlen(dir), nl = strlen(name);
  if (dl + nl + 2 > sizeof(path)) return -1;
  memcpy(path, dir, dl); path[dl] = '/'; memcpy(path + dl + 1, name, nl + 1);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return -1;
  int ok = write(fd, val, strlen(val)) == (ssize_t)strlen(val);
  close(fd);
  return ok ? 0 : -1;
}

/* Only /sys/fs/bpf/net_shared gets its own bpffs (attempt 15). What each attempt measured:
 *   12: one bpffs, every object fs_bpf -> ClatCoordinator aborts: net_shared must be fs_bpf_net_shared.
 *   13: one bpffs per policy subdirectory -> NetBpfLoader's cross-directory rename fails with EXDEV.
 *   14: one bpffs over /sys/fs/bpf labelled fs_bpf_net_shared -> ClatCoordinator aborts: the root itself must
 *       be fs_bpf (`context of '/sys/fs/bpf' is 'u:object_r:fs_bpf_net_shared:s0' != 'u:object_r:fs_bpf:s0'`).
 *   And relabelling is impossible on this kernel: chcon on a bpffs directory returns EOPNOTSUPP (tested in the
 *   card recovery on the same 4.19.111+ kernel).
 * Those two paths are the only labels any component checked. So init's root bpffs stays as it is (fs_bpf),
 * and only net_shared is a separate instance with its label. A rename into or out of net_shared from
 * another directory would still fail; if the loader needs one, its log names the object. */
static void label_bpffs(const char *root) {
  char path[160], msg[220];
  const char *opt = "context=u:object_r:fs_bpf_net_shared:s0";
  snprintf(path, sizeof(path), "%s/net_shared", root);
  if (mkdir(path, 01777) != 0 && errno != EEXIST) {
    snprintf(msg, sizeof(msg), "mkdir %s failed (errno %d)", path, errno); say(msg); return;
  }
  if (mount("bpf", path, "bpf", MS_NOSUID | MS_NODEV | MS_NOEXEC, opt) != 0) {
    snprintf(msg, sizeof(msg), "bpffs %s with %s failed (errno %d)", path, opt, errno); say(msg); return;
  }
  (void)chmod(path, 01777);
  snprintf(msg, sizeof(msg), "bpffs %s mounted with %s; the root stays fs_bpf", path, opt); say(msg);
}

int main(int argc, char **argv) {
  (void)argc;
  const char *dir = getenv("HU_NB_DIR");
  const char *real = getenv("HU_NB_REAL");
  int test = dir != NULL;
  if (!dir) dir = "/proc/sys/net/core";
  if (!real) real = access("/apex/com.android.tethering/bin/netbpfload", X_OK) == 0
                        ? "/apex/com.android.tethering/bin/netbpfload" : "/system/bin/netbpfload";
  kfd = open(test ? "/dev/null" : "/dev/kmsg", O_WRONLY | O_CLOEXEC);

  if (!test) label_bpffs("/sys/fs/bpf");

  if (test) {
    /* the gate exercises the file step only; namespaces and mounts need privileges it does not have */
    if (put(dir, "bpf_jit_enable", "1\n") == 0 && put(dir, "bpf_jit_kallsyms", "0\n") == 0)
      say("test: JIT knobs created");
  } else if (unshare(CLONE_NEWNS) != 0) {
    say("unshare(CLONE_NEWNS) failed - running netbpfload unchanged");
  } else if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    say("making mounts private failed - running netbpfload unchanged");
  } else if (mount("tmpfs", dir, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0755") != 0) {
    say("tmpfs over /proc/sys/net/core failed - running netbpfload unchanged");
  } else if (put(dir, "bpf_jit_enable", "1\n") != 0 || put(dir, "bpf_jit_kallsyms", "0\n") != 0) {
    say("creating the JIT knobs failed - running netbpfload with an empty net/core");
  } else {
    say("private /proc/sys/net/core with bpf_jit_enable and bpf_jit_kallsyms; BPF runs interpreted");
  }
  say(real[1] == 'a' ? "exec /apex/com.android.tethering/bin/netbpfload" : "exec (fallback or test target)");

  argv[0] = (char *)real;
  execv(real, argv);
  say("exec of netbpfload failed");
  return 127;
}
