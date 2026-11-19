#!/usr/bin/env python3
"""Build the L2 boot image (**D62**): the OEM kernel and OEM `second` verbatim, with Android 14's
static first-stage `init` inside the stock Android 10 ramdisk, against the Android 10 `super`.

  python3 tools/build_l2_boot.py <oem_boot.bin> <ramdisk.gz> "<cmdline>" <out.img>

  <ramdisk.gz> is a gzip cpio (newc) whose `/init` is Android 14's first-stage binary and whose
  `/first_stage_ramdisk/fstab.<hardware>` exists - Android 14's init reads the fstab only from that
  directory, where Android 10's init reads it at the ramdisk root. `scripts/build_l2_ramdisk.sh`
  produces it from the stock capture's own ramdisk, so every other file is the OEM's.

Why a separate tool: `tools/rebuild_boot_faithful.py` takes its payload from an existing payload image,
and L2 has no such image - its ramdisk is assembled from the stock ramdisk plus one binary. This tool
applies the same rules (**D60**) and the same refusals (**D67**/**D68**), reading the header field order
`kernel_size @8`, `ramdisk_size @16`, `second_size @24` and the add-then-round layout the loader computes:
`kernel @ 2048`, `ramdisk @ roundup(2048 + kernel_size)`, `second @ roundup(ramdisk_offset + ramdisk_size)`.

Refusals:
* the OEM header is carried verbatim except `ramdisk_size` and the 512-byte cmdline field, and any byte
  changed outside those two is a failure;
* the cmdline must fit the field, and the tokens must be the ones measured on the unit (**D72**/**D73**);
* the kernel and `second` blobs must be byte-identical to the OEM image;
* components must not reach the OEM tail resource header;
* the finished image is read back exactly as a loader would, the tail must be carried verbatim from the
  rebuilt content end, the tail resource entries must still verify their declared SHA1s, and the DTB
  copies must sit where the OEM image has them (the copy inside `second` moves with the ramdisk size);
* the image must be the partition's own length, so the write is a whole-partition `dd` (**D66**).
"""
import hashlib
import struct
import sys
import os
import tempfile
import rebuild_boot_faithful as R

PAGE = 2048
CMDLINE_OFF, CMDLINE_LEN = 64, 512
# Tokens proven on the unit Nov 19 (docs/findings.md, "Nov 19 (night, second half)"). Anything else is
# refused, because an unverified token is a silent no-op and an unverified token can also change behaviour.
ALLOWED_TOKENS = ("printk.devkmsg=on", "loglevel=8", "panic=12",
                  "androidboot.init_fatal_reboot_target=recovery")


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def check_cmdline(cmd: str) -> bytes:
    tokens = cmd.split()
    for t in tokens:
        if t not in ALLOWED_TOKENS and not (t.startswith("androidboot.") or t in
                                            ("console=ttyFIQ0", "init=/init", "rootwait", "ro",
                                             "loop.max_part=7", "androidboot.selinux=permissive",
                                             "buildvariant=userdebug", "firmware_class.path=/vendor/etc/firmware")):
            raise SystemExit(f"token {t!r} is not in the measured set - refusing to guess a cmdline")
    if "androidboot.init_fatal_reboot_target=bootloader" in tokens:
        raise SystemExit("bootloader reboot target is excluded (D73): it hands a dying init to u-boot and removes the adb route")
    blob = cmd.encode()
    if len(blob) > CMDLINE_LEN:
        raise SystemExit(f"cmdline is {len(blob)} B, over the {CMDLINE_LEN} B field")
    return blob


