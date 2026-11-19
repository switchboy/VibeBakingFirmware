#!/usr/bin/env python3
"""Rebuild a payload boot image that is byte-faithful to the OEM boot image (**D60**).

  python3 tools/rebuild_boot_faithful.py <oem_boot> <payload_boot> <out>

What it produces: the OEM image's header page verbatim EXCEPT `ramdisk_size` and the 512-byte cmdline
field (copied from the payload image), with `dtb_load_address` restored to the OEM value, then the OEM
kernel, the payload's first-stage ramdisk, the OEM `second` stage, and from the rebuilt image's own
content end onward **the OEM bytes verbatim** - splash data, the tail resource image and its DTB copies -
padded or truncated to the OEM image's own size so the partition ends up the same length as it already is.

Nothing in the tail is zero-filled. The Nov 19 identity gate (`tools/identity_gate.py`, **D67**) proved the
earlier rule was a defect: the OEM partition keeps 2,624,960 non-zero bytes between the Android image's own
end (27,407,104) and the tail resource header at 32,092,160, so zero-filling that span made a "faithful"
image differ from the OEM image by 4.68 MB of content it did not change - and feeding stock content through
the tooling was no longer a byte-identical round trip.

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
* components must not reach the OEM tail resource header (the RSCE region),
* the finished image is read back and every component is checked at the offsets a loader computes,
* the bytes from the rebuilt content end to the partition end must equal the OEM bytes at the same offsets,
  and the tail resource header plus its DTB copies must sit exactly where the OEM image has them,
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
RESOURCE_MAGIC = re.compile(re.escape(b'RSCE'))
ENTRY_MAGIC = re.compile(re.escape(b'ENTR'))
CMDLINE_OFF, CMDLINE_LEN = 64, 512
DTB_SIZE_OFF, DTB_ADDR_OFF = 1648, 1652
# A Rockchip resource image: a header page of RSCE + version + flag + entry count, then 512-byte entry
# records (ENTR, a name padded to 224, a 20-byte SHA1, then hash_len / offset-in-512-byte-blocks / size).
# Measured Nov 19: every declared SHA1 verifies on the OEM boot image and on the OEM recovery image.
ENTRY_RECORD = 512
ENTRY_NAME_OFF, ENTRY_HASH_OFF, ENTRY_HASH_LEN_OFF, ENTRY_OFF_OFF, ENTRY_SIZE_OFF = 4, 224, 256, 260, 264


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


def resource_entries(d: bytes, base: int):
    """The entries of the resource image at `base`, with each declared SHA1 checked against its bytes."""
    n = struct.unpack_from('<I', d, base + 12)[0]
    out = []
    for i in range(n):
        e = base + ENTRY_RECORD * (i + 1)
        if d[e:e + 4] != b'ENTR':
            continue
        name = d[e + ENTRY_NAME_OFF:e + ENTRY_NAME_OFF + 220].split(b'\x00')[0].decode(errors='replace')
        declared = d[e + ENTRY_HASH_OFF:e + ENTRY_HASH_OFF + 20]
        h_len = struct.unpack_from('<I', d, e + ENTRY_HASH_LEN_OFF)[0]
        blocks = struct.unpack_from('<I', d, e + ENTRY_OFF_OFF)[0]
        size = struct.unpack_from('<I', d, e + ENTRY_SIZE_OFF)[0]
        pos = base + blocks * 512
        data = d[pos:pos + size]
        out.append({'name': name, 'pos': pos, 'size': size, 'sha1': hashlib.sha1(data).hexdigest(),
                    'declared': declared.hex(), 'hash_len': h_len, 'ok': hashlib.sha1(data).hexdigest() == declared.hex()})
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

    # The OEM tail is the region the Android boot image does not describe: splash content, then a second
    # resource image carrying the other DTB variant and the panel logo. It is carried verbatim, from the
    # rebuilt image's own content end to the end of the partition.
    oem_content_end = roundup(oem_so + oem_ss)
    pay_content_end = roundup(pay_so + pay_ss)
    res_positions = [m.start() for m in RESOURCE_MAGIC.finditer(oem) if m.start() >= oem_content_end]
    if not res_positions:
        raise SystemExit(f"OEM image has no resource header at or after its content end ({oem_content_end:,} B)")
    tail_res_start = min(res_positions)
    if pay_content_end > tail_res_start:
        raise SystemExit(f"components reach {pay_content_end:,} B, past the OEM tail resource header at {tail_res_start:,} B")
    dtbs = dtb_positions(oem)
    tail_dtbs = [p for p, _ in dtbs if p >= tail_res_start]
    if not tail_dtbs:
        raise SystemExit("OEM image holds no tail DTB copies - nothing to carry")

    hdr = bytearray(oem[:PAGE])
    struct.pack_into('<I', hdr, 16, pay_rs)
    hdr[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = payload[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN]
    struct.pack_into('<Q', hdr, DTB_ADDR_OFF, struct.unpack_from('<Q', oem, DTB_ADDR_OFF)[0])
    struct.pack_into('<I', hdr, DTB_SIZE_OFF, struct.unpack_from('<I', oem, DTB_SIZE_OFF)[0])

    body = bytearray(hdr) + kernel
    body += b'\x00' * (pay_ro - len(body))
    body += ramdisk
    body += b'\x00' * (pay_so - len(body)) + second
    body += b'\x00' * (pay_content_end - len(body))
    if len(body) != pay_content_end:
        raise SystemExit(f"assembled content is {len(body):,} B, not the loader's content end {pay_content_end:,} B")
    out = bytes(body) + oem[pay_content_end:]
    if len(out) > len(oem):
        raise SystemExit(f"payload content plus the OEM tail is {len(out):,} B, past the partition's {len(oem):,} B")
    out += b'\x00' * (len(oem) - len(out))

    # Read it back exactly the way a boot loader would.
    ks, rs, ss, ro, so = offsets(out)
    if out[2048:2048 + ks] != kernel or out[so:so + ss] != second or out[ro:ro + roundup(rs)] != ramdisk:
        raise SystemExit("self-check failed: a component is not readable at its computed offset")
    if out[pay_content_end:] != oem[pay_content_end:]:
        raise SystemExit("self-check failed: the OEM tail is not carried verbatim from the content end")
    found = dtb_positions(out)
    # The DTB inside `second` moves with the payload's ramdisk size; the tail copies must stay exactly where
    # the OEM image has them, because the partition tail is carried verbatim.
    in_second = [(p, t) for p, t in dtbs if oem_so <= p < oem_so + oem_ss]
    tail = [(p, t) for p, t in dtbs if p >= tail_res_start]
    expected = sorted([(so + (p - oem_so), t) for p, t in in_second] + tail)
    if sorted(found) != expected:
        raise SystemExit(f"DTB positions changed: expected {expected} vs rebuilt {sorted(found)}")
    entries = resource_entries(out, tail_res_start)
    if not entries or any(not e['ok'] for e in entries):
        raise SystemExit(f"tail resource entries failed: {[(e['name'], e['declared'][:12], e['sha1'][:12]) for e in entries]}")

    print(f"oem      size {len(oem):,}  kernel {sha(kernel)[:12]}  second {sha(second)[:12]}  ramdisk {sha(oem[oem_ro:roundup(oem_ro + oem_rs)])[:12]}")
    print(f"payload  size {len(payload):,}  ramdisk {sha(ramdisk)[:12]}")
    print(f"rebuilt  size {len(out):,} sha256 {sha(out)}")
    print(f"  kernel {sha(kernel)[:12]} (carried)  second {sha(second)[:12]} (carried)")
    print(f"  OEM tail carried verbatim from {pay_content_end:,} B ({len(oem) - pay_content_end:,} B), resource header at {tail_res_start:,} B")
    for e in entries:
        print(f"  tail entry {e['name']} @{e['pos']:,} {e['size']:,} B sha1 {e['sha1'][:12]} {'MATCHES declared' if e['ok'] else 'MISMATCH'}")
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
