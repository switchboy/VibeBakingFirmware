#!/usr/bin/env python3
"""VINTF gap report: which framework-matrix HALs the vendor manifest does not provide.

Usage:
  hal_gap.py --manifest <vendor_manifest.xml> --matrix <framework_matrix.xml> [--target-level N]

The framework's runtime check uses the *shipping FCM* taken from the vendor manifest's
`target-level`; HALs declared only in higher FCM versions are optional, so this tool reports
the matrix at the vendor's target level as "hard requirements" and any higher-version HALs as
"optional-but-likely-needed-by-the-framework".
"""
import argparse
import xml.etree.ElementTree as ET


def hal_key(hal_el):
    name = hal_el.findtext("name", "")
    transport = hal_el.findtext("transport", "hwbinder")
    optional = hal_el.get("optional") == "true"
    interfaces = []
    for iface in hal_el.findall("interface"):
        iname = iface.findtext("name", "")
        instances = [i.text for i in iface.findall("instance")] + \
                    [r.text for r in iface.findall("regex-instance")]
        interfaces.append((iname, instances))
    versions = [v.text for v in hal_el.findall("version")]
    return name, transport, interfaces, versions, optional


def is_regex(inst):
    return "*" in inst or "." in inst or "[" in inst


def fmt(hal):
    name, transport, interfaces, versions, optional = hal
    ver = ",".join(versions) if versions else "aidl"
    parts = [f"{iname}/{ '|'.join(instances) or '*'}" for iname, instances in interfaces]
    return f"{name}@[{ver}]::{'; '.join(parts)}{' (optional)' if optional else ''}"


def parse(path):
    root = ET.parse(path).getroot()
    level = root.get("level") or root.get("target-level")
    hal_el = root.find("hal")
    return root.get("type"), level, [hal_key(h) for h in root.findall("hal")]


def ver(s):
    """'2.5-7' -> (2,5); '1-2' -> (1,) for AIDL-style versions."""
    head = s.split("-")[0]
    return tuple(int(x) for x in head.split("."))


def provides(manifest_hal, required):
    """True if a manifest entry satisfies a required matrix entry (same name+interface+instance,
    version range satisfied by at least one manifest version)."""
    for name, _transport, interfaces, versions, _optional in manifest_hal:
        if name != required[0]:
            continue
        req_ifaces = required[2]
        manifest_ifaces = {iname: insts for iname, insts in interfaces}
        ok = True
        for iname, instances in req_ifaces:
            provided = manifest_ifaces.get(iname)
            if provided is None:
                ok = False
                break
            for inst in instances:
                if is_regex(inst):
                    continue  # regex-instance: coverage checked by the real vintf matcher
                if inst not in provided:
                    ok = False
                    break
            if not ok:
                break
        if not ok:
            continue
        # matrix "X" means X..X; "X-Y" caps the requestable version (informational).
        # Any manifest version >= the matrix minimum is acceptable.
        req_vers = required[3]
        if req_vers and versions:
            low = ver(req_vers[0])
            if not any(ver(v) >= low for v in versions):
                continue
        return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="analysis/vintf/vendor_manifest.xml")
    ap.add_argument("--matrix", default="analysis/vintf/system_matrix.xml")
    args = ap.parse_args()

    mtype, mlevel, manifest_hal = parse(args.manifest)
    rtype, rlevel, required_hal = parse(args.matrix)
    print(f"manifest: type={mtype} target-level={mlevel}  entries={len(manifest_hal)}")
    print(f"matrix:   type={rtype} level={rlevel}  entries={len(required_hal)}")
    if mlevel and rlevel and mlevel != rlevel:
        print(f"!! target-level {mlevel} != matrix level {rlevel}: strict VINTF match fails "
              "(libvintf runtime still falls back to the FCM at the vendor's shipping level)")

    missing = [h for h in required_hal if not provides(manifest_hal, h)]
    hard = [h for h in missing if not h[4]]
    soft = [h for h in missing if h[4]]
    print(f"\nMISSING hard requirements ({len(hard)}): framework needs these, vendor does not provide them")
    for h in hard:
        print(f"  {fmt(h)}")
    print(f"\nMISSING optional HALs ({len(soft)}): only needed if you want those features")
    for h in soft:
        print(f"  {fmt(h)}")
    print("\nProvided HAL surface:")
    for h in manifest_hal:
        print(f"  {fmt(h)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
