#!/usr/bin/env python3
"""Which native libraries each candidate APK actually names.

An APK reaches a native library in two ways:

* an entry under `lib/<abi>/` inside the zip (or a symlink there, which is what AOSP uses to point an
  app at a library that lives in `/system/lib64`), loaded by the installer into the app's own lib dir;
* `System.loadLibrary("<name>")` in the dex, which for a *system* app is resolved against the system
  library path (`/system/lib` / `/system/lib64`) rather than the app's own directory.

The second one is only visible in the dex's strings, which live in a deflated zip entry, so a plain
`grep` on the apk finds nothing - this reads the zip and scans the decompressed classes*.dex.

  tools/hu_apk_native_libs.py <apps-root> [<name> ...]

Without <name> the candidates are the OEM libraries from the reference payload. Output per apk: the
embedded lib entries, then the library names the dex mentions.
"""
import glob
import re
import sys
import zipfile

DEFAULT_NAMES = [
    "rksoundsetting", "rockcv_java", "rockit", "rockchipxxx", "rockchip_update", "bluelet",
    "brlinktd", "bt_platform", "gocdfu", "gralloc_priv", "rga", "mdnssd", "rttinyxml",
    "rtmem", "rtopus", "ffmpeg", "mtc.mfi", "outputmanager", "speedplay", "zlink", "hidltransport",
    "vibrator", "radio_metadata",
]


def paths(apk: str):
    """Filesystem paths and device nodes the dex mentions - what the app actually touches."""
    z = zipfile.ZipFile(apk)
    rx = re.compile(rb"[ -~]{4,}")
    out = set()
    for entry in z.namelist():
        if not (entry.endswith(".dex") or entry.endswith(".jar")):
            continue
        for s in rx.findall(z.read(entry)):
            t = s.decode(errors="ignore")
            if t.startswith("/") and len(t) < 80 and " " not in t:
                out.add(t)
            elif re.search(r"\b(mtc-[a-z0-9]+|ttyS\d|ttyV\d|goc_serial|bluesoleil|mnt/oem)\b", t):
                out.add(t[:80])
    return sorted(out)


def scan(apk: str, names: list[str]):
    z = zipfile.ZipFile(apk)
    embedded = sorted(n for n in z.namelist() if n.startswith("lib/") and not n.endswith("/"))
    # `System.loadLibrary("rockchip_update_jni")` names the library without the `lib` prefix, so match
    # the whole word with an optional prefix - matching `rga` as a substring hit every "orga"nization.
    rx = re.compile(rb"\b(?:lib)?(" + b"|".join(n.encode() for n in names) + rb")\b")
    hits = set()
    for entry in z.namelist():
        if not (entry.endswith(".dex") or entry.endswith(".jar")):
            continue
        data = z.read(entry)
        for s in re.findall(rb"[ -~]{4,}", data):
            m = rx.search(s)
            if m:
                hits.add(f"{m.group(1).decode()} <- {s.decode(errors='ignore')[:70]}")
    return embedded, sorted(hits)


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit("usage: hu_apk_native_libs.py <apps-root> [--paths] [<library-name> ...]")
    mode_paths = "--paths" in args
    args = [a for a in args if a != "--paths"]
    if not args:
        raise SystemExit("usage: hu_apk_native_libs.py <apps-root> [--paths] [<library-name> ...]")
    root = args[0]
    names = args[1:] if len(args) > 1 else DEFAULT_NAMES
    for apk in sorted(glob.glob(root + "/**/*.apk", recursive=True)):
        if mode_paths:
            print(f"{apk}\t{paths(apk)}")
        else:
            embedded, hits = scan(apk, names)
            print(f"{apk}\tembedded={embedded}\tdex={hits}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
