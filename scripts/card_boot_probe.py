#!/usr/bin/env python3
"""Probe the boot/recovery images inside a card dump: Android boot header, embedded DTB, and whether the
DTB is the HCT board's own (rockchip,rk3399-hct) or a generic PX6 board's. Read-only on a dumped file.

  python3 scripts/card_boot_probe.py card-dump.img [start_sector] [ref1.img ref2.img ...]

Default start_sector 59392 = the boot partition. Reference images (if given) are compared against the
carved image by sha256. The second stage is Rockchip's RSCE wrapper: a raw DTB sits at +2048.
"""
import hashlib, mmap, re, struct, sys

SECTOR = 512

def sha(b):
    return hashlib.sha256(b).hexdigest()[:12]

def probe(m, sector, label, refs):
    off = sector * SECTOR
    hdr = m[off:off + 2048]
    if hdr[:8] != b'ANDROID!':
        print(f"{label} @ sector {sector}: no ANDROID! header -> {hdr[:8]!r}")
        return
    # boot_img_hdr: magic(8) kernel_size(4)@8 ramdisk_size(4)@12 third/second_size(4)@24
    #               header_version(4)@28 header_size(4)@32 reserved board(16)@64 name(64)@80
    kernel_size, ramdisk_size, second_size, hdr_version = struct.unpack_from('<4I', hdr, 8)
    hdr_size, = struct.unpack_from('<I', hdr, 32)
    total = hdr_size + (kernel_size + ramdisk_size + second_size) * SECTOR
    board = hdr[64:80].split(b'\x00')[0].decode('latin1', 'replace')
    name = hdr[80:144].split(b'\x00')[0].decode('latin1', 'replace')
    print(f"\n{label} @ sector {sector}: board={board!r} name={name!r} v{hdr_version} hdr {hdr_size} B")
    print(f"  kernel {kernel_size} pages ({kernel_size*SECTOR:,} B), ramdisk {ramdisk_size} pages "
          f"({ramdisk_size*SECTOR:,} B), second {second_size} pages ({second_size*SECTOR:,} B)")
    print(f"  declared total {total:,} B")
    img = m[off:off + total]
    print(f"  image sha256 {sha(img)}")
    for r in refs:
        rb = open(r, 'rb').read()
        print(f"  vs {r.split('/')[-1]} ({len(rb):,} B, {sha(rb)}) -> {'SAME' if rb == img else 'DIFFER'}")
    # second stage: RSCE wrapper, raw DTB at +2048
    if second_size:
        sec = m[off + hdr_size + (kernel_size + ramdisk_size) * SECTOR:
                off + hdr_size + (kernel_size + ramdisk_size + second_size) * SECTOR]
        print(f"  second stage magic {sec[:4]!r} sha {sha(sec)}")
        dtb = sec[2048:]
        if dtb[:4] == b'\xd0\x02\x07\x00':
            print(f"  DTB at second+2048: {len(dtb):,} B sha {sha(dtb)}")
            comp = re.search(rb'compatible\s*=\s*"([^"]+)"', dtb[:4096])
            print(f"  compatible: {comp.group(1).decode() if comp else '?'}")
            mach = re.search(rb'machine\s*=\s*"([^"]+)"', dtb[:4096])
            if mach:
                print(f"  machine: {mach.group(1).decode()}")
        else:
            print(f"  no dtb header at second+2048 ({dtb[:4]!r}) - try scanning for d0020700")
            pos = sec.find(b'\xd0\x02\x07\x00')
            if pos >= 0:
                print(f"  dtb found at second+{pos} sha {sha(sec[pos:])}")
                comp = re.search(rb'compatible\s*=\s*"([^"]+)"', sec[pos:pos + 4096])
                print(f"  compatible: {comp.group(1).decode() if comp else '?'}")

def main():
    path = sys.argv[1]
    sector = int(sys.argv[2]) if len(sys.argv) > 2 else 59392
    refs = sys.argv[3:]
    with open(path, 'rb') as f:
        f.seek(0, 2)
        m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    probe(m, sector, 'boot', refs)
    probe(m, 124928, 'recovery', refs)

if __name__ == '__main__':
    main()
