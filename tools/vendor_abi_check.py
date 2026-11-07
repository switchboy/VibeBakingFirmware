#!/usr/bin/env python3
"""Does the Android 11 vendor blob actually resolve its symbols on Android 14?

  tools/vendor_abi_check.py <lineage-tree> <device-dir> [<product-dir>]

A blob is kept (copied byte-for-byte) or replaced by an Android 14 module. Keeping it only works if
every symbol it needs is defined by something the *vendor* namespace can load, for the architecture
the blob itself is:

  * files installed in /vendor/<lib|lib64>  (Android 14's own copies, incl. the vendor variants that
    vendor_modules_extra.mk asks for), plus /odm/<lib|lib64>
  * the other kept staged blobs in the same architecture directory (Rockchip's libraries link each
    other)
  * /system libraries listed as public in system/etc/linker.config.pb, in the matching arch directory,
    and the public libraries that Android 14 keeps in APEXes: bionic (com.android.runtime's
    lib{,64}/bionic) and TLS (conscrypt). /system/lib64/libc.so does not exist on Android 14, which
    is why memcpy/abort/__cxa_finalize looked missing.

The architecture comes from the blob's own ELF class, not its directory: /vendor/bin and
/vendor/bin/hw hold 32-bit *and* 64-bit executables on this vendor tree, and a 32-bit binary resolves
its sonames against /vendor/lib. The reason an earlier version of this tool lied is that symbol sets
were collected by file *name*: `lib/libhidlbase.so` (32-bit) exports
`configureRpcThreadpool(unsigned int, bool)` - `_ZN...Ejb` - while `lib64/libhidlbase.so` exports the
`unsigned long` variant (`_ZN...Emb`), so a 32-bit Rockchip HAL was matched against the 64-bit library
and reported dozens of symbols it would actually find. Symbols are therefore keyed by partition-
relative path, and a blob is checked against its own architecture only.

Anything left over is a real ABI break: the HAL would fail to dlopen at boot, and the log line is
`dlopen failed: cannot locate symbol ...`. Symbol versions (`memcpy@@LIBC`) are stripped, since the
linker matches the base name.

Output: one line per blob with unresolved symbols, then the symbols grouped by the library that could
provide them, so the break is actionable. Exit 1 when a blob has unresolved symbols.
"""
import os
import re
import subprocess
import sys

BIONIC = {"libc.so", "libm.so", "libdl.so", "libpthread.so"}


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


def tree_symbols(root):
    """{partition-relative path: defined symbols} for every ELF .so under a directory tree."""
    out = {}
    if not os.path.isdir(root):
        return out
    for dp, _dirs, fs in os.walk(root):
        rel = os.path.relpath(dp, root)
        for f in fs:
            if not f.endswith(".so"):
                continue
            fp = os.path.join(dp, f)
            if not is_elf(fp):
                continue
            rp = os.path.join(rel, f) if rel != "." else f
            out[rp] = defined_symbols(fp)
    return out


def arch_of(rel):
    """The directory the loader searches for this blob's sonames. Used as a fallback: /vendor/bin and
    /vendor/bin/hw hold both 32-bit and 64-bit executables on this vendor tree, so the ELF class
    decides (see elf_class below)."""
    d = os.path.dirname(rel)
    if d.startswith("lib64"):
        return "lib64"
    if d.startswith("lib"):
        return "lib"
    if d == "bin/hw":
        return "lib64"
    if d == "bin":
        return "lib"
    return None


def elf_class(path):
    """ELF class: offset 4 is 0x02 for 64-bit, 0x01 for 32-bit."""
    try:
        with open(path, "rb") as f:
            magic = f.read(5)
    except OSError:
        return None
    if magic[:4] != b"\x7fELF":
        return None
    return "lib64" if magic[4] == 2 else "lib"


def path_arch(path):
    """The architecture directory a library belongs to. For an APEX payload the component is inside
    the APEX's own layout (com.android.runtime/lib64/bionic/libc.so)."""
    parts = path.split("/")
    return next((p for p in parts if p in ("lib", "lib64")), os.path.dirname(path))


