#!/usr/bin/env python3
"""Which libraries do the kept Rockchip vendor blobs link against, and does the built image really
provide them?

  tools/blob_deps.py <vendor-tree-dir> [<drop-list-file>] \
                     [<built-vendor.img> | <installed-files-vendor.txt>] [<vendor_dest_keep.txt>]

vendor_dest_keep.txt names the destinations that are in the drop list (Soong defines a rule, so the
blob cannot be copied) but that scripts/inject_vendor_blobs.sh writes into /vendor anyway: those
sonames resolve and are not reported as "the build replaces them".

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
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
    """Drop destinations and injected destinations, as partition-relative paths and bare names.
    vendor_dest_keep.txt is tab-separated (<path>\t<source>\t<reason>), so only the first field counts."""
    rels, names = set(), set()
    for path in files:
        if not os.path.exists(path):
            continue
        for line in open(path, errors="replace"):
            s = line.split("#", 1)[0].split("\t")[0].strip()
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


def arch_root(d):
    """Which directory the dynamic loader searches for a blob's DT_NEEDED sonames. A module in
    lib64/hw is dlopen'd from that directory, but its NEEDED libraries come from /vendor/lib64 (and
    /odm), not from lib64/hw; the first version of this tool looked in the blob's own directory and
    reported libutils/libz/libui/libtinyalsa as missing for every HAL impl."""
    if d.startswith("lib64"):
        return "lib64"
    if d.startswith("lib"):
        return "lib"
    if d == "bin/hw":
        return "lib64"
    if d == "bin":
        return "lib"
    return None


def public_libs(image_arg):
    """Sonames the vendor namespace may load straight out of /system. linkerconfig builds ld.config.txt
    at boot from system/etc/linker.config.pb, whose public_libs list is what sibling namespaces can
    resolve; those libraries need no copy in /vendor (liblog.so, libc.so, libsync.so, libEGL.so ...)."""
    if not image_arg or not image_arg.endswith(".img"):
        return set()
    pb = os.path.join(os.path.dirname(image_arg), "system", "etc", "linker.config.pb")
    if not os.path.isfile(pb):
        return set()
    return {m.decode() for m in re.findall(rb"[ -~]+\.so", open(pb, "rb").read())}


def main():
    root = sys.argv[1]
    drop_rels, drop_names = drop_paths(sys.argv[2:3])
    # Injected anyway (Android 14 has no vendor variant for them): they exist in /vendor, so a blob
    # that needs them loads fine. Do not call those "replaced by the build".
    keep_rels, keep_names = drop_paths(sys.argv[4:5]) if len(sys.argv) > 4 else (set(), set())
    inv = inventory(sys.argv[3]) if len(sys.argv) > 3 else set()
    public = public_libs(sys.argv[3] if len(sys.argv) > 3 else "")

    all_rels = sorted(elf_files(root))
    staged_rels = set(all_rels)
    kept = [rel for rel in all_rels if rel not in drop_rels]
    print("ELF files staged: %d ; kept as blobs: %d ; dropped (build installs): %d ; public libraries: %d"
          % (len(all_rels), len(kept), len(all_rels) - len(kept), len(public)))
    if not inv:
        print("no post-build inventory given - the 'resolves' answer below is unverifiable")

    # A staged blob that is in the drop list never lands in /vendor, so it cannot satisfy a NEEDED
    # soname: only the build's own file (if it materialised) or an injected copy can.
    staged_kept = {r for r in staged_rels if r not in drop_rels}
    resolved_public = set()
    replaced, missing = {}, {}
    for rel in kept:
        d = os.path.dirname(rel)
        arch = arch_root(d)
        other = "lib64" if arch == "lib" else "lib"
        for lib in needed(os.path.join(root, rel)):
            if lib.startswith("libc.") or lib in ("libc.so", "libm.so", "libdl.so"):
                continue                          # provided by the bionic vendor variant
            cands = [os.path.join(r, lib) for r in (arch, other) if r]
            if any(c in inv for c in cands):
                continue                          # present in the built /vendor
            if any(c in keep_rels for c in cands):
                continue                          # injected into /vendor by inject_vendor_blobs.sh
            if any(c in staged_kept for c in cands):
                continue                          # kept as a staged vendor blob
            if lib in public:
                resolved_public.add(lib)          # loaded out of /system through the linker config
                continue
            if any(c in drop_rels for c in cands):
                # The build defines a rule for the path but never installed it, and Android 14 built
                # the library for /system only: neither the blob nor the module is in /vendor.
                replaced.setdefault(lib, []).append(rel)
                missing.setdefault(lib, []).append(rel)
                continue
            missing.setdefault(lib, []).append(rel)

    print("resolved through the vendor namespace's public /system libraries: %d (%s)"
          % (len(resolved_public), ", ".join(sorted(resolved_public)[:8])))

    if replaced:
        print("\nkept blobs whose DT_NEEDED lands on a library the build defines but did not install"
              " (%d libraries) - a rebuilt copy would differ in ABI:" % len(replaced))
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