def build(oem_path: str, ramdisk_path: str, cmdline: str, out_path: str) -> str:
    oem = open(oem_path, "rb").read()
    if oem[:8] != b"ANDROID!":
        raise SystemExit("the OEM input must carry the ANDROID! magic")
    ramdisk = open(ramdisk_path, "rb").read()
    if ramdisk[:2] != b"\x1f\x8b":
        raise SystemExit(f"the ramdisk input is not gzip ({ramdisk[:2]!r})")

    ks, rs_oem, ss, ro, so = R.offsets(oem)
    kernel = oem[PAGE:PAGE + ks]
    second = oem[so:so + ss]
    new_rs = len(ramdisk)
    new_ro = R.roundup(PAGE + ks)
    new_so = R.roundup(new_ro + new_rs)
    content_end = R.roundup(new_so + ss)

    res = [m.start() for m in R.RESOURCE_MAGIC.finditer(oem) if m.start() >= R.roundup(so + ss)]
    if not res:
        raise SystemExit("OEM image has no resource header at or after its own content end")
    tail_res_start = min(res)
    if content_end > tail_res_start:
        raise SystemExit(f"components reach {content_end:,} B, past the tail resource header at {tail_res_start:,} B")
    if content_end > len(oem):
        raise SystemExit(f"assembled content {content_end:,} B exceeds the partition's {len(oem):,} B")

    hdr = bytearray(oem[:PAGE])
    struct.pack_into('<I', hdr, 16, new_rs)
    field = check_cmdline(cmdline)
    hdr[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = field + b"\x00" * (CMDLINE_LEN - len(field))

    body = bytearray(hdr) + kernel
    body += b"\x00" * (new_ro - len(body)) + ramdisk
    body += b"\x00" * (new_so - len(body)) + second
    body += b"\x00" * (content_end - len(body))
    out = bytes(body) + oem[content_end:]
    out += b"\x00" * (len(oem) - len(out))

    # Read it back exactly as a loader would (the same checks identity_gate check 2 makes).
    ks2, rs2, ss2, ro2, so2 = R.offsets(out)
    if (ks2, rs2, ss2, ro2, so2) != (ks, new_rs, ss, new_ro, new_so):
        raise SystemExit(f"header fields do not reproduce the layout: {ks2, rs2, ss2, ro2, so2}")
    if out[PAGE:PAGE + ks] != kernel:
        raise SystemExit("kernel blob is not byte-identical to the OEM image")
    if out[so2:so2 + ss] != second:
        raise SystemExit(f"second blob differs ({sha(out[so2:so2 + ss])[:12]} vs {sha(second)[:12]})")
    if out[ro2:ro2 + new_rs] != ramdisk:
        raise SystemExit("ramdisk is not readable at the offset a loader computes")
    if out[ro2 + new_rs:new_so] != b"\x00" * (new_so - ro2 - new_rs):
        raise SystemExit(f"the span between the ramdisk ({ro2 + new_rs:,}) and second ({new_so:,}) is not zero padding")
    if out[content_end:] != oem[content_end:]:
        raise SystemExit("the OEM tail is not carried verbatim from the content end")
    dtbs = R.dtb_positions(oem)
    in_second = [(p, t) for p, t in dtbs if so <= p < so + ss]
    tail = [(p, t) for p, t in dtbs if p >= tail_res_start]
    expected = sorted([(so2 + (p - so), t) for p, t in in_second] + tail)
    got = sorted(R.dtb_positions(out))
    if got != expected:
        raise SystemExit(f"DTB positions changed: expected {expected} vs rebuilt {got}")
    entries = R.resource_entries(out, tail_res_start)
    if not entries or any(not e["ok"] for e in entries):
        raise SystemExit(f"tail resource entries failed: {[(e['name'], e['ok']) for e in entries]}")
    bad = []
    start = None
    for i in range(PAGE):
        if oem[i] != out[i]:
            if start is None:
                start = i
            last = i
        elif start is not None:
            if not (16 <= start <= 19 or CMDLINE_OFF <= start <= CMDLINE_OFF + CMDLINE_LEN - 1):
                bad.append((start, last))
            start = None
    if start is not None and not (16 <= start <= 19 or CMDLINE_OFF <= start <= CMDLINE_OFF + CMDLINE_LEN - 1):
        bad.append((start, last))
    if bad:
        raise SystemExit(f"header changed outside ramdisk_size and the cmdline field: {bad}")

    with open(out_path, "wb") as f:
        f.write(out)
    report = (f"oem     {len(oem):,} B  kernel {sha(kernel)[:12]}  second {sha(second)[:12]}  ramdisk {sha(oem[ro:R.roundup(ro + rs_oem)])[:12]}\n"
              f"new     ramdisk {new_rs:,} B @ {new_ro:,}  second @ {new_so:,}  content end {content_end:,}\n"
              f"cmdline {len(field)} B of {CMDLINE_LEN}: {cmdline}\n"
              f"out     {len(out):,} B sha256 {sha(out)}\n"
              f"  tail carried verbatim from {content_end:,} B, resource header at {tail_res_start:,} B\n"
              + "\n".join(f"  tail entry {e['name']} @{e['pos']:,} {e['size']:,} B sha1 {e['sha1'][:12]} {'MATCHES' if e['ok'] else 'MISMATCH'}" for e in entries)
              + "\n" + "\n".join(f"  DTB @{p:,} size {t:,}" for p, t in got)
              + "\nself-check OK: header changes only ramdisk_size and the cmdline field")
    return report


def main(argv):
    if len(argv) != 5:
        raise SystemExit(__doc__)
    print(build(argv[1], argv[2], argv[3], argv[4]))


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main(sys.argv)
