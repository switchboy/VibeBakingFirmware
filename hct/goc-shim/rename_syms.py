#!/usr/bin/env python3
"""Rename a 32-bit ELF's undefined references to android::AudioTrack / AudioRecord / MediaPlayer into namespace
hugoc__ (same length), so they bind to libhugoc.so instead of Android 14's libaudioclient/libmedia.

    rename_syms.py IN OUT [--exports exports.txt]

Only the string bytes "android" -> "hugoc__" at the namespace position of the selected symbols change. The tool
refuses to write if any OTHER dynamic symbol name would change (string-tail sharing in .dynstr), and, with
--exports (one mangled name per line, e.g. `llvm-nm -D --defined-only libhugoc.so`), if any renamed reference is
not exported by the shim.
"""
import argparse
import struct
import sys

CLASSES = (b"10AudioTrack", b"11AudioRecord", b"11MediaPlayer")


def sections(b):
    e_shoff, = struct.unpack_from("<I", b, 0x20)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", b, 0x2E)
    sh = [struct.unpack_from("<IIIIIIIIII", b, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    shstr = sh[e_shstrndx]
    def name(s):
        o = shstr[4] + s[0]
        return b[o:b.index(b"\0", o)].decode()
    return {name(s): s for s in sh}


def dyn_names(b, secs):
    dynsym, dynstr = secs[".dynsym"], secs[".dynstr"]
    out = []
    for i in range(dynsym[5] // 16):
        st_name, _v, _s, _info, _o, shndx = struct.unpack_from("<IIIBBH", b, dynsym[4] + i * 16)
        o = dynstr[4] + st_name
        out.append((st_name, bytes(b[o:b.index(b"\0", o)]), shndx))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--exports")
    a = ap.parse_args()
    b = bytearray(open(a.src, "rb").read())
    if b[:4] != b"\x7fELF" or b[4] != 1:
        sys.exit("not a 32-bit ELF")
    secs = sections(b)
    before = dyn_names(b, secs)
    targets = []
    for st_name, n, shndx in before:
        if shndx != 0:            # only undefined references
            continue
        for pre in (b"_ZN7android", b"_ZNK7android"):
            if n.startswith(pre) and any(n[len(pre):].startswith(c) for c in CLASSES):
                targets.append((st_name, n, len(pre) - len(b"android")))
    base = secs[".dynstr"][4]
    for st_name, n, pos in targets:
        o = base + st_name + pos
        assert b[o:o + 7] == b"android"
        b[o:o + 7] = b"hugoc__"
    after = dyn_names(b, secs)
    renamed = {n for _, n, _ in targets}
    for (o1, n1, _), (o2, n2, _) in zip(before, after):
        if n1 != n2 and n1 not in renamed:
            sys.exit(f"REFUSING: unrelated symbol changed by string sharing: {n1!r} -> {n2!r}")
    new_names = sorted(n2.decode() for (_, n1, _), (_, n2, _) in zip(before, after) if n1 in renamed)
    if a.exports:
        ex = set(l.split()[-1] for l in open(a.exports) if l.strip())
        missing = [n for n in new_names if n not in ex]
        if missing:
            sys.exit("REFUSING: not exported by the shim:\n  " + "\n  ".join(missing))
    open(a.dst, "wb").write(b)
    print(f"renamed {len(new_names)} references; no other symbol changed")
    for n in new_names:
        print("  ", n)


if __name__ == "__main__":
    main()
