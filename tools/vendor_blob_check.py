#!/usr/bin/env python3
"""Compare the vendor blob hashes a live probe reported against a reference firmware image.

  tools/vendor_blob_check.py <probe-report.md> <vendor.img> [--system IMG --product IMG --odm IMG] [--out FILE]

The probe (scripts/probe.sh) runs `sha256sum` on /vendor/bin/hw/*, /vendor{,64}/hw/*.so,
/vendor/lib/modules/*.ko and the key config files, and writes those lines into its report. This tool
re-reads the same paths out of the reference ext4 images with debugfs (no root, no mounting) and
hashes them, so we can say whether the live vendor is byte-for-byte the reference vendor - which is
what closes the P1 gap in agentPlan.md and settles the "installed firmware is not the reference ROM"
risk.

Output categories:
  identical   live hash == reference hash
  differ      both exist, bytes differ (live hash and reference hash are printed)
  live-only   path exists on the unit, not in the reference image
  unreadable  debugfs could not read it (in a stock vendor most of these are the toybox alias
              symlinks and the egl aliases, which have no content of their own)

Only the paths the probe hashed are compared; the reference tree is not walked, so a file the probe
did not list is not reported as missing from the unit.

Exit status is 0 when every hashed path is identical, 1 otherwise, so this can gate a flash.
"""
import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

HASH_LINE = re.compile(r"^([0-9a-f]{64})\s+(.+)$")


def debugfs_sha256(image: str, path: str, scratch: str) -> str | None:
    """sha256 of `path` inside `image`, or None if debugfs cannot read it (symlink, missing).

    `debugfs -R cat` prints its own version banner on stdout, so the bytes are dumped to a scratch
    file and hashed there; `cat` through a pipe hashes the banner plus the file.
    """
    res = subprocess.run(["debugfs", "-R", f"dump {path} {scratch}", image], capture_output=True)
    if res.returncode != 0 or not os.path.exists(scratch):
        return None
    import hashlib

    h = hashlib.sha256()
    with open(scratch, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    os.remove(scratch)
    return h.hexdigest()


def parse_report(report: str) -> dict[str, str]:
    """-> {absolute path on the unit: live sha256}, from the probe's vendor blob inventory section."""
    lines = open(report, encoding="utf-8", errors="replace").read().splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith("## Vendor blob inventory")), None)
    if start is None:
        sys.exit(f"{report}: no '## Vendor blob inventory' section - is this a probe report?")
    out: dict[str, str] = {}
    for line in lines[start:]:
        m = HASH_LINE.match(line.strip())
        if m and m.group(2).startswith("/"):
            out[m.group(2)] = m.group(1)
        if line.startswith("## ") and out:
            break
    if not out:
        sys.exit(f"{report}: vendor blob inventory produced no sha256 lines (sha256sum missing?)")
    return out


def image_for(path: str, images: dict[str, str]) -> tuple[str, list[str]] | None:
    """-> (image, candidate paths inside image) for an on-device absolute path, or None if none covers it.

    A partition image (vendor/product/odm) is rooted at the partition, so `/vendor/x` is `/x` inside
    it. The Android 10 reference `system.img` in analysis/ is a rootfs layout that still has a
    `system/` directory, so `/system/x` is `/system/x` there. Both forms are tried, in that order.
    """
    top = path.split("/")[1]  # vendor / system / product / odm
    img = images.get(top)
    if not img:
        return None
    return img, [path[len(f"/{top}") :] or "/", path]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("vendor")
    ap.add_argument("--system")
    ap.add_argument("--product")
    ap.add_argument("--odm")
    ap.add_argument("--out", help="write the per-path verdict as TSV")
    args = ap.parse_args()

    images = {"vendor": args.vendor}
    for top, img in (("system", args.system), ("product", args.product), ("odm", args.odm)):
        if img:
            images[top] = img
    for img in images.values():
        if not os.path.exists(img):
            sys.exit(f"missing reference image: {img}")

    live = parse_report(args.report)
    scratch_dir = os.environ.get("TMPDIR", "/run/media/Daan/Opslagmonster/a14-work/scratch")
    os.makedirs(scratch_dir, exist_ok=True)
    scratch = os.path.join(scratch_dir, "vendor-blob-scratch.bin")
    hashed: dict[str, str] = {}
    unreadable: list[str] = []
    for path in live:
        mapped = image_for(path, images)
        if mapped is None:
            continue
        img, candidates = mapped
        for inner in candidates:
            ref = debugfs_sha256(img, inner, scratch)
            if ref is not None:
                hashed[path] = ref
                break
        else:
            unreadable.append(path)

    identical = sorted(p for p in hashed if hashed[p] == live[p])
    differ = sorted(p for p in hashed if hashed[p] != live[p])
    live_only = sorted(p for p in live if p not in hashed and p not in unreadable)

    by_dir: dict[str, list[str]] = defaultdict(list)
    for p in differ:
        by_dir[os.path.dirname(p)].append(p)

    rows = []
    for p in sorted(hashed) + live_only:
        if p in identical:
            verdict, ref = "identical", live[p]
        elif p in differ:
            verdict, ref = "differ", hashed[p]
        else:
            verdict, ref = "live-only", "-"
        rows.append(f"{verdict}\t{p}\t{live[p]}\t{ref}")

    if args.out:
        with open(args.out, "w") as f:
            f.write("verdict\tpath\tlive_sha\treference_sha\n")
            f.write("\n".join(rows) + "\n")

    print(f"hashed {len(hashed)} paths ({len(identical)} identical, {len(differ)} differ, "
          f"{len(live_only)} live-only); {len(unreadable)} unreadable in the reference image")
    for d in sorted(by_dir):
        print(f"  differ in {d}: {len(by_dir[d])}")
    for p in differ:
        print(f"    {p}  live {live[p][:12]} ref {hashed[p][:12]}")
    for p in live_only:
        print(f"    live-only {p}")
    if unreadable:
        print(f"  unreadable (symlink aliases / not present): {len(unreadable)}")
    return 0 if not differ and not live_only else 1


if __name__ == "__main__":
    sys.exit(main())
