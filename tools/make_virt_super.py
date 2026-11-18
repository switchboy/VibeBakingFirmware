#!/usr/bin/env python3
"""Build a GPT-wrapped container whose partitions carry the payload, so Android 14's first-stage
init can be run against PARTITION NAMES that live in a file instead of the eMMC (the harness that
**D59** froze Nov 18, and that **D64** must make safe before it ever runs again).

  python3 tools/make_virt_super.py <super.img> <out-dir>

Why: the unit boots Android 10 while `boot`/`super` hold our payload, so we cannot reboot into the
payload and still keep adb. The alternative is to run Android 14's own first-stage init under Android
10, in a private mount namespace, against a loop device whose GPT partition names are exactly the ones
the fstab asks for (super/metadata/cache/boot/recovery/misc/userdata). init resolves partitions by
PARTNAME out of uevents, so a GPT inside a file is a real partition to init - a "virtual partition".

Outputs (all in <out-dir>):
  virt-gpt.bin     the first 1 MiB of the image: protective MBR + primary GPT header + entries
  virt-backup.bin  the last 33 sectors: backup GPT entry array + backup header
  virt-layout.txt  tab-separated assembly recipe: name, start-sector, sector-count, bytes
The image itself is assembled ON THE UNIT from these two blobs + the payload super image already
pushed there, so no 4 GB goes over adb twice. Nothing here touches a device.

Sizes mirror the real eMMC layout measured Nov 18 (super 3,263,168,512 B, metadata 16 MiB, cache
384 MiB, boot 32 MiB, recovery 32 MiB, misc 1 MiB) and add a 512 MiB userdata so a later second-stage
run can format /data in the file instead of the real partition.
"""
import os
import subprocess
import sys

SECTOR = 512
LEADING_SECTORS = 2048          # 1 MiB of GPT region; data starts here
PARTITIONS = [                  # contiguous from LEADING_SECTORS, in fstab order. The names other
                                # than super are hu-prefixed on purpose: Android 10's init already
                                # maps those PARTNAMEs to the real mmc partitions, and init's
                                # MakeDeviceSymlinks skips names that exist - so a colliding name
                                # resolves to the REAL partition. "super" stays exact because the
                                # logical rows need that name; for super the harness seeds the
                                # symlink host-side and the mmc fallback is a read-only super read.
    ("super", 3263168512),      # the payload container itself
    ("humetadata", 16 * 1024 * 1024),
    ("hucache", 384 * 1024 * 1024),
    ("huboot", 32 * 1024 * 1024),
    ("hurecovery", 32 * 1024 * 1024),
    ("humisc", 1 * 1024 * 1024),
    ("huuserdata", 512 * 1024 * 1024),
]
BACKUP_SECTORS = 33             # backup entry array (32) + backup header (1)


def main():
    super_img, out = sys.argv[1], sys.argv[2]
    super_bytes = os.path.getsize(super_img)
    if super_bytes != PARTITIONS[0][1]:
        raise SystemExit("super image is %d B, the layout expects %d B" % (super_bytes, PARTITIONS[0][1]))

    os.makedirs(out, exist_ok=True)
    virt = os.path.join(out, "virt.img")
    sectors = LEADING_SECTORS + sum(b // SECTOR for _, b in PARTITIONS) + BACKUP_SECTORS
    size = sectors * SECTOR

    # Sparse file: only the GPT regions get written; sgdisk computes the CRCs for us.
    if os.path.exists(virt):
        os.remove(virt)
    with open(virt, "wb") as f:
        f.seek(size - 1)
        f.write(b"\0")

    args = ["sgdisk"]
    n = 1
    start = LEADING_SECTORS
    for name, b in PARTITIONS:
        count = b // SECTOR
        args += ["-n", "%d:%d:%d" % (n, start, start + count - 1), "-c", "%d:%s" % (n, name)]
        start += count
        n += 1
    args.append(virt)
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("sgdisk failed: %s" % (r.stdout + r.stderr).strip()[:300])

    gpt = os.path.join(out, "virt-gpt.bin")
    bak = os.path.join(out, "virt-backup.bin")
    with open(virt, "rb") as f:
        f.seek(0)
        open(gpt, "wb").write(f.read(LEADING_SECTORS * SECTOR))
        f.seek(size - BACKUP_SECTORS * SECTOR)
        open(bak, "wb").write(f.read(BACKUP_SECTORS * SECTOR))

    # The assembly recipe the on-unit script follows. Fill = the zero region between super and the
    # backup blob; the unit writes it with dd, so the numbers must be exact multiples of dd's block.
    fill_bytes = size - LEADING_SECTORS * SECTOR - super_bytes - BACKUP_SECTORS * SECTOR
    if fill_bytes % 4096:
        raise SystemExit("fill region %d B is not a multiple of 4096" % fill_bytes)

    layout = os.path.join(out, "virt-layout.txt")
    with open(layout, "w") as f:
        f.write("# name\tstart_sector\tsectors\tbytes\n")
        start = LEADING_SECTORS
        for name, b in PARTITIONS:
            f.write("%s\t%d\t%d\t%d\n" % (name, start, b // SECTOR, b))
            start += b // SECTOR
        f.write("# assembly: gpt=%d B, super=%d B, fill=%d B (bs=4096 count=%d), backup=%d B\n" % (
            LEADING_SECTORS * SECTOR, super_bytes, fill_bytes, fill_bytes // 4096,
            BACKUP_SECTORS * SECTOR))
        f.write("# total %d B\n" % size)

    print("virt.img %d B (%d sectors), partitions:" % (size, sectors))
    start = LEADING_SECTORS
    for name, b in PARTITIONS:
        print("  %-9s byte %d  %d B" % (name, start * SECTOR, b))
        start += b // SECTOR
    for p in (gpt, bak, layout):
        print("  %-16s %d B  %s" % (os.path.basename(p), os.path.getsize(p), p))


if __name__ == "__main__":
    main()
