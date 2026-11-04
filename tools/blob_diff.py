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
    """'vendor/...' relative path -> sha256, for the blob families the probe hashes. Indexed by path
    so lib and lib64 copies stay distinct."""
    out = {}
    for rel in ["vendor/bin/hw", "vendor/lib/hw", "vendor/lib64/hw", "vendor/lib/modules",
                "vendor/etc/vintf", "vendor/etc"]:
        d = tree / rel
        if not d.is_dir():
            continue
        for f in d.iterdir():
            if not f.is_file():
                continue
            accepted = (rel == "vendor/bin/hw" or f.suffix in {".so", ".ko"} or f.name in {
                "manifest.xml", "compatibility_matrix.xml", "audio_policy_configuration.xml",
                "audio_effects.xml", "build.prop"})
            if accepted:
                out[str(f.relative_to(tree))] = hash_file(f)
    return out


def probe_hashes(report: Path) -> dict:
    """device path -> sha256, from the 'Vendor blob inventory' section."""
    text = report.read_bytes().decode("utf-8", "replace")
    start = text.find("## Vendor blob inventory")
    if start < 0:
        raise SystemExit("report has no 'Vendor blob inventory' section - re-run allinone.sh")
    open_fence = text.find("```", start)
    end = text.find("```", open_fence + 3)  # closing fence
    out = {}
    for line in text[open_fence + 3:end].splitlines():
        m = re.match(r"^([0-9a-f]{64})\s+(\S+)$", line.strip())
        if m:
            out[m.group(2)] = m.group(1)
    return out


def main():
    report, tree = Path(sys.argv[1]), Path(sys.argv[2])
    ref = reference_hashes(tree)
    dev = probe_hashes(report)
    same, differ, only_unit, only_ref = [], [], [], []
    for path, digest in sorted(dev.items()):
        key = path.lstrip("/")
        if key in ref:
            (same if ref[key] == digest else differ).append(key)
        else:
            only_unit.append(path)
    listed = {p.lstrip("/") for p in dev}
    only_ref = sorted(p for p in ref if p not in listed)

    print(f"byte-identical: {len(same)}, differing: {len(differ)}, "
          f"on unit only: {len(only_unit)}, in reference only: {len(only_ref)}")
    for p in differ:
        print(f"  DIFFERS {p}")
        print(f"    unit sha {dev['/' + p]}")
        print(f"    ref  sha {ref[p]}")
    for p in only_unit[:30]:
        print(f"  not in reference tree: {p}")
    for p in only_ref[:30]:
        print(f"  reference file not hashed by probe: {p}")
    print(f"\nidentical list: {', '.join(same) if same else '(none)'}")


if __name__ == "__main__":
    main()
