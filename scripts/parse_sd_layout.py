#!/usr/bin/env python3
"""Parse a Rockchip SD/eMMC card dump: GPT (main + backup), the RKAF parameter block, and where the
payload images actually sit. Read-only analysis of a dumped image file, not of a live device.

  python3 scripts/parse_sd_layout.py card-dump.img

It prints: GPT partitions (name, first/last LBA, size, attributes), the RKAF parameter partition list
(names + start sectors + sizes as encoded by Rockchip), and signature offsets (BOOT/RK33HH/RSAK/
LOADER/ANDROID!/AVB0/sparse), so a rescue card can be mirrored sector-for-sector.

The file is memory-mapped rather than slurped: a card dump is ~8 GB and reading it into RAM stalls
the machine (this is what blew past the ssh timeout on the first run).
"""
import mmap, re, struct, sys

SECTOR = 512

def guid(e):
    # UEFI text form: first three fields little-endian, the last two big-endian byte strings.
    a, b, c = struct.unpack_from('<IHH', e, 0)
    return f"{a:08x}-{b:04x}-{c:04x}-{''.join(f'{x:02x}' for x in e[8:10])}-{''.join(f'{x:02x}' for x in e[10:16])}"

def parse_gpt(m, n, label, off):
    hdr = m[off:off + SECTOR]
    if hdr[:8] != b'EFI PART':
        print(f"{label} GPT: no header at {off:#x}")
        return []
    # Header: magic(8) rev(4) hdr_size(4) hdr_crc(4) reserved(4) my_lba(8) alt_lba(8)
    #         first_usable(8) last_usable(8) disk_guid(16) entries_lba(8) parts(4) ent_size(4) ent_crc(4)
    rev, hdr_size, hdr_crc = struct.unpack_from('<III', hdr, 8)
    my_lba, alt_lba, first_lba, last_lba = struct.unpack_from('<4Q', hdr, 24)
    entries_lba, parts, ent_size, ent_crc = struct.unpack_from('<QIII', hdr, 72)
    print(f"\n{label} GPT @ sector {off//SECTOR}: rev {rev:#x}, hdr {hdr_size} B crc {hdr_crc:#x}, "
          f"{parts} entries of {ent_size} B @ LBA {entries_lba}, first usable {first_lba}, last usable {last_lba}")
    ents = []
    base = entries_lba * SECTOR
    for i in range(parts):
        e = m[base + i * ent_size: base + (i + 1) * ent_size]
        if e[:16] == b'\x00' * 16:
            continue
        # Entry: type(16) uuid(16) first_lba(8) last_lba(8) attrs(8) name(72 utf-16)
        f_lba, l_lba = struct.unpack_from('<2Q', e, 32)
        attrs, = struct.unpack_from('<Q', e, 48)
        name = e[56:128].decode('utf-16-le', 'replace').split('\x00')[0]
        ents.append((name, f_lba, l_lba, attrs, guid(e)))
        print(f"  {i+1:2} {name:<12} LBA {f_lba:>9}..{l_lba:>9} ({(l_lba-f_lba+1)*SECTOR:>12,} B) "
              f"attrs {attrs:#x} type {guid(e)}")
    return ents

def scan(m, sigs, ranges):
    print("\nsignature offsets (targeted ranges):")
    for label, a, b in ranges:
        for sig, name in sigs:
            pos = m.find(sig, a, min(b, len(m)))
            if pos >= 0:
                print(f"  {name:<20} in {label:<26} at byte {pos:,} ({pos//SECTOR} sector)")

def main():
    path = sys.argv[1]
    with open(path, 'rb') as f:
        n = f.seek(0, 2)
        m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    print(f"dump {path}: {n:,} bytes = {n//SECTOR:,} sectors (512B)")

    # ---- MBR -------------------------------------------------------------
    mbr = m[0:SECTOR]
    print("\nMBR @ sector 0:")
    for i in range(4):
        rec = mbr[446 + i * 16: 446 + (i + 1) * 16]
        if rec[:4] == b'\x00' * 4:
            continue
        typ, = struct.unpack_from('<B', rec, 4)
        start, = struct.unpack_from('<I', rec, 8)
        size, = struct.unpack_from('<I', rec, 12)
        print(f"  {i}: type {typ:#04x} start {start} size {size} ({size*SECTOR:,} B) boot {rec[0]:#x}")
    print(f"  signature: {mbr[510:512].hex()}")

    # ---- GPT -------------------------------------------------------------
    main_ents = parse_gpt(m, n, 'main', SECTOR)
    # Backup GPT header sits at the last usable LBA; find it by scanning the tail.
    tail = min(n, (n // SECTOR) * SECTOR)
    for back in range(1, 34):
        off = tail - back * SECTOR
        if m[off:off + 8] == b'EFI PART':
            parse_gpt(m, n, 'backup', off)
            break
    else:
        print("\nbackup GPT: no header found in the last 33 sectors")

    # ---- RKAF parameter --------------------------------------------------
    hits = [mt.start() for mt in re.finditer(rb'RKAF', m)]
    print(f"\nRKAF parameter hits: {len(hits)} -> {[hex(h) for h in hits[:8]]}")
    for h in hits[:4]:
        print(f"  RKAF @ {h:#x} (sector {h//SECTOR})")
        print(f"    chip id: {m[h+16:h+48].split(b'\\x00')[0].decode('latin1','replace')!r}")
        strings = [(h + mt.start(), mt.group().decode()) for mt in re.finditer(rb'[A-Za-z0-9_\-/.]{4,}', m[h:h+6000])]
        prev = None
        for off, nm in strings[:26]:
            print(f"    {off:#x} (+{off - (prev if prev is not None else h)}) {nm}")
            prev = off

    # ---- payload signatures ---------------------------------------------
    scan(m,
         [(b'BOOT\x00\x00', 'BOOT container'), (b'RK33HH', 'DDR init header'),
          (b'RSAK', 'miniloader header'), (b'LOADER  ', 'u-boot header'),
          (b'ANDROID!', 'boot/recovery img'), (b'AVB0', 'vbmeta hash'),
          (b'RKFW', 'update.img container'), (b'\x87\x04\x05\x24', 'sparse header')],
         [('loader area 0..16383', 0, 16384 * SECTOR),
          ('uboot 16384..24575', 16384 * SECTOR, 24576 * SECTOR),
          ('trust 24576..32767', 24576 * SECTOR, 32768 * SECTOR),
          ('misc 32768..40959', 32768 * SECTOR, 40960 * SECTOR),
          ('dtb 40960..49151', 40960 * SECTOR, 49152 * SECTOR),
          ('dtbo 49152..57343', 49152 * SECTOR, 57344 * SECTOR),
          ('vbmeta 57344..59391', 57344 * SECTOR, 59392 * SECTOR),
          ('boot 59392..124927', 59392 * SECTOR, 124928 * SECTOR),
          ('recovery 124928..321535', 124928 * SECTOR, 321536 * SECTOR),
          ('super 1378328..7752703', 1378328 * SECTOR, 7752704 * SECTOR)])

    # ---- ID block --------------------------------------------------------
    print("\nid block (sector 64):")
    idb = m[64 * SECTOR: 64 * SECTOR + 64]
    print(f"  head {idb[:16].hex()}")
    print(f"  sector 0 head {m[:16].hex()}")
    print(f"  sector 1 head {m[SECTOR:SECTOR+16].hex()}")

if __name__ == '__main__':
    main()
