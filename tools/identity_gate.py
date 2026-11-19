#!/usr/bin/env python3
"""Identity round-trip gate (**D67**): can our own tooling reproduce the OEM image byte-for-byte?

  python3 tools/identity_gate.py <stock_boot> <payload_boot> <stock_super> <payload_super> [--work <dir>]

Why this gate exists. Every Android 14 result is uninterpretable if the packing pipeline itself changes bytes
the boot chain cares about: a repack that silently differs from stock would make a failed payload boot look
like an Android 14 problem when it is really a pipeline defect. The gate answers that offline, with no unit
involved. It ran for the first time on Nov 19 and failed check 1, which is how the zero-filled tail in
tools/rebuild_boot_faithful.py was found (docs/findings.md, "Nov 19").

Check 1 - identity. The stock capture is fed to tools/rebuild_boot_faithful.py as BOTH inputs (no content
change), so the result must be byte-identical to the capture. Any difference is a pipeline defect.

Check 2 - payload fidelity. The same tool fed with the payload must keep: the header page identical except the
two documented regions (`ramdisk_size` at 16..19 and the 512-byte cmdline field at 64..575); the kernel blob;
the `second` blob; and everything from the payload's own content end to the partition end, verbatim from stock
(splash content, the tail resource image and its DTB copies). Content may differ only inside the ramdisk span
and the padding span - never in the kernel, never past the content end.

Check 3 - super metadata. `lpdump` both supers and report every difference: device size, first sector, metadata
slots, partition names, groups, attributes and extents. The payload's metadata changes the group name, drops the
OEM's readonly attributes and adds system_ext; that is stated as a delta, not hidden. A device-size or
first-sector change is a hard failure (**D18** - `super` is never resized).

Exit status 0 only when all three checks prove what they claim. A FAIL line names the region, so a wrong image
cannot be proposed for a write quietly.
"""
import argparse
import re
import struct
import subprocess
import sys
from pathlib import Path

PAGE = 2048
CMDLINE_OFF, CMDLINE_LEN = 64, 512
ALLOWED_HEADER = [(16, 19), (CMDLINE_OFF, CMDLINE_OFF + CMDLINE_LEN - 1)]
REBUILD = Path(__file__).with_name("rebuild_boot_faithful.py")


def read(path: Path) -> bytes:
    return path.read_bytes()


def ranges(a: bytes, b: bytes):
    """Byte ranges where two same-length images differ."""
    if len(a) != len(b):
        raise SystemExit(f"length differs: {len(a):,} vs {len(b):,}")
    out = []
    i = 0
    while i < len(a):
        if a[i] != b[i]:
            j = i
            while j < len(a) and a[j] != b[j]:
                j += 1
            out.append((i, j - 1))
            i = j
        else:
            i += 1
    return out


def outside(span, rs):
    """Ranges that fall outside `span`."""
    lo, hi = span
    return [r for r in rs if not (lo <= r[0] and r[1] <= hi)]


def outside_allowed(rs):
    """Ranges that fall outside the documented header regions."""
    return [r for r in rs if not any(lo <= r[0] and r[1] <= hi for lo, hi in ALLOWED_HEADER)]


