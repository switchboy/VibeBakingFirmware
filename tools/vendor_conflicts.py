#!/usr/bin/env python3
"""List vendor staging destinations that collide with a file the build installs itself.

  tools/vendor_conflicts.py <lineage-tree> [<device-dir>]

PRODUCT_COPY_FILES turns each `src:dest` pair into a Make install rule for $(PRODUCT_OUT)/<dest>.
If a module (Soong or legacy Make) installs the same path, ckati aborts on the first one:

  build/make/core/Makefile:161: error: overriding commands for target
  `out/target/product/rk3399/vendor/bin/applypatch', previously defined at
  out/soong/installs-lineage_rk3399.mk:83800

Duplicate *copy* pairs are silently ignored (Makefile:159 dedups copy pairs against copy pairs
only), so a copy that collides with a module is not deduped - it is a hard parse error, ~20 min
into a build. This tool checks the copy list against the install targets Soong generated for the
current product, so the whole list is reported in seconds.

For every collision it also names the module that installs the path, which decides the fix:

  build wins   the install target comes from upstream AOSP source (art/, bionic/, bootable/,
               build/, external/, frameworks/, hardware/, packages/, prebuilts/, system/) - the
               stock vendor ships the same component (toybox/sh/awk, libchrome, libdrm, libusb,
               the AOSP default HAL services and their default impls, generated sepolicy), just
               compiled for Android 14 -> drop the staged blob. --write-drop-list records these
               so gen_vendor_staging.py regenerates the copy list without them.
  blob wins    the install target comes from vendor/ or a device tree, which would shadow a
               Rockchip blob -> keep the blob and take the competing module out of
               PRODUCT_PACKAGES. Dropping a head-unit HAL silently replaces Rockchip's audio
               routing / GPS / composer behaviour with an AOSP default; on this partition every
               Rockchip HAL has its own name (hwcomposer.rk30board.so, audio.primary.rk30board.so,
               camera.rk30board.so, gps.default.so, allocator/mapper -impl-midgard, mfi.default.so,
               hw_output.default.so, rockchip.hardware.outputmanager@1.0-impl.so), so none collide
               and none of this happens.

Source of install targets:
  out/soong/installs-<product>.mk   the install rules Soong defines for this product's modules

The previous build's staging directory is deliberately *not* an oracle: it holds the blobs that an
earlier pass copied, so every staged path would look "installed by the build" and attribution is
impossible. Legacy Make modules install paths too, but nothing enumerates them statically; ckati
reports them one at a time and scripts/package.sh records each in vendor_dest_skip_extra.txt.

Note that Soong's file lists rules for modules this product never pulls in - a rule is not proof the
file lands in the image. tools/vendor_dropped_check.py is the post-build check for that.

Exit status is 1 when there are collisions; the caller decides what to do with them.
"""
import argparse
import os
import re
import sys

DEST_PREFIX = "$(TARGET_COPY_OUT_VENDOR)/"
# Soong variant names: android_arm64_armv8-a, android_vendor_arm_armv8-a_shared_cfi, ...
VARIANT = re.compile(r"^android(_|-)[a-z0-9_-]*$")
# Where to look for "who puts this module in PRODUCT_PACKAGES".
PRODUCT_MK_DIRS = ("device/rockchip/rk3399", "vendor/lineage/config", "vendor/lineage/build",
                   "build/make/core", "vendor/lineage/overlay")
# A module built from upstream AOSP source is the same component as the stock vendor's copy of it,
# just compiled for Android 14 - so the build's file wins and the blob is dropped. Anything coming
# from vendor/ or a device tree would shadow a Rockchip blob instead, and needs the opposite fix.
UPSTREAM_PREFIXES = ("art/", "bionic/", "bootable/", "build/", "device/generic/", "external/",
                     "frameworks/", "hardware/", "kernel/", "libcore/", "packages/", "prebuilts/",
                     "system/", "tools/")