def symbols_for(arch, sources):
    """Union of the symbol sets of every library that sits in the <arch> directory of a source."""
    out = set()
    for _label, table in sources:
        for path, syms in table.items():
            if path_arch(path) == arch:
                out |= syms
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

    installed = tree_symbols(os.path.join(pdir, "vendor"))
    odm = tree_symbols(os.path.join(pdir, "odm"))
    public = public_libs(pdir)
    system = {p: s for p, s in tree_symbols(os.path.join(pdir, "system")).items()
              if os.path.basename(p) in public}
    # Android 14 keeps bionic and TLS in APEXes, so there is no /system/lib64/libc.so: the unpacked
    # apex payload under the product dir (com.android.runtime/lib64/bionic/libc.so, conscrypt's
    # libssl/libcrypto) is where those public libraries actually live.
    apex = {p: s for p, s in tree_symbols(os.path.join(pdir, "apex")).items()
            if os.path.basename(p) in public}
    staged_kept = {p: s for p, s in tree_symbols(staged_root).items() if p not in dropped}
    # The dropped staged copies: kept for one reason - to say where a missing symbol would have come
    # from, so the report can name the drop that took it away.
    staged_dropped = {p: s for p, s in tree_symbols(staged_root).items() if p in dropped}

    print("libraries in /vendor: %d ; in /odm: %d ; kept staged: %d ; dropped staged: %d ; "
          "public /system libraries: %d ; public APEX libraries: %d"
          % (len(installed), len(odm), len(staged_kept), len(staged_dropped), len(system), len(apex)))

    kept = []
    for dp, _dirs, fs in os.walk(staged_root):
        rel = os.path.relpath(dp, staged_root)
        for f in fs:
            rp = os.path.join(rel, f) if rel != "." else f
            if rp in dropped:
                continue
            fp = os.path.join(dp, f)
            if is_elf(fp):
                kept.append((rp, elf_class(fp) or arch_of(rp)))

    bad = {}
    for rel, arch in sorted(kept):
        if arch is None:
            continue
        defined = symbols_for(arch, [("vendor", installed), ("odm", odm), ("APEX", apex),
                                     ("staged", staged_kept), ("system-public", system)])
        want = undefined_symbols(os.path.join(staged_root, rel)) - defined - BIONIC
        if want:
            bad[rel] = (want, arch, needed(os.path.join(staged_root, rel)))

    if not bad:
        print("every kept blob resolves its undefined symbols against the libraries of its own "
              "architecture (/vendor, /odm, kept staged blobs, public /system libraries)")
        return 0

    # Group the missing symbols by the library that could provide them, in the same arch.
    providers = {}
    for rel, (want, arch, _sonames) in bad.items():
        for s in want:
            src = []
            for p, syms in installed.items():
                if s in syms and path_arch(p) == arch:
                    src.append("/vendor/" + p)
            for p, syms in apex.items():
                if s in syms and path_arch(p) == arch:
                    src.append("APEX/" + p)
            for p, syms in system.items():
                if s in syms and path_arch(p) == arch:
                    src.append("/system/" + p)
            for p, syms in staged_dropped.items():
                if s in syms and path_arch(p) == arch:
                    src.append("dropped staged copy: " + p)
            providers.setdefault((s, tuple(src)), []).append(rel)

    print("\nBLOBS THAT WOULD NOT LOAD (%d):" % len(bad))
    for rel in sorted(bad):
        want, arch, sonames = bad[rel]
        print("   %s [%s]  (%d unresolved symbols)" % (rel, arch, len(want)))
        for s in sorted(want)[:6]:
            print("      %-64s" % s)
        if len(want) > 6:
            print("      ... %d more" % (len(want) - 6))
        print("      links: %s" % ", ".join(sorted(sonames)[:8]))

    print("\nThe unresolved symbols, grouped by what could provide them:")
    nowhere, by_provider = [], {}
    for (s, src), users in providers.items():
        if not src:
            nowhere.append((s, users))
        else:
            by_provider.setdefault(src[0], []).append((s, users))
    for prov in sorted(by_provider, key=lambda p: -len(by_provider[p]))[:14]:
        users = sorted({u for _s, ulist in by_provider[prov] for u in ulist})
        print("   %-34s %3d symbol(s), needed by %d blob(s): %s"
              % (prov, len(by_provider[prov]), len(users), ", ".join(users[:3])))
        if len(users) > 3:
            print("      ... %d more users" % (len(users) - 3))
    if nowhere:
        print("\n   NO Android 14 library and no staged Android 11 copy defines these %d symbol(s):"
              % len(nowhere))
        for s, users in sorted(nowhere)[:20]:
            print("      %-64s  needed by %s" % (s, ", ".join(sorted(users)[:2])))
        if len(nowhere) > 20:
            print("      ... %d more" % (len(nowhere) - 20))
        print("\n   Android 14 rewrote the library underneath the blob (libutils/libbase/libstagefright:\n"
              "   constructors and AString became inline or std::string), or the owner library is not\n"
              "   in this tree at all. Options, in order: extract Android 10/11's own copy of the\n"
              "   defining library from a reference partition with tools/extract_reference_libs.py\n"
              "   (it lands in prebuilt_vendor_libs/<arch>/ and vendor_dest_keep.txt injects it),\n"
              "   restore the staged blob by removing the path from vendor_build_wins.txt, or declare\n"
              "   the HAL a gap in vendor_dest_deviations.txt. A gap is a lost feature: widevine DRM,\n"
              "   software codecs, the Rockchip composer/rockit/outputmanager HALs, the MTC/MFI HAL.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
