#!/usr/bin/env python3
"""Per-library decision table for the legacy vendor blobs.
# ARCHIVED (Nov 9): tool of the DROPPED blob-overwrite strategy (docs/decisions.md: the libdrm
# overwrite plan was dropped in favour of patching Android 14's own libdrm, D22).

For every soname a kept Android 11 blob links, answer the four questions that decide whether the
Android 14 build can carry the blob unchanged:

  1. who installs that soname in our build (/vendor module, public /system lib, APEX, nothing)?
  2. what does the *installed* copy actually provide, and what do the consumers still miss?
  3. does a reference copy (the stock Android 10 firmware) provide what the blobs need?
  4. would swapping that reference copy into /vendor cost anything to Android 14's own consumers?

The answer per library is one of:
  keep      Android 14's own copy satisfies every consumer  -> nothing to do
  replace   the reference copy covers the blobs and costs Android 14 nothing  -> drop the module,
            keep the staged blob (vendor_dest_skip_extra / PRODUCT_PACKAGES removal)
  both      the reference copy covers the blobs but Android 14's consumers need symbols it lacks
            -> needs a shim or a split (cannot have two files with one soname)
  shim      nothing in the tree or the firmware provides the symbols -> a small shim library
  unresolved  nobody provides them -> report and decide by hand

Usage:
  abi_swap_plan.py <lineage-product-dir> <staged-vendor-tree> <ref-a10-dir> <device-dir> [soname ...]

<ref-a10-dir> holds the reassembled Android 10 partitions (system.img, vendor.img), produced with
tools/reassemble.py. debugfs reads them; no mounting, no root.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, walk
from vendor_abi_check import (defined_symbols, elf_class, is_elf, path_arch, public_libs,
                              read_list, tree_symbols, undefined_symbols)

# Everything Android 14's own copy of these may have changed under the blobs. Probed even when the
# build installs them; a soname nothing installs is just reported as missing.
DEFAULT = ["libui.so", "libui.vendor.so", "libdrm.so", "libcrypto.so", "libssl.so", "libnl.so",
           "libsysutils.so", "libgralloctypes.so", "libutils.so", "libbase.so", "libhidlbase.so",
           "libchrome.so", "libc++.so", "libc++_vendor.so", "libcutils.so", "liblog.so",
           "libhardware.so", "libhardware_legacy.so", "libbinder.so", "libbinder_ndk.so",
           "libstagefright.so", "libmedia.so", "libmedia_codec.so", "libstagefright_foundation.so",
           "libwebrtc_audio_coding.so", "libprotobuf-cpp-full.so", "libprotobuf-cpp-full-3.9.1.so",
           "libsqlite.so", "libtinyalsa.so", "libaudioroute.so", "libion.so", "libril.so",
           "librilutils.so", "libreference-ril.so", "librkisp.so", "libvpu.so", "librga.so",
           "libjpeghwenc.so", "libgralloc_dry.so", "libgralloc_priv.so", "libgralloc_priv_omx.so",
          ]


def arch_table(table, arch):
    out = set()
    for p, syms in table.items():
        if path_arch(p) == arch:
            out |= syms
    return out


def needed(fp):
    out = subprocess.run(["readelf", "-d", fp], capture_output=True, text=True).stdout
    return [m for m in __import__("re").findall(r"\(NEEDED\)\s+Shared library: \[([^]]+)\]", out)]


def load_ref_images(refdir, sonames):
    """The stock Android 10 partitions, as symbol tables keyed by partition-relative path.

    Only the sonames we ask about are dumped: debugfs is slow per file, and a full /system walk
    (1200 libraries) costs minutes for answers nobody reads."""
    wanted = set(sonames)
    out = {}
    for part in ("system", "vendor"):
        img = os.path.join(refdir, part + ".img")
        if not os.path.isfile(img):
            continue
        for rel in walk(img, "/", sizes=False, pattern=None, dirs=False):
            rel = rel.lstrip("/")
            if os.path.basename(rel) not in wanted or path_arch(rel) is None:
                continue
            dest = os.path.join(refdir, "_dump", part + "_" + rel.replace("/", "_"))
            os.makedirs(os.path.join(refdir, "_dump"), exist_ok=True)
            try:
                dump_file(img, "/" + rel, dest)
            except RuntimeError:
                continue
            if os.path.isfile(dest) and os.path.getsize(dest) > 0:
                out[part + "/" + rel] = defined_symbols(dest)
    return out


def main():
    prod, staged, refdir, devdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    sonames = sys.argv[5:] or DEFAULT

    drop = set()
    for d in (devdir, staged, prod):
        for f in ("vendor_build_wins.txt", "vendor_dest_skip_extra.txt"):
            p = os.path.join(d, f)
            if os.path.isfile(p):
                drop |= read_list(p)

    pub = public_libs(prod)
    vend = tree_symbols(os.path.join(prod, "vendor"))
    odm = tree_symbols(os.path.join(prod, "odm"))
    system = {p: s for p, s in tree_symbols(os.path.join(prod, "system")).items()
              if os.path.basename(p) in pub}
    apex = {p: s for p, s in tree_symbols(os.path.join(prod, "apex")).items()
            if os.path.basename(p) in pub}
    kept = {p: s for p, s in tree_symbols(staged).items() if p not in drop}
    ref = load_ref_images(refdir, sonames)
    print("built /vendor files: %d ; kept staged blobs: %d ; public /system libs: %d ; "
          "APEX libs: %d ; reference copies: %d" %
          (len(vend), len(kept), len(system), len(apex), len(ref)))

    for soname in sonames:
        inst = sorted(p for p in list(vend) + list(odm) + list(system) + list(apex)
                      if os.path.basename(p) == soname)
        refcopy = sorted(p for p in ref if os.path.basename(p) == soname)
        if not inst and not refcopy:
            continue

        # Consumers: every ELF that links this soname, split by who built it.
        a14, a11 = [], []
        for table, label, root in ((vend, "Android 14 module", prod + "/vendor"),
                                   (odm, "Android 14 module", prod + "/odm"),
                                   (kept, "kept blob", staged)):
            for rel in table:
                fp = os.path.join(root, rel)
                if not is_elf(fp) or soname not in needed(fp):
                    continue
                arch = elf_class(fp) or path_arch(rel)
                if arch is None:
                    continue
                pool = (arch_table(vend, arch) | arch_table(odm, arch) | arch_table(system, arch)
                        | arch_table(apex, arch) | arch_table(kept, arch))
                gap = undefined_symbols(fp) - pool
                (a14 if label == "Android 14 module" else a11).append((arch, rel, gap))

        print("\n== %s" % soname)
        print("   installed in our build: %s" % (", ".join(inst) or "nothing"))
        print("   reference copies (stock A10): %s" % (", ".join(refcopy) or "none"))
        for arch in ("lib", "lib64"):
            take14 = [r for _a, r, _g in a14 if _a == arch]
            need11 = [r for _a, r, _g in a11 if _a == arch]
            gap11 = set().union(*(g for _a, _r, g in a11 if _a == arch)) if need11 else set()
            if not take14 and not need11:
                continue
            prov14 = arch_table({p: s for p, s in
                                 list(vend.items()) + list(odm.items()) + list(system.items())
                                 + list(apex.items()) if os.path.basename(p) == soname}, arch)
            prov10 = arch_table({p: s for p, s in ref.items() if os.path.basename(p) == soname}, arch)
            print("   [%s] Android 14 consumers: %d ; kept blobs: %d ; blob symbols still missing: %d"
                  % (arch, len(take14), len(need11), len(gap11)))
            if prov10:
                covered = len(gap11 & prov10)
                # What Android 14's consumers resolve from the installed copy that the A10 copy lacks.
                take_from_installed = set()
                for _a, rel, _g in a14:
                    if _a != arch:
                        continue
                    fp = os.path.join(prod + "/vendor" if rel in vend else prod + "/odm", rel)
                    take_from_installed |= undefined_symbols(fp) & prov14
                cost = take_from_installed - prov10
                print("      A10 copy covers %d/%d of the blob gap%s"
                      % (covered, len(gap11), "" if covered == len(gap11) else
                         " (still missing: " + ", ".join(sorted(gap11 - prov10)[:3]) + ")"))
                print("      swapping it in would cost Android 14 %d symbol(s)%s"
                      % (len(cost), "" if not cost else " -> " + ", ".join(sorted(cost)[:3])))
                verdict = ("replace" if covered == len(gap11) and not cost else
                           "both" if covered == len(gap11) and cost else "shim")
                print("      verdict: %s" % verdict)
            elif gap11:
                print("      no reference copy -> verdict: shim (or drop the blob)")
            else:
                print("      verdict: keep")
            if gap11 and not prov10:
                for s in sorted(gap11)[:8]:
                    print("         missing: %s" % s)


if __name__ == "__main__":
    main()
