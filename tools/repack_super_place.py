#!/usr/bin/env python3
"""Re-place the logical extents of a liblp `super` image so chosen byte offsets stay unused.

Why this exists (D102): the SD-boot card used as the Android 14 test bed has three stuck-at-zero
bits inside its p14 span. They were found by writing the shape A super and reading the whole
partition back: three 1 MiB blocks differed, each by exactly ONE byte, and in each case the byte on
the card was the image byte with one bit cleared (xor 0x40, 0x40, 0x10). A targeted 512 B rewrite of
one of those sectors did not change it, so the cells are frozen, not transiently bad. Mapped through
liblp and ext4 the three bits landed in /vendor/lib64/librkisp.so, SystemUI.odex and
TrebuchetQuickStep.apk - real code, which would confound a boot result.

The container is 3,263,168,512 B and the five filesystems need 2,300 MiB, so there is 811 MiB of
slack. This tool re-places the extents - the filesystem images are copied byte-for-byte, nothing is
rebuilt - so that the damaged offsets fall between extents, where the image is zero. A stuck-at-zero
bit under a zero byte is invisible, so the whole partition then reads back byte-exact and the
verification is meaningful again.

What is changed in the metadata: only each extent's `target_data` (its start sector). Partition
names, sizes, groups, attributes, the geometry and the block-device descriptor are untouched. Both
metadata slots and the backup copy of each are rewritten, and `tables_checksum` plus
`header_checksum` (both plain SHA-256 - verified against the source image before writing) are
recomputed.

Usage:
  tools/repack_super_place.py SRC DST --place system=1 --place product=967 ... --avoid 1551079141 ...
Placements are in MiB from the start of the container and must respect the block device's alignment.
The tool refuses to write unless every check passes.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys

GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
RESERVED = 4096
HEADER_MAGIC = 0x414C5030
GEOMETRY_MAGIC = 0x616C4467
MIB = 1024 * 1024
SECTOR = 512


class Meta:
    """The pieces of an LpMetadata we need: partitions, extents, the block device descriptor."""

    def __init__(self, blob: bytes, offset: int):
        self.offset = offset
        hdr = blob[offset : offset + 128]
        magic, self.major, self.minor, self.header_size = struct.unpack("<IHHI", hdr[:12])
        if magic != HEADER_MAGIC:
            raise ValueError(f"no metadata header at {offset}")
        self.header = bytearray(blob[offset : offset + self.header_size])
        (self.tables_size,) = struct.unpack("<I", hdr[44:48])
        self.p_off, self.p_num, self.p_sz = struct.unpack("<III", hdr[80:92])
        self.e_off, self.e_num, self.e_sz = struct.unpack("<III", hdr[92:104])
        self.b_off, self.b_num, self.b_sz = struct.unpack("<III", hdr[116:128])
        t0 = offset + self.header_size
        self.tables = bytearray(blob[t0 : t0 + self.tables_size])

    # --- checks -------------------------------------------------------------------------------
    def checksums_ok(self) -> bool:
        if hashlib.sha256(bytes(self.tables)).digest() != bytes(self.header[48:80]):
            return False
        h = bytearray(self.header)
        h[12:44] = b"\0" * 32
        return hashlib.sha256(bytes(h)).digest() == bytes(self.header[12:44])

    def partitions(self):
        out = []
        for i in range(self.p_num):
            b = self.tables[self.p_off + i * self.p_sz : self.p_off + (i + 1) * self.p_sz]
            name = b[:36].rstrip(b"\0").decode()
            attrs, first_extent, num_extents, group = struct.unpack("<IIII", b[36:52])
            out.append((name, first_extent, num_extents))
        return out

    def extent(self, i):
        b = self.tables[self.e_off + i * self.e_sz : self.e_off + (i + 1) * self.e_sz]
        num_sectors, target_type, target_data = struct.unpack("<QIQ", b[:20])
        return num_sectors, target_type, target_data

    def set_extent_start(self, i, sector):
        base = self.e_off + i * self.e_sz
        self.tables[base + 12 : base + 20] = struct.pack("<Q", sector)

    def block_device(self):
        b = self.tables[self.b_off : self.b_off + self.b_sz]
        first_sector, alignment, alignment_offset, size = struct.unpack("<QIIQ", b[:24])
        return first_sector, alignment, alignment_offset, size

    def reseal(self):
        self.header[48:80] = hashlib.sha256(bytes(self.tables)).digest()
        h = bytearray(self.header)
        h[12:44] = b"\0" * 32
        self.header[12:44] = hashlib.sha256(bytes(h)).digest()

    def write_into(self, buf: bytearray):
        buf[self.offset : self.offset + self.header_size] = self.header
        t0 = self.offset + self.header_size
        buf[t0 : t0 + self.tables_size] = self.tables


def metadata_offsets(blob: bytes):
    magic, struct_size = struct.unpack("<II", blob[GEOMETRY_OFFSET : GEOMETRY_OFFSET + 8])
    if magic != GEOMETRY_MAGIC:
        raise ValueError("no liblp geometry at 4096")
    max_size, slots, logical_block_size = struct.unpack(
        "<III", blob[GEOMETRY_OFFSET + 40 : GEOMETRY_OFFSET + 52]
    )
    primary = RESERVED + GEOMETRY_SIZE * 2
    backup = primary + max_size * slots
    offs = []
    for base in (primary, backup):
        for slot in range(slots):
            off = base + max_size * slot
            (m,) = struct.unpack("<I", blob[off : off + 4])
            if m == HEADER_MAGIC:
                offs.append(off)
    return offs, max_size, slots, logical_block_size


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--place", action="append", default=[], metavar="NAME=MIB",
                    help="new start of a partition's single extent, in MiB")
    ap.add_argument("--avoid", action="append", type=int, default=[], metavar="BYTE",
                    help="byte offset that must end up outside every extent and read 0x00")
    args = ap.parse_args()

    placements = {}
    for p in args.place:
        name, _, mib = p.partition("=")
        placements[name] = int(mib)

    with open(args.src, "rb") as f:
        head = f.read(MIB)
        offs, max_size, slots, lbs = metadata_offsets(head)
        print(f"liblp: {len(offs)} metadata copies at {offs}, max_size {max_size}, "
              f"slots {slots}, logical_block_size {lbs}")
        metas = [Meta(head, o) for o in offs]
        for m in metas:
            if not m.checksums_ok():
                print(f"ABORT: metadata at {m.offset} does not verify against its own checksums")
                return 1
        print("every metadata copy verifies against its own SHA-256 checksums")

        ref = metas[0]
        first_sector, alignment, align_off, dev_size = ref.block_device()
        print(f"block device: size {dev_size} B, alignment {alignment} B, "
              f"first_logical_sector {first_sector}")
        parts = ref.partitions()

        # old layout, and the moves we are asked for
        moves = []  # (name, extent_index, num_sectors, old_sector, new_sector)
        for name, fe, ne in parts:
            if ne != 1:
                print(f"ABORT: {name} has {ne} extents; this tool only moves single-extent partitions")
                return 1
            num_sectors, ttype, old = ref.extent(fe)
            if ttype != 0:
                print(f"ABORT: {name} extent target_type {ttype} is not linear")
                return 1
            if name not in placements:
                print(f"ABORT: no --place given for {name}")
                return 1
            new = placements[name] * MIB // SECTOR
            moves.append((name, fe, num_sectors, old, new))

        # --- placement checks -----------------------------------------------------------------
        spans = []
        for name, fe, ns, old, new in moves:
            start, end = new * SECTOR, (new + ns) * SECTOR
            if new * SECTOR % alignment:
                print(f"ABORT: {name} start {start} is not aligned to {alignment}")
                return 1
            if new < first_sector:
                print(f"ABORT: {name} would start below first_logical_sector")
                return 1
            if end > dev_size:
                print(f"ABORT: {name} would end at {end}, past the device size {dev_size}")
                return 1
            spans.append((start, end, name))
        spans.sort()
        for (s1, e1, n1), (s2, e2, n2) in zip(spans, spans[1:]):
            if e1 > s2:
                print(f"ABORT: {n1} [{s1},{e1}) overlaps {n2} [{s2},{e2})")
                return 1
        for off in args.avoid:
            for s, e, n in spans:
                if s <= off < e:
                    print(f"ABORT: avoided offset {off} still lands inside {n} [{s},{e})")
                    return 1
        print("placement: no overlaps, everything inside the device, every avoided offset outside "
              "all extents")
        for s, e, n in spans:
            print(f"  {n:<12} {s:12d} .. {e:12d}   {(e - s) / MIB:9.2f} MiB")

        # --- build ----------------------------------------------------------------------------
        for m in metas:
            for name, fe, ns, old, new in moves:
                m.set_extent_start(fe, new)
            m.reseal()
            if not m.checksums_ok():
                print(f"ABORT: resealed metadata at {m.offset} fails its own check")
                return 1
        newhead = bytearray(head)
        for m in metas:
            m.write_into(newhead)

        with open(args.dst, "wb") as g:
            g.write(newhead)
            g.truncate(dev_size)
            for name, fe, ns, old, new in moves:
                f.seek(old * SECTOR)
                g.seek(new * SECTOR)
                left = ns * SECTOR
                h = hashlib.sha256()
                while left:
                    chunk = f.read(min(8 * MIB, left))
                    if len(chunk) != min(8 * MIB, left):
                        print(f"ABORT: short read of {name}")
                        return 1
                    h.update(chunk)
                    g.write(chunk)
                    left -= len(chunk)
                print(f"  copied {name:<12} {ns * SECTOR:12d} B  sha256 {h.hexdigest()[:16]}")
            g.flush()

    # --- verify the result independently -----------------------------------------------------
    with open(args.dst, "rb") as g:
        head2 = g.read(MIB)
        offs2, _, _, _ = metadata_offsets(head2)
        metas2 = [Meta(head2, o) for o in offs2]
        if len(metas2) != len(metas):
            print("ABORT: metadata copy count changed")
            return 1
        for m in metas2:
            if not m.checksums_ok():
                print(f"ABORT: written metadata at {m.offset} does not verify")
                return 1
        for name, fe, ns, old, new in moves:
            got_ns, _, got_new = metas2[0].extent(fe)
            if (got_ns, got_new) != (ns, new):
                print(f"ABORT: {name} reads back as sectors={got_ns} start={got_new}")
                return 1
        print("written metadata verifies, and every extent reads back at its new start")

        # each filesystem must be byte-identical to the source and carry its own volume name
        with open(args.src, "rb") as f:
            for name, fe, ns, old, new in moves:
                f.seek(old * SECTOR)
                g.seek(new * SECTOR)
                left = ns * SECTOR
                ha, hb = hashlib.sha256(), hashlib.sha256()
                while left:
                    n = min(8 * MIB, left)
                    ha.update(f.read(n))
                    hb.update(g.read(n))
                    left -= n
                if ha.digest() != hb.digest():
                    print(f"ABORT: {name} content differs after the move")
                    return 1
                g.seek(new * SECTOR + 1024)
                sb = g.read(1024)
                (ext4_magic,) = struct.unpack("<H", sb[56:58])
                vol = sb[120:136].rstrip(b"\0").decode(errors="replace")
                tag = "ext4" if ext4_magic == 0xEF53 else f"magic {ext4_magic:#x}"
                print(f"  {name:<12} content identical, {tag}, volume name {vol!r}")

        for off in args.avoid:
            g.seek(off)
            b = g.read(1)
            note = "(zero - a stuck-at-zero bit there is invisible)" if b == b"\x00" else "(NOT ZERO)"
            print(f"  avoided offset {off}: image byte {b.hex()} {note}")
            if b != b"\x00":
                print("ABORT: an avoided offset is not zero in the written image")
                return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
