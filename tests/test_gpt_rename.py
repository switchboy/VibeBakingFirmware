#!/usr/bin/env python3
"""tests/test_gpt_rename.py - behaviour tests for tools/gpt_rename.py.

Run:  python3 -m pytest -q   (or: python3 tests/test_gpt_rename.py)

tools/gpt_rename.py edits extracted GPT blobs offline: it must refuse anything that could
produce a bogus partition table, and it must prove afterwards that only the renamed name
fields and the two CRC fields of each header changed. The point of these tests is that
safety contract, not the rename itself.

Scratch lives outside the repo (/tmp/opencode, overridable with HU_SCRATCH_ROOT, falling
back to the system temp dir if that root cannot hold files). Nothing here opens a block
device, uses adb, or touches the network.

The real-card tests run against /run/media/Daan/Opslagmonster/a14-work/card-gpt/ if that
directory is present with head34.bin/tail33.bin; otherwise they skip.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GPT_RENAME = os.path.join(REPO, "tools", "gpt_rename.py")
CARD_DIR = os.environ.get("CARD_GPT_DIR") or "/run/media/Daan/Opslagmonster/a14-work/card-gpt"
CARD_HEAD = os.path.join(CARD_DIR, "head34.bin")
CARD_TAIL = os.path.join(CARD_DIR, "tail33.bin")
CARD_SECTORS = 15523840

SECTOR = 512
GPT_SIG = b"EFI PART"
NAME_OFF = 56
MAX_NAME_CHARS = 36

SCRATCH_ROOT = os.environ.get("HU_SCRATCH_ROOT") or "/tmp/opencode"


def _usable_scratch_root(root):
    """Like tests/test_doc_edit.py: a root counts as usable only if bytes can be written."""
    os.makedirs(root, exist_ok=True)
    try:
        d = tempfile.mkdtemp(prefix="scratch_probe.", dir=root)
        with open(os.path.join(d, "probe.txt"), "w", encoding="utf-8") as fh:
            fh.write("probe\n")
        with open(os.path.join(d, "probe.txt"), "r", encoding="utf-8") as fh:
            if fh.read() != "probe\n":
                raise OSError("probe read-back mismatch")
        shutil.rmtree(d, ignore_errors=True)
        return root
    except OSError:
        return None


def scratch_dir():
    root = _usable_scratch_root(SCRATCH_ROOT)
    if root is None:
        root = tempfile.gettempdir()
    return tempfile.mkdtemp(prefix="gpt_rename.", dir=root)


def run_tool(args, cwd=None):
    """Runs tools/gpt_rename.py and returns (rc, stdout, stderr)."""
    proc = subprocess.run([sys.executable, GPT_RENAME, *args], capture_output=True,
                          text=True, cwd=cwd)
    return proc.returncode, proc.stdout, proc.stderr


def crc(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def header_crc(block: bytes, hdr_size: int) -> int:
    return crc(block[:16] + b"\x00" * 4 + block[20:hdr_size])


def build_gpt(disk_sectors=4096, num_entries=8, entry_size=128, names=("bootloader", "boot", "recovery", "super", "misc")):
    """A small valid GPT in the header layout this card (and GPT fdisk) uses: header_size 92,
    my_lba@24, alt_lba@32, first_usable@40, last_usable@48, GUID@56, flags@72, count@80,
    entry_size@84, entry-array CRC@88. Entries: type GUID@0, unique GUID@16, first@32,
    last@40, attrs@48, name@56..127."""
    entries_len = num_entries * entry_size
    entry_sectors = entries_len // SECTOR
    first_usable = 2 + entry_sectors
    last_usable = disk_sectors - 2 - entry_sectors
    backup_header_lba = disk_sectors - 1

    entries = bytearray(entries_len)
    for i, name in enumerate(names):
        off = i * entry_size
        entries[off:off + 16] = bytes([0x12 + i, 0x34, 0x00, 0x00, 0x56, 0x78, 0x00, 0x00,
                                      0x9a, 0xbc, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44 + i])
        entries[off + 16:off + 32] = bytes([0x78 + i, 0x0a, 0x00, 0x00, 0x4e, 0x67, 0x00, 0x00,
                                            0x43, 0xc2, 0x00, 0x00, 0x5d, 0x8c, 0x00, 0x01 + i])
        start = first_usable + i * 100
        end = start + 99
        entries[off + 32:off + 40] = struct.pack("<Q", start)
        entries[off + 40:off + 48] = struct.pack("<Q", end)
        enc = name.encode("utf-16-le")
        entries[off + NAME_OFF:off + NAME_OFF + len(enc)] = enc

    ent_crc = crc(bytes(entries))

    def make_header(my_lba: int, alt_lba: int) -> bytearray:
        h = bytearray(SECTOR)
        h[0:8] = GPT_SIG
        h[8:12] = struct.pack("<I", 0x00010000)
        h[12:16] = struct.pack("<I", 92)          # header_size
        h[24:32] = struct.pack("<Q", my_lba)
        h[32:40] = struct.pack("<Q", alt_lba)
        h[40:48] = struct.pack("<Q", first_usable)
        h[48:56] = struct.pack("<Q", last_usable)
        h[56:72] = b"\x23\x00\x00\x00\x00\x00\x4c\x4a\x80\x00\x69\x90\x00\x00\x5a\xbb"
        h[72:80] = struct.pack("<Q", 2)           # attributes
        h[80:84] = struct.pack("<I", num_entries)
        h[84:88] = struct.pack("<I", entry_size)
        h[88:92] = struct.pack("<I", ent_crc)
        h[16:20] = struct.pack("<I", header_crc(bytes(h[:92]), 92))
        return h

    head = bytearray(2 * SECTOR + entries_len)
    head[:SECTOR] = b"\x00" * SECTOR
    head[446 + 4] = 0xEE                            # protective MBR record
    head[446 + 8:446 + 12] = struct.pack("<I", 1)
    head[446 + 12:446 + 16] = struct.pack("<I", min(disk_sectors - 1, 0xFFFFFFFF))
    head[510:512] = b"\x55\xAA"
    head[SECTOR:2 * SECTOR] = make_header(1, backup_header_lba)
    head[2 * SECTOR:] = entries

    tail = bytearray(entries_len + SECTOR)
    tail[:entries_len] = entries
    tail[entries_len:] = make_header(backup_header_lba, 1)
    return bytes(head), bytes(tail), disk_sectors


def blob_paths(disk, tmp):
    head, tail, sectors = disk
    hp = os.path.join(tmp, "head.bin")
    tp = os.path.join(tmp, "tail.bin")
    with open(hp, "wb") as fh:
        fh.write(head)
    with open(tp, "wb") as fh:
        fh.write(tail)
    return hp, tp, sectors


def decode(entry: bytes) -> str:
    return entry[NAME_OFF:128].decode("utf-16-le").rstrip("\x00")


def diff_set(a: bytes, b: bytes) -> set:
    return {i for i, (x, y) in enumerate(zip(a, b)) if x != y}


def allowed_set(head_len: int, tail_len: int, indices, entry_size=128) -> set:
    """The byte indices a rename of `indices` may legitimately touch."""
    out = set()
    field = entry_size - NAME_OFF
    for idx in indices:
        for base in (2 * SECTOR + (idx - 1) * entry_size, (idx - 1) * entry_size):
            out.update(range(base + NAME_OFF, base + NAME_OFF + field))
    out.update(range(SECTOR + 16, SECTOR + 20))
    out.update(range(SECTOR + 88, SECTOR + 92))
    tail_hdr = tail_len - SECTOR
    out.update(range(tail_hdr + 16, tail_hdr + 20))
    out.update(range(tail_hdr + 88, tail_hdr + 92))
    return out


class RenameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch_dir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_synthetic_rename_produces_valid_crcs(self):
        hp, tp, sectors = blob_paths(build_gpt(), self.tmp)
        oh = os.path.join(self.tmp, "out-head.bin")
        ot = os.path.join(self.tmp, "out-tail.bin")
        rc, out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                 "--rename", "2:boot:sd_boot", "--rename", "4:super:sd_super",
                                 "--out-head", oh, "--out-tail", ot])
        self.assertEqual(rc, 0, err)
        self.assertIn("partition 2: 'boot' -> 'sd_boot'", out)
        self.assertIn("partition 4: 'super' -> 'sd_super'", out)
        self.assertIn("(OK)", out)
        self.assertIn("sha256", out)
        # independent re-parse of the outputs
        rc2, out2, err2 = run_tool(["--verify", oh, ot, "--disk-sectors", str(sectors)])
        self.assertEqual(rc2, 0, err2)
        self.assertIn("CRC VALID", out2)
        self.assertIn("name='sd_boot'", out2)
        self.assertIn("name='sd_super'", out2)
        self.assertNotIn("name='boot'", out2)
        self.assertIn("'bootloader'", out2)

    def test_only_name_and_crc_bytes_change(self):
        head, tail, sectors = build_gpt()
        hp, tp, _ = blob_paths((head, tail, sectors), self.tmp)
        oh = os.path.join(self.tmp, "out-head.bin")
        ot = os.path.join(self.tmp, "out-tail.bin")
        rc, out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                 "--rename", "2:boot:sd_boot", "--rename", "4:super:sd_super",
                                 "--out-head", oh, "--out-tail", ot])
        self.assertEqual(rc, 0, err)
        self.assertNotIn("NOT ALLOWED", out)
        new_head = open(oh, "rb").read()
        new_tail = open(ot, "rb").read()
        self.assertEqual(len(new_head), len(head))
        self.assertEqual(len(new_tail), len(tail))
        allowed = allowed_set(len(head), len(tail), (2, 4))
        changed = diff_set(head, new_head) | diff_set(tail, new_tail)
        self.assertTrue(changed, "something must change")
        self.assertEqual(changed - allowed, set(), "bytes outside the name/CRC fields changed")
        # sector 0 (protective MBR) untouched
        self.assertEqual(new_head[:SECTOR], head[:SECTOR])
        # CRC fields really did change
        self.assertNotEqual(new_head[SECTOR + 16:SECTOR + 20], head[SECTOR + 16:SECTOR + 20])
        self.assertNotEqual(new_head[SECTOR + 88:SECTOR + 92], head[SECTOR + 88:SECTOR + 92])
        self.assertNotEqual(new_tail[len(tail) - SECTOR + 16:len(tail) - SECTOR + 20],
                            tail[len(tail) - SECTOR + 16:len(tail) - SECTOR + 20])
        # entry-array CRC is the crc32 of the new array, in both headers
        new_entries = new_head[2 * SECTOR:]
        want = struct.pack("<I", crc(new_entries))
        self.assertEqual(new_head[SECTOR + 88:SECTOR + 92], want)
        self.assertEqual(new_tail[len(tail) - SECTOR + 88:len(tail) - SECTOR + 92], want)
        # header CRC is crc32 over header_size (92) with the CRC field zeroed
        want_hdr_p = struct.pack("<I", header_crc(new_head[SECTOR:2 * SECTOR], 92))
        self.assertEqual(new_head[SECTOR + 16:SECTOR + 20], want_hdr_p)
        want_hdr_b = struct.pack("<I", header_crc(new_tail[len(tail) - SECTOR:], 92))
        self.assertEqual(new_tail[len(tail) - SECTOR + 16:len(tail) - SECTOR + 20], want_hdr_b)

    def test_primary_and_backup_arrays_stay_identical(self):
        head, tail, sectors = build_gpt()
        hp, tp, _ = blob_paths((head, tail, sectors), self.tmp)
        oh = os.path.join(self.tmp, "out-head.bin")
        ot = os.path.join(self.tmp, "out-tail.bin")
        rc, out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                 "--rename", "2:boot:sd_boot", "--rename", "4:super:sd_super",
                                 "--out-head", oh, "--out-tail", ot])
        self.assertEqual(rc, 0, err)
        self.assertIn("byte-identical (after)", out)
        new_head = open(oh, "rb").read()
        new_tail = open(ot, "rb").read()
        entries_len = len(new_head) - 2 * SECTOR
        self.assertEqual(new_head[2 * SECTOR:], new_tail[:entries_len])
        # both arrays carry the new names
        self.assertEqual(decode(new_head[2 * SECTOR + 128:2 * SECTOR + 256]), "sd_boot")
        self.assertEqual(decode(new_tail[128:256]), "sd_boot")
        self.assertEqual(decode(new_head[2 * SECTOR + 384:2 * SECTOR + 512]), "sd_super")
        self.assertEqual(decode(new_tail[384:512]), "sd_super")

    def test_refuses_when_old_name_does_not_match(self):
        hp, tp, sectors = blob_paths(build_gpt(), self.tmp)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:nonsense:sd_boot",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("REFUSED", err)
        self.assertIn("primary array holds 'boot'", err)
        # nothing written
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "o1.bin")))

    def test_refuses_on_corrupt_entry_array_crc(self):
        head, tail, sectors = build_gpt()
        broken = bytearray(head)
        broken[2 * SECTOR + 30] ^= 0xFF            # inside the entry array -> CRC no longer valid
        hp, tp, _ = blob_paths((bytes(broken), tail, sectors), self.tmp)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:boot:sd_boot",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("entry-array CRC", err)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "o1.bin")))

    def test_refuses_on_corrupt_header_crc(self):
        head, tail, sectors = build_gpt()
        broken = bytearray(head)
        broken[SECTOR + 60] ^= 0xFF               # inside header_size (92): the header CRC no longer matches
        hp, tp, _ = blob_paths((bytes(broken), tail, sectors), self.tmp)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:boot:sd_boot",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("header CRC", err)

    def test_refuses_on_too_long_name(self):
        hp, tp, sectors = blob_paths(build_gpt(), self.tmp)
        long_name = "a" * (MAX_NAME_CHARS + 1)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", f"2:boot:{long_name}",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("limit is 36", err)

    def test_refuses_on_non_ascii_name(self):
        hp, tp, sectors = blob_paths(build_gpt(), self.tmp)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:boot:super\u00e9",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("not pure ASCII", err)

    def test_refuses_duplicate_rename_of_one_partition(self):
        hp, tp, sectors = blob_paths(build_gpt(), self.tmp)
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:boot:sd_boot", "--rename", "2:boot:sd_boot2",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("both target partition 2", err)

    def test_refuses_when_backup_array_disagrees(self):
        head, tail, sectors = build_gpt()
        broken_tail = bytearray(tail)
        enc = "otherboot".encode("utf-16-le")
        broken_tail[128 + NAME_OFF:128 + NAME_OFF + len(enc)] = enc
        hp = os.path.join(self.tmp, "h.bin")
        tp = os.path.join(self.tmp, "t.bin")
        with open(hp, "wb") as fh:
            fh.write(head)
        with open(tp, "wb") as fh:
            fh.write(bytes(broken_tail))
        rc, _out, err = run_tool(["--head", hp, "--tail", tp, "--disk-sectors", str(sectors),
                                  "--rename", "2:boot:sd_boot",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("REFUSED", err)
        self.assertTrue("entry-array CRC" in err or "byte-identical" in err, err)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "o1.bin")))


class RealCardTests(unittest.TestCase):
    """Runs against the measured card blobs when they are present, else skips."""

    def setUp(self):
        if not (os.path.isfile(CARD_HEAD) and os.path.isfile(CARD_TAIL)):
            self.skipTest(f"no real card blobs in {CARD_DIR}")
        self.tmp = scratch_dir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_verify_reports_valid_crcs_and_names(self):
        rc, out, err = run_tool(["--verify", CARD_HEAD, CARD_TAIL, "--disk-sectors", str(CARD_SECTORS)])
        self.assertEqual(rc, 0, err)
        self.assertIn("CRC VALID", out)
        self.assertIn("name='metadata'", out)
        self.assertIn("name='super'", out)
        self.assertIn("128 entries x 128", out)

    def test_rename_real_card(self):
        oh = os.path.join(self.tmp, "new-head.bin")
        ot = os.path.join(self.tmp, "new-tail.bin")
        rc, out, err = run_tool(["--head", CARD_HEAD, "--tail", CARD_TAIL,
                                 "--disk-sectors", str(CARD_SECTORS),
                                 "--rename", "12:metadata:sd_metadata",
                                 "--rename", "14:super:sd_super",
                                 "--out-head", oh, "--out-tail", ot])
        self.assertEqual(rc, 0, err)
        self.assertIn("byte-identical (after)", out)
        self.assertIn("head sector 0 (protective MBR): unchanged", out)
        self.assertNotIn("NOT ALLOWED", out)
        head = open(CARD_HEAD, "rb").read()
        tail = open(CARD_TAIL, "rb").read()
        new_head = open(oh, "rb").read()
        new_tail = open(ot, "rb").read()
        changed = diff_set(head, new_head) | diff_set(tail, new_tail)
        self.assertEqual(changed - allowed_set(len(head), len(tail), (12, 14)), set())
        entries_len = len(new_head) - 2 * SECTOR
        self.assertEqual(new_head[2 * SECTOR:], new_tail[:entries_len])
        self.assertEqual(decode(new_head[2 * SECTOR + 11 * 128:2 * SECTOR + 12 * 128]), "sd_metadata")
        self.assertEqual(decode(new_tail[11 * 128:12 * 128]), "sd_metadata")
        self.assertEqual(decode(new_head[2 * SECTOR + 13 * 128:2 * SECTOR + 14 * 128]), "sd_super")
        self.assertEqual(decode(new_tail[13 * 128:14 * 128]), "sd_super")

    def test_real_card_refuses_stale_old_name(self):
        rc, _out, err = run_tool(["--head", CARD_HEAD, "--tail", CARD_TAIL,
                                  "--disk-sectors", str(CARD_SECTORS),
                                  "--rename", "12:super:sd_metadata",
                                  "--out-head", os.path.join(self.tmp, "o1.bin"),
                                  "--out-tail", os.path.join(self.tmp, "o2.bin")])
        self.assertEqual(rc, 1)
        self.assertIn("primary array holds 'metadata'", err)


if __name__ == "__main__":
    unittest.main()
