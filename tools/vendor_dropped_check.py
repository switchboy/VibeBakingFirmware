#!/usr/bin/env python3
"""Prove that every destination dropped from the vendor copy list is really replaced.

  tools/vendor_dropped_check.py <lineage-tree> <device-dir> <built-vendor.img>

`tools/vendor_conflicts.py` drops a staged blob when a *module* installs the same path, because
PRODUCT_COPY_FILES would collide with the module's install rule. That is only safe if the module is
actually in the product's install closure and lands in the image. Soong's install list contains
rules for modules this product never installs (Android 14 ships AIDL HAL services instead of the
HIDL ones the stock Android 11 vendor carried), so a drop can silently delete a head-unit HAL
service that nothing replaces: audio, camera provider, GNSS, sensors, composer, health, memtrack,
CAS, the OMX service, vndservicemanager.

Three inputs are cross-checked:
  1. the drop list            device-dir/vendor_build_wins.txt
  2. what the build installed out/soong/installs-*.mk + the built image inventory
  3. device-dir/vendor_dest_deviations.txt - paths deliberately not restored (no cellular modem),
     which are reported but never fail the check.

A replacement must be a *same-kind* file: a service in bin/hw is only replaced by another service
in bin/hw, a 64-bit lib only by a 64-bit lib. Matching android.hardware.bluetooth@1.0-service
against etc/permissions/android.hardware.bluetooth.xml, or lib64/libwifi-hal.so against
lib/libwifi-hal.so, is not a replacement - that is what the first version of this tool wrongly
accepted.

Exit status is non-zero when something is lost with no replacement and no declared deviation.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import walk  # noqa: E402


def drop_list(device_dir):
    path = os.path.join(device_dir, "vendor_build_wins.txt")
    if not os.path.isfile(path):
        raise SystemExit("no vendor_build_wins.txt in %s (run scripts/prebuilt_vendor.sh)" % device_dir)
    return {line.split("#", 1)[0].strip() for line in open(path)
            if line.strip() and not line.strip().startswith("#")}


def deviations(device_dir):
    """Paths we knowingly do not restore, with the reason from the file's comments."""
    path = os.path.join(device_dir, "vendor_dest_deviations.txt")
    if not os.path.isfile(path):
        return {}
    reason, out = "", {}
    for line in open(path):
        s = line.strip()
        if s.startswith("#"):
            reason = s.lstrip("# ").strip()
            continue
        if s:
            out[s] = reason
    return out


def installed_paths(tree, image):
    """Every /vendor path Soong has an install rule for, plus every path in the built image."""
    paths = set()
    for dirpath, _dirs, files in os.walk(os.path.join(tree, "out")):
        for name in files:
            if not (name.startswith("installs-") and name.endswith(".mk")):
                continue
            try:
                with open(os.path.join(dirpath, name), errors="replace") as f:
                    for line in f:
                        m = re.match(r"^out/target/product/[^/]+/vendor/([^ :]+):", line)
                        if m:
                            paths.add(m.group(1))
            except OSError:
                continue
    in_image = {line.split("\t", 1)[0].lstrip("/") for line in walk(image, "/", sizes=False,
                                                                  pattern=None, dirs=False)}
    return paths, in_image


def stem(rel):
    """Interface/service name without version or trailing -service/-impl/-impl-<flavour>."""
    base = os.path.basename(rel)
    base = re.sub(r"\.so$|\.rc$|\.apk$|\.xml$", "", base)
    base = re.sub(r"@[0-9.]+", "", base)
    base = re.sub(r"-service$|-impl.*$", "", base)
    return base


def kind(rel):
    """What sort of file this is, so a replacement can only be a peer of the same kind."""
    d = os.path.dirname(rel)
    base = os.path.basename(rel)
    if d == "bin/hw":
        return "hw-service"
    if d == "bin":
        return "bin"
    if d in ("lib", "lib64"):
        return "lib-" + os.path.basename(rel)          # exact file name must match across arches
    if d in ("lib/hw", "lib64/hw"):
        return "hw-impl-" + stem(rel)                  # same interface, same arch directory class
    if d == "lib/mediadrm" or d.startswith("lib/mediacas"):
        return "media-" + os.path.basename(rel)
    if d.endswith("soundfx"):
        return "soundfx-" + os.path.basename(rel)
    return "file-" + rel                               # anything else: only the identical path counts


