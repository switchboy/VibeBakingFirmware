#!/usr/bin/env python3
"""Add or replace files inside a raw super image WITHOUT rebuilding anything.

  python3 tools/super_patch.py <raw-super.img> <patch-manifest>

The manifest is tab-separated, one line per file:
  partition   local-file   dest-path-inside-partition   octal-mode
example:
  system   /path/hu_sdlog.sh      bin/hu_sdlog.sh      0755
  vendor   /path/hu.rc            etc/init/hu.rc       0644

How it works, and why it is safe:
  * lpdump gives each logical partition's extent offset and size inside the container. The partitions
    are carved out to scratch files, edited with debugfs (which reads and writes an ext4 image without
    mounting, so this needs no root), then written back at the SAME byte offset with the SAME size.
  * The container's metadata region (the first 1 MiB, metadata max size 65536 B) is never touched:
    the partition table stays byte-identical, and before/after bytes of that region are compared.
  * A partition whose size changes is rejected - super's metadata records fixed sizes, so a grown
    image would not be readable by init.
  * Nothing here writes to a device. The output is the container file itself, staged on the bench.

debugfs only adds inodes/blocks; if the filesystem has no free inodes or blocks left the tool aborts
before writing anything, which is the failure mode that would otherwise silently produce a corrupt fs.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

METADATA_BYTES = 1048576   # sectors 0..2047; lpdump: metadata max size 65536 B, partitions start at sector 2048


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def partitions(img):
    """{name: (byte_offset, byte_size)} from lpdump. Extents are 512-byte sectors."""
    out = sh(["lpdump", img]).stdout
    if not out:
        raise SystemExit("lpdump produced nothing for %s" % img)
    table = {}
    name = None
    for line in out.splitlines():
        m = re.match(r"\s*Name:\s+(\S+)", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"\s*(\d+)\s+\.\.\s+(\d+)\s+linear\s+super\s+(\d+)", line)
        if m and name:
            first, last, off = (int(x) for x in m.groups())
            table[name] = (off * 512, (last - first + 1) * 512)
    if not table:
        raise SystemExit("lpdump found no logical partitions in %s" % img)
    return table


def free_stats(part_file):
    """Free blocks + free inodes straight from the ext4 superblock.

    debugfs has no showfreeb/showfreeinode in this version (freeb/freei free an inode, not stats), so
    read the counters directly. Measured Nov 18 on these images: the superblock starts at byte 1024,
    s_inodes_count at +0, s_blocks_count_lo at +4, s_free_blocks_count_lo at +12, s_free_inodes_count
    at +16, and the magic (0xEF53) at +56 - which is why check_super.py scans at ~1080, not 1024.
    """
    import struct
    with open(part_file, "rb") as f:
        f.seek(1024)
        sb = f.read(64)
    if len(sb) < 60 or sb[56:58] != b"\x53\xef":
        raise SystemExit("%s: no ext4 superblock at byte 1024 (magic bytes read %r)" % (part_file, sb[56:58]))
    inodes_total, blocks_total, reserved, free_b, free_i = struct.unpack("<IIIII", sb[0:20])
    if not inodes_total or not blocks_total or free_i > inodes_total or free_b > blocks_total:
        raise SystemExit("%s: implausible superblock counters (inodes %d, blocks %d, free %d/%d)" % (
            part_file, inodes_total, blocks_total, free_b, free_i))
    return {"blocks": free_b, "inodes": free_i, "inodes_total": inodes_total}


def exists(part_file, path):
    return sh(["debugfs", "-R", "stat /%s" % path, part_file]).returncode == 0


def main():
    img, manifest = sys.argv[1], sys.argv[2]
    size = os.path.getsize(img)
    table = partitions(img)
    head_before = open(img, "rb").read(METADATA_BYTES)

    work = tempfile.mkdtemp(prefix="super_patch.", dir=os.path.dirname(os.path.abspath(img)))
    entries = {}
    for line in open(manifest):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        part, src, dest, mode = line.split("\t")
        if part not in table:
            raise SystemExit("no logical partition named %r in the container (known: %s)" % (part, ", ".join(sorted(table))))
        if not os.path.isfile(src):
            raise SystemExit("source file missing: %s" % src)
        if dest.startswith("/") or ".." in dest:
            raise SystemExit("dest must be a plain path inside the partition: %s" % dest)
        entries.setdefault(part, []).append((src, dest, int(mode, 8)))

    fail = 0
    for part, items in entries.items():
        off, psize = table[part]
        carve = os.path.join(work, part + ".img")
        with open(img, "rb") as f, open(carve, "wb") as o:
            f.seek(off)
            o.write(f.read(psize))
        st = free_stats(carve)
        if st["inodes"] is not None and st["inodes"] <= len(items) + 2:
            print("  ABORT %s: only %s free inodes for %d new files" % (part, st["inodes"], len(items)))
            fail = 1
            continue
        if st["blocks"] is not None:
            need = sum(os.path.getsize(s) for s, _, _ in items) // 4096 + 8
            if st["blocks"] <= need:
                print("  ABORT %s: only %s free blocks for %d B of files" % (part, st["blocks"], need))
                fail = 1
                continue

        script = os.path.join(work, part + ".script")
        with open(script, "w") as f:
            for src, dest, mode in items:
                d = os.path.dirname(dest)
                base = os.path.basename(dest)
                f.write("cd /\n")
                if d and not exists(carve, d):
                    f.write("mkdir %s\n" % d)
                if d:
                    f.write("cd %s\n" % d)
                if exists(carve, "%s/%s" % (d, base) if d else base):
                    f.write("rm %s\n" % base)
                f.write("write %s %s\n" % (os.path.abspath(src), base))
                f.write("set_inode_field /%s i_mode 0%o\n" % (dest, mode | 0o100000))
        r = sh(["debugfs", "-w", "-f", script, carve])
        if r.stderr.strip():
            for ln in r.stderr.strip().splitlines()[:6]:
                if any(w in ln for w in ("not a directory", "File not found", "Ext2", "Error")):
                    print("    debugfs: %s" % ln)
        if r.returncode:
            print("  debugfs %s failed: %s" % (part, r.stderr.strip()[:200]))
            fail = 1
            continue
        for src, dest, mode in items:
            st = sh(["debugfs", "-R", "stat /%s" % dest, carve])
            if st.returncode:
                print("  ABORT %s: /%s not present after debugfs" % (part, dest))
                fail = 1
                continue
            size_ok = re.search(r"\bSize:\s+(\d+)", st.stdout)
            mode_ok = re.search(r"\bMode:\s+0*(\d+)", st.stdout)
            want = os.path.getsize(src)
            if not size_ok or int(size_ok.group(1)) != want:
                print("  ABORT %s: /%s size %s, source %d B" % (part, dest,
                      size_ok.group(1) if size_ok else "?", want))
                fail = 1
            elif not mode_ok or int(mode_ok.group(1), 8) != mode:
                print("  ABORT %s: /%s mode %s, wanted %o" % (part, dest,
                      mode_ok.group(1) if mode_ok else "?", mode))
                fail = 1
        if sh(["debugfs", "-R", "stat /", carve]).returncode:
            print("  ABORT %s: filesystem no longer parses after the write" % part)
            fail = 1

    if fail:
        shutil.rmtree(work)
        raise SystemExit("patches refused; %s untouched" % img)

    # Splice each patched partition back at its recorded offset, same size, then re-verify the header.
    new_sha = None
    with open(img, "r+b") as f:
        for part, items in entries.items():
            off, psize = table[part]
            carve = os.path.join(work, part + ".img")
            blob = open(carve, "rb").read()
            if len(blob) != psize:
                raise SystemExit("%s changed size (%d -> %d); super metadata records fixed sizes" % (part, psize, len(blob)))
            f.seek(off)
            f.write(blob)
            print("  wrote %s at byte %d, %d B" % (part, off, psize))
        f.flush()
        os.fsync(f.fileno())
        f.seek(0)
        head_after = f.read(METADATA_BYTES)
        if head_after != head_before:
            raise SystemExit("metadata region changed - aborting after write; restore from the backup copy")
        if os.path.getsize(img) != size:
            raise SystemExit("container size changed (%d -> %d)" % (size, os.path.getsize(img)))
        f.seek(0)
        new_sha = hashlib_sha(f.read())

    print("container %s: %d B, sha %s" % (img, size, new_sha))
    print("metadata region unchanged, partition sizes unchanged")
    shutil.rmtree(work)


def hashlib_sha(b):
    import hashlib
    return hashlib.sha256(b).hexdigest()


if __name__ == "__main__":
    main()
