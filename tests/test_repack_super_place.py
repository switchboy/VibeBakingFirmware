#!/usr/bin/env python3
"""tests/test_repack_super_place.py - behaviour tests for tools/repack_super_place.py.

Run:  python3 -m pytest -q tests/test_repack_super_place.py   (or: python3 tests/test_repack_super_place.py)

tools/repack_super_place.py re-places the single LINEAR extents of a liblp super container by
rewriting only each extent's target_data (and, since Nov 24, its num_sectors for --size), resealing
both metadata slots and both backups. The contract under test:

* without --size/--image the old contract stands unchanged: every partition needs --place, sizes
  are untouched, and the moved filesystems are byte-identical to their source;
* --size NAME=MIB sets num_sectors to MIB*2048 - only for a single LINEAR extent; a grown extent
  carries the partition's old bytes followed by zeros; shrinking without --image is refused;
* --image NAME=PATH fills the new extent with PATH's bytes then zero padding, PATH must be <= the
  new size;
* the group table (header 104..116, LpMetadataPartitionGroup = name[36] + flags u32 + maximum_size
  u64) is parsed, and the sum of a group's partition sizes must stay <= its maximum_size (0 =
  unbounded);
* alignment, first_logical_sector, device size, overlap and the --avoid offsets are all checked,
  and nothing is written unless every check passes.

The container here is synthetic but genuine liblp - its geometry/header/table layout is the real
one and Android's own lpdump reads the tool's output (test below, if lpdump is installed). Scratch
lives outside the repo (/tmp/opencode, falling back to the system temp dir). Nothing here opens a
block device or uses adb.
"""

import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, "tools", "repack_super_place.py")
SCRATCH_ROOT = os.environ.get("HU_SCRATCH_ROOT") or "/tmp/opencode"

SECTOR = 512
MIB = 1024 * 1024
GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
RESERVED = 4096
HEADER_MAGIC = 0x414C5030
GEOMETRY_MAGIC = 0x616C4467
HEADER_SIZE = 128
P_SIZE, E_SIZE, G_SIZE, B_SIZE = 52, 24, 48, 64
META_MAX_SIZE = 4096
SLOTS = 2
LBS = 4096
CONTAINER = 16 * MIB
PRIMARY = RESERVED + GEOMETRY_SIZE * 2
FIRST_SECTOR = 2048          # the block device's own first logical sector
ALIGNMENT = 1024
GROUP_MAX = 6 * MIB          # the capacity-bearing group "dyn"
ONE_MIB_EXTENT = 2048        # sectors -> exactly 1 MiB per partition


def scratch() -> str:
    root = SCRATCH_ROOT
    try:
        os.makedirs(root, exist_ok=True)
        return tempfile.mkdtemp(prefix="repack-test-", dir=root)
    except OSError:
        return tempfile.mkdtemp(prefix="repack-test-")


def sha(b: bytes) -> bytes:
    return hashlib_sha256(b).digest()


def hashlib_sha256(b: bytes):
    import hashlib
    return hashlib.sha256(b)


def run(*args: str) -> tuple[int, str]:
    r = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def pat(seed: int, n: int) -> bytes:
    return bytes(((j * (seed + 3) + seed + 1) & 0xFF) for j in range(n))


