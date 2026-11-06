#!/usr/bin/env python3
"""Which libraries do the kept Rockchip vendor blobs link against, and are those libraries the
ones the build replaces?

  tools/blob_deps.py <vendor-tree-dir> [<drop-list-file>]

For every ELF under the staged vendor tree that is *not* in the drop list, read the DT_NEEDED
entries and the undefined symbols it expects, then report how many of those dependencies are
destinations the build installs itself (Android 14's own build of libdrm/libchrome/libusb/...).
That is the ABI risk: a Rockchip HAL that needs a symbol the AOSP-built library no longer exports
fails at runtime, quietly, when the HAL is loaded.
"""
import os
import re
import subprocess
import sys

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


def needed_and_undefs(path):
    try:
        out = subprocess.run([READELF, "-d", path], capture_output=True, text=True).stdout
    except OSError:
        return [], []
    needed = re.findall(r"\(NEEDED\)\s+Shared library: \[([^]]+)\]", out)
    try:
        syms = subprocess.run([READELF, "--dyn-syms", path], capture_output=True, text=True).stdout
    except OSError:
        syms = ""
    undefs = [m.group(2) for m in re.finditer(r"\s+(\d+):\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+UND\s+(\S+)", syms)]
    return needed, [u for u in undefs if u and not u.startswith("_ZTIS")]


def main():
    root = sys.argv[1]
    drop = set()
    if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
        drop = {line.split("#", 1)[0].strip() for line in open(sys.argv[2])
                if line.strip() and not line.strip().startswith("#")}

    staged = {os.path.basename(rel) for rel in elf_files(root)}
    kept = [rel for rel in sorted(elf_files(root)) if rel not in drop]
    print("ELF files staged: %d ; kept as blobs: %d ; dropped (build installs): %d"
          % (len(staged), len(kept), len(staged) - len(kept)))

    replaced = {}
    for rel in kept:
        needed, _undefs = needed_and_undefs(os.path.join(root, rel))
        for lib in needed:
            # A NEEDED soname is resolved in /vendor/lib(64)/; if that path is one the build
            # installs, the blob gets Android 14's build of it.
            if lib in drop:
                replaced.setdefault(lib, []).append(rel)

    print("\nkept blobs whose DT_NEEDED points at a library the build replaces (%d libraries):"
          % len(replaced))
    for lib, users in sorted(replaced.items()):
        print("   %-30s used by %d blob(s)" % (lib, len(users)))
        for rel in users[:6]:
            print("      %s" % rel)
        if len(users) > 6:
            print("      ... %d more" % (len(users) - 6))

    # Libraries a kept blob needs that are neither staged nor installed -> it would not load.
    installed = set()
    if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
        installed = {os.path.basename(line.strip()) for line in open(sys.argv[3])
                     if line.strip().startswith("out/target/product/") and "/vendor/" in line}
    missing = {}
    for rel in kept:
        needed, _ = needed_and_undefs(os.path.join(root, rel))
        for lib in needed:
            if lib not in staged and lib not in installed and not lib.startswith("libc."):
                missing.setdefault(lib, []).append(rel)
    if missing:
        print("\nNEEDED but present nowhere under /vendor (would fail to load): %d libraries" % len(missing))
        for lib, users in sorted(missing.items()):
            print("   %-30s needed by %s" % (lib, ", ".join(sorted(users)[:4])))
    else:
        print("\nNEEDED but missing: none (every DT_NEEDED resolves in /vendor or in the build's own list)")


if __name__ == "__main__":
    sys.exit(main())