def other_partitions(prod):
    """Every file name the build installed outside /vendor, mapped to its partition. Android 14
    dropped the VNDK, so libchrome/libdrm/libvpx/... are built for /system only: a vendor HAL that
    links one of them cannot load it, so the staged vendor copy has to stay."""
    out = {}
    for part in ("system", "system_ext", "product", "odm"):
        root = os.path.join(prod, part)
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                out.setdefault(name, set()).add(part)
    return out


def main():
    tree, device_dir, image = sys.argv[1], sys.argv[2], sys.argv[3]
    prod = os.path.join(tree, "out", "target", "product")
    dev_prod = os.path.join(prod, os.listdir(prod)[0]) if os.path.isdir(prod) else ""
    moved = other_partitions(dev_prod) if dev_prod else {}
    keep_out = None
    if "--write-keep-list" in sys.argv:
        keep_out = sys.argv[sys.argv.index("--write-keep-list") + 1]
        sys.argv = [a for i, a in enumerate(sys.argv) if i not in (sys.argv.index("--write-keep-list"),
                                                                   sys.argv.index("--write-keep-list") + 1)]
    dropped = drop_list(device_dir)
    accepted = deviations(device_dir)
    rules, in_image = installed_paths(tree, image)

    replaced = sorted(p for p in dropped if p in in_image)
    lost = sorted(p for p in dropped if p not in in_image)
    excused = sorted(p for p in lost if p in accepted)
    lost = [p for p in lost if p not in accepted]

    print("dropped destinations: %d ; present in the built image: %d ; absent: %d "
          "(declared deviations: %d)" % (len(dropped), len(replaced), len(lost) + len(excused), len(excused)))

    # Only a peer of the same kind counts: bin/hw <-> bin/hw, lib64/hw <-> lib64/hw, and for plain
    # libraries the same file name in the same 32/64-bit directory.
    by_kind = {}
    for p in in_image:
        by_kind.setdefault(kind(p), []).append(p)

    real_loss, substituted, shifted = [], [], []
    for p in lost:
        parts = moved.get(os.path.basename(p))
        if parts:
            # The build installed the same file name into /system or /product, not /vendor. The
            # vendor copy is gone and a vendor process cannot read those partitions: keep the blob.
            shifted.append((p, sorted(parts)))
            real_loss.append((p, "moved to /%s by Android 14 (no VNDK) - keep the staged vendor blob"
                              % "/, /".join(sorted(parts))))
            continue
        alts = [q for q in by_kind.get(kind(p), []) if q != p]
        if alts:
            substituted.append((p, alts))
        elif p in rules:
            real_loss.append((p, "soong defines an install rule, but the module is not in this "
                                 "product's install closure (add it to PRODUCT_PACKAGES)"))
        else:
            real_loss.append((p, "no module installs this path at all"))

    if substituted:
        print("substituted by another provider of the same interface (%d):" % len(substituted))
        for p, alts in sorted(substituted):
            print("   %-52s -> %s" % (p, ", ".join(sorted(alts)[:4])))

    if excused:
        print("declared deviations, not restored (%d):" % len(excused))
        for p in excused:
            print("   %-52s %s" % (p, accepted[p][:70]))

    if shifted:
        print("installed OUTSIDE /vendor by Android 14 (%d) - a vendor HAL cannot load these:" % len(shifted))
        for p, parts in sorted(shifted):
            print("   %-52s -> /%s" % (p, ", /".join(parts)))
        if keep_out:
            header = (
                '# Destinations Android 14 installs into /system (or /product) instead of /vendor.\n'
                '# Android 14 has no VNDK, so the vendor copy of these libraries is not built, and\n'
                '# a vendor process cannot read /system: the HAL keeps its staged vendor copy.\n'
                '# tools/vendor_dropped_check.py writes this from a real build;\n'
                '# scripts/prebuilt_vendor.sh feeds it back so these blobs are never dropped again.\n'
            )
            with open(keep_out, "w") as f:
                f.writelines(header)
                for p, _parts in sorted(shifted):
                    f.write("%s\n" % p)
            print("wrote %s (%d destinations to keep as blobs)" % (keep_out, len(shifted)))

    if real_loss:
        print("LOST with no replacement (%d) - the vendor partition would lack these:" % len(real_loss))
        for p, why in sorted(real_loss):
            print("   %-52s %s" % (p, why))
        print("\nFix: add the Android 14 module that installs the path to PRODUCT_PACKAGES "
              "(tools/vendor_module_names.py names it), or keep the blob staged by removing the "
              "path from vendor_build_wins.txt. Declare an intentional gap in "
              "vendor_dest_deviations.txt. Dropping a HAL service silently removes the feature.")
        return 1

    print("every dropped destination is present, substituted, or declared as a deviation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