def staging_destinations(device_dir):
    """Destination paths (partition-relative) carried by the generated vendor_staging.mk."""
    mk = os.path.join(device_dir, "vendor_staging.mk")
    if not os.path.isfile(mk):
        raise SystemExit("no vendor_staging.mk in %s (run scripts/prebuilt_vendor.sh first)" % device_dir)
    dests = []
    for line in open(mk, errors="replace"):
        # Each entry is `src:$(TARGET_COPY_OUT_VENDOR)/dest \` - strip the continuation and any
        # whitespace left behind it, or the destination ends in a space and never matches.
        line = line.strip().rstrip("\\").strip()
        if not line.startswith("vendor/") or ":" not in line:
            continue
        dest = line.rsplit(":", 1)[1].strip()
        if dest.startswith(DEST_PREFIX):
            dests.append(dest[len(DEST_PREFIX):])
    return dests


def install_targets(tree):
    """dest path -> (module name, module source dir, where the rule came from)."""
    out = os.path.join(tree, "out")
    targets = {}
    for dirpath, _dirnames, filenames in os.walk(out):
        for name in filenames:
            if not (name.startswith("installs-") and name.endswith(".mk")):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, errors="replace") as f:
                    for line in f:
                        m = re.match(r"^(out/target/product/[^/]+/vendor/[^ :]+): ?(.*)$", line)
                        if not m:
                            continue
                        dest, deps = m.group(1), m.group(2)
                        mod, src = "?", "?"
                        first = deps.split()[0] if deps else ""
                        if first.startswith("out/soong/.intermediates/"):
                            # <module dir>/<module name>/<variant>/<hash?>/<file>. The variant is the
                            # segment matching `android_*`, so the module name is the segment before
                            # it and the module dir is everything before that. Counting from the end
                            # is wrong: shared libraries carry an extra hash directory, and binaries
                            # name their output file like the module.
                            parts = first[len("out/soong/.intermediates/"):].split("/")
                            for i, seg in enumerate(parts):
                                if VARIANT.match(seg) and i >= 1:
                                    src, mod = "/".join(parts[:i - 1]), parts[i - 1]
                                    break
                            else:
                                if len(parts) >= 3:
                                    src, mod = "/".join(parts[:-3]), parts[-3]
                        targets[dest] = (mod, src, os.path.relpath(path, tree))
            except OSError:
                continue
    return targets


