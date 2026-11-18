#!/usr/bin/env python3
"""Rebuild a payload boot image that is byte-faithful to the OEM boot image (**D60**).

  python3 tools/rebuild_boot_faithful.py <oem_boot> <payload_boot> <out>

What it produces: the OEM image's header page verbatim EXCEPT `ramdisk_size` and the 512-byte cmdline
field (copied from the payload image), with `dtb_load_address` restored to the OEM value, then the OEM
kernel, the payload's first-stage ramdisk, the OEM `second` stage, and the OEM tail DTB copies - padded
to the OEM image's own size so the partition ends up the same length as it already is.

Why this tool exists (measured Nov 18, docs/findings.md):
* `scripts/rebuild_boot_with_fstab.sh` zeroes `dtb_load_address` (the OEM image carries 0x11f00000) and
  truncates the image, so the image carried only the small DTB variant inside `second` and none of the
  tail DTBs that carry the `mmc0`/`mmc1`/`mmc2` aliases.
* The layout a Rockchip boot loader computes is `kernel @ 2048`, `ramdisk @ roundup(2048 + kernel_size)`,
  `second @ roundup(ramdisk_offset + ramdisk_size)` - i.e. the offset is rounded AFTER adding the header
  page. Rounding each size alone puts every component one page early; RSCE/DTB magics confirm the
  add-then-round rule on the OEM image, the payload image and the OEM recovery image.

Refusals, so a wrong image cannot be produced quietly:
* kernel blob must be byte-identical between OEM and payload,
* `second` blob must be byte-identical between OEM and payload,
* components must not reach the tail DTB region,
* the finished image is read back and every component is checked at the offsets a loader computes,
* the header page is compared against the OEM header and the differing byte ranges are printed; anything
  outside `ramdisk_size`, the cmdline field and `dtb_load_address` is a failure.

The 20-byte field at header offset 576 is carried verbatim from the OEM image. It is not a sha1 of any
component concatenation we can reconstruct (measured Nov 18), so we do not recompute it; step L0 of the
boot-only ladder (D62) is what tells us whether the boot loader reads it.
"""
import hashlib
import re
import struct
import sys

PAGE = 2048
DTB_MAGIC = re.compile(re.escape(b'\xd0\x0d\xfe\xed'))
CMDLINE_OFF, CMDLINE_LEN = 64, 512
DTB_SIZE_OFF, DTB_ADDR_OFF = 1648, 1652


