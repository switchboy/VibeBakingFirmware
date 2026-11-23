#!/usr/bin/env python3
"""Splice replacement filesystem images into a liblp `super` container without touching its metadata.

Why this exists: the Android 14 bring-up needs two edited ext4 images (a system image carrying an
extra bpfloader wrapper, a vendor image with two HAL entries dropped) placed back into the raw super
that is currently on the unit. The extents must land exactly where liblp already says they are, and
nothing else in the container may move: the metadata (geometry, both slots, both backups), the gap
bytes before and between extents and the other three filesystems all have to stay byte-identical,
otherwise a readback of the card cannot be compared against the image we wrote.

The parser is imported from tools/repack_super_place.py unchanged - geometry at 4096, metadata header
and tables, the block-device descriptor. This tool only reads the metadata: it never rewrites a
header, table or checksum, so it refuses when a replacement image is not exactly the length of the
extent it is spliced into.

Subcommands:
  list SUPER                              every partition with its extent (byte offset, length)
  extract SUPER NAME OUT                  copy one extent's bytes to OUT
  splice SUPER OUT --part NAME=IMG ...    copy SUPER to OUT, overwrite each named extent with IMG,
                                          then self-verify OUT against SUPER in 4 MiB windows - every
                                          byte outside a replaced extent must be identical, every byte
                                          inside one must equal its IMG, without holding the container
                                          (3.26 GB) in RAM
  diffchunks OLD NEW --chunk-mib N        which N-MiB chunk indexes differ, and how many

Usage:
  tools/splice_super.py splice raw-super.img super-new.img \
      --part system=system-new.img --part vendor=vendor-new.img
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys

from repack_super_place import (
    GEOMETRY_OFFSET,
    GEOMETRY_SIZE,
    MIB,
    RESERVED,
    SECTOR,
    Meta,
    metadata_offsets,
)

# Streaming window. 4 MiB keeps the self-verify loop far below 100 MB of RAM; reading the whole 3.26 GB
# container twice, as two buffers, would need 6.5 GB.
IO_CHUNK = 4 * MIB


class Partition:
    """A partition whose single linear extent, expressed as byte offsets inside the container."""

    def __init__(self, name: str, extent_index: int, start: int, length: int):
        self.name = name
        self.extent_index = extent_index
        self.start = start
        self.length = length

    @property
    def end(self) -> int:
        return self.start + self.length

    def __str__(self) -> str:
        return (f"{self.name:<12} extent #{self.extent_index:<2} {self.start:12d} .. {self.end:12d}"
                f"  {self.length:12d} B ({self.length / MIB:.2f} MiB, {self.length // SECTOR} sectors)")


def size_of(path: str) -> int:
    return os.path.getsize(path)


def metadata_region_end(path: str) -> int:
    """How far into the container the geometry + metadata slots + backups reach."""
    _, max_size, slots, _, size = read_metadata(path)
    return min(size, RESERVED + GEOMETRY_SIZE * 2 + max_size * slots * 2)


def read_metadata(path: str):
    """Every metadata copy in the container, each verified against its own SHA-256 checksums."""
    size = size_of(path)
    with open(path, "rb") as f:
        f.seek(GEOMETRY_OFFSET)
        geo = f.read(GEOMETRY_SIZE)
    if len(geo) < 52:
        raise ValueError("short read of the liblp geometry")
    # metadata_offsets() checks the geometry magic itself; these three fields decide how far the
    # metadata region reaches, so they are read before asking for the offsets.
    max_size, slots, logical_block_size = struct_unpack_max_size(geo)
    blob = open(path, "rb").read(min(size, RESERVED + GEOMETRY_SIZE * 2 + max_size * slots * 2))
    offs, max_size, slots, logical_block_size = metadata_offsets(blob)
    if not offs:
        raise ValueError(f"{path}: no metadata header found in the metadata region")
    metas = [Meta(blob, o) for o in offs]
    for m in metas:
        if not m.checksums_ok():
            raise ValueError(f"{path}: metadata at {m.offset} does not verify against its own checksums")
    return metas, max_size, slots, logical_block_size, size


def struct_unpack_max_size(geo: bytes):
    import struct

    return struct.unpack("<III", geo[40:52])


def layout(path: str):
    """Slot 0's partition table as byte-offset spans, plus the container's own numbers."""
    metas, max_size, slots, lbs, size = read_metadata(path)
    slot0 = metas[0]
    _, _, _, dev_size = slot0.block_device()
    parts = []
    for name, first_extent, num_extents in slot0.partitions():
        if num_extents != 1:
            raise ValueError(
                f"{name} has {num_extents} extents; this tool only splices single-extent partitions")
        num_sectors, target_type, target_data = slot0.extent(first_extent)
        if target_type != 0:
            raise ValueError(f"{name} extent target_type {target_type} is not linear")
        start, length = target_data * SECTOR, num_sectors * SECTOR
        if start + length > dev_size:
            raise ValueError(f"{name} extent ends at {start + length}, past the device size {dev_size}")
        parts.append(Partition(name, first_extent, start, length))
    parts.sort(key=lambda p: p.start)
    return parts, slot0, size, dev_size, max_size, slots, lbs


def digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(IO_CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def spans(parts: list[Partition], replacements: dict[str, str], total: int):
    """The container split into spans: (container start, container end, image file, offset in that file).

    A gap carries None and is read from the source container at its own byte offset. A replaced extent
    carries its image file, which is read from byte 0 of that file - the extent is exactly one image.
    """
    out = []
    pos = 0
    for p in parts:
        if p.start > pos:
            out.append((pos, p.start, None, pos))
        img = replacements.get(p.name)
        out.append((p.start, p.end, img, 0 if img is not None else p.start))
        pos = p.end
    if pos < total:
        out.append((pos, total, None, pos))
    return out


def self_verify(old: str, new: str, parts: list[Partition], replacements: dict[str, str]):
    """Byte-for-byte check of NEW against OLD, one byte looked at exactly once.

    Bytes outside every replaced extent - the whole metadata region, everything before the first
    extent and every gap - must be identical between OLD and NEW; bytes inside a replaced extent must
    equal the IMG spliced there. Runs in IO_CHUNK windows with seeks, so no whole-container buffer.
    Raises on the first mismatching byte. Returns (bytes compared, windows compared, mismatch count).
    """
    if size_of(old) != size_of(new):
        raise ValueError(f"container size changed: {size_of(old)} B -> {size_of(new)} B")
    total = size_of(new)
    windows = mismatch = 0
    for start, end, img, src_off in spans(parts, replacements, total):
        pos = start
        src = img if img is not None else old
        where = f"inside the extent of {next(n for n, v in replacements.items() if v == img)}" \
            if img is not None else "outside every replaced extent"
        with open(src, "rb") as f, open(new, "rb") as g:
            f.seek(src_off)
            g.seek(pos)
            left = end - pos
            while left:
                n = min(IO_CHUNK, left)
                want, got = f.read(n), g.read(n)
                if len(want) != n or len(got) != n:
                    raise ValueError(f"short read at byte {pos}")
                windows += 1
                if want != got:
                    mismatch += 1
                    first = next(i for i, (a, b) in enumerate(zip(want, got)) if a != b)
                    raise ValueError(
                        f"byte {pos + first} differs ({where}): {want[first:first + 1].hex()} in {src} "
                        f"!= {got[first:first + 1].hex()} in {new}")
                pos += n
                src_off += n
                left -= n
    return total, windows, mismatch


def main() -> int:
    ap = argparse.ArgumentParser(prog="splice_super.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list")
    p_list.add_argument("super")

    p_extract = sub.add_parser("extract")
    p_extract.add_argument("super")
    p_extract.add_argument("name")
    p_extract.add_argument("out")

    p_splice = sub.add_parser("splice")
    p_splice.add_argument("super")
    p_splice.add_argument("out")
    p_splice.add_argument("--part", action="append", default=[], metavar="NAME=IMG",
                          help="fill this partition's extent with IMG; IMG must be exactly the extent length")

    p_diff = sub.add_parser("diffchunks")
    p_diff.add_argument("old")
    p_diff.add_argument("new")
    p_diff.add_argument("--chunk-mib", type=int, default=128, metavar="N")

    args = ap.parse_args()

    if args.cmd == "list":
        parts, slot0, size, dev_size, max_size, slots, lbs = layout(args.super)
        print(f"liblp: metadata max size {max_size} B, slots {slots}, logical block size {lbs} B; "
              f"container {size} B, block device {dev_size} B")
        print(f"metadata copies verify against their own checksums; slot 0 lists "
              f"{len(slot0.partitions())} partitions")
        for p in parts:
            print(f"  {p}")
        gaps, pos = [], 0
        for p in parts:
            if p.start > pos:
                gaps.append((pos, p.start))
            pos = p.end
        if pos < size:
            gaps.append((pos, size))
        print("  unused: " + ", ".join(f"{a}..{b} ({b - a} B)" for a, b in gaps))
        return 0

    if args.cmd == "extract":
        parts, _, _, _, _, _, _ = layout(args.super)
        p = next((x for x in parts if x.name == args.name), None)
        if p is None:
            print(f"ABORT: no partition {args.name!r} in slot 0")
            return 1
        if os.path.abspath(args.out) == os.path.abspath(args.super):
            print(f"ABORT: refusing to write {args.out} over the source container")
            return 1
        h = hashlib.sha256()
        with open(args.super, "rb") as f, open(args.out, "wb") as g:
            f.seek(p.start)
            left = p.length
            while left:
                n = min(IO_CHUNK, left)
                b = f.read(n)
                if len(b) != n:
                    print(f"ABORT: short read of {p.name} at byte {p.start + (p.length - left)}")
                    return 1
                h.update(b)
                g.write(b)
                left -= n
        print(f"extracted {p.name}: {p.length} B from byte {p.start}, sha256 {h.hexdigest()}")
        return 0

    if args.cmd == "splice":
        parts, slot0, size, dev_size, _, _, _ = layout(args.super)
        metas, _, _, _, _ = read_metadata(args.super)
        by_name = {p.name: p for p in parts}

        replacements = {}
        for spec in args.part:
            name, _, img = spec.partition("=")
            if name not in by_name:
                print(f"ABORT: no partition {name!r} in slot 0 (have {', '.join(sorted(by_name))})")
                return 1
            if not os.path.isfile(img):
                print(f"ABORT: no replacement image {img}")
                return 1
            if os.path.abspath(img) == os.path.abspath(args.super):
                print(f"ABORT: {img} is the source container itself")
                return 1
            replacements[name] = img
        if os.path.abspath(args.out) in {os.path.abspath(args.super),
                                         *(os.path.abspath(v) for v in replacements.values())}:
            print(f"ABORT: refusing to write {args.out} over an input")
            return 1

        # --- size refusal ---------------------------------------------------------------------
        # An extent is a fixed span of the container. A short image would leave stale bytes of the
        # old filesystem under it; a long one would spill into the next extent's data.
        for name, img in replacements.items():
            want, got = by_name[name].length, size_of(img)
            if got != want:
                print(f"ABORT: {img} is {got} B but the extent of {name} is {want} B - "
                      f"refusing, an extent must be filled exactly")
                return 1

        # --- build ----------------------------------------------------------------------------
        written = 0
        with open(args.out, "wb") as g:
            for start, end, img, src_off in spans(parts, replacements, size):
                g.seek(start)
                pos = start
                left = end - pos
                with open(img if img is not None else args.super, "rb") as f:
                    f.seek(src_off)
                    while left:
                        n = min(IO_CHUNK, left)
                        b = f.read(n)
                        if len(b) != n:
                            print(f"ABORT: short read at byte {pos}")
                            return 1
                        g.write(b)
                        written += n
                        pos += n
                        src_off += n
                        left -= n
            g.truncate(size)
        print(f"wrote {args.out}: {written} B over {len(spans(parts, replacements, size))} spans, "
              f"size {size_of(args.out)} B")

        # --- self-verify ----------------------------------------------------------------------
        metas_out, _, _, _, _ = read_metadata(args.out)
        if [m.offset for m in metas_out] != [m.offset for m in metas]:
            print(f"ABORT: metadata copy offsets changed: {[m.offset for m in metas]} -> "
                  f"{[m.offset for m in metas_out]}")
            return 1
        parts_out, _, _, _, _, _, _ = layout(args.out)
        if [(p.name, p.extent_index, p.start, p.length) for p in parts_out] != \
           [(p.name, p.extent_index, p.start, p.length) for p in parts]:
            print("ABORT: OUT re-parses with different partitions or extents")
            return 1
        print(f"re-parsed OUT: metadata copies at {[m.offset for m in metas_out]} verify against their "
              f"own checksums; {len(parts_out)} partitions, every extent at its original offset and length")

        first_extent = parts[0].start
        meta_end = metadata_region_end(args.super)
        if meta_end > first_extent:
            print(f"ABORT: the metadata region reaches {meta_end}, past the first extent at {first_extent}")
            return 1
        print(f"metadata region 0..{meta_end} lies entirely before the first extent, so the byte-for-byte "
              f"pass below covers all of it")

        total, windows, mismatch = self_verify(args.super, args.out, parts, replacements)
        print(f"byte-for-byte against SUPER: {total} B in {windows} windows of "
              f"{IO_CHUNK // MIB} MiB, {mismatch} mismatching windows; the whole range before the first "
              f"extent (0..{first_extent}) and every gap outside a replaced extent is identical")
        for name, img in replacements.items():
            p = by_name[name]
            h_img, h_ext = hashlib.sha256(), hashlib.sha256()
            with open(img, "rb") as f, open(args.out, "rb") as g:
                f.seek(0)
                g.seek(p.start)
                left = p.length
                while left:
                    n = min(IO_CHUNK, left)
                    h_img.update(f.read(n))
                    h_ext.update(g.read(n))
                    left -= n
            if h_img.digest() != h_ext.digest():
                print(f"ABORT: the extent of {name} in OUT does not equal {img}")
                return 1
            print(f"  {name:<12} extent {p.start}..{p.end} equals {img} (sha256 {h_img.hexdigest()})")
        untouched = [p.name for p in parts if p.name not in replacements]
        print(f"untouched partitions still in place: {', '.join(untouched)}")
        print(f"sha256 {args.out}: {digest(args.out)}")
        print("OK")
        return 0

    if args.cmd == "diffchunks":
        n = args.chunk_mib * MIB
        if n <= 0:
            print("ABORT: --chunk-mib must be positive")
            return 1
        a, b = size_of(args.old), size_of(args.new)
        shared = min(a, b)
        whole = (shared + n - 1) // n
        differing = []
        with open(args.old, "rb") as f, open(args.new, "rb") as g:
            for i in range(whole):
                if f.read(n) != g.read(n):
                    differing.append(i)
        print(f"chunk size {args.chunk_mib} MiB over {shared} B of shared length -> {whole} chunks")
        if a != b:
            print(f"note: sizes differ ({a} vs {b}); {abs(a - b)} B past the shared length are uncompared")
        print("differing chunk indexes: " + (", ".join(str(i) for i in differing) if differing else "none"))
        print(f"total differing chunks: {len(differing)}")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
