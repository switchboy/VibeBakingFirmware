#!/system/bin/sh
# Namespace half of the harness that D59 froze (Nov 18). A safe version needs D64's guard set: an
# unshare(CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWIPC|CLONE_NEWUTS) from a native helper, then
# mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) before any mount, then a fork so init really is
# PID 1 of its namespace, seccomp + a ptrace path filter, BLKROSET on the partitions it must never
# write, and a namespace-wide kill. Post-run inspection lives
# in hu_first_stage_harness.sh (the host namespace), because init exits early and /proc/<pid>/root
# then vanishes; the namespace's mounts leak back through Android's shared /data mount, so the host
# can read the staging tree afterwards. By-name seeding also runs host-side there - inside the
# namespace init umounts /data and the staging tmpfs, so nothing can resolve staging paths mid-run.
#
# The staging root mirrors a fresh boot, per the payload ramdisk's cpio listing:
#   - tmpfs at the staging root,
#   - /dev = devtmpfs (fresh kernel nodes); init umounts it, mounts its own tmpfs, mknod's
#     console/kmsg/null and builds block nodes from sysfs uevents,
#   - /proc, /sys, /mnt, /debug_ramdisk, /second_stage_resources: init mounts/creates them itself;
#     pre-mounting proc/sys gives EBUSY and aborts,
#   - /first_stage_ramdisk/fstab.rk30board is the payload fstab.
# Everything init mounts or formats stays inside this namespace and inside virt.img.

R=/data/local/tmp/hu_test/root

toybox mount -t tmpfs tmpfs "$R" || { echo "inner: staging tmpfs mount failed"; exit 1; }
toybox mkdir -p "$R/dev" "$R/system" "$R/vendor" "$R/product" "$R/system_ext" "$R/odm" \
  "$R/metadata" "$R/cache" "$R/data" "$R/mnt" "$R/debug_ramdisk" "$R/proc" "$R/sys" \
  "$R/first_stage_ramdisk" "$R/second_stage_resources"
# Payload pieces, copied while /data is still mounted (init umounts it inside the namespace).
toybox cp /data/local/tmp/hu_test/root-init "$R/init" || echo "inner: copy init failed"
toybox chmod 0755 "$R/init" || echo "inner: chmod init failed"
toybox cp /data/local/tmp/hu_test/fstab-harness.rk30board "$R/first_stage_ramdisk/fstab.rk30board" || echo "inner: copy fstab failed"

toybox mount -t devtmpfs devtmpfs "$R/dev" || echo "inner: devtmpfs mount failed"

if [ "$HU_NO_INIT" = 1 ]; then
  echo "inner: HU_NO_INIT set, skipping init launch (plumbing probe only)"
else
echo "inner: launching payload first-stage init (bg, watchdog 3 s)"
chroot "$R" /init &
IP=$!
toybox sleep 3
# kill is a shell builtin: /system is umounted inside the namespace, so toybox may be gone by now.
kill -9 "$IP" 2>/dev/null
echo "inner: init pid $IP killed/exited"
fi
