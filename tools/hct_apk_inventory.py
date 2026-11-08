#!/usr/bin/env python3
"""Inventory prebuilt APKs: package name, sharedUserId, target SDK, requested permissions.

Two things need to be answered before the HCT/Microntek apps from the reference payload can be
staged into the Android 14 build:

1. *Package collisions*: an HCT apk must not be installed when Lineage 21 already installs the same
   package name (two installed packages with one name = one wins, the other is never installed, and
   PackageManager reports a duplicate). So the apk's real package name is read out of the binary
   AndroidManifest.xml, not from the directory name: `HCTSettings10` ships package `com.android.settings`.
2. *Signing*: an apk that declares `android:sharedUserId` (above all `android.uid.system`) is only
   accepted by PackageManager when it is signed with the same certificate as the platform. A signed
   with the wrong key is refused outright (`SIGNATURE_FAILED`), so these need the platform key, and
   apps that trust each other through signature permissions need the same key too.

The manifest is read with AAPT2 (`aapt2 dump xmltree --file AndroidManifest.xml`), which decodes the
binary XML - the repo has no AXML parser and this keeps the evidence reproducible on the build host.

  hct_apk_inventory.py --aapt2 <path> <root>...           one inventory per root
  hct_apk_inventory.py --aapt2 <path> --collision A B     packages in A vs packages in B

Output is one line per apk: <root>/<path>\t<package>\t<sharedUserId>\t<sdk>\t<size>\t<sha256>\t<perms>
"""
import hashlib
import re
import subprocess
import sys
from pathlib import Path

# AAPT2 prints attributes as `A: <namespace>:<name>(0x...)=<value> (Raw: "<value>")`.
# Namespace-less attributes (`package=`) must match too.
ATTR = re.compile(r'^\s*A:\s+(?:\S+[:.])?(?P<name>[\w.]+)(?:\([^)]*\))?=(?P<value>.*)$')
VALUE = re.compile(r'"(?P<quoted>[^"]*)"|(?P<plain>\d+)')
PERM = re.compile(r'^\s*E:\s+(?P<kind>uses-permission|permission)\b')


def attr_value(raw: str) -> str:
    """`"android.uid.system" (Raw: "android.uid.system")` -> `android.uid.system`."""
    m = VALUE.match(raw.strip())
    if m:
        return m.group("quoted") or m.group("plain")
    return raw.strip()


def xmltree(aapt2: str, apk: Path) -> list[str]:
    res = subprocess.run([aapt2, "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"{apk}: aapt2 failed: {res.stderr.strip()}")
    return res.stdout.splitlines()


def inventory(aapt2: str, root: Path) -> list[dict]:
    rows = []
    for apk in sorted(root.rglob("*.apk")):
        lines = xmltree(aapt2, apk)
        package = None
        shared = ""
        sdk = ""
        perms: list[str] = []
        in_perm = False
        for line in lines:
            m = ATTR.match(line)
            if m:
                val = attr_value(m.group("value"))
                name = m.group("name")
                if name == "sharedUserId":
                    shared = val
                elif name == "targetSdkVersion":
                    sdk = val
                if in_perm and name == "name":
                    perms.append(val)
                    in_perm = False
            e = PERM.match(line)
            if e:
                in_perm = True
        # The manifest's `package` attribute sits on the <manifest> element, without a namespace.
        for line in lines:
            m = ATTR.match(line)
            if m and m.group("name") == "package":
                package = attr_value(m.group("value"))
                break
        data = apk.read_bytes()
        rows.append({
            "path": str(apk.relative_to(root)),
            "package": package or "?",
            "sharedUserId": shared,
            "sdk": sdk,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "perms": sorted(set(perms)),
        })
    return rows


def print_inventory(aapt2: str, root: Path) -> list[dict]:
    rows = inventory(aapt2, root)
    for r in rows:
        print(f"{r['path']}\t{r['package']}\t{r['sharedUserId'] or '-'}\t{r['sdk']}\t"
              f"{r['size']}\t{r['sha256'][:16]}\t{len(r['perms'])}")
    return rows


def print_permissions(aapt2: str, root: Path) -> list[dict]:
    """The permission names themselves - what a privapp whitelist has to grant."""
    rows = inventory(aapt2, root)
    for r in rows:
        print(f"{r['path']}\t{r['package']}\t{r['sharedUserId'] or '-'}\t" +
              ",".join(r["perms"]))
    return rows


def collision(aapt2: str, ours: list[Path], theirs: Path) -> int:
    """Packages installed by <ours> (Lineage, may be several staging roots) vs the candidate
    apks in <theirs> (reference payload)."""
    our_pkgs = {}
    for root in ours:
        if root.is_dir():
            for r in inventory(aapt2, root):
                our_pkgs.setdefault(r["package"], f"{root}:{r['path']}")
    rows = inventory(aapt2, theirs)
    hits = 0
    for r in rows:
        if r["package"] in our_pkgs:
            hits += 1
            print(f"COLLISION  {r['package']}  candidate={r['path']}  "
                  f"lineage={our_pkgs[r['package']]}")
    print(f"candidates={len(rows)} our_packages={len(our_pkgs)} collisions={hits}")
    return hits


def main():
    args = sys.argv[1:]
    aapt2 = "aapt2"
    if "--aapt2" in args:
        i = args.index("--aapt2")
        aapt2 = args[i + 1]
        del args[i:i + 2]
    if args and args[0] == "--perms":
        for root in args[1:]:
            print_permissions(aapt2, Path(root))
        return 0
    if args and args[0] == "--collision":
        # usage: --collision <candidate-root> <our-root> [<our-root>...]
        theirs, ours = Path(args[1]), [Path(p) for p in args[2:]]
        return 1 if collision(aapt2, ours, theirs) else 0
    for root in args:
        print_inventory(aapt2, Path(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
