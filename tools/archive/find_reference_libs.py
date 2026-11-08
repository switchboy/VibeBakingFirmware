#!/usr/bin/env python3
"""Where the Android 10/11 copies of the four breaking libraries live, and whether they cover
# ARCHIVED (Nov 9): one-shot investigation of the four breaking libs; answers are in D20/D22/D23.
# Superseded by tools/extract_reference_libs.py + tools/vendor_link_closure.py.
the needs of both the Android 11 blobs and Android 14's own vendor libraries."""
import os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, walk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGES = [REPO + "/analysis/images/assembled/system.img",
          REPO + "/analysis/daisaita_a10/system.img",
          REPO + "/analysis/daisaita_a11/system.img",
          REPO + "/analysis/images/assembled/vendor.img",
          REPO + "/analysis/daisaita_a10/vendor.img",
          REPO + "/analysis/daisaita_a11/vendor.img"]

wanted = ["libui.so", "libdrm.so", "libcrypto.so", "libnl.so", "libsysutils.so",
          "libutils.so", "libbase.so", "libhidlbase.so"]
breaking = {
    "libui.so": ["_ZN7android19GraphicBufferMapper4lockEPK13native_handlejRKNS_4RectEPPvPiS9_",
                 "_ZN7android19GraphicBufferMapper6unlockEPK13native_handle"],
    "libdrm.so": ["drmModeAddFB2_ext"],
    "libcrypto.so": ["sk_dup"],
    "libnl.so": ["nl_send_auto_complete", "nl_cb_alloc", "genl_ctrl_resolve", "nl_socket_add_membership"],
    "libsysutils.so": ["_ZN14SocketListener13startListenerEv", "_ZN12NetlinkEvent9findParamEPKc"],
}


def defs(fp):
    out = subprocess.run(["nm", "-D", "--defined-only", fp], capture_output=True, text=True).stdout
    return {m.split()[-1].split("@")[0] for m in re.findall(r"^\S+ [A-Za-z] (\S+)$", out, re.M)}


tmp = "/tmp/opencode/ref_libs"
os.makedirs(tmp, exist_ok=True)
found = {}
for img in IMAGES:
    if not os.path.isfile(img):
        continue
    tag = os.path.basename(os.path.dirname(img)) + "/" + os.path.basename(img)
    for rel in walk(img, "/", sizes=False, pattern=None, dirs=False):
        base = os.path.basename(rel)
        if base not in wanted:
            continue
        arch = next((p for p in rel.lstrip("/").split("/") if p in ("lib", "lib64")), None)
        if arch is None:
            continue
        out = os.path.join(tmp, tag.replace("/", "_") + "_" + arch + "_" + base)
        try:
            dump_file(img, "/" + rel.lstrip("/"), out)
        except RuntimeError as e:
            print("  ! %s in %s: %s" % (rel, tag, e))
            continue
        syms = defs(out)
        found.setdefault(base, []).append((tag, arch, rel.lstrip("/"), syms, out))

print("extracted copies: %d files" % sum(len(v) for v in found.values()))
for base in wanted:
    print("\n%s" % base)
    for tag, arch, rel, syms, out in sorted(found.get(base, [])):
        need = [s for s in breaking.get(base, []) if s in syms]
        print("   %-24s [%s] %-30s %5d symbols ; breaking symbols present: %d/%d%s"
              % (tag, arch, rel, len(syms), len(need), len(breaking.get(base, [])),
                 "" if len(need) == len(breaking.get(base, [])) else "  missing: "
                 + ", ".join(s for s in breaking.get(base, []) if s not in syms)[:60]))
    if not found.get(base):
        print("   NOT in any reference image")
