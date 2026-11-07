#!/usr/bin/env python3
"""Do the libraries that link a given soname still resolve their symbols on Android 14?

  tools/consumer_abi_check.py <lineage-tree> <device-dir> [soname]     (default: libdrm.so)

tools/vendor_abi_check.py answers the question for the kept Rockchip blobs. This answers it for the
other side of the same link edge: every ELF installed in /vendor - libraries and `bin/hw` daemons -
whose DT_NEEDED names <soname>. When we patch an open-source library to export a Rockchip symbol,
those consumers must keep working, so this reuses vendor_abi_check's pool logic verbatim (imported,
not reimplemented): /vendor + /odm + the kept staged blobs + the /system libraries listed as public
in linker.config.pb + the public libraries Android 14 keeps in APEXes, matched per architecture
(ELF class, not directory).

Exit 0 when every consumer resolves; 1 when one has unresolved symbols.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vendor_abi_check import (BIONIC, arch_of, defined_symbols, elf_class, is_elf,  # noqa: E402
                              needed, public_libs, read_list, symbols_for, tree_symbols,
                              undefined_symbols)


def main():
    tree, device_dir = sys.argv[1], sys.argv[2]
    soname = sys.argv[3] if len(sys.argv) > 3 else "libdrm.so"
    prod = os.path.join(tree, "out", "target", "product")
    devices = sorted(os.listdir(prod)) if os.path.isdir(prod) else []
    if not devices:
        raise SystemExit("no built product dir under %s" % prod)
    pdir = os.path.join(prod, devices[0])

    staged_root = os.path.join(tree, "vendor", "hct4", "tree", "vendor")
    dropped = read_list(os.path.join(device_dir, "vendor_build_wins.txt"))
    dropped |= read_list(os.path.join(device_dir, "vendor_dest_skip_extra.txt"))
    public = public_libs(pdir)

    installed = tree_symbols(os.path.join(pdir, "vendor"))
    odm = tree_symbols(os.path.join(pdir, "odm"))
    system = {p: s for p, s in tree_symbols(os.path.join(pdir, "system")).items()
              if os.path.basename(p) in public}
    apex = {p: s for p, s in tree_symbols(os.path.join(pdir, "apex")).items()
            if os.path.basename(p) in public}
    staged_kept = {p: s for p, s in tree_symbols(staged_root).items() if p not in dropped}
    sources = [("vendor", installed), ("odm", odm), ("APEX", apex),
               ("staged", staged_kept), ("system-public", system)]

    print("checking every installed /vendor ELF that links %s" % soname)
    vroot = os.path.join(pdir, "vendor")
    bad, checked = [], 0
    for dp, _dirs, fs in os.walk(vroot):
        rel = os.path.relpath(dp, vroot)
        for f in sorted(fs):
            fp = os.path.join(dp, f)
            if not is_elf(fp) or soname not in needed(fp):
                continue                       # only the consumers of this library
            arch = elf_class(fp) or arch_of(rel)
            if arch is None:
                continue
            checked += 1
            defined = symbols_for(arch, sources)
            want = undefined_symbols(fp) - defined - BIONIC
            path = os.path.join(rel, f) if rel != "." else f
            print("   %-52s [%s]  %d exported, %d unresolved%s"
                  % (path, arch, len(defined_symbols(fp)), len(want),
                     "  " + ", ".join(sorted(want)[:4]) if want else ""))
            if want:
                bad.append((path, arch, sorted(want)))

    print("consumers checked: %d ; unresolved consumers: %d" % (checked, len(bad)))
    if bad:
        for rel, arch, want in bad:
            print("   WOULD NOT LOAD: /vendor/%s [%s] missing %s" % (rel, arch, ", ".join(want[:6])))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
