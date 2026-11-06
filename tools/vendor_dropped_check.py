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
in bin/hw, a 64-bit lib only by a 64-bit lib. Destinations Android 14 builds for /system instead of
/vendor are listed separately and written to `--write-keep-list <file>` for
scripts/inject_vendor_blobs.sh; if one of them is missing from the image the check fails, because a
vendor process cannot read /system. Matching android.hardware.bluetooth@1.0-service
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


def vendor_installed(tree):
    """The /vendor paths the build's install rules produce (installed-files-vendor.txt). Injected
    blobs are not listed there, so this stays the oracle for "the build installs it in /vendor by
    itself" even after scripts/inject_vendor_blobs.sh put the blob in the image."""
    out = set()
    prod = os.path.join(tree, "out", "target", "product")
    if not os.path.isdir(prod):
        return out
    for device in os.listdir(prod):
        for root, _dirs, files in os.walk(os.path.join(prod, device)):
            if os.path.dirname(root) != prod:
                continue                       # only the device dir itself, not subdirs
            for name in files:
                if name.startswith("installed-files-vendor"):
                    for line in open(os.path.join(root, name), errors="replace"):
                        m = re.search(r"/vendor/(\S+)$", line.strip())
                        if m:
                            out.add(m.group(1))
    return out


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
    built_in_vendor = vendor_installed(tree)
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

    # Android 14 has no VNDK: libchrome/libdrm/libvpx/libopus/libstagefright_*/libvorbisidec/
    # libhwbinder/libkeymaster4support are built for /system only, while Soong still defines an
    # install rule for the /vendor path. So the blob cannot be copied (ckati: "overriding
    # commands") and nothing lands in /vendor, and a vendor process cannot read /system. Those
    # destinations are listed in vendor_dest_keep.txt and written into the vendor staging
    # directory by scripts/inject_vendor_blobs.sh.
    #
    # Derived from the drop list + the non-vendor inventory, not from what is missing: after the
    # injection the paths *are* in the image, and the list must still be regenerable.
    # Only paths the build does NOT install in /vendor need injecting. liblog/libeffectsconfig/...
    # exist in both /system and /vendor: their name is in /system, but the vendor variant is built,
    # so they must not end up in vendor_dest_keep.txt.
    shifted = sorted((p, sorted(moved[os.path.basename(p)])) for p in dropped
                     if os.path.basename(p) in moved and p not in built_in_vendor)
    if keep_out:
        header = (
            '# Vendor destinations Android 14 installs into /system (or /product) instead of /vendor.\n'
            '# Android 14 has no VNDK, so no vendor variant is installed, but Soong still defines an\n'
            '# install rule for the /vendor path: PRODUCT_COPY_FILES may not copy the stock blob\n'
            '# there (ckati says "overriding commands"), and a vendor process cannot read /system.\n'
            '# scripts/inject_vendor_blobs.sh writes these from the staged tree into the vendor\n'
            '# staging directory after the install rules have run. Regenerate after every build:\n'
            '#   tools/vendor_dropped_check.py <tree> <device-dir> <vendor.img> --write-keep-list <this file>\n'
        )
        with open(keep_out, "w") as f:
            f.writelines(header)
            for p, _parts in shifted:
                f.write("%s\n" % p)
        print("wrote %s (%d destinations to inject into /vendor)" % (keep_out, len(shifted)))

    real_loss, substituted = [], []
    for p in lost:
        if p not in built_in_vendor and os.path.basename(p) in moved:
            real_loss.append((p, "Android 14 builds this for /%s only (no VNDK) - "
                              "scripts/inject_vendor_blobs.sh did not put it in /vendor"
                              % "/, /".join(sorted(moved[os.path.basename(p)]))))
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
        print("built OUTSIDE /vendor by Android 14 (%d) - injected by scripts/inject_vendor_blobs.sh:" % len(shifted))
        for p, parts in shifted:
            print("   %-52s -> /%s" % (p, ", /".join(parts)))

    if real_loss:
        print("LOST with no replacement (%d) - the vendor partition would lack these:" % len(real_loss))
        for p, why in sorted(real_loss):
            print("   %-52s %s" % (p, why))
        print("\nFix: add the Android 14 module that installs the path to PRODUCT_PACKAGES "
              "(tools/vendor_module_names.py names it); for a library Android 14 builds for /system "
              "only, run scripts/inject_vendor_blobs.sh (vendor_dest_keep.txt names it); declare an "
              "intentional gap in vendor_dest_deviations.txt. Dropping a HAL service silently "
              "removes the feature.")
        return 1

    print("every dropped destination is present, substituted, or declared as a deviation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
