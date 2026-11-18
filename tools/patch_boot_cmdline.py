#!/usr/bin/env python3
"""Add or replace kernel command-line tokens inside a Rockchip Android boot image header.

  python3 tools/patch_boot_cmdline.py <boot.img> --add panic=12
  python3 tools/patch_boot_cmdline.py <boot.img> --add panic=12 --replace androidboot.selinux=enforcing

Why a byte patch and not mkbootimg: the shape-A image (boot-a10k-a14rd.img) is assembled byte-wise by
scripts/rebuild_boot_with_fstab.sh, because mkbootimg --header_version 2 refuses a DTB-less build and
this image carries the OEM Android 10 kernel plus the OEM `second` blob (the DTB lives inside it, D38).
Repacking with mkbootimg would drop `second` and shift every component offset. The cmdline is a fixed
512-byte field in the header page, so editing only it moves nothing.

Measured Nov 18 on boot-a10k-a14rd.img: the field sits at byte 64 and already reads
  console=ttyFIQ0 androidboot.baseband=N/A androidboot.wificountrycode=NL androidboot.veritymode=disabled
  androidboot.hardware=rk30board androidboot.console=ttyFIQ0 androidboot.verifiedbootstate=orange
  firmware_class.path=/vendor/etc/firmware init=/init rootwait ro loop.max_part=7
  androidboot.selinux=permissive buildvariant=userdebug
The trailing tokens are Android's own defaults added by mkbootimg. Replacing the whole field would
lose init=/init, ro, rootwait and loop.max_part=7, so this tool edits tokens and keeps the rest.

Safety: the field is located as the single printable run containing "androidboot." in the first page;
the new string must be <= 512 B; the output is written to a temp file and only replaces the original
after the bytes have been read back and every untouched byte outside the field is compared.
"""
import hashlib
import os
import sys

CMDLINE_FIELD = 512


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    img = sys.argv[1]
    add, replace = [], []
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--add":
            add += sys.argv[i + 1].split(",")
            i += 2
        elif sys.argv[i] == "--replace":
            replace += sys.argv[i + 1].split(",")
            i += 2
        else:
            raise SystemExit("unexpected argument %r (use --add k=v[,k=v] / --replace k=v)" % sys.argv[i])

    orig = open(img, "rb").read()
    page = orig[:2048]

    # The cmdline field: one printable run in the header page that mentions androidboot.*.
    runs = []
    start = 0
    while start < len(page):
        if 32 <= page[start] <= 126:
            end = start
            while end < len(page) and 32 <= page[end] <= 126:
                end += 1
            if b"androidboot." in page[start:end]:
                runs.append((start, end))
            start = end
        else:
            start += 1
    if len(runs) != 1:
        raise SystemExit("expected exactly one cmdline field in the header page, found %d: %s" % (
            len(runs), [(s, e - s) for s, e in runs]))
    off, end = runs[0]
    old = page[off:end].decode("ascii")
    print("cmdline field at byte %d, %d B of %d" % (off, end - off, CMDLINE_FIELD))
    print("  old: %s" % old)

    tokens = old.split()
    for tok in replace:
        key = tok.split("=", 1)[0]
        tokens = [t for t in tokens if t.split("=", 1)[0] != key]
        tokens.append(tok)
    for tok in add:
        key = tok.split("=", 1)[0]
        if any(t.split("=", 1)[0] == key for t in tokens):
            print("  %s already present - not added" % tok)
            continue
        tokens.append(tok)

    new = " ".join(tokens)
    # Space available = the run itself plus the zero padding that follows it. Anything non-zero after
    # the run is other header data (this image has signature hashes at byte 520), so it is off limits.
    avail = end
    while avail < off + CMDLINE_FIELD and page[avail] == 0:
        avail += 1
    if len(new) > avail - off:
        raise SystemExit("new cmdline is %d B but only %d B of field+padding is free (byte %d is not zero)" % (
            len(new), avail - off, avail))
    print("  new: %s (%d B, field+free padding %d B)" % (new, len(new), avail - off))

    data = bytearray(orig)
    data[off:avail] = new.encode("ascii") + b"\x00" * (avail - off - len(new))
    out = bytes(data)
    if len(out) != len(orig):
        raise SystemExit("image size changed (%d -> %d)" % (len(orig), len(out)))
    # Everything outside off..avail must be byte-identical.
    if out[:off] != orig[:off] or out[avail:] != orig[avail:]:
        raise SystemExit("bytes outside the cmdline field changed - aborting")
    got = out[off:avail].split(b"\x00", 1)[0].decode("ascii")
    if got != new:
        raise SystemExit("read-back mismatch:\n  got: %s\n  want: %s" % (got, new))

    tmp = img + ".tmp"
    with open(tmp, "wb") as f:
        f.write(out)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, img)
    print("size %d B  old sha %s  new sha %s" % (len(out), sha(orig)[:16], sha(out)[:16]))


if __name__ == "__main__":
    main()
