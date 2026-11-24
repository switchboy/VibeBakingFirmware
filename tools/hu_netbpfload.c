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
 * the root's fs_bpf. The wrapper therefore forks: the child loads exactly as netbpfload expects, and the
 * parent, still in the shared mount namespace, re-pins net_shared under a labelled bpffs afterwards (see
 * repin_net_shared).
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

/* Re-pin net_shared into a labelled bpffs AFTER loading (attempt 16). What each attempt measured:
 *   12: one bpffs, every object fs_bpf -> ClatCoordinator aborts: net_shared must be fs_bpf_net_shared.
 *   13: one bpffs per policy subdirectory, mounted before loading -> NetBpfLoader's cross-directory
 *       rename fails with EXDEV (netd_readonly -> netd_shared).
 *   14: one bpffs over /sys/fs/bpf labelled fs_bpf_net_shared -> ClatCoordinator aborts: the root must be fs_bpf.
 *   15: only net_shared as a separate bpffs, mounted before loading -> EXDEV again: net_shared is also a
 *       staging directory (`rename .../net_shared/tmp_map_netd_uid_counterset_map .../netd_shared/...`).
 *   And bpffs cannot be relabelled on this kernel: chcon returns EOPNOTSUPP.
 * So loading runs on init's single bpffs, where every rename works, and only afterwards are the objects that
 * ended up in /sys/fs/bpf/net_shared opened (BPF_OBJ_GET), a bpffs labelled fs_bpf_net_shared is mounted over
 * that directory, and each object is pinned again under the same name with the same mode and owner. The
 * kernel objects are the same; only their net_shared paths now carry the label ClatCoordinator checks, and
 * the root stays fs_bpf. init's `exec_start` waits for this process, so it finishes before netd or
 * system_server can start. */
#include <dirent.h>
#include <linux/bpf.h>
#include <sys/syscall.h>
#include <sys/wait.h>

struct pinned { char name[200]; int fd; mode_t mode; uid_t uid; gid_t gid; };

static long bpf_call(int cmd, union bpf_attr *attr) { return syscall(__NR_bpf, cmd, attr, sizeof(*attr)); }

static void repin_net_shared(const char *dir) {
  static struct pinned obj[256];
  int n = 0; char msg[300], path[460];
  struct stat dst;
  if (stat(dir, &dst) != 0) { say("repin: net_shared missing - nothing to do"); return; }
  DIR *d = opendir(dir);
  if (!d) { say("repin: cannot open net_shared"); return; }
  struct dirent *e;
  while ((e = readdir(d)) && n < 256) {
    if (e->d_name[0] == '.') continue;
    snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
    struct stat st;
    if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
      snprintf(msg, sizeof(msg), "repin: skipping non-object %s", path); say(msg); continue;
    }
    union bpf_attr at; memset(&at, 0, sizeof(at));
    at.pathname = (unsigned long)path;
    int fd = (int)bpf_call(BPF_OBJ_GET, &at);
    if (fd < 0) { snprintf(msg, sizeof(msg), "repin: BPF_OBJ_GET %s failed (errno %d)", path, errno); say(msg); continue; }
    snprintf(obj[n].name, sizeof(obj[n].name), "%s", e->d_name);
    obj[n].fd = fd; obj[n].mode = st.st_mode & 07777; obj[n].uid = st.st_uid; obj[n].gid = st.st_gid; n++;
  }
  closedir(d);
  const char *opt = "context=u:object_r:fs_bpf_net_shared:s0";
  if (mount("bpf", dir, "bpf", MS_NOSUID | MS_NODEV | MS_NOEXEC, opt) != 0) {
    snprintf(msg, sizeof(msg), "repin: labelled bpffs over %s failed (errno %d) - objects stay fs_bpf", dir, errno);
    say(msg); return;
  }
  (void)chmod(dir, dst.st_mode & 07777);
  (void)chown(dir, dst.st_uid, dst.st_gid);
  int ok = 0;
  for (int i = 0; i < n; i++) {
    snprintf(path, sizeof(path), "%s/%s", dir, obj[i].name);
    union bpf_attr at; memset(&at, 0, sizeof(at));
    at.pathname = (unsigned long)path; at.bpf_fd = (unsigned)obj[i].fd;
    if (bpf_call(BPF_OBJ_PIN, &at) != 0) {
      snprintf(msg, sizeof(msg), "repin: BPF_OBJ_PIN %s failed (errno %d)", path, errno); say(msg); continue;
    }
    (void)chmod(path, obj[i].mode);
    (void)chown(path, obj[i].uid, obj[i].gid);
    close(obj[i].fd);
    ok++;
  }
  snprintf(msg, sizeof(msg), "repin: %d of %d net_shared objects pinned again under fs_bpf_net_shared (dir mode %o uid %d gid %d)",
           ok, n, (unsigned)(dst.st_mode & 07777), (int)dst.st_uid, (int)dst.st_gid);
  say(msg);
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

  pid_t child = test ? 0 : fork();
  if (child > 0) {
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      say("netbpfload failed - not re-pinning, passing its status on");
      return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    repin_net_shared("/sys/fs/bpf/net_shared");
    return 0;
  }
  if (child < 0) say("fork failed - running netbpfload without the re-pin");

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
