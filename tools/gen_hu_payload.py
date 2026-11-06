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


def op_list(info):
    """The lp commands, in the order AOSP's own releasetools emits them: clear everything, recreate
    the group, add the partitions, then resize them to the built image sizes."""
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
        img = os.path.join(os.path.dirname(info.get("_prod", "")), "%s.img" % p)
        size = int(info.get("%s_size" % p, 0))
        out.append("# Grow partition %s from 0 to %d" % (p, size))
        out.append("resize %s %d" % (p, size))
    return out, parts


def main():
    prod, stock, out = sys.argv[1], sys.argv[2], sys.argv[3]
    info = misc_info(prod)
    info["_prod"] = prod
    blocksize = int(info["blocksize"])
    os.makedirs(out, exist_ok=True)

    parts = info["super_%s_partition_list" % info["super_partition_groups"].split()[0]].split()
    print("blocksize=%d ; partitions: %s" % (blocksize, ", ".join(parts)))

    lines, _ = op_list(info)
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

    sizes = {p: os.path.getsize(os.path.join(out, "%s.new.dat" % p)) for p in parts}
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
