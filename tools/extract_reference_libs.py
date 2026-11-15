#!/usr/bin/env python3
"""Copy specific libraries out of a reference firmware image into the device folder.

  tools/extract_reference_libs.py <device-dir> <image>... <libs> [--arch lib64|lib]

`libs` is a comma-separated list of sonames, e.g. `librkisp.so,libteec.so`.

This is the last resort, and on a converged build nothing needs it: tools/vendor_link_closure.py
answers almost every `DT_NEEDED` of a kept Rockchip blob with Android 14's own
`<name>.vendor` module (vendor_modules_extra.mk) or with a public library that loads straight out of
/system. The remaining case is a library Android 14 does not build at all - a Rockchip vendor
library such as `librilutils.so` or `librkisp.so` that only exists in the factory firmware. Those go
in `<device-dir>/prebuilt_vendor_libs/<arch>/`, which the closure lists in vendor_dest_keep.txt and
scripts/inject_vendor_blobs.sh writes into /vendor.

The image may be Android sparse (magic 0xED26FF3A, which reads `3a ff 26 ed`): debugfs cannot read
that at all, so it is converted with the build tree's simg2img first. Pass --simg2img if the build
tree is not next to the image.

Every extracted file is checked to be an ELF whose SONAME matches the requested soname, so a
32-bit copy cannot be dropped into /vendor/lib64 by mistake. Files already present are left alone
unless --force.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, walk  # noqa: E402

SPARSE_MAGIC = b"\x3a\xff\x26\xed"


def as_raw(image, simg2img, tmp):
    """Path debugfs can read: a raw ext4 image (sparse images are converted into tmp)."""
    if open(image, "rb").read(4) != SPARSE_MAGIC:
        return image
    if not simg2img:
        raise SystemExit("%s is Android sparse and no simg2img was found; pass --simg2img <path>" % image)
    raw = os.path.join(tmp, os.path.basename(image) + ".raw")
    res = subprocess.run([simg2img, image, raw], capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit("simg2img %s failed: %s" % (image, res.stderr.strip()))
    return raw


def find_simg2img(images, tree):
    for cand in (shutil.which("simg2img"),
                 os.path.join(tree or "", "out", "host", "linux-x86", "bin", "simg2img")):
        if cand and os.path.isfile(cand):
            return cand
    return None


def soname(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    m = re.search(r"\(SONAME\).*Shared library: \[([^]]+)\]", out)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("device_dir", help="the device folder, e.g. device/rk3399-px6-hct4")
    ap.add_argument("images", nargs="+", help="reference firmware vendor images to read")
    ap.add_argument("libs", help="comma-separated sonames to extract, e.g. librkisp.so,libteec.so")
    ap.add_argument("--arch", choices=("lib64", "lib"), default=None,
                    help="only look in this 64/32-bit directory (default: both)")
    ap.add_argument("--tree", help="lineage tree, used to find simg2img")
    ap.add_argument("--simg2img", help="explicit path to simg2img")
    ap.add_argument("--force", action="store_true", help="overwrite an existing copy")
    args = ap.parse_args()

    dest_root = os.path.join(args.device_dir, "prebuilt_vendor_libs")
    os.makedirs(dest_root, exist_ok=True)
    sonames = [s.strip() for s in args.libs.split(",") if s.strip()]
    tmp = tempfile.mkdtemp(prefix="extract_libs_")
    simg2img = find_simg2img(args.images, args.tree)
    arches = [args.arch] if args.arch else ["lib64", "lib"]

    # Read every image once, so the first one that has the soname wins and the report can say where
    # each file came from. Images are searched in the order given.
    # The arch directory is the *last* component of the path, so /lib(64)/<soname> in a vendor image
    # and /system/lib(64)/<soname> in an Android 10 system image (which has no VNDK APEX) both match.
    sources = {}
    for img in args.images:
        raw = as_raw(img, simg2img, tmp)
        for rel in walk(raw, "/", sizes=False, pattern=None, dirs=False):
            base = os.path.basename(rel)
            if base not in sonames:
                continue
            dirname = rel.lstrip("/").rsplit("/", 1)[0] if "/" in rel.lstrip("/") else ""
            arch = dirname.rsplit("/", 1)[-1] if dirname else dirname
            if arch not in arches:
                continue
            key = (base, arch)
            if key not in sources:
                sources[key] = (raw, rel.lstrip("/"), img)

    got, missing = [], []
    for want in sonames:
        placed = []
        for (base, arch), (raw, rel, img) in sorted(sources.items()):
            if base != want:
                continue
            out = os.path.join(dest_root, arch, base)
            if os.path.isfile(out) and not args.force:
                placed.append("%s/%s (already there)" % (arch, base))
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            dump_file(raw, rel, out + ".part")
            with open(out + ".part", "rb") as f:
                magic = f.read(4)
            if magic != b"\x7fELF":
                os.remove(out + ".part")
                print("  ! %s from %s: not an ELF (%s) - left out" % (rel, img, magic))
                continue
            real = soname(out + ".part")
            if real in (None, base):
                # Rockchip's vendor libraries usually carry no DT_SONAME at all; the loader then
                # uses the file name, which is exactly the path being copied to.
                os.replace(out + ".part", out)
                placed.append("%s/%s <- %s (%d B%s)" % (arch, base, rel, os.path.getsize(out),
                                                       "" if real else ", no DT_SONAME"))
            else:
                os.remove(out + ".part")
                print("  ! %s from %s: SONAME is %s, not %s - left out" % (rel, img, real, base))
                continue
        if placed:
            got.extend(placed)
        else:
            missing.append(want)

    shutil.rmtree(tmp, ignore_errors=True)
    print("extracted into %s:" % dest_root)
    for line in got:
        print("   ", line)
    if missing:
        print("\nnot found in the given images (%d): %s" % (len(missing), ", ".join(sorted(missing))))
        print("  Try the other reference images (analysis/images/assembled/, analysis/daisaita_a10/,\n"
              "  analysis/daisaita_a11/), or check whether Android 14 builds it at all - if it does,\n"
              "  tools/vendor_link_closure.py would have asked for its vendor variant instead.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
