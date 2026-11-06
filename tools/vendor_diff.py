#!/usr/bin/env python3
"""Check that our *built* vendor image is the stock Android 11 vendor plus only the intended changes.

  tools/vendor_diff.py <stock_vendor.img> <our_vendor.img> <device-dir>

Vendor is no longer a prebuilt blob: scripts/prebuilt_vendor.sh stages the stock partition through
PRODUCT_COPY_FILES so Android 14's OTA packer gets a real VENDOR/ directory. That means the two
images differ on purpose, in exactly these ways:

  dropped            the 178 /vendor/bin toybox aliases (acp dereferences symlinks, so each would
                     become a 489 KB toybox_vendor copy), libOpenCL.so.1/.1.1 aliases, the /odm
                     symlink, default.prop, recovery-from-boot.p, and the three usb_modeswitch.d
                     rules whose names contain '#' (Make cannot express them).
  materialised       libGLES_mali.so and libOpenCL.so in lib/ and lib64/: stock keeps them as
                     aliases to egl/libGLES_mali.so, ours are real copies of that blob, because
                     Android 14's EGL loader looks for libGLES_<ro.hardware.egl>.so.
  replaced           /etc/fstab.rk30board (ours), /build.prop (Android 14 generates it), and
                     /etc/vintf/compatibility_matrix.xml (stock minus the <vendor-ndk> block).
  added              /etc/init/hu.rc, /etc/hu_insmod.sh, /etc/ueventd.rc.

Anything outside those categories is a bug in the staging, so the script lists it and fails.

There is one more category, and it is expected: ~160 destinations are installed by the build's own
modules (vendor_build_wins.txt, written by tools/vendor_conflicts.py) - Android 14 compiles the same
upstream component (toybox, mksh, libchrome, libdrm, the AOSP default HAL services, generated
sepolicy), so those files legitimately differ in size. The script checks they are *present*, which
is what proves the module actually installed them.

debugfs reads both images without root or mounting.
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, walk  # noqa: E402

# Files we copy from the device directory instead of the stock blob.
OVERLAYS = {
    "/etc/fstab.rk30board": "fstab.rk30board",
    "/etc/ueventd.rc": "configs/ueventd.rk30board.rc",
    "/etc/init/hu.rc": "configs/init.hu.rc",
    "/etc/hu_insmod.sh": "configs/hu_insmod.sh",
}

# Intentionally not staged (paths relative to the vendor partition root).
DROPPED = {
    "default.prop",
    "recovery-from-boot.p",
    "odm",
    "etc/usb_modeswitch.d/12d1_#android",
    "etc/usb_modeswitch.d/12d1_#linux",
    "etc/usb_modeswitch.d/19d2_#linux",
    "lib/libOpenCL.so.1",
    "lib/libOpenCL.so.1.1",
    "lib64/libOpenCL.so.1",
    "lib64/libOpenCL.so.1.1",
    "etc/vintf/manifest/",
}

# Aliases that became real copies; the size must equal the blob in egl/.
MATERIALISED = {"lib/libGLES_mali.so", "lib/libOpenCL.so",
                "lib64/libGLES_mali.so", "lib64/libOpenCL.so"}

# Files whose content legitimately differs (generated or rewritten by us).
REPLACED = {"build.prop", "etc/fstab.rk30board", "etc/ueventd.rc",
            "etc/vintf/compatibility_matrix.xml", "etc/vintf/manifest.xml",
            "etc/NOTICE.xml.gz"}


def inventory(image):
    """path -> size for every entry in the image, symlinks included (their size is the target)."""
    inv = {}
    for line in walk(image, "/", sizes=True, pattern=None, dirs=False):
        path, size = line.split("\t", 1)
        inv[path.lstrip("/")] = int(size)
    return inv


def hal_entries(text):
    """Every <hal> block as (name, version, instance-or-fqname), for comparing manifest/matrix sets."""
    out = set()
    for block in re.findall(r"<hal\b.*?</hal>", text, flags=re.S):
        name = re.search(r"<name>(.*?)</name>", block, flags=re.S)
        if not name:
            continue
        version = re.search(r"<version>(.*?)</version>", block, flags=re.S)
        inst = re.search(r"<fqname>(.*?)</fqname>", block, flags=re.S) or \
               re.search(r"<instance>(.*?)</instance>", block, flags=re.S)
        out.add((name.group(1).strip(),
                 version.group(1).strip() if version else "",
                 inst.group(1).strip() if inst else ""))
    return out


def main():
    stock, ours, dev = sys.argv[1], sys.argv[2], sys.argv[3]
    a = inventory(stock)
    b = inventory(ours)

    # Destinations the build installs from its own modules (vendor_build_wins.txt, written by
    # tools/vendor_conflicts.py). Android 14 compiles the same upstream component, so these paths
    # legitimately differ in size/content - but they must still be present in the image.
    build_replaced = set()
    wins = os.path.join(dev, "vendor_build_wins.txt")
    if os.path.exists(wins):
        build_replaced = {line.split("#", 1)[0].strip() for line in open(wins)
                          if line.strip() and not line.strip().startswith("#")}

    # Aliases are symlinks in the stock image; walk() lists them as files whose size is the
    # length of the target string (13 bytes for "toybox_vendor", 19 for "./egl/...").
    alias_bin = {p for p in a if p.startswith("bin/") and a[p] <= 20}
    alias_lib = {p for p in a if p.startswith(("lib/", "lib64/")) and a[p] <= 32}

    only_stock = sorted(set(a) - set(b))
    only_ours = sorted(set(b) - set(a))
    changed = sorted(p for p in set(a) & set(b) if a[p] != b[p])

    print("stock entries: %d ; our entries: %d" % (len(a), len(b)))
    print("only in stock: %d ; only in ours: %d ; size changed: %d" %
          (len(only_stock), len(only_ours), len(changed)))

    unexpected_new = [p for p in only_ours if p not in set(OVERLAYS)]
    unexpected_gone = [p for p in only_stock
                       if p not in alias_bin and p not in alias_lib and p not in DROPPED]

    print("dropped as intended: %d /vendor/bin aliases, %d lib aliases, %d other" %
          (len([p for p in only_stock if p.startswith("bin/")]),
           len([p for p in only_stock if p.startswith(("lib/", "lib64/"))]),
           len([p for p in only_stock if not p.startswith(("bin/", "lib/", "lib64/"))])))

    egl_sizes = {"lib/": a.get("lib/egl/libGLES_mali.so"), "lib64/": a.get("lib64/egl/libGLES_mali.so")}
    print("materialised copies:")
    mat_ok = True
    for p in MATERIALISED:
        if p not in b:
            print("   %-30s MISSING" % p)
            mat_ok = False
            continue
        want = egl_sizes[p.split("/")[0] + "/"]
        ok = b[p] == want
        mat_ok = mat_ok and ok
        print("   %-30s %d B (egl blob %s) correct=%s" % (p, b[p], want, ok))

    print("overlay content check:")
    ov_ok = True
    for in_image, src_rel in OVERLAYS.items():
        src = os.path.join(dev, src_rel)
        tmp = os.path.join(tempfile.mkdtemp(prefix="vendor-diff-"), os.path.basename(in_image))
        dump_file(ours, "/" + in_image, tmp)
        same = open(tmp, "rb").read() == open(src, "rb").read()
        ov_ok = ov_ok and same
        print("   %-28s matches device source: %s" % (in_image, same))

    # The two VINTF files are NOT byte-identical to stock, so compare them by HAL coverage:
    #  - /vendor/etc/vintf/manifest.xml is assembled by assemble_vintf from our DEVICE_MANIFEST_FILE
    #    plus every HAL fragment the build installs, and it gets Android 14's sepolicy version
    #    (BOARD_SEPOLICY_VERS=202404); the stock Android 11 <sepolicy><version>30.0</version> is
    #    dropped on purpose (assemble_vintf refuses to override a declared value).
    #  - /vendor/etc/vintf/compatibility_matrix.xml is the stock matrix with its <vendor-ndk> block
    #    removed (Android 14 has no VNDK).
    # What must hold: every HAL the stock partition declared is still declared here, and neither
    # file mentions VNDK. Extra entries are fine - those are HAL services this build adds.
    tmp = tempfile.mkdtemp(prefix="vendor-vintf-")
    dump_file(ours, "/etc/vintf/manifest.xml", os.path.join(tmp, "ours.xml"))
    dump_file(stock, "/etc/vintf/manifest.xml", os.path.join(tmp, "stock.xml"))
    ours_txt = open(os.path.join(tmp, "ours.xml")).read()
    stock_txt = open(os.path.join(tmp, "stock.xml")).read()
    stock_hal, ours_hal = hal_entries(stock_txt), hal_entries(ours_txt)
    lost = sorted(stock_hal - ours_hal)
    print("   manifest HAL entries: stock=%d ours=%d (extra in ours=%d)" %
          (len(stock_hal), len(ours_hal), len(ours_hal - stock_hal)))
    for h in lost[:12]:
        print("      MISSING from our manifest: %s" % ("@".join(h)))
    sep = re.search(r"<sepolicy>\s*<version>([^<]+)</version>", ours_txt)
    manifest_ok = not lost and "<vendor-ndk>" not in ours_txt and sep and sep.group(1).strip() != "30.0"
    print("   manifest sepolicy version: %s (stock would say 30.0)" % (sep.group(1).strip() if sep else "none"))
    print("   manifest keeps every stock HAL=%s, no vendor-ndk=%s" % (not lost, "<vendor-ndk>" not in ours_txt))

    dump_file(ours, "/etc/vintf/compatibility_matrix.xml", os.path.join(tmp, "ours-matrix.xml"))
    dump_file(stock, "/etc/vintf/compatibility_matrix.xml", os.path.join(tmp, "stock-matrix.xml"))
    ours_mat_txt = open(os.path.join(tmp, "ours-matrix.xml")).read()
    stock_mat_txt = open(os.path.join(tmp, "stock-matrix.xml")).read()
    stock_m, ours_m = hal_entries(stock_mat_txt), hal_entries(ours_mat_txt)
    lost_m = sorted(stock_m - ours_m)
    print("   matrix HAL entries: stock=%d ours=%d ; stock entries missing=%d" %
          (len(stock_m), len(ours_m), len(lost_m)))
    for h in lost_m[:12]:
        print("      MISSING from our matrix: %s" % ("@".join(h)))
    matrix_ok = not lost_m and "<vendor-ndk>" not in ours_mat_txt
    print("   matrix vendor-ndk: stock=%s, ours=%s" % ("<vendor-ndk>" in stock_mat_txt,
                                                      "<vendor-ndk>" in ours_mat_txt))

    unexpected_changed = [p for p in changed if p not in REPLACED and p not in MATERIALISED
                          and p not in build_replaced]
    replaced_missing = sorted(p for p in build_replaced if p not in b)
    print("build-installed paths (%d): present=%d, missing=%d" %
          (len(build_replaced), len(build_replaced) - len(replaced_missing), len(replaced_missing)))
    for p in replaced_missing[:15]:
        print("   MISSING although a module should install it: %s" % p)

    print("unexpected differences:")
    for group, items in (("added", unexpected_new), ("missing", unexpected_gone),
                         ("size changed", unexpected_changed)):
        for p in items[:15]:
            print("   %s: %s" % (group, p))
        if not items:
            print("   %s: none" % group)

    verdict = (mat_ok and ov_ok and manifest_ok and matrix_ok
               and not unexpected_new and not unexpected_gone
               and not unexpected_changed and not replaced_missing)
    print("VERDICT: stock blobs carried over, only the intended changes = %s" % verdict)
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
