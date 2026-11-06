#!/usr/bin/env python3
"""Does the Android 11 vendor blob actually resolve its symbols on Android 14?

  tools/vendor_abi_check.py <lineage-tree> <device-dir> [<product-dir>]

A blob is kept (copied byte-for-byte) or replaced by an Android 14 module. Keeping it only works if
every symbol it needs is defined by something the *vendor* namespace can load:

  * files installed in /vendor (the built image, incl. Android 14's vendor variants)
  * the other kept staged blobs (Rockchip's own libraries link each other)
  * /system libraries listed as public in system/etc/linker.config.pb

Anything left over is a real ABI break: the HAL would fail to dlopen at boot, and the log line is
`dlopen failed: cannot locate symbol ...`. Symbol versions (`memcpy@@LIBC`) are stripped, since the
linker matches the base name.

Output: one line per blob with unresolved symbols, then the symbol names grouped by blob so the
break can be read. Exit 1 when a blob has unresolved symbols.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import walk  # noqa: E402

BIONIC = {"libc.so", "libm.so", "libdl.so", "libpthread.so"}
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^]]+)\]", out)


def undefined_symbols(fp):
    out = subprocess.run(["nm", "-D", "--undefined-only", fp], capture_output=True, text=True).stdout
    return {m.split()[-1].split("@")[0] for m in re.findall(r"^\s*U (\S+)$", out, re.M)}


def defined_symbols(fp):
    out = subprocess.run(["nm", "-D", "--defined-only", fp], capture_output=True, text=True).stdout
    return {m.split()[-1].split("@")[0] for m in re.findall(r"^\S+ [A-Za-z] (\S+)$", out, re.M)}


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def read_list(path):
    if not os.path.isfile(path):
        return set()
    return {line.split("#", 1)[0].split("\t")[0].strip() for line in open(path, errors="replace")
            if line.strip() and not line.strip().startswith("#")}


def public_libs(pdir):
    pb = os.path.join(pdir, "system", "etc", "linker.config.pb")
    if not os.path.isfile(pb):
        return set()
    return {m.decode() for m in re.findall(rb"[ -~]+\.so", open(pb, "rb").read())}


def dir_symbols(root):
    """{basename: defined symbols} for every ELF under a directory tree."""
    out = {}
    for dp, _dirs, fs in os.walk(root):
        for f in fs:
            fp = os.path.join(dp, f)
            if f.endswith(".so") and is_elf(fp):
                out[f] = defined_symbols(fp)
    return out


def main():
    tree, device_dir = sys.argv[1], sys.argv[2]
    pdir = sys.argv[3] if len(sys.argv) > 3 else None
    if not pdir:
        prod = os.path.join(tree, "out", "target", "product")
        devices = sorted(os.listdir(prod)) if os.path.isdir(prod) else []
        if not devices:
            raise SystemExit("no built product dir under %s" % prod)
        pdir = os.path.join(prod, devices[0])

    staged_root = os.path.join(tree, "vendor", "hct4", "tree", "vendor")
    dropped = read_list(os.path.join(device_dir, "vendor_build_wins.txt"))
    dropped |= read_list(os.path.join(device_dir, "vendor_dest_skip_extra.txt"))

    # What the vendor namespace can load, as defined symbols.
    avail = dir_symbols(os.path.join(pdir, "vendor"))
    staged_kept = {}
    for dp, _dirs, fs in os.walk(staged_root):
        rel = os.path.relpath(dp, staged_root)
        for f in fs:
            rp = os.path.join(rel, f) if rel != "." else f
            if rp in dropped or not f.endswith(".so"):
                continue
            fp = os.path.join(dp, f)
            if is_elf(fp):
                staged_kept[os.path.basename(fp)] = defined_symbols(fp)
    public = public_libs(pdir)
    syslibs = dir_symbols(os.path.join(pdir, "system"))
    defined = set()
    for syms in avail.values():
        defined |= syms
    for syms in staged_kept.values():
        defined |= syms
    for name, syms in syslibs.items():
        if name in public:
            defined |= syms
    print("libraries in /vendor: %d ; kept staged libs: %d ; public /system libs: %d ; symbols known "
          "to the vendor namespace: %d" % (len(avail), len(staged_kept), len(public), len(defined)))

    bad = {}
    kept = []
    for dp, _dirs, fs in os.walk(staged_root):
        rel = os.path.relpath(dp, staged_root)
        for f in fs:
            rp = os.path.join(rel, f) if rel != "." else f
            if rp in dropped:
                continue
            if is_elf(os.path.join(dp, f)):
                kept.append(rp)
    for rel in sorted(kept):
        fp = os.path.join(staged_root, rel)
        want = undefined_symbols(fp) - defined
        if want:
            bad[rel] = (want, needed(fp))

    if bad:
        print("\nBLOBS THAT WOULD NOT LOAD (%d):" % len(bad))
        for rel in sorted(bad):
            want, sonames = bad[rel]
            print("   %s  (%d unresolved symbols)" % (rel, len(want)))
            for s in sorted(want)[:6]:
                print("      %-60s" % s)
            if len(want) > 6:
                print("      ... %d more" % (len(want) - 6))
            print("      links: %s" % ", ".join(sorted(sonames)[:8]))
        print("\nFor each: the symbol's owner may be a library Android 14 built with a changed ABI\n"
              "(libstagefright_foundation's AString became std::string), a library we dropped from the\n"
              "copy list, or a HAL interface version Android 14 no longer ships. tools/vendor_link_closure.py\n"
              "names the vendor variant to request; tools/vendor_dropped_check.py names the drop that lost it.")
        return 1
    print("every kept blob resolves its undefined symbols against /vendor + kept staged libs + public /system libs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
