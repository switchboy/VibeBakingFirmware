#!/system/bin/sh
# Android 14 first-stage init against VIRTUAL partitions, under the running Android 10 unit.
#
# FROZEN (D59, Nov 18). Do not run this against a live unit. A mount+pid namespace does not isolate
# device-mapper, block devices, binder, GPU, panel, sysctls, sysrq or power state, `toybox unshare -mp`
# does not fork so init is never PID 1 of its namespace (a fatal abort reaches the host's reboot(2)), and
# the running Android 10 already owns device-mapper targets named system/vendor/product/odm, so a clean
# logical-mount result is impossible here. Runs correlated with framework restarts and one kernel reboot.
# Any future live harness must implement D64's guard set first.
#
# Nothing here writes a real partition and nothing reboots: the payload lives in a file
# (/data/local/tmp/hu_test/virt.img) whose GPT partition names are exactly the ones the payload
# fstab asks for. Android 14's own static first-stage init runs inside a private mount+pid
# namespace against loop9's partition nodes. The design intent was:
#   - every "partition" init mounts is a byte range of a file in /data, but that only holds if the
#     by-name links resolve to loop9's partitions - init's own symlink pass uses plain symlink() and
#     SKIPS existing names, so a colliding bare name resolves to the real mmc partition (the host-side
#     seeder exists precisely because of that),
#   - nothing here opens the eMMC for writing, yet a namespace does not stop init from touching global
#     kernel state (uevent flood, device-mapper, sysctls, power), which is why **D59** freezes it and
#     **D64** lists the guards a safe version would need,
#   - failure output lands on stdout + kmsg + the log file, but the kernel's /dev/kmsg ratelimiter can
#     still swallow lines ("N output lines suppressed due to ratelimiting"), which is what hid the
#     logical-mount outcome.
#
# Run as: sh hu_first_stage_harness.sh 2>&1 | tee hu-harness.log   (needs root adb) - FROZEN, see above.
# The namespace work itself lives in hu_harness_inner.sh (unshare cannot take a complex -c string
# in toybox sh). Guard: refuse to run while anything else owns the loop slot or the image is short.

HT=/data/local/tmp/hu_test
IMG=$HT/virt.img
LOOP=/dev/block/loop9
NEED_BYTES=4288692736
INNER=$HT/hu_harness_inner.sh

fail() { echo "HARNESS-STOP: $1"; exit 1; }

# Root adb is mandatory (losetup, mknod, mount). After a unit reboot adb is shell again.
toybox id -u | grep -q '^0$' || fail "not root: run 'adb root' first"

# Android's /data mount is shared, so mounts made inside the namespace propagate back to the host
# mount table and survive namespace exit. Sweep them (lazy unmount) before AND after the run so the
# staging dirs are never stale mountpoints (that is what made init's own proc/sysfs mounts EBUSY).
clean_leaks() {
  toybox mount | awk '{print $3}' | grep -E '^/data/local/tmp/hu_test' | sort -r |
    while read m; do toybox umount -l "$m" 2>/dev/null; done
}
# Read-only fingerprint of the partitions the payload init could plausibly touch. If any of these
# changes across a run, the harness leaked a write into the real eMMC and must be stopped.
guard_hashes() {
  for p in 7 12 14 15; do
    echo "  mmcblk2p$p $(toybox dd if=/dev/block/mmcblk2p$p bs=4096 count=1 2>/dev/null | toybox sha256sum | cut -c1-16)"
  done
}
clean_leaks
echo "harness: pre-run leak sweep done"
echo "=== real-partition fingerprints BEFORE ==="
guard_hashes

[ -f "$IMG" ] || fail "missing $IMG (assemble it: see virt-layout.txt)"
size=$(toybox ls -l "$IMG" | awk '{print $5}')
[ "$size" = "$NEED_BYTES" ] || fail "virt.img is $size bytes, expected $NEED_BYTES"
[ -f "$HT/hu_harness_inner.sh" ] || fail "missing $INNER"
[ -f "$HT/root-init" ] || fail "missing $HT/root-init (payload first-stage init)"
[ -f "$HT/fstab.rk30board" ] || fail "missing $HT/fstab.rk30board"

# Harness fstab: the non-super rows point at hu-prefixed names, which exist ONLY as GPT PARTNAMEs
# inside virt.img - the real mmc partitions do not carry those names, so init can never resolve
# them to the eMMC. super keeps its exact name (logical rows require it); for super the seeder below
# tries to make /dev/block/by-name/super point at the loop partition before init's symlink pass,
# and if the mmc partition wins the fallback is a read-only super read (superio never writes).
sed -e 's|/dev/block/by-name/metadata|/dev/block/by-name/humetadata|' \
    -e 's|/dev/block/by-name/cache|/dev/block/by-name/hucache|' \
    -e 's|/dev/block/by-name/boot|/dev/block/by-name/huboot|' \
    -e 's|/dev/block/by-name/recovery|/dev/block/by-name/hurecovery|' \
    -e 's|/dev/block/by-name/misc|/dev/block/by-name/humisc|' \
    -e 's|/dev/block/by-name/userdata|/dev/block/by-name/huuserdata|' \
    "$HT/fstab.rk30board" > "$HT/fstab-harness.rk30board"