def product_lists(tree):
    """module name -> the makefiles that mention it, for the PRODUCT_MK_DIRS above."""
    mentions = {}
    for d in PRODUCT_MK_DIRS:
        root = os.path.join(tree, d)
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".mk") or name in ("vendor_staging.mk", "vendor_props.mk"):
                    continue   # the generated copy list mentions every blob name; it is not a package list
                path = os.path.join(dirpath, name)
                try:
                    text = open(path, errors="replace").read()
                except OSError:
                    continue
                for mod in re.findall(r"[A-Za-z0-9_.-]+", text):
                    mentions.setdefault(mod, set()).add(os.path.relpath(path, tree))
    return mentions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree")
    ap.add_argument("device_dir", nargs="?")
    ap.add_argument("--write-drop-list",
                    help="write the destinations to drop from the copy list (build wins) here, "
                         "so tools/gen_vendor_staging.py --dest-skip can regenerate without them")
    ap.add_argument("--keep-file",
                    help="paths that must stay staged even though a module defines a rule for them: "
                         "Android 14 installs that file into /system, not /vendor (no VNDK), so there "
                         "is no Make collision and a vendor HAL would lose its library. Written from a "
                         "real build by tools/vendor_dropped_check.py --write-keep-list")
    args = ap.parse_args()

    tree = args.tree
    device_dir = args.device_dir or os.path.join(tree, "device", "rockchip", "rk3399")
    dests = staging_destinations(device_dir)
    targets = install_targets(tree)
    mentions = product_lists(tree) if os.path.isdir(os.path.join(tree, "vendor")) else {}

    keep = set()
    if args.keep_file and os.path.exists(args.keep_file):
        keep = {line.split("#", 1)[0].strip() for line in open(args.keep_file, errors="replace")
                if line.strip() and not line.strip().startswith("#")}
    collisions = []
    kept = []
    for rel in sorted(dests):
        hit = [dest for dest, (_mod, _src, _where) in targets.items() if dest.endswith("/vendor/" + rel)]
        if not hit:
            continue
        # A rule for /vendor/<rel> does not mean the product installs it there: Android 14 may build
        # the same library for /system only. Those paths stay staged (no collision, needed library).
        if rel in keep:
            kept.append((rel, hit[0]))
            continue
        for dest, (mod, src, where) in targets.items():
            if dest.endswith("/vendor/" + rel):
                collisions.append((rel, mod, src, where))

    print("staged destinations: %d ; build install targets under /vendor: %d ; kept despite a rule: %d"
          % (len(dests), len(targets), len(kept)))
    if kept:
        print("  kept as vendor blobs (Android 14 installs them into /system):")
        for rel, dest in sorted(kept)[:12]:
            print("     %-52s (rule exists as %s)" % (rel, dest.split("/vendor/")[-1]))
        if len(kept) > 12:
            print("     ... %d more" % (len(kept) - 12))
    if not collisions:
        print("no collisions - the copy list can be parsed")
        if args.write_drop_list:
            open(args.write_drop_list, "w").write("")
        return 0

    # The build's own module wins when it is compiled from upstream AOSP source: the stock vendor
    # ships the same component (toybox, mksh, libchrome, libdrm, the AOSP default HAL services and
    # their default impls, generated sepolicy), just built for Android 14. Only a module built from
    # vendor/ or a device tree could shadow a Rockchip blob, and that needs PRODUCT_PACKAGES instead.
    service_collisions = {os.path.basename(c[0]): c for c in collisions if c[0].startswith("bin/hw/")}
    blob_wins, build_wins = [], []
    for c in collisions:
        rel, mod, src, where = c
        if src == "?":
            # Generated install rules (init .rc, VINTF fragments). They come from a Soong module;
            # if the matching HAL service binary is upstream, the rc is AOSP's too.
            stem = os.path.basename(rel)[:-3] if rel.endswith(".rc") else os.path.basename(rel)
            peer = service_collisions.get(stem)
            if peer and peer[2] != "?" and not peer[2].startswith(UPSTREAM_PREFIXES):
                blob_wins.append(c)
            else:
                build_wins.append(c)
        elif src.startswith(UPSTREAM_PREFIXES):
            build_wins.append(c)
        else:
            blob_wins.append(c)

    print("COLLISIONS: %d  ->  build wins %d (drop the blob), blob must win %d "
          "(keep the blob, remove the module)" % (len(collisions), len(build_wins), len(blob_wins)))

    def dump(title, items):
        print("\n%s (%d)" % (title, len(items)))
        by_src = {}
        for rel, mod, src, where in items:
            by_src.setdefault(src, []).append((rel, mod))
        for src in sorted(by_src):
            print("  from %-32s (%d)" % (src, len(by_src[src])))
            for rel, mod in sorted(by_src[src])[:40]:
                stem = os.path.basename(rel)
                for suffix in (".rc", ".so", ".apk"):
                    if stem.endswith(suffix):
                        stem = stem[:-len(suffix)]
                # The module name usually equals the installed file name; try both.
                who = sorted((mentions.get(mod, set()) | mentions.get(stem, set())))[:3]
                print("     %-52s module=%-34s %s" % (rel, mod, "listed by " + ", ".join(who) if who else ""))

    dump("build wins: drop these staged blobs (Android 14 builds the same component itself)", build_wins)
    if blob_wins:
        dump("blob must win: keep the Rockchip file, remove the competing module from PRODUCT_PACKAGES",
             blob_wins)
    if args.write_drop_list:
        with open(args.write_drop_list, "w") as f:
            f.write("# Destinations the build installs itself (from upstream AOSP source), so the\n"
                    "# staged blob must not also be copied: PRODUCT_COPY_FILES would collide with\n"
                    "# the module's install rule and ckati aborts at Makefile:161.\n"
                    "# Written by tools/vendor_conflicts.py; read by tools/gen_vendor_staging.py.\n")
            for rel, _mod, _src, _where in build_wins:
                f.write("%s\n" % rel)
        print("\nwrote %s (%d destinations to drop)" % (args.write_drop_list, len(build_wins)))
        if blob_wins:
            print("NOT dropped: %d paths need their module removed from PRODUCT_PACKAGES" % len(blob_wins))
    print("\nTake the module names above out of PRODUCT_PACKAGES (device.mk / Lineage config), and\n"
          "drop the build-wins paths from the copy list; otherwise ckati aborts at Makefile:161.")
    return 1 if blob_wins else 0


if __name__ == "__main__":
    sys.exit(main())
