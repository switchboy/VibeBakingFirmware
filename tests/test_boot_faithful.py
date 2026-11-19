#!/usr/bin/env python3
"""tests/test_boot_faithful.py - behaviour tests for tools/rebuild_boot_faithful.py (**D60**, **D68**).

Run:  python3 -m unittest discover -s tests   (or: python3 tests/test_boot_faithful.py)

Scratch lives outside the repo, the same way tests/test_doc_edit.py picks it; nothing here touches the
head unit or the NAS. These images are synthetic - a header page, a kernel blob, a ramdisk, a `second`
blob and a tail that mimics the OEM partition's structure (splash bytes, then a resource header whose
entry record names a DTB by a 20-byte SHA1, then that DTB). The contract under test is the one the Nov 19
identity gate proved on the real capture:

* a stock -> stock round trip must reproduce the OEM image byte-for-byte;
* a payload-fed image may change only `ramdisk_size`, the cmdline field, its own ramdisk and its own
  padding, and everything from its content end onward must be the OEM's bytes verbatim;
* it refuses when the payload's components reach the resource header, when a kernel or `second` blob
  differs, and when a resource entry's declared SHA1 does not match the bytes it names.
"""

import hashlib
import os
import shutil
import struct
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))

import rebuild_boot_faithful as R  # noqa: E402

PAGE = 2048
DTB = b'\xd0\x0d\xfe\xed'


def _usable_scratch_root(root):
    """A root is usable only if bytes can actually be written there - mkdir alone succeeds on a
    quota-limited tmpfs, which is what made this workstation's /tmp unusable on Nov 18."""
    os.makedirs(root, exist_ok=True)
    try:
        d = tempfile.mkdtemp(prefix="scratch_probe.", dir=root)
        with open(os.path.join(d, "probe.txt"), "w", encoding="utf-8") as fh:
            fh.write("probe\n")
        if open(os.path.join(d, "probe.txt"), encoding="utf-8").read() != "probe\n":
            return None
    except OSError:
        return None
    shutil.rmtree(d, ignore_errors=True)
    return root


SCRATCH_ROOT = None
for _root in (os.environ.get("HU_SCRATCH_ROOT") or "/tmp/opencode", tempfile.gettempdir(),
              os.path.join(REPO, ".scratch_tests")):
    SCRATCH_ROOT = _usable_scratch_root(_root)
    if SCRATCH_ROOT:
        break
if SCRATCH_ROOT is None:
    raise SystemExit("tests: no writable scratch root (set HU_SCRATCH_ROOT to a writable directory)")