def build_super(path: str, partitions: list[tuple[str, list[tuple[int, int]], int]],
                groups: list[tuple[str, int, int]] = (("default", 0, 0), ("dyn", 1, GROUP_MAX))) -> bytes:
    """A minimal but genuine liblp container: geometry, 2 metadata slots, 2 backups.

    partitions is [(name, [(start_sector, num_sectors), ...], group_index)]; groups is
    [(name, flags, maximum_size)] with the real struct layout: name[36], flags u32 at 36,
    maximum_size u64 at 40. Returns the container bytes as written.
    """
    tables = bytearray()
    p_off, p_num = 0, len(partitions)
    extent_list = []
    for name, extents, group in partitions:
        first = len(extent_list)
        extent_list += extents
        tables += name.encode().ljust(36, b"\0") + struct.pack("<IIII", 0, first, len(extents), group)
    e_off = len(tables)
    for start, count in extent_list:
        entry = struct.pack("<QIQ", count, 0, start)
        tables += entry + b"\0" * (E_SIZE - len(entry))
    g_off = len(tables)
    for gname, flags, gmax in groups:
        entry = gname.encode().ljust(36, b"\0") + struct.pack("<I", flags) + struct.pack("<Q", gmax)
        tables += entry + b"\0" * (G_SIZE - len(entry))
    b_off = len(tables)
    entry = struct.pack("<QIIQ", FIRST_SECTOR, ALIGNMENT, 0, CONTAINER) + b"super".ljust(36, b"\0")
    tables += entry + b"\0" * (B_SIZE - len(entry))

    hdr = bytearray(HEADER_SIZE)
    hdr[0:12] = struct.pack("<IHHI", HEADER_MAGIC, 10, 0, HEADER_SIZE)
    hdr[44:48] = struct.pack("<I", len(tables))
    hdr[48:80] = sha(tables)
    hdr[80:92] = struct.pack("<III", p_off, p_num, P_SIZE)
    hdr[92:104] = struct.pack("<III", e_off, len(extent_list), E_SIZE)
    hdr[104:116] = struct.pack("<III", g_off, len(groups), G_SIZE)
    hdr[116:128] = struct.pack("<III", b_off, 1, B_SIZE)
    zeroed = bytearray(hdr)
    zeroed[12:44] = b"\0" * 32
    hdr[12:44] = sha(bytes(zeroed))
    meta = bytes(hdr) + bytes(tables)
    assert len(meta) <= META_MAX_SIZE, f"metadata {len(meta)} B exceeds the declared max size"

    geo = bytearray(GEOMETRY_SIZE)
    geo[0:8] = struct.pack("<II", GEOMETRY_MAGIC, 52)
    geo[40:52] = struct.pack("<III", META_MAX_SIZE, SLOTS, LBS)
    zeroed = bytearray(geo[:52])
    zeroed[8:40] = b"\0" * 32
    geo[8:40] = sha(bytes(zeroed))

    buf = bytearray(CONTAINER)
    buf[GEOMETRY_OFFSET:GEOMETRY_OFFSET + GEOMETRY_SIZE] = geo[:GEOMETRY_SIZE]
    backup = PRIMARY + META_MAX_SIZE * SLOTS
    for off in (PRIMARY, PRIMARY + META_MAX_SIZE, backup, backup + META_MAX_SIZE):
        buf[off:off + len(meta)] = meta

    for i, (_, extents, _g) in enumerate(partitions):
        for start, count in extents:
            buf[start * SECTOR:start * SECTOR + count * SECTOR] = pat(i, count * SECTOR)
    with open(path, "wb") as f:
        f.write(buf)
    return bytes(buf)


class RepackSuperPlaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = scratch()
        self.src = os.path.join(self.dir, "super.img")
        # system 1 MiB at 1 MiB, vendor 1 MiB at 2 MiB, product 1 MiB at 6 MiB; all in group "dyn"
        # (group total 3 MiB <= GROUP_MAX 6 MiB; a gap of 3 MiB sits between vendor and product)
        self.original = build_super(self.src, [
            ("system", [(2048, ONE_MIB_EXTENT)], 1),
            ("vendor", [(4096, ONE_MIB_EXTENT)], 1),
            ("product", [(12288, ONE_MIB_EXTENT)], 1),
        ])
        self.sys_off, self.len1 = 2048 * SECTOR, ONE_MIB_EXTENT * SECTOR
        self.vnd_off = 4096 * SECTOR
        self.prod_off, self.prod_len = 12288 * SECTOR, ONE_MIB_EXTENT * SECTOR

    def tearDown(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def read(self, path: str, off: int, n: int) -> bytes:
        with open(path, "rb") as f:
            f.seek(off)
            return f.read(n)

    def meta_end(self) -> int:
        return PRIMARY + META_MAX_SIZE * SLOTS * 2

    # --- old contract, unchanged -----------------------------------------------------------------
    def test_place_only_moves_and_copies_byte_identical(self) -> None:
        dst = os.path.join(self.dir, "moved.img")
        code, o = run(self.src, dst, "--place", "system=2", "--place", "vendor=4", "--place", "product=8")
        self.assertEqual(code, 0, o)
        self.assertIn("OK", o)
        out = open(dst, "rb").read()
        self.assertEqual(len(out), CONTAINER)
        # the geometry block is untouched; the metadata copies are rewritten (resealed), not identical
        self.assertEqual(out[:PRIMARY], self.original[:PRIMARY], "geometry region changed")
        for off in (PRIMARY, PRIMARY + META_MAX_SIZE, PRIMARY + META_MAX_SIZE * 2, PRIMARY + META_MAX_SIZE * 3):
            self.assertEqual(out[off:off + 4], struct.pack("<I", HEADER_MAGIC), f"copy at {off} is gone")
        self.assertIn("written metadata verifies", o)
        self.assertEqual(out[2 * MIB:2 * MIB + self.len1], self.original[self.sys_off:self.sys_off + self.len1])
        self.assertEqual(out[4 * MIB:4 * MIB + self.len1], self.original[self.vnd_off:self.vnd_off + self.len1])
        self.assertEqual(out[8 * MIB:8 * MIB + self.prod_len], self.original[self.prod_off:self.prod_off + self.prod_len])
        self.assertIn("content identical", o)
        self.assertIn("maximum_size", o)  # the group lines are printed from the header's group table

    def test_no_size_still_requires_every_place(self) -> None:
        dst = os.path.join(self.dir, "partial.img")
        code, o = run(self.src, dst, "--place", "system=2", "--place", "vendor=4")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT: no --place given for product", o)
        self.assertFalse(os.path.exists(dst), "a refused run must not write anything")

    # --- --size ------------------------------------------------------------------------------------
    def test_size_grows_copies_old_bytes_then_zero(self) -> None:
        dst = os.path.join(self.dir, "grown.img")
        code, o = run(self.src, dst, "--place", "product=10", "--size", "product=2")
        self.assertEqual(code, 0, o)
        self.assertIn("OK", o)
        out = open(dst, "rb").read()
        self.assertEqual(len(out), CONTAINER)
        # the first MiB of the new 2 MiB extent is the old product content, the second MiB is zero
        self.assertEqual(out[10 * MIB:11 * MIB], self.original[self.prod_off:self.prod_off + self.prod_len])
        self.assertEqual(out[11 * MIB:12 * MIB], b"\0" * MIB)
        # untouched partitions stayed put, with their old bytes
        self.assertEqual(out[self.sys_off:self.sys_off + self.len1], self.original[self.sys_off:self.sys_off + self.len1])
        self.assertEqual(out[self.vnd_off:self.vnd_off + self.len1], self.original[self.vnd_off:self.vnd_off + self.len1])
        # the old product area is now a gap and reads zero
        self.assertEqual(out[self.prod_off:self.prod_off + self.prod_len], b"\0" * self.prod_len)
        # the extent really carries the new size
        self.assertIn("reads back at its new start and size", o)
        self.assertIn("zero-filled tail", o)
        for off in (PRIMARY, PRIMARY + META_MAX_SIZE, PRIMARY + META_MAX_SIZE * 2, PRIMARY + META_MAX_SIZE * 3):
            self.assertEqual(out[off:off + 4], struct.pack("<I", HEADER_MAGIC), f"copy at {off} is gone")

    def test_size_without_place_keeps_current_start(self) -> None:
        dst = os.path.join(self.dir, "grow-in-place.img")
        code, o = run(self.src, dst, "--size", "vendor=2")
        self.assertEqual(code, 0, o)
        self.assertIn("OK", o)
        out = open(dst, "rb").read()
        self.assertEqual(out[self.vnd_off:self.vnd_off + self.len1], self.original[self.vnd_off:self.vnd_off + self.len1])
        self.assertEqual(out[self.vnd_off + self.len1:self.vnd_off + 2 * MIB], b"\0" * MIB)
        # product still sits right behind the grown vendor, untouched
        self.assertEqual(out[self.prod_off:self.prod_off + self.prod_len], self.original[self.prod_off:self.prod_off + self.prod_len])

    def test_shrink_refused_without_image(self) -> None:
        dst = os.path.join(self.dir, "shrink.img")
        code, o = run(self.src, dst, "--size", "product=0")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)
        self.assertIn("shrink", o)
        self.assertFalse(os.path.exists(dst))

    def test_size_past_device_and_moved_overlap_refused(self) -> None:
        dst = os.path.join(self.dir, "bad.img")
        code, o = run(self.src, dst, "--place", "product=15", "--size", "product=2")
        self.assertEqual(code, 1, o)
        self.assertIn("past the device size", o)
        self.assertFalse(os.path.exists(dst))
        code, o = run(self.src, dst, "--place", "system=2", "--place", "vendor=2", "--place", "product=8")
        self.assertEqual(code, 1, o)
        self.assertIn("overlaps", o)
        self.assertFalse(os.path.exists(dst))

    # --- --image ------------------------------------------------------------------------------------
    def test_image_fills_extent_then_zero_padding(self) -> None:
        img = os.path.join(self.dir, "product-new.img")
        content = bytes((j * 7 + 3) & 0xFF for j in range(600 * 1024))
        open(img, "wb").write(content)
        dst = os.path.join(self.dir, "withimg.img")
        code, o = run(self.src, dst, "--place", "product=10", "--size", "product=2", "--image", f"product={img}")
        self.assertEqual(code, 0, o)
        self.assertIn("OK", o)
        out = open(dst, "rb").read()
        self.assertEqual(out[10 * MIB:10 * MIB + len(content)], content)
        self.assertEqual(out[10 * MIB + len(content):12 * MIB], b"\0" * (2 * MIB - len(content)))
        self.assertIn("product-new.img", o)

    def test_image_larger_than_new_size_refused(self) -> None:
        img = os.path.join(self.dir, "big.img")
        open(img, "wb").write(b"\0" * (3 * MIB))
        dst = os.path.join(self.dir, "big.out")
        code, o = run(self.src, dst, "--size", "product=2", "--image", f"product={img}")
        self.assertEqual(code, 1, o)
        self.assertIn("must be <= the new size", o)
        self.assertFalse(os.path.exists(dst))

    # --- group table -------------------------------------------------------------------------------
    def test_group_maximum_size_enforced(self) -> None:
        dst = os.path.join(self.dir, "group.img")
        # system 1 + vendor 1 + product 5 = 7 MiB > the group's 6 MiB
        code, o = run(self.src, dst, "--place", "product=10", "--size", "product=5")
        self.assertEqual(code, 1, o)
        self.assertIn("over its maximum_size", o)
        self.assertIn("group 'dyn'", o)
        self.assertFalse(os.path.exists(dst))
        # exactly at the limit passes
        code, o = run(self.src, dst, "--place", "product=10", "--size", "product=4")
        self.assertEqual(code, 0, o)
        self.assertIn("maximum_size 6291456", o)
        self.assertIn("group 'dyn': 6291456 B", o)

    def test_groups_are_printed_from_the_header_slot(self) -> None:
        code, o = run(self.src, "/nonexistent-dir/out.img")  # fails at the place check; groups print first
        self.assertEqual(code, 1, o)
        self.assertIn("groups: 'default' flags 0x0 maximum_size 0", o)
        self.assertIn("'dyn' flags 0x1 maximum_size 6291456", o)

    # --- multi-extent / avoid ------------------------------------------------------------------------
    def test_multi_extent_partition_refused(self) -> None:
        src = os.path.join(self.dir, "split.img")
        build_super(src, [("system", [(2048, 1024), (8192, 1024)], 1), ("vendor", [(4096, ONE_MIB_EXTENT)], 1)])
        dst = os.path.join(self.dir, "split.out")
        code, o = run(src, dst, "--place", "system=2", "--place", "vendor=4")
        self.assertEqual(code, 1, o)
        self.assertIn("only moves single-extent partitions", o)
        self.assertFalse(os.path.exists(dst))
        # --size must refuse it too
        code, o = run(src, dst, "--place", "system=2", "--place", "vendor=4", "--size", "system=2")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)
        self.assertFalse(os.path.exists(dst))

    def test_avoid_offsets_must_land_outside_every_extent(self) -> None:
        dst = os.path.join(self.dir, "avoid.img")
        # after moving product to 10 MiB, its old area (6 MiB) is a zero gap -> avoid passes
        code, o = run(self.src, dst, "--place", "system=1", "--place", "vendor=2",
                      "--place", "product=10", "--avoid", str(6 * MIB + 7))
        self.assertEqual(code, 0, o)
        self.assertIn("avoided offset", o)
        self.assertIn("zero - a stuck-at-zero bit there is invisible", o)
        # a byte inside the untouched vendor extent cannot be avoided
        bad = os.path.join(self.dir, "avoid-bad.img")
        code, o = run(self.src, bad, "--place", "system=1", "--place", "vendor=2",
                      "--place", "product=10", "--avoid", str(self.vnd_off + 11))
        self.assertEqual(code, 1, o)
        self.assertIn("still lands inside vendor", o)
        self.assertFalse(os.path.exists(bad))


