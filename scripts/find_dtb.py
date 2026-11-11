#!/usr/bin/env python3
"""Find every DTB in a boot image / partition slice and say which board it claims.

  python3 scripts/find_dtb.py boot.img dtb.img [more files ...]

A binary DTB stores property values as raw NUL-separated strings (no quotes, no '='), so this reads the
strings instead of parsing DTS. It reports each FDT (magic d00dfeed, plus the legacy d0020700 tag), its
totalsize, whether the unit's own board string "rk3399-hct" appears, and the model/compatible-looking
strings, so a generic PX6/RK3399 board can be told apart from the HCT4 MTCE board.
"""
import hashlib, re, struct, sys

MAGICS = [b'\xd0\x0d\xfe\xed', b'\xd0\x02\x07\x00']   # FDT magic; legacy ARM/Rockchip DTB tag

def scan(path):
    d = open(path, 'rb').read()
    name = path.split('/')[-1]
    print(f"\n{name}: {len(d):,} bytes")
    found = 0
    for magic in MAGICS:
        for m in re.finditer(re.escape(magic), d):
            off = m.start()
            totalsize, = struct.unpack_from('>I', d, off + 4)
            if not totalsize or totalsize > 4_000_000:
                continue
            blob = d[off:off + totalsize]
            hct = b'rk3399-hct' in blob
            parts = [s.decode('latin1', 'replace') for s in blob.split(b'\x00') if len(s) > 4]
            board = [s for s in parts if 'Board' in s or 'board' in s][:3]
            compat = [s for s in parts if ',' in s][:6]
            found += 1
            print(f"  DTB @ {off:,} ({off//512} sector) totalsize {totalsize:,} B "
                  f"sha {hashlib.sha256(blob).hexdigest()[:12]} hct={hct}")
            if board:
                print(f"    model/boards: {board}")
            if compat:
                print(f"    compat-ish strings: {compat}")
    if not found:
        print(f"  no DTB found (checked {', '.join(m.hex() for m in MAGICS)})")

if __name__ == '__main__':
    for p in sys.argv[1:]:
        scan(p)