# HU_NO_LOGICAL=1 comments out the logical rows (system/vendor/product/system_ext/odm): the run
# then exercises only init's namespace setup + the virtual non-super partitions. Logical mounts are
# the heavy/fragile part (device-mapper targets over a loop file, payload filesystem reads) and the
# Nov 18 runs that reached them rebooted the unit.
if [ "$HU_NO_LOGICAL" = 1 ]; then
  sed -E '/logical/ s/^/#/' "$HT/fstab-harness.rk30board" > "$HT/fstab-harness-nolog.rk30board"
  cp "$HT/fstab-harness-nolog.rk30board" "$HT/fstab-harness.rk30board"
  echo "harness: HU_NO_LOGICAL set - logical rows disabled"
fi

# Attach the image to the loop slot if it is not attached yet (partition nodes present == attached).
if ! toybox ls "$LOOP"p1 >/dev/null 2>&1; then
  toybox losetup "$LOOP" "$IMG" || fail "losetup $LOOP failed"
  toybox sleep 1
fi
toybox ls "$LOOP"p7 >/dev/null 2>&1 || fail "$LOOP has no partition nodes (loop.max_part?)"

echo "=== virtual partitions as the kernel sees them ==="
for p in 1 2 3 4 5 6 7; do
  echo "  loop9p$p: $(toybox cat /sys/block/loop9/loop9p$p/uevent 2>/dev/null | tr '\n' ' ')"
done

echo "=== running namespace harness (init gets 8 s, then is killed) ==="
# Host-side by-name seeding: Android's /data is a shared mount, so init's tmpfs /dev appears here
# the instant it is mounted, while the namespace still lives. init's MakeDeviceSymlinks uses plain
# symlink() and skips existing names, and the mmc partitions are scanned first - so without this,
# by-name resolves to the real eMMC (observed: init mounted mmcblk2p12 for metadata). Seeding the
# names pointing at the loop partitions makes the virtual map win. Inside the namespace the seed
# cannot run: init umounts /data and the staging tmpfs, so /proc/<pid>/root stops resolving.
SEED_NAMES="super:loop9p1"
( while :; do
    toybox mkdir -p "$HT/root/dev/block/by-name" 2>/dev/null
    i=1
    for pair in $SEED_NAMES; do
      n=${pair%%:*}; d=${pair##*:}
      # init builds nodes AFTER its symlink pass, so by-name targets must exist as nodes already.
      toybox mknod "$HT/root/dev/block/$d" b 7 $((72 + i)) 2>/dev/null
      toybox ln -sf "/dev/block/$d" "$HT/root/dev/block/by-name/$n" 2>/dev/null
      i=$((i + 1))
    done
  done ) &
SD=$!
toybox unshare -mp sh "$INNER"
kill -9 "$SD" 2>/dev/null

# init exits early (first-stage mount fails -> abort), so the post-mortem is read here, in the host
# namespace: the namespace's mounts leak back through Android's shared /data mount and stay readable
# until the sweep below.
echo "=== post-mortem by-name map (virtual == loop9, danger == mmcblk) ==="
toybox ls -l "$HT/root/dev/block/by-name" 2>&1
echo "=== payload mounts visible from the host ==="
toybox mount | grep -E "$HT/root/(dev|proc|sys|mnt|metadata|cache|data|system|vendor|product|system_ext|odm|debug_ramdisk|second_stage_resources)|super" | head -25
echo "=== what first-stage mount produced ==="
for d in system vendor product system_ext odm metadata cache data; do
  echo "  $d: $(toybox ls "$HT/root/$d" 2>&1 | head -4 | tr '\n' ' ')"
done
echo "namespace rc=$?"

echo "=== namespace process list while leaked (did any payload service run?) ==="
for p in $(toybox ls "$HT/root/proc" 2>/dev/null | grep -E '^[0-9]+$'); do
  echo "  pid $p: $(toybox cat "$HT/root/proc/$p/cmdline" 2>/dev/null | tr '\0' ' ' | head -c 90)"
done
echo "=== dm devices seen by the kernel (payload targets?) ==="
toybox ls /sys/block | grep '^dm-' | while read d; do echo "  $d: $(toybox cat /sys/block/$d/dm/name 2>/dev/null)"; done

echo "=== kernel tail after the run ==="
toybox dmesg | tail -40

echo "=== real-partition fingerprints AFTER (must match BEFORE) ==="
guard_hashes

clean_leaks
echo "=== harness finished; post-run leak sweep done; real partitions untouched, unit not rebooted ==="
