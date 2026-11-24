#!/usr/bin/env python3
"""Check which framework methods an app's dex calls are missing from a target framework.

Usage: dex_api_check.py --framework A.dex [B.dex ...] --app X.dex [Y.dex ...]

Reads only the dex header tables (strings, types, protos, methods, class_defs, class_data), so it works on
any dex version. For every method the app invokes on a class defined in the framework dexes, it walks the
class's superclasses and interfaces and reports the reference if no class in that chain defines the
method (name + descriptor). References to classes the framework dexes do not define are listed separately
(they live in other boot-classpath jars or are app-internal).
"""
import argparse
import struct
import sys


def uleb(b, o):
    r = s = 0
    while True:
        x = b[o]; o += 1
        r |= (x & 0x7F) << s; s += 7
        if x < 0x80:
            return r, o


class Dex:
    def __init__(self, path):
        b = self.b = open(path, "rb").read()
        if not b.startswith(b"dex\n"):
            raise SystemExit(f"{path}: not a dex")
        (self.str_n, self.str_off, self.type_n, self.type_off, self.proto_n, self.proto_off,
         _fn, _fo, self.meth_n, self.meth_off, self.cls_n, self.cls_off) = struct.unpack_from("<12I", b, 0x38)
        self._s = {}

    def s(self, i):
        if i not in self._s:
            o = struct.unpack_from("<I", self.b, self.str_off + 4 * i)[0]
            _, o = uleb(self.b, o)
            e = self.b.index(b"\0", o)
            self._s[i] = self.b[o:e].decode("utf-8", "replace")
        return self._s[i]

    def t(self, i):
        return self.s(struct.unpack_from("<I", self.b, self.type_off + 4 * i)[0])

    def type_list(self, off):
        if off == 0:
            return []
        n = struct.unpack_from("<I", self.b, off)[0]
        return [self.t(struct.unpack_from("<H", self.b, off + 4 + 2 * k)[0]) for k in range(n)]

    def proto(self, i):
        _shorty, ret, params = struct.unpack_from("<III", self.b, self.proto_off + 12 * i)
        return "(" + "".join(self.type_list(params)) + ")" + self.t(ret)

    def method(self, i):
        cls, pr, name = struct.unpack_from("<HHI", self.b, self.meth_off + 8 * i)
        return self.t(cls), self.s(name) + self.proto(pr)

    def classes(self):
        """yield (class, super, [interfaces], {method sigs})"""
        for k in range(self.cls_n):
            ci, _acc, sup, ifo, _src, _ann, cdo, _sv = struct.unpack_from("<8I", self.b, self.cls_off + 32 * k)
            sigs = set()
            if cdo:
                o = cdo
                sf, o = uleb(self.b, o); inf, o = uleb(self.b, o)
                dm, o = uleb(self.b, o); vm, o = uleb(self.b, o)
                for _ in range(sf + inf):
                    _, o = uleb(self.b, o); _, o = uleb(self.b, o)
                for cnt in (dm, vm):
                    idx = 0
                    for _ in range(cnt):
                        d, o = uleb(self.b, o); _, o = uleb(self.b, o); _, o = uleb(self.b, o)
                        idx += d
                        sigs.add(self.method(idx)[1])
            yield self.t(ci), (self.t(sup) if sup != 0xFFFFFFFF else None), self.type_list(ifo), sigs

    def invoked(self):
        """Method references used by invoke instructions (scans code_items via class_data)."""
        refs = set()
        for k in range(self.cls_n):
            cdo = struct.unpack_from("<I", self.b, self.cls_off + 32 * k + 24)[0]
            if not cdo:
                continue
            o = cdo
            sf, o = uleb(self.b, o); inf, o = uleb(self.b, o)
            dm, o = uleb(self.b, o); vm, o = uleb(self.b, o)
            for _ in range(sf + inf):
                _, o = uleb(self.b, o); _, o = uleb(self.b, o)
            for cnt in (dm, vm):
                for _ in range(cnt):
                    _, o = uleb(self.b, o); _, o = uleb(self.b, o); code, o = uleb(self.b, o)
                    if code:
                        self._scan_code(code, refs)
        return refs

    def _scan_code(self, off, refs):
        insns = struct.unpack_from("<I", self.b, off + 12)[0]
        base = off + 16
        i = 0
        while i < insns:
            w = struct.unpack_from("<H", self.b, base + 2 * i)[0]
            op = w & 0xFF
            if op == 0x00 and w != 0:  # payload pseudo-instructions
                if w == 0x0100:
                    n = struct.unpack_from("<H", self.b, base + 2 * i + 2)[0]; i += n * 2 + 4; continue
                if w == 0x0200:
                    n = struct.unpack_from("<H", self.b, base + 2 * i + 2)[0]; i += n * 4 + 2; continue
                if w == 0x0300:
                    ew, n = struct.unpack_from("<HI", self.b, base + 2 * i + 2); i += (n * ew + 1) // 2 + 4; continue
            if 0x6E <= op <= 0x72 or 0x74 <= op <= 0x78:
                refs.add(self.method(struct.unpack_from("<H", self.b, base + 2 * i + 2)[0]))
            i += FMT[op]


