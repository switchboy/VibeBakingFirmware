#!/usr/bin/env python3
"""card_image_analysis.py - STEP 0.3 for the verified SD-boot card image (**D98**).

Runs against the workstation's captured image (never a device): reads the GPT, checks each partition
span against the size the unit reported, then analyses the card's OWN boot (p7) and recovery (p8)
partition contents - header fields, cmdline, kernel banner, second/dtbo digests, ramdisk listing,
init.rc, init.recovery.rk30board.rc, recovery.fstab, prop.default, the recovery binary digest, and
whether the ax88179_178a driver is present in the kernel blob. Extracted artifacts are written to a
directory so they can be diffed against the eMMC capture. cpio extraction runs as an ordinary user, so the
ramdisk's device nodes do not come out - the listing (cpio -it) is complete and the regular files are
what gets analysed.
"""
import argparse
import gzip
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rebuild_boot_faithful as R
import sd_card_layout as L

LBA = 512


def sha(path, start=None, length=None):
    return L.sha(path, start, length)


def gpt(image):
    """The card's own GPT reader, shared with tools/sd_card_layout.py: the header's entry_count and
    entry_size are unusable on this card, so the entries are read from the record area itself."""
    rows, facts = L.read_gpt(image)
    return rows, facts


def extract_ramdisk(part_file, outdir):
    d = open(part_file, "rb").read()
    ks, rs, ss, ro, so = R.offsets(d)
    raw = gzip.decompress(d[ro:ro + rs])
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "ramdisk.cpio"), "wb") as w:
        w.write(raw)
    subprocess.run(["cpio", "-idmf", "--quiet"], cwd=outdir,
                   stdin=open(os.path.join(outdir, "ramdisk.cpio"), "rb"),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return ks, rs, ss, ro, so, raw


def find_strings(blob, needle, limit=6):
    out, pos = [], 0
    while True:
        i = blob.find(needle, pos)
        if i < 0 or len(out) >= limit:
            break
        out.append((i, blob[i:i + 90].split(b"\x00")[0].decode(errors="replace")))
        pos = i + 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--sizes", default="", help="device sizes pN=BYTES, comma separated")
    ap.add_argument("--extract", default="", help="directory for extracted artifacts")
    ap.add_argument("--tsv", default="", help="layout table to write")
    opts = ap.parse_args()
    extract = opts.extract or tempfile.mkdtemp(prefix="hu-card-analysis.")
    os.makedirs(extract, exist_ok=True)

    expect = {}
    for tok in opts.sizes.split(","):
        k, _, v = tok.partition("=")
        if k and v:
            expect[k.strip()] = int(v)

    rows, facts = gpt(opts.image)
    total = facts["image_bytes"]
    print("image %d B ; GPT %s rev=%d header_size=%d entry_count_claimed=%d entry_size_claimed=%d "
          "entry_crc=%d first_usable_lba=%d last_usable_lba=%d protective_mbr=%s"
          % (total, facts["signature"], facts["revision"], facts["header_size"],
             facts["entry_count_claimed"], facts["entry_size_claimed"], facts["entry_crc_claimed"],
             facts["first_usable_lba"], facts["last_usable_lba"], facts["protective_mbr"]))
    lines = []
    for idx, lbl, start, size in rows:
        key = "p%d" % idx
        flag = ""
        if key in expect:
            flag = "device-size match" if expect[key] == size else "MISMATCH device=%d" % expect[key]
        trunc = "TRUNCATED image ends at %d B" % total if start + size > total else ""
        dg = sha(opts.image, start, size)
        if trunc:
            lines.append(f"p{idx} {lbl} offset={start} size={size} {trunc}")
            print(lines[-1])
            continue
        pfile = os.path.join(extract, f"p{idx}.bin")
        with open(opts.image, "rb") as f:
            f.seek(start)
            with open(pfile, "wb") as w:
                w.write(f.read(size))
        lines.append(f"p{idx} {lbl} offset={start} size={size} sha256={dg} {flag}")
    if opts.tsv:
        with open(opts.tsv, "w", encoding="utf-8") as w:
            w.write("index\tlabel\toffset\tsize\tsha256\tdevice_check\n")
            for idx, lbl, start, size in rows:
                w.write(f"{idx}\t{lbl}\t{start}\t{size}\t{sha(opts.image, start, size)}\t"
                        f"{expect.get('p%d' % idx, '')}\n")

    for idx, lbl, start, size in rows:
        if lbl not in ("boot", "recovery"):
            continue
        pfile = os.path.join(extract, f"p{idx}.bin")
        d = open(pfile, "rb").read()
        magic = d[:8]
        ks, rs, ss, ro, so = R.offsets(d)
        header = d[:128]
        cmdline = d[64:576].split(b"\x00")[0].decode(errors="replace")
        board = d[12:24].split(b"\x00")[0].decode(errors="replace")
        print(f"\n== partition {idx} ({lbl}) size={size} magic={magic!r} ==")
        print(f"  header: kernel {ks} ramdisk_gz {rs} @{ro} second {ss} @{so} board={board!r}")
        print(f"  cmdline: {cmdline}")
        print(f"  partition sha256={sha(pfile)}")
        print(f"  kernel blob  sha256={hashlib.sha256(d[2048:2048 + ks]).hexdigest()} len={ks}")
        print(f"  ramdisk gz   sha256={hashlib.sha256(d[ro:ro + rs]).hexdigest()} len={rs}")
        print(f"  second blob  sha256={hashlib.sha256(d[so:so + ss]).hexdigest()} len={ss}")
        for pos, total in R.dtb_positions(d):
            print(f"  DTB at {pos} size {total} sha256={hashlib.sha256(d[pos:pos + total]).hexdigest()}")
        banner = find_strings(d[2048:2048 + ks], b"Linux version", 2)
        for off, s in banner:
            print(f"  kernel banner @{off}: {s[:80]}")
        drv = find_strings(d[2048:2048 + ks], b"ax88179", 4)
        print(f"  ax88179 strings in kernel blob: {len(drv)}")
        for off, s in drv:
            print(f"    @{off}: {s[:70]}")
        rd = os.path.join(extract, f"rd{idx}")
        _ks, _rs, _ss, _ro, _so, raw = extract_ramdisk(pfile, rd)
        listing = subprocess.run(["cpio", "-it", "--quiet"], cwd=rd,
                                 stdin=open(os.path.join(rd, "ramdisk.cpio"), "rb"),
                                 capture_output=True, text=True).stdout.split()
        with open(os.path.join(extract, f"rd{idx}-listing.txt"), "w") as w:
            w.write("\n".join(sorted(listing)) + "\n")
        print(f"  ramdisk entries: {len(listing)} ; listing in rd{idx}-listing.txt")
        for f in ("init.rc", "init.recovery.rk30board.rc", "recovery.fstab", "prop.default",
                  "system/bin/recovery", "sbin/sh", "sbin/busybox"):
            path = os.path.join(rd, f)
            if os.path.isfile(path):
                print(f"  {f}: size={os.path.getsize(path)} sha256={sha(path)}")
            elif os.path.islink(path):
                print(f"  {f}: symlink -> {os.readlink(path)}")
            else:
                print(f"  {f}: ABSENT")
        fst = os.path.join(rd, "recovery.fstab")
        if os.path.isfile(fst):
            print("  recovery.fstab:")
            for ln in open(fst, errors="replace"):
                if ln.strip() and not ln.startswith("#"):
                    print(f"    {ln.rstrip()}")
        pd = os.path.join(rd, "prop.default")
        if os.path.isfile(pd):
            keys = [ln.split("=")[0] for ln in open(pd, errors="replace") if "=" in ln]
            print(f"  prop.default keys: {len(keys)}")
            for k in ("ro.bootimage.build.fingerprint", "ro.build.display.id", "ro.adb.secure",
                      "ro.debuggable", "ro.boot.mode"):
                if k in keys:
                    print(f"    present: {k}")
    print(f"\nextracted artifacts in {extract}")


if __name__ == "__main__":
    main()