@unittest.skipUnless(shutil.which("lpdump"), "lpdump not installed")
class SyntheticIsRealLiblpTests(unittest.TestCase):
    """The synthetic container, grown and resealed by the tool, must still read back with Android's
    own lpdump - that proves the new num_sectors and group table are genuine liblp, not just
    something this test's parser likes."""

    def test_lpdump_reads_moved_and_grown_image(self) -> None:
        d = scratch()
        try:
            src = os.path.join(d, "super.img")
            build_super(src, [("system", [(2048, ONE_MIB_EXTENT)], 1),
                              ("vendor", [(4096, ONE_MIB_EXTENT)], 1),
                              ("product", [(12288, ONE_MIB_EXTENT)], 1)])
            dst = os.path.join(d, "grown.img")
            code, o = run(src, dst, "--place", "product=10", "--size", "product=2")
            self.assertEqual(code, 0, o)
            r = subprocess.run(["lpdump", dst], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("Name: product", r.stdout)
            self.assertIn("Group: dyn", r.stdout)
            # the grown extent: 2 MiB = 4096 sectors of 512 B, at sector 20480
            self.assertIn("product (4096 sectors)", r.stdout)
            self.assertIn("super: 20480 .. 24576: product", r.stdout)
            self.assertIn("Maximum size: 6291456 bytes", r.stdout)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
