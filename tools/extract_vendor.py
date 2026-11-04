#!/usr/bin/env python3
"""Extract a filesystem tree out of an ext4 image into a directory (no root, debugfs only).

Used to turn the reference firmware's vendor.img into a vendor tree we can repackage
(blobs + configs, no rebuild). Symlinks are recorded as text files; special files are skipped.

Usage:
  extract_vendor.py <image> <outdir> [--prefix vendor] [--exclude PATTERN] [--skip-magisk]
"""
import argparse
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import debugfs, parse_ls  # noqa: E402


def list_dir(image, path):
    entries = []
    for line in debugfs(image, f'ls -l "{path}"').splitlines():
        parsed = parse_ls(line)
        if parsed and parsed[0] not in (".", ".."):
            entries.append(parsed)
    return entries


def extract(image, outdir, prefix, exclude, skip_magisk, root="/"):
    rx = re.compile(exclude) if exclude else None
    outdir = os.path.join(outdir, prefix)
    os.makedirs(outdir, exist_ok=True)
    queue = [root]
    copied = 0
    skipped = 0
    links = []
    while queue:
        path = queue.pop(0)
        rel = os.path.normpath(path).lstrip("/")
        local = os.path.join(outdir, rel)
        for name, mode, size, is_dir in list_dir(image, path):
            full = f"{path.rstrip('/')}/{name}"
            rel_full = os.path.normpath(f"{rel}/{name}") if rel not in ("", ".") else name
            target = os.path.join(outdir, rel_full)
            if skip_magisk and rel_full.startswith("magisk"):
                skipped += 1
                continue
            if rx and rx.search(rel_full):
                skipped += 1
                continue
            if is_dir:
                os.makedirs(target, exist_ok=True)
                queue.append(full)
                continue
            st_mode = int(mode, 8)
            if st_mode & 0o170000 in (0o060000, 0o020000):  # fifo/socket/char/block
                skipped += 1
                continue
            if st_mode & 0o170000 == 0o120000:  # symlink: dump gives the target string
            # record it as a sidecar so packaging can recreate it
                tmp = target + ".link"
                debugfs(image, f'dump "{full}" "{tmp}"')
                links.append(rel_full)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            debugfs(image, f'dump "{full}" "{target}"')
            copied += 1
    print(f"{image}: copied {copied} files, skipped {skipped}, symlinks recorded {len(links)} -> {outdir}")
    return copied


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("outdir")
    ap.add_argument("--prefix", default="vendor", help="partition name used as top-level dir")
    ap.add_argument("--exclude", help="regex to skip paths (relative to partition root)")
    ap.add_argument("--skip-magisk", action="store_true", help="drop magisk/ from the extract")
    args = ap.parse_args()
    extract(args.image, args.outdir, args.prefix, args.exclude, args.skip_magisk)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