def roundup(n: int) -> int:
    return ((n + PAGE - 1) // PAGE) * PAGE


def offsets(d: bytes):
    ks = struct.unpack_from('<I', d, 8)[0]
    rs = struct.unpack_from('<I', d, 16)[0]
    ss = struct.unpack_from('<I', d, 24)[0]
    ramdisk = roundup(2048 + ks)
    second = roundup(ramdisk + rs)
    return ks, rs, ss, ramdisk, second


def dtb_positions(d: bytes):
    out = []
    for m in DTB_MAGIC.finditer(d):
        total = struct.unpack_from('>I', d, m.start() + 4)[0]
        if total and m.start() + total <= len(d):
            out.append((m.start(), total))
    return out


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def main(argv):
    if len(argv) != 4:
        raise SystemExit(__doc__)
    oem_path, payload_path, out_path = argv[1:]
    oem = open(oem_path, 'rb').read()
    payload = open(payload_path, 'rb').read()
    if oem[:8] != b'ANDROID!' or payload[:8] != b'ANDROID!':
        raise SystemExit("both inputs must carry the ANDROID! magic")

    oem_ks, oem_rs, oem_ss, oem_ro, oem_so = offsets(oem)
    pay_ks, pay_rs, pay_ss, pay_ro, pay_so = offsets(payload)
    if (oem_ks, oem_ss) != (pay_ks, pay_ss) or oem_ro != pay_ro:
        raise SystemExit(f"kernel/second sizes differ: oem {oem_ks}/{oem_ss} vs payload {pay_ks}/{pay_ss}")
    kernel = oem[2048:2048 + oem_ks]
    if payload[2048:2048 + oem_ks] != kernel:
        raise SystemExit(f"kernel blob differs ({sha(payload[2048:2048 + oem_ks])[:12]} vs {sha(kernel)[:12]})")
    second = oem[oem_so:oem_so + oem_ss]
    if payload[pay_so:pay_so + oem_ss] != second:
        raise SystemExit(f"second blob differs ({sha(payload[pay_so:pay_so + oem_ss])[:12]} vs {sha(second)[:12]})")
    ramdisk = payload[pay_ro:pay_ro + roundup(pay_rs)]

    dtbs = dtb_positions(oem)
    tail_positions = [p for p, _ in dtbs if p >= oem_so + oem_ss]
    if not tail_positions:
        raise SystemExit("OEM image holds no tail DTB copies - nothing to carry")
    tail_start = min(tail_positions)
    tail_end = max(p + t for p, t in dtbs)
    tail = oem[tail_start:tail_end]

    hdr = bytearray(oem[:PAGE])
    struct.pack_into('<I', hdr, 16, pay_rs)
    hdr[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = payload[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN]
    struct.pack_into('<Q', hdr, DTB_ADDR_OFF, struct.unpack_from('<Q', oem, DTB_ADDR_OFF)[0])
    struct.pack_into('<I', hdr, DTB_SIZE_OFF, struct.unpack_from('<I', oem, DTB_SIZE_OFF)[0])

    body = bytearray(hdr) + kernel
    body += b'\x00' * (pay_ro - len(body))
    body += ramdisk
    if len(body) > tail_start:
        raise SystemExit(f"components reach {len(body)} B, past the tail DTB region at {tail_start:,} B")
    out = body + b'\x00' * (pay_so - len(body)) + second
    out += b'\x00' * (tail_start - len(out)) + tail
    out += b'\x00' * (len(oem) - len(out))

    # Read it back exactly the way a boot loader would.
    ks, rs, ss, ro, so = offsets(out)
    if out[2048:2048 + ks] != kernel or out[so:so + ss] != second or out[ro:ro + roundup(rs)] != ramdisk:
        raise SystemExit("self-check failed: a component is not readable at its computed offset")
    found = dtb_positions(out)
    if len(found) != len(dtbs):
        raise SystemExit(f"DTB count changed: OEM {len(dtbs)} vs rebuilt {len(found)}")

    print(f"oem      size {len(oem):,}  kernel {sha(kernel)[:12]}  second {sha(second)[:12]}  ramdisk {sha(oem[oem_ro:roundup(oem_ro + oem_rs)])[:12]}")
    print(f"payload  size {len(payload):,}  ramdisk {sha(ramdisk)[:12]}")
    print(f"rebuilt  size {len(out):,} sha256 {sha(out)}")
    print(f"  kernel {sha(kernel)[:12]} (carried)  second {sha(second)[:12]} (carried)  tail DTBs carried from {tail_start:,} B ({len(tail):,} B)")
    for pos, total in found:
        print(f"  DTB @{pos:,} size {total:,}")
    start = None
    for i in range(PAGE):
        if oem[i] != out[i]:
            if start is None:
                start = i
            last = i
        elif start is not None:
            print(f"  header differs at bytes {start}..{last}")
            start = None
    if start is not None:
        print(f"  header differs at bytes {start}..{last}")
    allowed = [(16, 19), (CMDLINE_OFF, CMDLINE_OFF + CMDLINE_LEN - 1)]
    bad = []
    start = None
    for i in range(PAGE):
        if oem[i] != out[i]:
            if start is None:
                start = i
            last = i
        elif start is not None:
            if not any(a <= start and last <= b for a, b in allowed):
                bad.append((start, last))
            start = None
    if start is not None and not any(a <= start and last <= b for a, b in allowed):
        bad.append((start, last))
    if bad:
        raise SystemExit(f"header changed outside ramdisk_size and the cmdline field: {bad}")
    print("self-check OK: header changes only in ramdisk_size and the cmdline field, dtb_load_address kept at OEM value")
    with open(out_path, 'wb') as f:
        f.write(out)
    print(f"wrote {out_path}")


if __name__ == '__main__':
    main(sys.argv)
