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
                                 <max-bytes> <recovery-dtbo-size> [inplace]
The ramdisk dir is the extracted stock ramdisk with the injected files already overlaid. The dtbo
size comes from unpack_bootimg on the stock image - the dump is partition-sized and padded with
zeros after the dtbo, so the script needs to know where the real dtbo ends.

[inplace] is for the SD-boot card (**D98**): its partition holds high-entropy vendor data beyond the
dtbo (measured Nov 23: 61,816,029 B past the dtbo, 61,592,663 non-zero, 7.992 bits/byte, all 256 byte
values; the eMMC dump is zero padding there). Moving that data would change bytes nobody understands,
so inplace mode keeps EVERY offset identical: it refuses if the patched ramdisk is larger than the
stock one, pads the ramdisk span to the stock span so second and dtbo stay put, leaves the stored dtbo
offset alone, and appends the tail verbatim. The output must be exactly partition-sized.
"""
import hashlib
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



def normalize_mtimes(rd_dir: str) -> int:
    """Set every entry's mtime in the ramdisk tree to SOURCE_DATE_EPOCH before repacking.

    `cpio -o` stores each entry's mtime, so an untouched tree makes the image digest depend on WHEN the
    build ran - measured Nov 23: two builds of the same overlaid tree gave different image digests. The
    epoch is 1760000000 by default, the same one the wrapper build uses, so a re-run reproduces the image
    byte-for-byte. Symlinks are not followed, so their targets keep their own mtimes.
    """
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "1760000000"))
    for root, dirs, files in os.walk(rd_dir):
        for name in dirs + files:
            os.utime(os.path.join(root, name), (epoch, epoch), follow_symlinks=False)
    os.utime(rd_dir, (epoch, epoch))
    return epoch


def ramdisk_from(rd_dir: str, names: list) -> bytes:
    # --reproducible zeroes the newc inode/device fields, which otherwise change on every extraction and
    # make the image digest depend on the run (measured Nov 23: 1,481 differing bytes in the cpio, all
    # inode fields). -R root:root still sets uid/gid 0.
    cpio = subprocess.run(["cpio", "-o", "-H", "newc", "-R", "root:root", "--reproducible"], cwd=rd_dir,
                          input="\n".join(names).encode(), capture_output=True, check=True)
    gzip = subprocess.run(["gzip", "-9", "-n"], input=cpio.stdout, capture_output=True, check=True)
    if not gzip.stdout.startswith(b"\x1f\x8b"):
        sys.exit("repacked ramdisk is not gzip")
    return gzip.stdout



def filler(n: int) -> bytes:
    """Deterministic pseudo-random bytes (sha256 counter mode), so a re-run of the builder reproduces the
    same image. Random content is deliberate: it compresses to about one byte per byte, so the gzip
    output grows predictably."""
    out = bytearray()
    i = 0
    while len(out) < n:
        out += hashlib.sha256(i.to_bytes(8, "little")).digest()
        i += 1
    return bytes(out[:n])


def tune_ramdisk(rd_dir: str, names: list, current: bytes, lo: int, hi: int) -> bytes:
    """Grow the ramdisk with an unused filler file until its gzip output falls inside the STOCK page span.

    The loader computes second_offset = ramdisk_offset + align(ramdisk_size, page), so inplace mode needs
    the declared size to land in the same page as the stock one: the interval (span - page, span]. Padding
    the gzip stream with zeros inside the declared length is avoided, because a decompressor would read the
    trailing bytes as part of the stream. The filler is random, so the output grows about one byte per byte
    added - but gzip's own block overhead makes the growth unpredictable byte-for-byte, so this binary
    searches the filler size instead of guessing it.
    """
    pad_path = os.path.join(rd_dir, "sbin", "hu-pad.bin")
    if "sbin/hu-pad.bin" not in names:
        names.append("sbin/hu-pad.bin")
        names.sort()

    def size_with(n: int) -> tuple:
        with open(pad_path, "wb") as f:
            f.write(filler(n))
        # Normalise before measuring, otherwise the final blob's size shifts by the few bytes the
        # mtime fields add when they are rewritten after tuning.
        normalize_mtimes(rd_dir)
        blob = ramdisk_from(rd_dir, names)
        return len(blob), blob

    if len(current) > hi:
        sys.exit(f"inplace: patched ramdisk {len(current)} B exceeds the stock span {hi} B - refuse")
    # Smallest filler size whose output exceeds lo. The output is monotone in n for random filler.
    lo_n, hi_n = 0, (hi - len(current)) + 4096
    best = None
    for _ in range(24):
        if lo_n > hi_n:
            break
        mid = (lo_n + hi_n) // 2
        size, blob = size_with(mid)
        if size <= lo:
            lo_n = mid + 1
        else:
            best = (mid, size, blob)
            hi_n = mid - 1
    if best is None:
        sys.exit(f"inplace: no filler size lands in the stock span ({lo}, {hi}] - refuse")
    n, size, blob = best
    if size > hi:
        sys.exit(f"inplace: filler {n} B gives {size} B, which jumps past the span ({lo}, {hi}] - refuse")
    print(f"  ramdisk filler: /sbin/hu-pad.bin {n} B added to land at {size} B inside the stock span "
          f"({lo}, {hi}]")
    return blob


def main() -> int:
    if len(sys.argv) not in (6, 7):
        print(__doc__)
        return 2
    stock_path, rd_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    max_bytes = int(sys.argv[4])
    dtbo_size = int(sys.argv[5])
    inplace = len(sys.argv) == 7 and sys.argv[6] == "inplace"

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
    # The loader derives every offset from the declared sizes and the page size, so an image stays at
    # its stock offsets only while the patched ramdisk aligns to the SAME page span as the stock one.
    # Inplace mode pads the ramdisk with an unused filler file until it does (tune_ramdisk above).

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
    tail = data[d_off + dtbo_size:]
    if inplace:
        # The card's tail is real data, not padding. It is carried verbatim and never rewritten.
        import hashlib
        print(f"  tail beyond dtbo: {len(tail):,} B, non-zero {sum(1 for b in tail if b):,}, "
              f"sha256 {hashlib.sha256(tail).hexdigest()[:12]} (carried verbatim)")
        if tail.strip(b"\x00"):
            print("  tail is not zero padding -> offsets must stay identical (inplace)")
    elif tail.strip(b"\x00"):
        sys.exit("unexpected non-zero data after the dtbo - the dump is not just zero padding")

    # Rebuild the ramdisk from the directory: gzip'd newc cpio, same shape as the stock one.
    if not os.path.isdir(rd_dir):
        sys.exit(f"no ramdisk dir: {rd_dir}")
    find = subprocess.run(["find", ".", "-mindepth", "1"], cwd=rd_dir, capture_output=True,
                          text=True, check=True)
    names = sorted(n.strip("./") for n in find.stdout.splitlines() if n.strip())
    normalize_mtimes(rd_dir)
    new_ramdisk = ramdisk_from(rd_dir, names)
    if inplace:
        # Keep the declared size inside the stock page span so every later offset is identical.
        span = align(ramdisk_size, page)
        if len(new_ramdisk) > span:
            sys.exit(f"inplace: patched ramdisk {len(new_ramdisk)} B exceeds the stock span {span} B - refuse")
        if len(new_ramdisk) <= span - page:
            new_ramdisk = tune_ramdisk(rd_dir, names, new_ramdisk, span - page, span)
        if align(len(new_ramdisk), page) != span:
            sys.exit(f"inplace: tuned ramdisk {len(new_ramdisk)} B still aligns to "
                     f"{align(len(new_ramdisk), page)} != stock span {span} - refuse")

    # Patch the header: ramdisk_size for sure, plus a stored dtbo offset if the image has one.
    header = bytearray(data[:hdr_pad])
    struct.pack_into("<I", header, OFF_RAMDISK_SIZE, len(new_ramdisk))
    new_r_off = k_off + align(kernel_size, page)
    new_s_off = new_r_off + align(len(new_ramdisk), page)
    new_d_off = new_s_off + align(second_size, page)
    if inplace:
        # Inplace: second and dtbo offsets must not move, so the stored dtbo offset stays as recorded.
        stored = struct.unpack_from("<Q", data, 1636)[0]
        if stored != d_off:
            sys.exit(f"inplace: header says dtbo at {stored}, layout gives {d_off} - refuse")
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
    # Recomputed from the STOCK span, not from the new ramdisk length: in inplace mode the lengths are
    # identical by construction, so these equal s_off and d_off and the guard below proves it.
    out = bytearray()
    out += header
    out += kernel + pad(kernel_size)
    if inplace:
        # Pad to the STOCK ramdisk span so second and dtbo keep their offsets; the span end stays zero.
        out += new_ramdisk + b"\0" * (align(ramdisk_size, page) - len(new_ramdisk))
        out += second + pad(second_size)
        # The card's dtbo is NOT page-padded: the vendor's tail begins at d_off + dtbo_size
        # (measured Nov 23: header dtbo_size 739 -> tail starts at 38,847,203). Padding it would
        # push the output past the partition, so the dtbo span is copied exactly as recorded.
        out += dtbo
        out += tail
    else:
        out += new_ramdisk + pad(len(new_ramdisk))
        out += second + pad(second_size)
        out += dtbo + pad(dtbo_size)

    if len(out) > max_bytes:
        sys.exit(f"patched image {len(out)} B exceeds the partition ({max_bytes} B)")
    if inplace and len(out) != len(data):
        sys.exit(f"inplace output {len(out)} B != capture {len(data)} B - refuse")
    if inplace and (new_s_off != s_off or new_d_off != d_off):
        sys.exit(f"inplace offsets moved: second {s_off}->{new_s_off}, dtbo {d_off}->{new_d_off}")
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