def roundup(n):
    return ((n + PAGE - 1) // PAGE) * PAGE


def resource(dtb_data, blocks=3):
    """A resource image: header record, one entry record naming `dtb_data` by SHA1, padding, then the data."""
    hdr = bytearray(512)
    hdr[0:4] = b'RSCE'
    struct.pack_into('<I', hdr, 12, 1)
    rec = bytearray(512)
    rec[0:4] = b'ENTR'
    rec[4:4 + len(b'rk-kernel.dtb')] = b'rk-kernel.dtb'
    rec[224:244] = hashlib.sha1(dtb_data).digest()
    struct.pack_into('<I', rec, 256, 20)
    struct.pack_into('<I', rec, 260, blocks)
    struct.pack_into('<I', rec, 264, len(dtb_data))
    return bytes(hdr) + bytes(rec) + b'\x00' * (blocks * 512 - 1024) + dtb_data


def dtb(size):
    return DTB + struct.pack('>I', size) + b'\x33' * (size - 8)


def make_image(kernel, ramdisk, second, tail, cmdline=b"androidboot.hardware=rk3399"):
    """An image laid out exactly the way a Rockchip loader computes it: add the header page, then round."""
    ks, rs, ss = len(kernel), len(ramdisk), len(second)
    ro, so = roundup(PAGE + ks), roundup(PAGE + ks + rs)
    ce = roundup(so + ss)
    hdr = bytearray(PAGE)
    hdr[0:8] = b'ANDROID!'
    struct.pack_into('<I', hdr, 8, ks)
    struct.pack_into('<I', hdr, 16, rs)
    struct.pack_into('<I', hdr, 24, ss)
    hdr[64:64 + len(cmdline)] = cmdline
    img = bytearray(hdr) + kernel
    img += b'\x00' * (ro - len(img)) + ramdisk
    img += b'\x00' * (so - len(img)) + second
    img += b'\x00' * (ce - len(img)) + tail
    return bytes(img)


class RebuildTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="boot_faithful_tests.", dir=SCRATCH_ROOT)
        self.kernel = b'K' * 4096
        self.second = b'S' * 1024
        # Splash bytes that are NOT zero, so a tool that zero-fills the tail fails this suite. Sized so a
        # payload with a bigger ramdisk still stops short of the resource header (the refusal is tested
        # separately, with a deliberately huge ramdisk).
        self.splash = b'\x11\x22\x33\x44' * 1024
        self.tail = self.splash + resource(dtb(2048))
        self.oem = make_image(self.kernel, b'\x00' * roundup(2048), self.second, self.tail)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, data, name):
        p = self.path(name)
        with open(p, 'wb') as fh:
            fh.write(data)
        return p

    def rebuild(self, oem, payload, out):
        sys.argv = ["rebuild_boot_faithful.py", oem, payload, out]
        R.main(sys.argv)
        with open(out, 'rb') as fh:
            return fh.read()

    def test_stock_round_trip_is_byte_identical(self):
        """Feeding the OEM image in both slots must reproduce it exactly - check 1 of the identity gate."""
        oem = self.write(self.oem, "oem.bin")
        out = self.rebuild(oem, oem, self.path("ident.img"))
        self.assertEqual(out, self.oem)

    def test_payload_keeps_the_tail_verbatim(self):
        """A bigger ramdisk moves `second`; everything past the payload's content end stays the OEM's bytes."""
        self.write(self.oem, "oem.bin")
        payload = self.write(make_image(self.kernel, b'\x55' * roundup(4096), self.second, b''), "pay.bin")
        out = self.rebuild(self.path("oem.bin"), payload, self.path("pay.img"))
        _, _, _, ro, so = R.offsets(out)
        content_end = roundup(so + len(self.second))
        self.assertEqual(len(out), len(self.oem))
        self.assertEqual(out[content_end:], self.oem[content_end:])
        self.assertEqual(out[PAGE:PAGE + len(self.kernel)], self.kernel)
        self.assertEqual(out[so:so + len(self.second)], self.second)
        base = self.oem.index(b'RSCE', roundup(PAGE + len(self.kernel)))
        self.assertEqual(out[base:base + 4], b'RSCE', "the tail resource header must survive")
        self.assertIn(DTB, out[base:], "the tail DTB must survive")

    def test_header_changes_only_in_ramdisk_size_and_cmdline(self):
        self.write(self.oem, "oem.bin")
        payload = self.write(make_image(self.kernel, b'\x55' * roundup(4096), self.second, b'',
                                        cmdline=b"androidboot.boot_devices=fe330000.sdhci"), "pay.bin")
        out = self.rebuild(self.path("oem.bin"), payload, self.path("pay.img"))
        diffs = [i for i in range(PAGE) if out[i] != self.oem[i]]
        self.assertTrue(diffs, "expected the header to change")
        self.assertTrue(all(16 <= i <= 19 or 64 <= i < 64 + 512 for i in diffs),
                        f"header changed outside the allowed regions: {min(diffs)}..{max(diffs)}")
        self.assertEqual(struct.unpack_from('<I', out, 16)[0], roundup(4096))

    def test_refuses_when_components_reach_the_resource_header(self):
        """A ramdisk large enough to reach the tail resource header must be refused, not truncated."""
        self.write(self.oem, "oem.bin")
        payload = self.write(make_image(self.kernel, b'\x55' * roundup(len(self.oem)), self.second, b''),
                             "big.bin")
        with self.assertRaises(SystemExit) as cm:
            self.rebuild(self.path("oem.bin"), payload, self.path("bad.img"))
        self.assertIn("resource header", str(cm.exception))

    def test_refuses_a_resource_entry_whose_declared_hash_is_wrong(self):
        self.write(self.oem, "oem.bin")
        broken = bytearray(self.oem)
        base = self.oem.index(b'RSCE', roundup(2048 + len(self.kernel)))
        broken[base + 512 + 224:base + 512 + 244] = b'\x00' * 20  # a hash that does not match the DTB bytes
        oem_broken = self.write(bytes(broken), "broken.bin")
        with self.assertRaises(SystemExit) as cm:
            self.rebuild(oem_broken, oem_broken, self.path("bad.img"))
        self.assertIn("resource entries failed", str(cm.exception))

    def test_refuses_a_changed_kernel_blob(self):
        self.write(self.oem, "oem.bin")
        tampered = self.write(make_image(b'K' * 4096 + b'X', b'\x00' * roundup(2048), self.second, b''),
                              "tampered.bin")
        with self.assertRaises(SystemExit) as cm:
            self.rebuild(self.path("oem.bin"), tampered, self.path("bad.img"))
        self.assertIn("kernel", str(cm.exception))

    def test_refuses_a_changed_second_blob(self):
        self.write(self.oem, "oem.bin")
        tampered = self.write(make_image(self.kernel, b'\x00' * roundup(2048), b'S' * 1024 + b'Z', b''),
                              "tampered2.bin")
        with self.assertRaises(SystemExit) as cm:
            self.rebuild(self.path("oem.bin"), tampered, self.path("bad.img"))
        self.assertIn("second", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
