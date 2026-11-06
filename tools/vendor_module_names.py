#!/usr/bin/env python3
"""For every dropped vendor destination that is NOT in the built image, name the module that would
install it, so device.mk's PRODUCT_PACKAGES can be written from real module names.

  tools/vendor_module_names.py <lineage-tree> <device-dir> <built-vendor.img>

Soong's `installs-<product>.mk` holds install *rules* for modules this product never pulls in, so
PRODUCT_COPY_FILES refuses the path (Make would define two rules for one target) while the module
also never installs it - the file ends up missing. Adding the module to PRODUCT_PACKAGES installs
Android 14's own build of it.

The module name is read from the rule's dependency path, which is
`out/soong/.intermediates/<module dir>/<module name>/<variant>/<hash?>/<file>`. The variant is the
segment matching `android_*`, so the module name is the segment before it; counting from the end is
wrong for shared libraries (their path has an extra hash directory) and for binaries whose output
file is named like the module. Paths with no Soong rule at all are legacy Make installs, which only
ckati reports.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import walk  # noqa: E402
from vendor_dropped_check import deviations, drop_list, kind  # noqa: E402

VARIANT = re.compile(r"^android(_|-)[a-z0-9_-]*$")


def soong_rules(tree):
    """dest -> module name, from every out/soong/installs-*.mk in the tree."""
    owners = {}
    for dirpath, _dirs, files in os.walk(os.path.join(tree, "out")):
        for name in files:
            if not (name.startswith("installs-") and name.endswith(".mk")):
                continue
            with open(os.path.join(dirpath, name), errors="replace") as f:
                for line in f:
                    m = re.match(r"^out/target/product/[^/]+/vendor/([^ :]+):\s*(.*)$", line)
                    if not m:
                        continue
                    dest, deps = m.group(1), m.group(2)
                    for tok in deps.split():
                        if not tok.startswith("out/soong/.intermediates/"):
                            continue
                        parts = tok[len("out/soong/.intermediates/"):].split("/")
                        for i, seg in enumerate(parts):
                            if VARIANT.match(seg) and i >= 1:
                                owners[dest] = parts[i - 1]
                                break
                        else:
                            if len(parts) >= 3:
                                owners.setdefault(dest, parts[-3])
                        break
    return owners


def main():
    tree, device_dir, image = sys.argv[1], sys.argv[2], sys.argv[3]
    dropped = drop_list(device_dir)
    accepted = deviations(device_dir)
    owners = soong_rules(tree)
    in_image = {line.split("\t", 1)[0].lstrip("/")
                for line in walk(image, "/", sizes=False, pattern=None, dirs=False)}

    need = sorted(p for p in dropped if p not in in_image and p not in accepted)
    excused = sorted(p for p in dropped if p not in in_image and p in accepted)
    print("paths to restore via PRODUCT_PACKAGES: %d ; declared deviations: %d" % (len(need), len(excused)))

    by_module = {}
    for p in need:
        by_module.setdefault(owners.get(p, "none"), []).append(p)
    for mod in sorted(by_module):
        paths = by_module[mod]
        tag = "" if mod != "none" else "  [no Soong rule: legacy Make install, revealed by ckati]"
        print("module=%-46s%s" % (mod, tag))
        for p in sorted(paths):
            print("    %-56s kind=%s" % (p, kind(p)))

    if excused:
        print("\ndeclared deviations (intentionally not restored):")
        for p in excused:
            print("    %-56s %s" % (p, accepted[p][:64]))
    print("\nPRODUCT_PACKAGES candidates (%d modules):" % len([m for m in by_module if m != "none"]))
    print("    " + " ".join(sorted(m for m in by_module if m != "none")))


if __name__ == "__main__":
    main()
