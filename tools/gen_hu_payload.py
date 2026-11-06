#!/usr/bin/env python3
"""Build the file set that goes into the HU's own update.zip (docs/flash.md).

  tools/gen_hu_payload.py <product-out-dir> <stock-package-dir> <outdir>

Everything the head unit's stock `update-binary` understands, and nothing else:

  dynamic_partitions_op_list  our Android 14 layout, built from misc_info.txt. Same super partition
                              size and same group size as stock, only the logical partition list and
                              sizes change - inside /dev/block/by-name/super, never the GPT (D11).
  <part>.transfer.list        one `flash` command covering the whole image, block-aligned
  <part>.new.dat              the raw ext4 image, in command order (concatenation of the `new` chunks)
  <part>.patch.dat            empty -> unconditional full flash, exactly like the stock package
  boot.img                    our Android 14 boot image

The stock package carries no system_ext; Android 14 does, so the op list must create it.

Prints the numbers the updater-script needs (partition sizes) and refuses to write anything if an
image is larger than the extent the op list will create.
"""
import os
import re
import subprocess
import sys

PARTITIONS = ("system", "vendor", "product", "system_ext", "odm")


def misc_info(prod):
    info = {}
    for line in open(os.path.join(prod, "misc_info.txt"), errors="replace"):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            info[k] = v
    return info


def transfer_list(image, blocksize):
    """Version-1 transfer list: header + one flash command for the whole image. patch.dat stays
    empty, so update_engine writes every block from new.dat (the stock package does the same)."""
    size = os.path.getsize(image)
    blocks = (size + blocksize - 1) // blocksize
    padded = blocks * blocksize
    lines = ["1", "%d %d" % (blocksize, blocks), "flash 0 %d" % blocks]
    return "\n".join(lines) + "\n", padded


def op_list(info, sizes):
    """The lp commands, in the order AOSP's own releasetools emits them: clear everything, recreate
    the group, add the partitions, then resize them.

    misc_info.txt has no per-partition size (only `use_dynamic_partition_size=true`), so the resize
    values are the built images' sizes rounded up to the block size - which is exactly what
    add_img_to_target_files puts in its own dynamic_partitions_op_list, and what `resize` needs:
    update_engine requires a multiple of the block size. Sizes are the raw images in the product dir,
    not dist's sparse copies, whose headers declare a different total.
    """
    group = info["super_partition_groups"].split()[0]
    group_size = int(info["super_%s_group_size" % group])
    parts = info["super_%s_partition_list" % group].split()
    out = ["# Remove partition scratch", "remove scratch",
           "# Remove all existing dynamic partitions and groups before applying full OTA",
           "remove_all_groups",
           "# Add group %s with maximum size %d" % (group, group_size),
           "add_group %s %d" % (group, group_size)]
    for p in parts:
        out.append("# Add partition %s to group %s" % (p, group))
        out.append("add %s %s" % (p, group))
    for p in parts:
        out.append("# Grow partition %s from 0 to %d" % (p, sizes[p]))
        out.append("resize %s %d" % (p, sizes[p]))
    return out, parts


def main():
    prod, stock, out = sys.argv[1], sys.argv[2], sys.argv[3]
    info = misc_info(prod)
    blocksize = int(info["blocksize"])
    os.makedirs(out, exist_ok=True)

    parts = info["super_%s_partition_list" % info["super_partition_groups"].split()[0]].split()
    print("blocksize=%d ; partitions: %s" % (blocksize, ", ".join(parts)))

    # Block-aligned sizes of the raw images, before anything is compressed.
    sizes = {}
    for p in parts:
        img = os.path.join(prod, "%s.img" % p)
        if not os.path.exists(img):
            raise SystemExit("missing image: %s (run `m dist`/`m superimage`)" % img)
        n = os.path.getsize(img)
        sizes[p] = (n + blocksize - 1) // blocksize * blocksize
        print("  %-10s raw %d B -> resize %d B (%d blocks)" % (p, n, sizes[p], sizes[p] // blocksize))

    lines, _ = op_list(info, sizes)
    with open(os.path.join(out, "dynamic_partitions_op_list"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote dynamic_partitions_op_list (%d lines)" % len(lines))

    for p in parts:
        img = os.path.join(prod, "%s.img" % p)
        if not os.path.exists(img):
            raise SystemExit("missing image: %s" % img)
        tl, padded = transfer_list(img, blocksize)
        with open(os.path.join(out, "%s.transfer.list" % p), "w") as f:
            f.write(tl)
        # new.dat is the concatenation of the new chunks in command order - for one flash command
        # that is the whole image, padded to a block multiple.
        with open(img, "rb") as src, open(os.path.join(out, "%s.new.dat" % p), "wb") as dst:
            data = src.read()
            dst.write(data + b"\0" * (padded - len(data)))
        open(os.path.join(out, "%s.patch.dat" % p), "wb").write(b"")
        print("  %-10s image %d B -> new.dat %d B (padded to %d blocks)" % (p, len(data), padded, padded // blocksize))

    boot = os.path.join(prod, "boot.img")
    if not os.path.exists(boot):
        raise SystemExit("missing boot.img - run `m bootimage`")
    # The stock package keeps uboot/trust/dtbo/RKLoader; we ship them byte-identical but do NOT write
    # them (docs/flash.md: the mainboard's MCU firmware path is only reachable through the stock
    # recovery's own loader step, and we do not touch recovery either).
    for f in ("boot.img", "uboot.img", "trust.img", "dtbo.img", "RKLoader.bin"):
        src = boot if f == "boot.img" else os.path.join(stock, f)
        if not os.path.exists(src):
            raise SystemExit("missing %s (stock package expected at %s)" % (f, stock))
        subprocess.run(["cp", "-a", src, os.path.join(out, f)], check=True)
        print("  copied %-12s %d B" % (f, os.path.getsize(os.path.join(out, f))))

    # new.dat is padded to the same aligned size the op list resizes to, so they must agree.
    for p in parts:
        n = os.path.getsize(os.path.join(out, "%s.new.dat" % p))
        if n != sizes[p]:
            raise SystemExit("%s.new.dat is %d B but the op list resizes %s to %d B" % (p, n, p, sizes[p]))
    group = info["super_partition_groups"].split()[0]
    total = sum(sizes.values())
    print("logical content %d B of group %s=%d B ; spare %d B" %
          (total, group, int(info["super_%s_group_size" % group]),
           int(info["super_%s_group_size" % group]) - total))
    if total > int(info["super_%s_group_size" % group]):
        raise SystemExit("logical images exceed the dynamic group - shrink them or resize super (D8)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
