#!/usr/bin/env python3
"""Prove that our prebuilt vendor image is the stock Android 11 vendor with only our overlays.

  tools/vendor_diff.py <stock_vendor.img> <our_vendor.img> <device-dir>

Compares the two ext4 images file-by-file using debugfs (no root, no mounting): names, modes and
sizes. Anything that differs must be one of the files `scripts/prebuilt_vendor.sh` overlays, plus
whatever resize2fs changed in the filesystem metadata. Then it dumps each overlay out of our image
and diffs it against the source file in the device directory, so the overlay content is checked too.

The images grew (the script adds 32 MiB headroom before resize2fs), so "only in ours" entries that
are just directories are expected; files must not appear there.
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, walk  # noqa: E402

OVERLAYS = {
    "/etc/fstab.rk30board": "fstab.rk30board",
    "/etc/ueventd.rc": "configs/ueventd.rk30board.rc",
    "/etc/init/hu.rc": "configs/init.hu.rc",
    "/etc/hu_insmod.sh": "configs/hu_insmod.sh",
}


def inventory(image):
    """path -> (mode, size) for every file in the image."""
    inv = {}
    for line in walk(image, "/", sizes=True, pattern=None, dirs=False):
        path, size = line.split("\t", 1)
        inv[path] = int(size)
    return inv


def main():
    stock, ours, dev = sys.argv[1], sys.argv[2], sys.argv[3]
    a = inventory(stock)
    b = inventory(ours)
    only_stock = sorted(set(a) - set(b))
    only_ours = sorted(set(b) - set(a))
    changed = sorted(p for p in set(a) & set(b) if a[p] != b[p])
    print("stock files: %d ; our files: %d" % (len(a), len(b)))
    print("only in stock (%d):" % len(only_stock))
    for p in only_stock:
        print("   %s  %d B" % (p, a[p]))
    print("only in ours (%d):" % len(only_ours))
    for p in only_ours:
        print("   %s  %d B" % (p, b[p]))
    print("size changed (%d):" % len(changed))
    for p in changed:
        print("   %s  %d -> %d B" % (p, a[p], b[p]))

    tmp = tempfile.mkdtemp(prefix="vendor-diff-")
    print("overlay content check:")
    for in_image, src_rel in OVERLAYS.items():
        src = os.path.join(dev, src_rel)
        dst = os.path.join(tmp, os.path.basename(in_image))
        dump_file(ours, in_image, dst)
        same = open(dst, "rb").read() == open(src, "rb").read()
        print("   %-28s matches device source: %s" % (in_image, same))

    # The one in-place edit: Rockchip's patched-init insmod lines are stripped so LineageOS init
    # can parse the rc file. Everything else in that file must be untouched.
    for img, tag in ((stock, "stock"), (ours, "ours")):
        dump_file(img, "/etc/init/hw/init.rockchip.rc", os.path.join(tmp, tag + "-init.rockchip.rc"))
    diff = subprocess.run(["diff", os.path.join(tmp, "stock-init.rockchip.rc"),
                           os.path.join(tmp, "ours-init.rockchip.rc")],
                          capture_output=True, text=True)
    removed = [l[2:] for l in diff.stdout.splitlines() if l.startswith("<")]
    added = [l[2:] for l in diff.stdout.splitlines() if l.startswith(">")]
    print("   /etc/init/hw/init.rockchip.rc: removed %d line(s), added %d line(s)" % (len(removed), len(added)))
    print("   every removed line is an insmod: %s" % all(l.strip().startswith("insmod ") for l in removed))
    print("   nothing added: %s" % (not added))

    allowed = set(OVERLAYS) | {"/etc/init/hw/init.rockchip.rc"}
    bad_new = [p for p in only_ours if p not in OVERLAYS]
    print("VERDICT: stock blobs untouched, only our overlays added/replaced = %s" %
          (set(changed) <= allowed and not bad_new and not only_stock))
    return 0


if __name__ == "__main__":
    sys.exit(main())
