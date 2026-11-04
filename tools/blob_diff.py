#!/usr/bin/env python3
"""Compare the head unit's vendor blob hashes (from a probe report) against the reference
firmware's vendor tree.

  python3 tools/blob_diff.py incoming/probe-xxx.md analysis/vendor_tree

Reference hashes are computed from analysis/vendor_tree (gitignored, derived from the shipped
update.zip). Prints only the interesting part: identical blobs, differing blobs, extra/missing.
"""
import hashlib
import re
import sys
from pathlib import Path

SECTIONS = {
    "vendor HAL binaries": "vendor/bin/hw",
    "vendor HAL libraries": "vendor/lib",
    "kernel modules": "vendor/lib/modules",
    "key config files": "vendor/etc",
}


def hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def reference_hashes(tree: Path) -> dict:
    """basename -> (expected sha256, relative path), for the blob families we care about."""
    out = {}
    for rel in ["vendor/bin/hw", "vendor/lib/hw", "vendor/lib64/hw", "vendor/lib/hw",
                "vendor/lib/modules", "vendor/etc/vintf", "vendor/etc"]:
        d = tree / rel
        if not d.is_dir():
            continue
        for f in d.iterdir():
            if f.is_file() and (f.suffix in {".so", ".ko"} or f.name in {
                "manifest.xml", "compatibility_matrix.xml", "audio_policy_configuration.xml",
                "audio_effects.xml", "build.prop"}):
                out[f.name] = (hash_file(f), str(f.relative_to(tree)))
    return out


def probe_hashes(report: Path) -> dict:
    """device path -> sha256, from the 'Vendor blob inventory' section."""
    text = report.read_bytes().decode("utf-8", "replace")
    start = text.find("## Vendor blob inventory")
    if start < 0:
        raise SystemExit("report has no 'Vendor blob inventory' section - re-run allinone.sh")
    end = text.find("```", text.find("```\n", start))
    out = {}
    for line in text[start:end].splitlines():
        m = re.match(r"^([0-9a-f]{64})\s+(\S+)$", line.strip())
        if m:
            out[m.group(2)] = m.group(1)
    return out


def main():
    report, tree = Path(sys.argv[1]), Path(sys.argv[2])
    ref = reference_hashes(tree)
    dev = probe_hashes(report)
    same, differ, missing, extra = [], [], [], []
    for path, digest in sorted(dev.items()):
        name = Path(path).name
        exp = ref.get(name)
        if exp is None:
            extra.append(path)
        elif exp[0] == digest:
            same.append(name)
        else:
            differ.append((name, path, exp[1]))
    listed = {Path(p).name for p in dev}
    missing = sorted(n for n in ref if n not in listed)

    print(f"identical: {len(same)}, differing: {len(differ)}, "
          f"present on unit but not in reference: {len(extra)}, "
          f"in reference but not listed by probe: {len(missing)}")
    for name, dev_path, ref_path in differ:
        print(f"  DIFFERS {name}  unit={dev_path}  reference={ref_path}")
    for p in extra[:40]:
        print(f"  EXTRA on unit: {p}")
    for n in missing[:40]:
        print(f"  not hashed by probe: {n}")


if __name__ == "__main__":
    main()