def rebuild(stock: Path, payload: Path, out: Path) -> str:
    p = subprocess.run([sys.executable, str(REBUILD), str(stock), str(payload), str(out)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"rebuild_boot_faithful.py failed: {(p.stdout + p.stderr).strip()}")
    return p.stdout


def layout(d: bytes):
    """The offsets a Rockchip loader computes: kernel @ 2048, ramdisk @ roundup(2048+kernel), second @ roundup(ramdisk+ramdisk_size)."""
    ks = struct.unpack_from('<I', d, 8)[0]
    rs = struct.unpack_from('<I', d, 16)[0]
    ss = struct.unpack_from('<I', d, 24)[0]
    ro = ((2048 + ks + PAGE - 1) // PAGE) * PAGE
    so = ((ro + rs + PAGE - 1) // PAGE) * PAGE
    return ks, rs, ss, ro, so, ((so + ss + PAGE - 1) // PAGE) * PAGE


def lpdump_fields(image: Path) -> dict:
    """Parse lpdump's slot-0 output into comparable facts, section by section."""
    p = subprocess.run(["lpdump", str(image)], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"lpdump failed on {image}: {(p.stdout + p.stderr).strip()}")

    def num(line):
        m = re.search(r"\d+", line.split(":", 1)[1])
        return int(m.group()) if m else None

    fields = {"partitions": {}, "groups": {}, "layout": [], "super_size": None, "super_first_sector": None,
              "metadata_size": None, "metadata_slots": None, "flags": None}
    cur = None
    section = None
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.endswith("table:") and not line.startswith("Slot"):
            section = line[:-6].strip().lower().replace(" ", "_")
            cur = None
            continue
        if line.startswith("Metadata size:"):
            fields["metadata_size"] = num(line)
        elif line.startswith("Metadata slot count:"):
            fields["metadata_slots"] = num(line)
        elif line.startswith("Header flags:"):
            fields["flags"] = line.split(":", 1)[1].strip()
        elif section == "partition" and line.startswith("Name:"):
            cur = line.split(":", 1)[1].strip()
            fields["partitions"][cur] = {}
        elif section == "partition" and cur and line.startswith("Group:"):
            fields["partitions"][cur]["group"] = line.split(":", 1)[1].strip()
        elif section == "partition" and cur and line.startswith("Attributes:"):
            fields["partitions"][cur]["attrs"] = line.split(":", 1)[1].strip()
        elif section == "partition" and cur and ".." in line:
            fields["partitions"][cur]["extent"] = line
        elif section == "super_partition_layout":
            fields["layout"].append(line)
        elif section == "block_device" and line.startswith("First sector:"):
            fields["super_first_sector"] = num(line)
        elif section == "block_device" and line.startswith("Size:"):
            fields["super_size"] = num(line)
        elif section == "group" and line.startswith("Name:"):
            cur = line.split(":", 1)[1].strip()
            fields["groups"][cur] = None
        elif section == "group" and line.startswith("Maximum size:"):
            fields["groups"][cur] = num(line)
    return fields


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("stock_boot"); ap.add_argument("payload_boot")
    ap.add_argument("stock_super"); ap.add_argument("payload_super")
    ap.add_argument("--work", default=".")
    args = ap.parse_args(argv[1:])
    work = Path(args.work); work.mkdir(parents=True, exist_ok=True)
    stock_boot = Path(args.stock_boot); payload_boot = Path(args.payload_boot)

    fails = []
    stock_bytes = read(stock_boot)

    print("== check 1: identity (stock content through our tooling must equal the stock capture) ==")
    ident = work / "identity-boot.img"
    rebuild(stock_boot, stock_boot, ident)
    rs = ranges(stock_bytes, read(ident))
    if rs:
        print(f"FAIL identity: the rebuilt image differs from the capture at {rs} "
              f"({sum(e - s + 1 for s, e in rs):,} bytes) - a pipeline defect, the leading suspect")
        fails.append("boot-identity")
    else:
        print(f"PASS identity: {len(stock_bytes):,} B reproduced byte-for-byte from {stock_boot.name}")

    print("== check 2: payload fidelity (what may and may not change) ==")
    faithful = work / "faithful-boot.img"
    rebuild(stock_boot, payload_boot, faithful)
    fb = read(faithful)
    _, _, _, _, _, pay_content_end = layout(fb)
    hdr_rs = [r for r in ranges(stock_bytes[:PAGE], fb[:PAGE])]
    bad_hdr = outside_allowed(hdr_rs)
    if bad_hdr:
        print(f"FAIL header: changed outside ramdisk_size and the cmdline field: {bad_hdr}")
        fails.append("boot-header")
    else:
        print(f"  header differs only in {hdr_rs} - all inside bytes 16..19 and 64..575")

    _, _, _, ro, so, _ = layout(fb)
    _, _, _, sro, sso, _ = layout(stock_bytes)
    ks = struct.unpack_from('<I', fb, 8)[0]
    if fb[2048:2048 + ks] != stock_bytes[2048:2048 + ks]:
        print("FAIL kernel: the kernel blob is not byte-identical to stock")
        fails.append("boot-kernel")
    else:
        print(f"  kernel blob identical ({ks:,} B)")
    ss = struct.unpack_from('<I', fb, 24)[0]
    if fb[so:so + ss] != stock_bytes[sso:sso + ss]:
        print("FAIL second: the OEM second stage is not byte-identical to stock")
        fails.append("boot-second")
    else:
        print(f"  second blob identical ({ss:,} B), moved from {sso:,} to {so:,} by the payload's ramdisk size")
    if fb[pay_content_end:] != stock_bytes[pay_content_end:]:
        print(f"FAIL tail: bytes from {pay_content_end:,} to the partition end are not stock's bytes")
        fails.append("boot-tail")
    else:
        print(f"  tail identical from {pay_content_end:,} B ({len(stock_bytes) - pay_content_end:,} B: splash, resource header, DTB copies)")

    content_rs = [r for r in ranges(stock_bytes[PAGE:pay_content_end], fb[PAGE:pay_content_end])]
    content_rs = [(s + PAGE, e + PAGE) for s, e in content_rs]
    allowed_content = [(ro, ((ro + struct.unpack_from('<I', fb, 16)[0] + PAGE - 1) // PAGE) * PAGE),
                       (so, so + ss), (so + ss, pay_content_end)]
    bad_content = outside((ro, pay_content_end), content_rs)
    stray = [r for r in content_rs if not any(lo <= r[0] and r[1] <= hi for lo, hi in allowed_content)]
    if bad_content or stray:
        print(f"FAIL content: payload changes reach outside the ramdisk/second/padding span: {bad_content or stray}")
        fails.append("boot-content")
    else:
        print(f"  content differs in {len(content_rs)} ranges totalling "
              f"{sum(e - s + 1 for s, e in content_rs):,} B, all inside the ramdisk span {ro:,}..{(ro + struct.unpack_from('<I', fb, 16)[0]):,} "
              f"and the padding span {so + ss:,}..{pay_content_end:,}")
        if content_rs:
            print(f"  ranges: {content_rs[:8]}{' ...' if len(content_rs) > 8 else ''}")

    print("== check 3: super metadata delta ==")
    a = lpdump_fields(Path(args.stock_super)); b = lpdump_fields(Path(args.payload_super))
    if a["super_size"] != b["super_size"]:
        print(f"FAIL super device size: stock {a['super_size']:,} vs payload {b['super_size']:,}")
        fails.append("super-device")
    else:
        print(f"  super device size identical ({a['super_size']:,} B)")
    if a["super_first_sector"] != b["super_first_sector"]:
        print(f"FAIL super first sector: stock {a['super_first_sector']} vs payload {b['super_first_sector']}")
        fails.append("super-first-sector")
    else:
        print(f"  first sector identical ({a['super_first_sector']})")
    if a["metadata_slots"] != b["metadata_slots"]:
        print(f"FAIL metadata slot count: stock {a['metadata_slots']} vs payload {b['metadata_slots']}")
        fails.append("super-slots")
    else:
        print(f"  metadata slots identical ({a['metadata_slots']}), metadata size {a['metadata_size']} -> {b['metadata_size']}, flags {a['flags']} -> {b['flags']}")
    only_stock = sorted(set(a["partitions"]) - set(b["partitions"]))
    only_pay = sorted(set(b["partitions"]) - set(a["partitions"]))
    print(f"  partitions: stock-only {only_stock}, payload-only {only_pay}")
    deltas = 0
    for n in sorted(set(a["partitions"]) & set(b["partitions"])):
        sa, sb = a["partitions"][n], b["partitions"][n]
        if sa != sb:
            deltas += 1
            print(f"  delta {n}: stock {sa} -> payload {sb}")
    if a["groups"] != b["groups"]:
        print(f"  group table: stock {a['groups']} -> payload {b['groups']}")
    if a["layout"] != b["layout"]:
        print(f"  layout rows differ ({len(a['layout'])} stock vs {len(b['layout'])} payload):")
        for row in b["layout"]:
            print(f"    payload: {row}")
    print(f"  partition deltas: {deltas}")

    if fails:
        print(f"identity_gate: FAIL ({', '.join(fails)}) - no image may be proposed for a write")
        return 1
    print("identity_gate: PASS - the pipeline reproduces the OEM image, and the payload's deviations are documented")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
