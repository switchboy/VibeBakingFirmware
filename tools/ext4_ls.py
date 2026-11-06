#!/usr/bin/env python3
"""Recursively list files inside an ext4 image using debugfs (no root, no mounting).

debugfs `ls -l` prints: <inode> <mode> (<links>) <uid> <gid> <size> <date> <time> <name>

Usage: ext4_ls.py <image> [start_dir] [--sizes] [--filter PATTERN] [--dirs]
"""
import argparse
import os
import re
import subprocess
import sys


def debugfs(image: str, command: str) -> str:
    res = subprocess.run(["debugfs", "-R", command, image], capture_output=True, text=True)
    if res.returncode != 0 and res.stderr:
        raise RuntimeError(f"debugfs {command!r} failed: {res.stderr.strip()}")
    return res.stdout


def parse_ls(line: str):
    """-> (name, mode, size, is_dir) or None for unparsable lines."""
    parts = line.split()
    if len(parts) < 9:
        return None
    inode, mode, links, uid, gid, size, date, time = parts[:8]
    name = " ".join(parts[8:])
    if not re.fullmatch(r"[0-7]{3,6}", mode) or not links.startswith("("):
        return None
    return name, mode, int(size), (int(mode, 8) & 0o170000) == 0o040000


def list_dir(image: str, path: str):
    out = debugfs(image, f'ls -l "{path}"')
    entries = []
    for line in out.splitlines():
        parsed = parse_ls(line)
        if parsed and parsed[0] not in (".", ".."):
            entries.append(parsed)
    return entries


def dump_file(image: str, path: str, out_path: str):
    # debugfs resolves "//etc/x" and "///etc/x" as *not found* but still exits 0 and prints the
    # error to stderr, so collapse the leading slashes and check the file really appeared.
    norm = "/" + path.lstrip("/")
    res = subprocess.run(["debugfs", "-R", f'dump "{norm}" "{out_path}"', image],
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"dump {path} failed: {res.stderr.strip()}")
    if not os.path.isfile(out_path) or os.path.getsize(out_path) == 0:
        raise RuntimeError(f"dump {path} produced no file ({res.stderr.strip()})")


def walk(image: str, root: str, sizes: bool, pattern: str | None, dirs: bool):
    rx = re.compile(pattern) if pattern else None
    queue = [root]
    seen = []
    while queue:
        path = queue.pop(0)
        for name, mode, size, is_dir in list_dir(image, path):
            full = f"{path.rstrip('/')}/{name}"
            if is_dir:
                if dirs:
                    seen.append(full + "/")
                queue.append(full)
            else:
                if rx is None or rx.search(full):
                    seen.append(f"{full}\t{size}" if sizes else full)
    return sorted(seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("start", nargs="?", default="/")
    ap.add_argument("--sizes", action="store_true")
    ap.add_argument("--dirs", action="store_true", help="include directories in output")
    ap.add_argument("--filter", help="regex filter on the full path")
    args = ap.parse_args()
    for line in walk(args.image, args.start, args.sizes, args.filter, args.dirs):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
