#!/usr/bin/env python3
"""Offline sanity check for the staged super image.

  1. simg2img the build's sparse super.img into a raw image.
  2. lpdump the raw image -> partition table (extent sectors + offset into super).
  3. byte-compare each logical partition's bytes against IMAGES/<name>.img from the target_files
     zip - that is what `m superimage` stages.
  4. carve each embedded partition back out into its own file and let debugfs read the ext4 super
     block: debugfs understands ext4, so "it parses" is the real proof that the filesystem inside
     super is intact. (The ext4 magic is 0xEF53, stored little-endian, so the bytes read 53 ef;
     it sits ~1080 bytes into the filesystem - s_magic is at offset 60 of the ext4 super block,
     which starts at byte 1024. Scanning at +1024 for 0xEF83 finds nothing: that is what made the
     first attempt look broken.)
  5. report group size, used bytes and spare bytes.

Run on the build host: python3 tmp/check_super.py
"""
import os
import re
import subprocess
import zipfile

TREE = os.environ.get("TREE", "/srv/dev-disk-by-label-SSData/aospbuild/lineage21s")
WORK = os.environ.get("WORK", "/srv/dev-disk-by-label-SSData/aospbuild/tmp")
RAW = os.path.join(WORK, "super_raw.img")
ZIP = os.path.join(TREE, "out/dist/lineage_rk3399-target_files-root.zip")
# The staging dir `m superimage` reads to build super.img; dist's zip is only a copy of it.
IMAGES_DIR = os.path.join(
    TREE,
    "out/target/product/rk3399/obj/PACKAGING/target_files_intermediates/"
    "lineage_rk3399-target_files/IMAGES")
LPDUMP = os.path.join(TREE, "out/host/linux-x86/bin/lpdump")
SIMG2IMG = os.path.join(TREE, "out/host/linux-x86/bin/simg2img")
SUPER_IMG = os.path.join(TREE, "out/target/product/rk3399/super.img")
MISC_INFO = os.path.join(TREE, "out/target/product/rk3399/misc_info.txt")

subprocess.run([SIMG2IMG, SUPER_IMG, RAW], check=True)
data = open(RAW, "rb").read()
print("raw super size: %d" % len(data))

info = {}
for line in open(MISC_INFO):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        info[k] = v
group = info.get("super_partition_groups", "").split()[0]
group_size = int(info["super_%s_group_size" % group])
super_size = int(info["super_partition_size"])
print("group: %s size=%d ; super_partition_size=%d" % (group, group_size, super_size))

dump = subprocess.run([LPDUMP, RAW], capture_output=True, text=True).stdout
parts = {}
name = None
for line in dump.splitlines():
    line = line.strip()
    if line.startswith("Name:"):
        name = line.split(":", 1)[1].strip()
    elif line.startswith("0 .."):
        tok = line.split()
        first, last, off = int(tok[0]), int(tok[2]), int(tok[-1])
        parts[name] = (last - first + 1, off * 512)
parts.pop("default", None)

zf = zipfile.ZipFile(ZIP)
all_ok = True
used = 0
for name_, (sectors, off) in sorted(parts.items(), key=lambda kv: kv[1][1]):
    entry = "IMAGES/" + name_ + ".img"
    src_path = os.path.join(IMAGES_DIR, name_ + ".img")
    if os.path.exists(src_path):
        # The staging directory is what `m superimage` actually stages into super.img.
        opener = open(src_path, "rb")
    elif entry in zf.namelist():
        opener = zf.open(entry)
    else:
        print("  %-10s MISSING from staging dir and from target_files zip" % name_)
        all_ok = False
        continue
    carved = os.path.join(WORK, "embed_%s.img" % name_)
    with opener as fh, open(carved, "wb") as out:
        pos = off
        match = True
        n = 0
        while True:
            chunk = fh.read(1 << 22)
            if not chunk:
                break
            if data[pos:pos + len(chunk)] != chunk:
                match = False
            data_slice = data[pos:pos + len(chunk)]
            out.write(data_slice)
            pos += len(chunk)
            n += len(chunk)
    magic_off = data[off:off + 4096].find(b"\x53\xef")
    # dumpe2fs validates the ext4 magic (0xEF53) and reports the geometry, so it is the real proof
    # that the filesystem inside super is intact.
    dmp = subprocess.run(["dumpe2fs", "-h", carved], capture_output=True, text=True)
    fs_ok = dmp.returncode == 0
    blocks = re.search(r"Block count:\s*(\d+)", dmp.stdout)
    bs = re.search(r"Block size:\s*(\d+)", dmp.stdout)
    fs_bytes = int(blocks.group(1)) * int(bs.group(1)) if blocks and bs else 0
    print("  %-10s off=%10d extent=%d img=%d embedded_matches=%s ext4_magic_offset=%d debugfs_parses=%s fs=%d" %
          (name_, off, sectors * 512, n, match, magic_off, fs_ok, fs_bytes))
    all_ok = all_ok and match and fs_ok and magic_off > 0 and sectors * 512 >= n
    used = max(used, off + sectors * 512)
    os.remove(carved)

print("used inside super: %d ; spare: %d (%d MiB)" % (used, len(data) - used, (len(data) - used) // 1048576))
print("used vs group size: %d of %d ; group spare %d" % (used, group_size, group_size - used))
print("group fits inside super_partition_size: %s" % (group_size <= super_size))
print("ALL LOGICAL PARTITIONS VERIFIED: %s" % all_ok)
