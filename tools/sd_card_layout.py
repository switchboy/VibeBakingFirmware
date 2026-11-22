#!/usr/bin/env python3
"""sd_card_layout.py - read a whole-card image and report its GPT layout, then carve partitions.

The card is addressed by size and type on the unit, never by partition number alone; this tool reads the
partition table out of the captured image so the carve offsets come from the layout itself, and checks each
partition's byte span against the size the device reported (`blockdev --getsize64`). It writes a TSV of
index, label, byte offset, byte size, sha256, plus carved copies when --carve is given.

Measured Nov 22 on the SD-boot card: its GPT header is vendor-written and self-inconsistent - signature
"EFI PART", header_size 92, entry_count 0, entry_size field 15,523,839 (not 128), entry CRC 0, and LBA0 all
zeros (no protective MBR). The partition records at LBA2 are nonetheless well formed. So the entry size is
taken as 128 B and the entry count as (first_usable_lba - 2), and the scan stops at the first zero GUID
rather than trusting the header's own numbers.

Nothing here touches a device. The image is a workstation file produced by the capture script.
"""
import argparse
import hashlib
import os
import struct
import sys

LBA = 512
GPT_SIG = b"EFI PART"
ENTRY_STD = 128


def sha(path, start=None, length=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        if start:
            f.seek(start)
        left = length
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            if left is not None:
                if len(chunk) > left:
                    chunk = chunk[:left]
                left -= len(chunk)
            h.update(chunk)
            if left is not None and left <= 0:
                break
    return h.hexdigest()


def name(raw):
    return raw.decode("utf-16-le", "replace").split("\x00")[0]


def read_gpt(image):
    """Returns (rows, facts). rows are (index, label, offset, size); facts is a dict of what the
    header itself claims, so the report states the inconsistency instead of hiding it."""
    total = os.path.getsize(image)
    with open(image, "rb") as f:
        mbr = f.read(LBA)
        f.seek(LBA)
        hdr = f.read(LBA)
        if hdr[0:4] != GPT_SIG[:4] or hdr[4:8] != GPT_SIG[4:]:
            raise SystemExit(f"no GPT header at LBA1 (signature {hdr[0:8]!r}) - this image is not GPT")
        facts = {
            "image_bytes": total,
            "signature": hdr[0:8].decode(errors="replace"),
            "revision": struct.unpack_from("<I", hdr, 8)[0],
            "header_size": struct.unpack_from("<I", hdr, 12)[0],
            "header_crc": struct.unpack_from("<I", hdr, 16)[0],
            "entry_count_claimed": struct.unpack_from("<I", hdr, 28)[0],
            "entry_size_claimed": struct.unpack_from("<I", hdr, 32)[0],
            "entry_crc_claimed": struct.unpack_from("<I", hdr, 36)[0],
            "first_usable_lba": struct.unpack_from("<Q", hdr, 40)[0],
            "last_usable_lba": struct.unpack_from("<Q", hdr, 48)[0],
            "disk_guid": hdr[56:72].hex(),
            "protective_mbr": bool(mbr[0:2] == b"\x55\xaa" and mbr[72:74] == b"\xee\xff"),
        }
        esize = ENTRY_STD if facts["entry_size_claimed"] != ENTRY_STD else ENTRY_STD
        claimed = facts["entry_count_claimed"]
        # The header's own counts are unusable on this card; derive the span from first_usable_lba.
        span = max(facts["first_usable_lba"] - 2, 1)
        n = claimed if claimed and claimed <= span else span
        f.seek(2 * LBA)
        recs = []
        for _ in range(n):
            e = f.read(esize)
            if len(e) < esize or e[:16] == b"\x00" * 16:
                break
            recs.append(e)
        # The bound is the disk size the header itself declares (last_usable_lba + 1), not the file
        # size, so a partial capture still parses and is reported as truncated per partition.
        disk_lba = facts["last_usable_lba"] + 1
        # Measured Nov 22 on this card: the records do NOT put the start/end LBAs at the standard 8/16.
        # The spans that tile the disk sit at record offset 32/40 (uboot 16384..24575, ..., userdata
        # 7752704..15523806), which equals the device-reported partition sizes exactly. Both layouts are
        # tried and the one that produces monotonic, non-overlapping spans inside the disk is used.
        candidates = [(8, 16), (16, 24), (24, 32), (32, 40), (40, 48)]
        chosen = None
        for o1, o2 in candidates:
            rows = []
            ok = True
            prev_end = 2
            for i, e in enumerate(recs):
                first = struct.unpack_from("<Q", e, o1)[0]
                last = struct.unpack_from("<Q", e, o2)[0]
                if not first or first < prev_end or last < first or last >= disk_lba:
                    ok = False
                    break
                rows.append((i + 1, name(e[56:128]), first * LBA, (last + 1) * LBA - first * LBA))
                prev_end = last + 1
            if ok and rows:
                chosen = (o1, o2, rows)
                break
        if not chosen:
            raise SystemExit("no record offset produced a consistent partition table - reporting raw records only")
        facts["lba_field_offsets"] = chosen[0]
        return chosen[2], facts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--sizes", default="", help="device sizes as pN=BYTES, comma separated")
    ap.add_argument("--carve", default="", help="directory to write pN.bin copies into")
    ap.add_argument("--tsv", default="", help="file to write the layout table to")
    opts = ap.parse_args()

    expect = {}
    if opts.sizes:
        for tok in opts.sizes.split(","):
            k, _, v = tok.partition("=")
            if k and v:
                expect[k.strip()] = int(v)

    rows, facts = read_gpt(opts.image)
    print("image %d B ; GPT %s rev=%d header_size=%d entry_count_claimed=%d entry_size_claimed=%d "
          "entry_crc=%d first_usable_lba=%d last_usable_lba=%d disk_guid=%s protective_mbr=%s"
          % (facts["image_bytes"], facts["signature"], facts["revision"], facts["header_size"],
             facts["entry_count_claimed"], facts["entry_size_claimed"], facts["entry_crc_claimed"],
             facts["first_usable_lba"], facts["last_usable_lba"], facts["disk_guid"], facts["protective_mbr"]))

    out = []
    total = facts["image_bytes"]
    for idx, lbl, start, size in rows:
        if start + size > total:
            print(f"p{idx} {lbl} offset={start} size={size} TRUNCATED: image ends at {total} B")
            continue
        dg = sha(opts.image, start, size)
        flag = ""
        key = "p%d" % idx
        if key in expect:
            flag = "match" if expect[key] == size else "MISMATCH device=%d" % expect[key]
        out.append((idx, lbl, start, size, dg, flag))
        print(f"p{idx} {lbl} offset={start} size={size} sha256={dg[:12]} {flag}")
        if opts.carve:
            os.makedirs(opts.carve, exist_ok=True)
            with open(opts.image, "rb") as f:
                f.seek(start)
                with open(os.path.join(opts.carve, f"p{idx}.bin"), "wb") as w:
                    w.write(f.read(size))

    if opts.tsv:
        with open(opts.tsv, "w", encoding="utf-8") as w:
            w.write("index\tlabel\toffset\tsize\tsha256\tdevice_check\n")
            for r in out:
                w.write("\t".join(str(x) for x in r) + "\n")
    if opts.carve:
        print(f"carved partitions into {opts.carve}")


if __name__ == "__main__":
    main()
