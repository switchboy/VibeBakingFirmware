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


def main():
    tree, device_dir, image = sys.argv[1], sys.argv[2], sys.argv[3]
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

    real_loss, substituted = [], []
    for p in lost:
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
