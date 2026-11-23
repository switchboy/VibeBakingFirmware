#!/usr/bin/env python3
"""tests/test_splice_super.py - behaviour tests for tools/splice_super.py.

Run:  python3 -m pytest -q   (or: python3 tests/test_splice_super.py)

tools/splice_super.py copies a liblp super container and overwrites the byte span of a named
partition's single extent with a replacement filesystem image. The safety contract being tested is
that it never touches anything else: metadata (geometry, both slots, both backups), the gaps between
extents and the partitions that were not named must stay byte-identical, and it must refuse a
replacement image that is not exactly the length of the extent - a short image would leave stale
bytes of the old filesystem under the extent, a long one would spill into the next extent.

The container used here is a synthetic liblp image built in this file, small enough to compare
byte-for-byte inside the test. Its geometry/header/table layout is the real one (parsed by
tools/repack_super_place.py, and cross-checked with lpdump when that tool is installed).

The tests that run against the real card image are skipped unless HU_REAL_SUPER_TESTS=1 is set, so
the default test run stays fast. Nothing here opens a block device, uses adb, or touches the network.
Scratch lives outside the repo (/tmp/opencode, falling back to the system temp dir).
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
TOOL = os.path.join(REPO, "tools", "splice_super.py")
SCRATCH_ROOT = os.environ.get("HU_SCRATCH_ROOT") or "/tmp/opencode"
REAL_SUPER = os.environ.get("REAL_SUPER_IMG") or "/run/media/Daan/Opslagmonster/a14-work/a14chk-shapeA/raw-super.img"
REAL_SPLICED = os.environ.get("REAL_SPLICED_IMG") or "/run/media/Daan/Opslagmonster/a14-work/super9/super-new.img"

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
CONTAINER = 8 * MIB
PRIMARY = RESERVED + GEOMETRY_SIZE * 2


def scratch() -> str:
    root = SCRATCH_ROOT
    try:
        os.makedirs(root, exist_ok=True)
        d = tempfile.mkdtemp(prefix="splice-test-", dir=root)
    except OSError:
        d = tempfile.mkdtemp(prefix="splice-test-")
    return d


def sha(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def run(*args: str) -> tuple[int, str]:
    """Run tools/splice_super.py in <scratch> and return (exit code, stdout+stderr)."""
    r = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def build_super(path: str, extents: list[tuple[str, int, int]]) -> bytes:
    """A minimal but genuine liblp container: geometry, 2 metadata slots and their backups.

    extents is [(name, start_sector, num_sectors)]; every partition gets exactly one linear extent.
    Returns the container bytes as written, so tests can compare against them afterwards.
    """
    # --- tables ---------------------------------------------------------------------
    tables = bytearray()
    p_off, p_num = 0, len(extents)
    for name, _, _ in extents:
        tables += name.encode().ljust(36, b"\0") + struct.pack("<IIII", 0, len(tables) // P_SIZE, 1, 1)
    e_off = len(tables)
    for _, start, count in extents:
        entry = struct.pack("<QIQ", count, 0, start)
        tables += entry + b"\0" * (E_SIZE - len(entry))
    g_off = len(tables)
    for gname, gmax in (("default", 0), ("dyn", CONTAINER)):
        entry = gname.encode().ljust(36, b"\0") + struct.pack("<QI", gmax, 0)
        tables += entry + b"\0" * (G_SIZE - len(entry))
    b_off = len(tables)
    entry = struct.pack("<QIIQ", 2048, LBS, 0, CONTAINER) + b"super".ljust(36, b"\0")
    tables += entry + b"\0" * (B_SIZE - len(entry))

    # --- header, sealed with its own SHA-256 checksums --------------------------------
    hdr = bytearray(HEADER_SIZE)
    hdr[0:12] = struct.pack("<IHHI", HEADER_MAGIC, 10, 0, HEADER_SIZE)
    hdr[44:48] = struct.pack("<I", len(tables))
    hdr[48:80] = sha(tables)
    hdr[80:92] = struct.pack("<III", p_off, p_num, P_SIZE)
    hdr[92:104] = struct.pack("<III", e_off, len(extents), E_SIZE)
    hdr[104:116] = struct.pack("<III", g_off, 2, G_SIZE)
    hdr[116:128] = struct.pack("<III", b_off, 1, B_SIZE)
    zeroed = bytearray(hdr)
    zeroed[12:44] = b"\0" * 32
    hdr[12:44] = sha(bytes(zeroed))
    meta = bytes(hdr) + bytes(tables)
    assert len(meta) <= META_MAX_SIZE, f"metadata {len(meta)} B exceeds the declared max size"

    # --- geometry -------------------------------------------------------------------
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

    # --- partition content ----------------------------------------------------------
    for i, (name, start, count) in enumerate(extents):
        pat = bytes(((j * (i + 3) + i + 1) & 0xFF) for j in range(count * SECTOR))
        buf[start * SECTOR:start * SECTOR + count * SECTOR] = pat
    with open(path, "wb") as f:
        f.write(buf)
    return bytes(buf)


class SpliceSuperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = scratch()
        self.src = os.path.join(self.dir, "super.img")
        self.original = build_super(self.src, [("system", 2048, 512), ("vendor", 4096, 512)])
        self.sys_off, self.sys_len = 2048 * SECTOR, 512 * SECTOR
        self.vnd_off, self.vnd_len = 4096 * SECTOR, 512 * SECTOR

    def tearDown(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    # --- helpers ---------------------------------------------------------------------
    def meta_end(self) -> int:
        """Everything liblp owns: geometry + both slots + both backups."""
        return PRIMARY + META_MAX_SIZE * SLOTS * 2

    def read(self, path: str, off: int, n: int) -> bytes:
        with open(path, "rb") as f:
            f.seek(off)
            return f.read(n)

    # --- tests -----------------------------------------------------------------------
    def test_list_reports_extents(self) -> None:
        code, out = run("list", self.src)
        self.assertEqual(code, 0, out)
        self.assertIn(f"{self.sys_off:12d} .. ", out)
        self.assertIn(f"{self.sys_len:12d} B", out)
        self.assertIn(f"{self.vnd_off:12d} .. ", out)
        self.assertIn("slot 0 lists 2 partitions", out)

    def test_extract_copies_exactly_the_extent(self) -> None:
        out = os.path.join(self.dir, "system.out")
        code, o = run("extract", self.src, "system", out)
        self.assertEqual(code, 0, o)
        got = open(out, "rb").read()
        self.assertEqual(got, self.original[self.sys_off:self.sys_off + self.sys_len])
        self.assertEqual(len(got), self.sys_len)
        self.assertIn(hashlib.sha256(got).hexdigest(), o)

    def test_extract_unknown_partition_refuses(self) -> None:
        code, o = run("extract", self.src, "telephony", os.path.join(self.dir, "x"))
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)

    def test_splice_replaces_only_the_named_extents(self) -> None:
        new_sys = bytes((j * 5 + 2) & 0xFF for j in range(self.sys_len))
        new_vnd = bytes((j * 11 + 7) & 0xFF for j in range(self.vnd_len))
        sys_img, vnd_img = os.path.join(self.dir, "system-new.img"), os.path.join(self.dir, "vendor-new.img")
        open(sys_img, "wb").write(new_sys)
        open(vnd_img, "wb").write(new_vnd)
        dst = os.path.join(self.dir, "super-new.img")
        code, o = run("splice", self.src, dst, "--part", f"system={sys_img}", "--part", f"vendor={vnd_img}")
        self.assertEqual(code, 0, o)
        self.assertIn("OK", o)

        out = open(dst, "rb").read()
        self.assertEqual(len(out), CONTAINER, "the container size must not change")
        # the whole metadata region, and every gap, must be byte-identical
        self.assertEqual(out[:self.sys_off], self.original[:self.sys_off])
        self.assertEqual(out[self.meta_end():self.sys_off], self.original[self.meta_end():self.sys_off])
        self.assertEqual(out[self.sys_off + self.sys_len:self.vnd_off],
                         self.original[self.sys_off + self.sys_len:self.vnd_off])
        self.assertEqual(out[self.vnd_off + self.vnd_len:], self.original[self.vnd_off + self.vnd_len:])
        # the replaced extents must carry exactly the new images
        self.assertEqual(out[self.sys_off:self.sys_off + self.sys_len], new_sys)
        self.assertEqual(out[self.vnd_off:self.vnd_off + self.vnd_len], new_vnd)
        # every metadata copy still reads back
        for off in (PRIMARY, PRIMARY + META_MAX_SIZE, PRIMARY + META_MAX_SIZE * 2, PRIMARY + META_MAX_SIZE * 3):
            self.assertEqual(out[off:off + 4], struct.pack("<I", HEADER_MAGIC), f"copy at {off} is gone")

    def test_splice_copies_an_untouched_extent_from_its_own_offset(self) -> None:
        """A partition that is not named must be copied from the container at its own byte offset.

        An earlier version of spans() handed the previous span's source offset to untouched extents,
        which produced a shifted copy of every later partition while the self-verify still passed -
        the build and the verify shared the same wrong offsets, so only this byte check catches it.
        """
        src = os.path.join(self.dir, "three.img")
        original = build_super(src, [("system", 2048, 512), ("vendor", 4096, 512), ("product", 6144, 512)])
        prod_off, prod_len = 6144 * SECTOR, 512 * SECTOR
        sys_img = os.path.join(self.dir, "system-only.img")
        open(sys_img, "wb").write(bytes((j * 5 + 2) & 0xFF for j in range(self.sys_len)))
        dst = os.path.join(self.dir, "three-new.img")
        code, o = run("splice", src, dst, "--part", f"system={sys_img}")
        self.assertEqual(code, 0, o)
        out = open(dst, "rb").read()
        self.assertEqual(out[self.vnd_off:self.vnd_off + self.vnd_len],
                         original[self.vnd_off:self.vnd_off + self.vnd_len], "vendor was not copied correctly")
        self.assertEqual(out[prod_off:prod_off + prod_len],
                         original[prod_off:prod_off + prod_len], "product was not copied correctly")
        self.assertEqual(out[self.sys_off:self.sys_off + self.sys_len],
                         open(sys_img, "rb").read())
        self.assertIn("untouched partitions still in place: vendor, product", o)

    def test_splice_refuses_a_wrong_size_image(self) -> None:
        short = os.path.join(self.dir, "short.img")
        open(short, "wb").write(b"\0" * (self.sys_len - 1))
        dst = os.path.join(self.dir, "super-new.img")
        code, o = run("splice", self.src, dst, "--part", f"system={short}")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)
        self.assertIn("refusing", o)
        self.assertFalse(os.path.exists(dst), "a refused splice must not write anything")

        long = os.path.join(self.dir, "long.img")
        open(long, "wb").write(b"\0" * (self.vnd_len + SECTOR))
        code, o = run("splice", self.src, dst, "--part", f"vendor={long}")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)
        self.assertFalse(os.path.exists(dst))

    def test_splice_refuses_unknown_partition_and_self_overwrite(self) -> None:
        img = os.path.join(self.dir, "ok.img")
        open(img, "wb").write(b"\0" * self.sys_len)
        code, o = run("splice", self.src, os.path.join(self.dir, "dst.img"), "--part", f"nope={img}")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)
        code, o = run("splice", self.src, self.src, "--part", f"system={img}")
        self.assertEqual(code, 1, o)
        self.assertIn("ABORT", o)

    def test_diffchunks_reports_indices_and_count(self) -> None:
        other = os.path.join(self.dir, "other.img")
        mutated = bytearray(self.original)
        # one byte each in chunk 0 (offset 0), in the system extent (chunk 1) and in chunk 3
        mutated[0] ^= 0xFF
        mutated[self.sys_off + 10] ^= 0xFF
        mutated[5 * MIB + 5] ^= 0xFF
        open(other, "wb").write(bytes(mutated))
        code, o = run("diffchunks", self.src, other, "--chunk-mib", "1")
        self.assertEqual(code, 0, o)
        self.assertIn("differing chunk indexes: 0, 1, 5", o)
        self.assertIn("total differing chunks: 3", o)
        # the same differences, seen as 4 MiB chunks: chunk 0 holds offsets 0 and 1 MiB, chunk 1 holds 3 MiB
        code, o = run("diffchunks", self.src, other, "--chunk-mib", "4")
        self.assertEqual(code, 0, o)
        self.assertIn("differing chunk indexes: 0, 1", o)
        self.assertIn("total differing chunks: 2", o)
        # identical images report nothing
        same = os.path.join(self.dir, "same.img")
        shutil.copyfile(self.src, same)
        code, o = run("diffchunks", self.src, same, "--chunk-mib", "4")
        self.assertEqual(code, 0, o)
        self.assertIn("differing chunk indexes: none", o)
        self.assertIn("total differing chunks: 0", o)

    def test_diffchunks_reports_a_size_difference(self) -> None:
        other = os.path.join(self.dir, "short.img")
        open(other, "wb").write(self.original[:CONTAINER - MIB])
        code, o = run("diffchunks", self.src, other, "--chunk-mib", "1")
        self.assertEqual(code, 0, o)
        self.assertIn("sizes differ", o)
        self.assertIn("total differing chunks: 0", o)


@unittest.skipUnless(os.environ.get("HU_REAL_SUPER_TESTS") == "1",
                     "set HU_REAL_SUPER_TESTS=1 to run against the real card image")
class RealCardImageTests(unittest.TestCase):
    """The real 3.26 GB container, if HU_REAL_SUPER_TESTS=1 is set."""

    def test_list_matches_lpdump(self) -> None:
        self.assertTrue(os.path.isfile(REAL_SUPER), REAL_SUPER)
        code, o = run("list", REAL_SUPER)
        self.assertEqual(code, 0, o)
        self.assertIn("system       extent #0       1048576 .. ", o)
        self.assertIn("1012871168 B", o)
        self.assertIn("vendor       extent #1    1013972992 .. ", o)
        self.assertIn("556072960 B", o)

    @unittest.skipUnless(os.path.isfile(REAL_SPLICED), f"no spliced image at {REAL_SPLICED}")
    def test_diffchunks_of_the_real_splice(self) -> None:
        code, o = run("diffchunks", REAL_SUPER, REAL_SPLICED, "--chunk-mib", "128")
        self.assertEqual(code, 0, o)
        self.assertIn("total differing chunks:", o)


@unittest.skipUnless(shutil.which("lpdump"), "lpdump not installed")
class SyntheticIsRealLiblpTests(unittest.TestCase):
    """The synthetic container must be readable by Android's own lpdump - that is what proves the
    test image is a genuine liblp container rather than something this test's parser happens to like."""

    def test_lpdump_reads_it(self) -> None:
        d = scratch()
        try:
            path = os.path.join(d, "super.img")
            build_super(path, [("system", 2048, 512), ("vendor", 4096, 512)])
            r = subprocess.run(["lpdump", path], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("Name: system", r.stdout)
            self.assertIn("Name: vendor", r.stdout)
            self.assertIn("linear super 2048", r.stdout)
            self.assertIn("linear super 4096", r.stdout)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
