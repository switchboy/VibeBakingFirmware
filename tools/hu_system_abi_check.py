#!/usr/bin/env python3
"""Do the staged /system binaries and OEM libraries actually resolve on Android 14?

The head-unit control binaries (gocsdk*, sdsdk*, blueletd, brlinktd, sd_carplay, dhcpcd) and the OEM
libraries that sit beside them were compiled against Android 10's framework libraries. Android 14
builds most of those sonames again - libaudioclient.so, libmedia.so, libbinder.so, libcutils.so,
libutils.so, liblog.so, libnetutils.so, libhardware.so exist in both /system/lib and /system/lib64 -
but rebuilding a library under the same name does not preserve its ABI, so the question is whether
every symbol the binary names is still exported by the file Android 14 installs.

  tools/hu_system_abi_check.py <lineage-tree> <staging-dir> [<product-dir>]

<staging-dir> mirrors the layout that lands in /system: bin/, lib/, lib64/, etc/. Every ELF in bin/,
lib/ and lib64/ is checked for its own architecture (ELF class, not directory): a 32-bit binary
resolves against the 32-bit library directories.

Resolution set for a /system binary on Android 14: /system/lib(64), /system_ext/lib(64),
/odm/lib(64), the unpacked APEX payloads (bionic lives in com.android.runtime, TLS in com.android.tz
data - there is no /system/lib64/libc.so), plus the staged copies themselves, since the OEM librar
ies link each other.

Exit 1 when something does not resolve, and the unresolved symbols are grouped by the library that
would have provided them in Android 10 so the gap is actionable.
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


def elf_class(path):
    """ELF class: byte 4 is 0x02 for 64-bit, 0x01 for 32-bit -> the lib directory the loader uses."""
    try:
        with open(path, "rb") as f:
            magic = f.read(5)
    except OSError:
        return None
    if magic[:4] != b"\x7fELF":
        return None
    return "lib64" if magic[4] == 2 else "lib"


def tree_symbols(root):
    """{arch-relative path: defined symbols} for every ELF .so under a directory tree."""
    out = {}
    if not os.path.isdir(root):
        return out
    for dp, _dirs, fs in os.walk(root):
        rel = os.path.relpath(dp, root)
        for f in fs:
            if not f.endswith(".so") or not is_elf(os.path.join(dp, f)):
                continue
            fp = os.path.join(dp, f)
            rp = os.path.join(rel, f) if rel != "." else f
            out[rp] = defined_symbols(fp)
    return out


def arch_of(path):
    """Which library directory a library belongs to (APEX payloads nest: com.android.tzdata/lib64/bionic)."""
    parts = path.split("/")
    return next((p for p in parts if p in ("lib", "lib64")), os.path.dirname(path))


def symbols_for(arch, sources):
    """Union of the symbols exported by every library in <arch>'s directory of each source."""
    out = set()
    for _label, table in sources:
        for path, syms in table.items():
            if arch_of(path) == arch:
                out |= syms
    return out


def main():
    tree, staging = sys.argv[1], sys.argv[2]
    pdir = sys.argv[3] if len(sys.argv) > 3 else None
    if not pdir:
        prod = os.path.join(tree, "out", "target", "product")
        devices = sorted(os.listdir(prod)) if os.path.isdir(prod) else []
        if not devices:
            raise SystemExit("no built product dir under %s" % prod)
        pdir = os.path.join(prod, devices[0])

    staged = tree_symbols(staging)
    sources = [
        ("/system", tree_symbols(os.path.join(pdir, "system"))),
        ("/system_ext", tree_symbols(os.path.join(pdir, "system_ext"))),
        ("/odm", tree_symbols(os.path.join(pdir, "odm"))),
        ("apex", {p: s for p, s in tree_symbols(os.path.join(pdir, "apex")).items()
                  if os.path.basename(p) in public_in_apex(pdir)}),
        ("staged", staged),
    ]
    print("staged ELF libraries: %d ; /system libs: %d ; /system_ext libs: %d ; apex libs: %d"
          % (len(staged), len(sources[0][1]), len(sources[1][1]), len(sources[4][1])))

    bad = 0
    for dp, _dirs, fs in os.walk(staging):
        rel = os.path.relpath(dp, staging)
        if rel not in ("bin", "lib", "lib64"):
            continue
        for f in sorted(fs):
            fp = os.path.join(dp, f)
            if not is_elf(fp):
                continue
            arch = elf_class(fp)
            avail = symbols_for(arch, sources)
            undef = undefined_symbols(fp) - avail
            sonames = needed(fp)
            # A soname that no installed or staged file provides is a dlopen failure on its own.
            have = set()
            for _label, table in sources:
                have |= {os.path.basename(p) for p in table if arch_of(p) == arch}
            missing_sonames = [s for s in sonames if s not in have]
            if undef or missing_sonames:
                bad += 1
                print(f"UNRESOLVED {rel}/{f} ({arch}) "
                      f"missing_sonames={missing_sonames} symbols={len(undef)}")
                for s in sorted(undef)[:12]:
                    print(f"    {s}")
                # Name the Android 10 library that used to export them, if the staged copy has one.
                for s in sorted(undef)[:12]:
                    for p, syms in staged.items():
                        if s in syms and arch_of(p) == arch:
                            print(f"      provided by staged {p}")
                            break
    print(f"checked ELF files under {staging}: unresolved = {bad}")
    return 1 if bad else 0


def public_in_apex(pdir):
    """Sonames the linker resolves from APEXes on Android 14: bionic plus the conscrypt/TLS libs."""
    pb = os.path.join(pdir, "system", "etc", "linker.config.pb")
    public = set()
    if os.path.isfile(pb):
        public = {m.decode() for m in re.findall(rb"[ -~]+\.so", open(pb, "rb").read())}
    return public | BIONIC | {"libssl.so", "libcrypto.so"}


if __name__ == "__main__":
    sys.exit(main())