# instruction sizes in 16-bit code units, by opcode
FMT = [1] * 256
for ops, n in (((0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1A, 0x1C, 0x1F, 0x20, 0x22, 0x23, 0x29,
                 *range(0x2D, 0x32), *range(0x32, 0x38), *range(0x38, 0x3E), *range(0x44, 0x6E),
                 *range(0x90, 0xB0), *range(0xD0, 0xE3), 0xFE, 0xFF), 2),
               ((0x03, 0x06, 0x09, 0x14, 0x17, 0x1B, 0x24, 0x25, 0x26, 0x2A, 0x2B, 0x2C,
                 *range(0x6E, 0x73), *range(0x74, 0x79), 0xFC, 0xFD), 3),
               ((0x18,), 5), ((0xFA, 0xFB), 4)):
    for op in ops:
        FMT[op] = n


OBJECT_METHODS = {"<init>", "toString", "equals", "hashCode", "getClass", "notify", "notifyAll", "wait",
                  "finalize", "clone"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--framework", nargs="+", required=True)
    ap.add_argument("--app", nargs="+", required=True)
    a = ap.parse_args()
    fw = {}
    for p in a.framework:
        for c, sup, ifs, sigs in Dex(p).classes():
            fw.setdefault(c, (sup, ifs, sigs))
    app_classes = set()
    refs = set()
    for p in a.app:
        d = Dex(p)
        app_classes |= {c for c, *_ in d.classes()}
        refs |= d.invoked()

    def has(c, sig, seen):
        if c == "Ljava/lang/Object;":
            # java.lang.Object is in the ART APEX, not in these dexes; its own methods are known
            return sig.split("(")[0] in OBJECT_METHODS
        if c.startswith("Ljava/") and c not in fw:
            return None  # other core-library classes: cannot tell
        if c in seen or c not in fw:
            return None if c not in fw else False
        seen.add(c)
        sup, ifs, sigs = fw[c]
        if sig in sigs:
            return True
        found_unknown = False
        for nxt in ([sup] if sup else []) + ifs:
            r = has(nxt, sig, seen)
            if r:
                return True
            if r is None:
                found_unknown = True
        return None if found_unknown else False

    missing, unknown = [], set()
    for c, sig in sorted(refs):
        if c in app_classes:
            continue
        if c not in fw:
            unknown.add(c); continue
        r = has(c, sig, set())
        if r is False:
            missing.append(f"{c}->{sig}")
        elif r is None:
            unknown.add(c + " (chain leaves framework)")
    print(f"framework classes: {len(fw)}; app invoke refs: {len(refs)}")
    print("MISSING:")
    for m in missing:
        print("  " + m)
    print(f"not resolvable here: {len(unknown)}")
    for u in sorted(unknown):
        print("  " + u)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
