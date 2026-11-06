#!/usr/bin/env python3
"""Which libraries do the kept Rockchip vendor blobs link against, and does the built image really
provide them?

  tools/blob_deps.py <vendor-tree-dir> [<drop-list-file>] [<built-vendor.img> | <installed-files-vendor.txt>]

For every ELF under the staged vendor tree that is *not* in the drop list, read the DT_NEEDED
entries, then resolve each soname the way the dynamic loader will: a blob installed in /vendor/lib64
searches /vendor/lib64, one in /vendor/lib searches /vendor/lib. Two answers come out:

  * which NEEDED sonames land on a path the build replaces (Android 14's own build of
    libdrm/libchrome/libusb/...), which is the ABI risk - a Rockchip HAL needing a symbol the
    rebuilt library no longer exports fails quietly when it is loaded;
  * which NEEDED sonames exist nowhere in /vendor, so the blob cannot load at all.

The third argument must be a *post-build inventory* - out/target/product/rk3399/installed-files-vendor.txt
or the built vendor.img. Soong's install *rules* are not usable here: they exist for modules this
product never pulls in, so a rule says "available" for a library that never lands in the image. That
is what the first version of this tool did with tmp/installed_vendor.txt, and it reported "nothing
missing" for exactly the case that matters (the kept keymaster/wifi services needing
libkeymaster4support.so and libwifi-hal.so, which pack20 did not install).
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file)))
from ext4_ls import walk  # noqa: E402

READELF = "readelf"


def elf_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as f:
                    head = f.read(4)
            except OSError:
                continue
            if head == b"\x7fELF":
                yield os.path.relpath(path, root)


def needed(path):
    try:
        out = subprocess.run([READELF, "-d", path], capture_output=True, text=True).stdout
    except OSError:
        return []
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^]]+)\]", out)


def drop_paths(files):
    """Drop-list destinations, as partition-relative paths and as bare file names."""
    rels, names = set(), set()
    for path in files:
        if not os.path.exists(path):
            continue
        for line in open(path, errors="replace"):
            s = line.split("#", 1)[0].strip()
            if s:
                rels.add(s)
                names.add(os.path.basename(s))
    return rels, names


def inventory(arg):
    """Partition-relative paths that exist in /vendor, from a built image or its file list."""
    if arg.endswith(".img"):
        return {line.split("\t", 1)[0].lstrip("/") for line in walk(arg, "/", sizes=False,
                                                                  pattern=None, dirs=False)}
    out = set()
    for line in open(arg, errors="replace"):
        m = re.search(r"/vendor/(\S+)$", line.strip())
        if m:
            out.add(m.group(1))
    return out


def main():
    root = sys.argv[1]
    drop_rels, drop_names = drop_paths(sys.argv[2:3])
    inv = inventory(sys.argv[3]) if len(sys.argv) > 3 else set()

    all_rels = sorted(elf_files(root))
    staged_rels = set(all_rels)
    staged_names = {os.path.basename(r) for r in all_rels}
    kept = [rel for rel in all_rels if rel not in drop_rels]
    print("ELF files staged: %d ; kept as blobs: %d ; dropped (build installs): %d"
          % (len(all_rels), len(kept), len(all_rels) - len(kept)))
    if not inv:
        print("no post-build inventory given - the 'resolves' answer below is unverifiable")

    replaced, missing = {}, {}
    for rel in kept:
        d = os.path.dirname(rel)
        for lib in needed(os.path.join(root, rel)):
            same_dir = os.path.join(d, lib) if d else lib
            if same_dir in drop_rels or lib in drop_names:
                replaced.setdefault(lib, []).append(rel)
                continue
            if same_dir in inv or same_dir in staged_rels:
                continue                                  # resolves in the same lib/lib64 dir
            if lib in inv or lib in staged_names:
                continue                                  # resolves, but in the other arch dir
            if lib.startswith("libc.") or lib in ("libc.so", "libm.so", "libdl.so"):
                continue                                  # provided by the bionic vendor variant
            missing.setdefault(lib, []).append(rel)

    print("\nkept blobs whose DT_NEEDED lands on a library the build replaces (%d libraries):"
          % len(replaced))
    for lib, users in sorted(replaced.items()):
        print("   %-32s used by %d blob(s)" % (lib, len(users)))
        for rel in sorted(users)[:6]:
            print("      %s" % rel)
        if len(users) > 6:
            print("      ... %d more" % (len(users) - 6))

    if missing:
        print("\nNEEDED but nowhere in /vendor (%d libraries) - these blobs would not load:" % len(missing))
        for lib, users in sorted(missing.items()):
            print("   %-32s needed by %s" % (lib, ", ".join(sorted(users)[:4])))
        print("\nFix: add the Android 14 module that installs that library to PRODUCT_PACKAGES, or\n"
              "restore the staged blob by removing the path from vendor_build_wins.txt.")
        return 1

    print("\nNEEDED but missing: none (every DT_NEEDED resolves in /vendor, in the staged tree, or in bionic)")
    return 0



if __name__ == "__main__":
    sys.exit(main())
