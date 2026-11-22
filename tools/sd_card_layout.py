#!/usr/bin/env python3
"""sd_card_layout.py - read a whole-card image and report its GPT layout, then carve partitions.

The card is addressed by size and type on the unit, never by partition number alone; this tool reads
the GPT in the captured image so the carve offsets come from the layout itself, and it checks each
partition's byte span against the size the device reported (`blockdev --getsize64`). It writes a TSV
of index, label, byte offset, byte size, sha256, plus carved copies when --carve is given.

Nothing here touches a device. The image is a workstation file produced by sd_image_capture.sh.
"""
import argparse
import hashlib
import os
import sys

LBA = 512
GPT_SIG = b"GPT\0"


def sha(path, start=None, length=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        if start:
            f.seek(start)
        left = length if length is not None else None
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--sizes", default="",
                    help="device sizes as pN=BYTES, comma separated, from blockdev --getsize64")
    ap.add_argument("--carve", default="", help="directory to write pN.bin copies into")
    ap.add_argument("--tsv", default="", help="file to write the layout table to")
    opts = ap.parse_args()

    expect = {}
    if opts.sizes:
        for tok in opts.sizes.split(","):
            k, _, v = tok.partition("=")
            if k and v:
                expect[k.strip()] = int(v)

    total = os.path.getsize(opts.image)
    with open(opts.image, "rb") as f:
        mbr = f.read(LBA)
        if mbr[0:2] != b"\x55\xaa" or mbr[72:74] != b"\xee\xff":
            sys.exit("no protective MBR (no 0xEE partition header) - this image is not GPT")
        f.seek(LBA)
        hdr = f.read(LBA)
        if hdr[0:4] != GPT_SIG:
            sys.exit("no GPT header at LBA1")
        hlen = int.from_bytes(hdr[16:20], "little")
        entries = int.from_bytes(hdr[48:52], "little")
        esize = int.from_bytes(hdr[52:56], "little")
        crc = int.from_bytes(hdr[56:60], "little")
        print(f"image {total} B ; GPT entries {entries} x {esize} B, header len {hlen}, crc {crc}")

        f.seek(2 * LBA)
        rows = []
        for i in range(entries):
            e = f.read(esize)
            if len(e) < esize or e[:16] == b"\x00" * 16:
                continue
            first = int.from_bytes(e[8:16], "little")
            last = int.from_bytes(e[16:24], "little")
            start, end = first * LBA, (last + 1) * LBA
            rows.append((i + 1, name(e[56:128]), start, end - start))

        out = []
        for idx, lbl, start, size in rows:
            dg = sha(opts.image, start, size)
            flag = ""
            if f"p{idx}" in expect:
                flag = "match" if expect[f"p{idx}"] == size else "MISMATCH device=%d" % expect[f"p{idx}"]
            out.append((idx, lbl, start, size, dg, flag))
            print(f"p{idx} {lbl} offset={start} size={size} sha256={dg[:12]} {flag}")

        if opts.tsv:
            with open(opts.tsv, "w", encoding="utf-8") as w:
                w.write("index\tlabel\toffset\tsize\tsha256\tdevice_check\n")
                for r in out:
                    w.write("\t".join(str(x) for x in r) + "\n")
        if opts.carve:
            os.makedirs(opts.carve, exist_ok=True)
            for idx, lbl, start, size in rows:
                with open(opts.image, "rb") as f:
                    f.seek(start)
                    buf = f.read(size)
                with open(os.path.join(opts.carve, f"p{idx}.bin"), "wb") as w:
                    w.write(buf)
            print(f"carved {len(rows)} partitions into {opts.carve}")


if __name__ == "__main__":
    main()
