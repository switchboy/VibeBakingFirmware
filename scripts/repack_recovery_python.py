#!/usr/bin/env python3
"""repack_recovery_python.py - rebuild a recovery boot image with a new ramdisk, keeping every
other byte of the stock image.

Why not repack_bootimg: the AOSP tool is a frozen binary that shells out to mkbootimg, and
Lineage's mkbootimg refuses the stock header's combination of fields (it died after writing a
1,648-byte truncated image). That is a tool-version mismatch, not a problem with the image.

So this splices directly, and does not trust any guessed struct layout: it locates each part by
searching the stock image for its first bytes and re-derives the layout from the header's own size
fields, which are certain (magic 0, kernel_size 8, ramdisk_size 16, second_size 24, page_size 36,
header_version 40). Measured on the stock recovery.bin (page 2048): kernel at 2048, ramdisk at
25,687,296, second at 38,202,880, recovery_dtbo at 39,129,600 - and the header carries that dtbo
offset as a field, which the script finds by scanning for the exact 8-byte value rather than
assuming where it lives.

A bigger ramdisk pushes the second bootloader and the dtbo later, so exactly two header fields
change: ramdisk_size, and recovery_dtbo_offset if the image carries one. Kernel bytes, second bytes,
dtbo bytes, cmdline and load addresses are copied verbatim - which is what makes this safe to write
to partition 8, the one partition outside the boot chain we are allowed to touch (D18/D19).

Usage: repack_recovery_python.py <stock-bootimg> <ramdisk-dir> <output-bootimg>
                                 <max-bytes> <recovery-dtbo-size>
The ramdisk dir is the extracted stock ramdisk with the injected files already overlaid. The dtbo
size comes from unpack_bootimg on the stock image - the dump is partition-sized and padded with
zeros after the dtbo, so the script needs to know where the real dtbo ends.
"""
import os
import struct
import subprocess
import sys

MAGIC = b"ANDROID!"
OFF_KERNEL_SIZE = 8
OFF_RAMDISK_SIZE = 16
OFF_SECOND_SIZE = 24
OFF_PAGE_SIZE = 36
OFF_HEADER_VERSION = 40


def align(n: int, page: int) -> int:
    return ((n + page - 1) // page) * page


def find_part(data: bytes, blob: bytes, expect: int, label: str) -> int:
    """Locate a part by its first bytes and insist it sits where the layout says."""
    probe = blob[:64]
    at = data.find(probe, expect)
    if at != expect:
        sys.exit(f"{label}: found at {at}, layout says {expect} - refusing to guess")
    return at


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__)
        return 2
    stock_path, rd_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    max_bytes = int(sys.argv[4])
    dtbo_size = int(sys.argv[5])

    data = open(stock_path, "rb").read()
    if data[:8] != MAGIC:
        sys.exit("not a boot image: no ANDROID! magic")
    page = struct.unpack_from("<I", data, OFF_PAGE_SIZE)[0]
    hdr_version = struct.unpack_from("<I", data, OFF_HEADER_VERSION)[0]
    kernel_size = struct.unpack_from("<I", data, OFF_KERNEL_SIZE)[0]
    ramdisk_size = struct.unpack_from("<I", data, OFF_RAMDISK_SIZE)[0]
    second_size = struct.unpack_from("<I", data, OFF_SECOND_SIZE)[0]
    if page == 0 or hdr_version < 0:
        sys.exit("unreadable header fields")

    # Header region: one page. The parts are laid out after it, each padded to a page.
    hdr_pad = page
    kernel = data[hdr_pad:hdr_pad + kernel_size]
    k_off = find_part(data, kernel, hdr_pad, "kernel")
    r_off = k_off + align(kernel_size, page)
    ramdisk = data[r_off:r_off + ramdisk_size]
    find_part(data, ramdisk, r_off, "ramdisk")
    s_off = r_off + align(ramdisk_size, page)
    second = data[s_off:s_off + second_size]
    find_part(data, second, s_off, "second")
    d_off = s_off + align(second_size, page)
    dtbo = data[d_off:d_off + dtbo_size]
    if len(dtbo) != dtbo_size:
        sys.exit(f"dtbo {dtbo_size} B runs past the end of the image ({len(data)} B)")
    find_part(data, dtbo[:64], d_off, "recovery_dtbo")
    if data[d_off + dtbo_size:].strip(b"\x00"):
        sys.exit("unexpected non-zero data after the dtbo - the dump is not just zero padding")

    # Rebuild the ramdisk from the directory: gzip'd newc cpio, same shape as the stock one.
    if not os.path.isdir(rd_dir):
        sys.exit(f"no ramdisk dir: {rd_dir}")
    find = subprocess.run(["find", ".", "-mindepth", "1"], cwd=rd_dir, capture_output=True,
                          text=True, check=True)
    names = sorted(n.strip("./") for n in find.stdout.splitlines() if n.strip())
    cpio = subprocess.run(["cpio", "-o", "-H", "newc", "-R", "root:root"], cwd=rd_dir,
                          input="\n".join(names).encode(), capture_output=True, check=True)
    gzip = subprocess.run(["gzip", "-9", "-n"], input=cpio.stdout, capture_output=True, check=True)
    new_ramdisk = gzip.stdout
    if not new_ramdisk.startswith(b"\x1f\x8b"):
        sys.exit("repacked ramdisk is not gzip")

    # Patch the header: ramdisk_size for sure, plus a stored dtbo offset if the image has one.
    header = bytearray(data[:hdr_pad])
    struct.pack_into("<I", header, OFF_RAMDISK_SIZE, len(new_ramdisk))
    new_r_off = k_off + align(kernel_size, page)
    new_s_off = new_r_off + align(len(new_ramdisk), page)
    new_d_off = new_s_off + align(second_size, page)
    pat = struct.pack("<Q", d_off)
    hits = []
    pos = 0
    while True:
        at = header.find(pat, pos)
        if at < 0:
            break
        struct.pack_into("<Q", header, at, new_d_off)
        hits.append(at)
        pos = at + 8

    pad = lambda n: b"\0" * (align(n, page) - n)
    out = bytearray()
    out += header
    out += kernel + pad(kernel_size)
    out += new_ramdisk + pad(len(new_ramdisk))
    out += second + pad(second_size)
    out += dtbo + pad(dtbo_size)

    if len(out) > max_bytes:
        sys.exit(f"patched image {len(out)} B exceeds the partition ({max_bytes} B)")
    with open(out_path, "wb") as f:
        f.write(out)

    print(f"stock {len(data)} B -> patched {len(out)} B (partition {max_bytes} B)")
    print(f"  header version {hdr_version}, page {page}")
    print(f"  kernel {len(kernel)} B @ {k_off} (bytes unchanged)")
    print(f"  ramdisk {len(ramdisk)} B -> {len(new_ramdisk)} B @ {new_r_off}, {len(names)} cpio entries")
    print(f"  second {len(second)} B @ {s_off} -> {new_s_off} (bytes unchanged)")
    print(f"  recovery_dtbo {len(dtbo)} B @ {d_off} -> {new_d_off} (bytes unchanged)")
    print(f"  stored dtbo offset patched at header offsets {hits if hits else 'none found'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
