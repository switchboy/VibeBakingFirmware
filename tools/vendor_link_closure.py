#!/usr/bin/env python3
"""What /vendor must contain so the kept Rockchip blobs can load, and how to get it there.

  tools/vendor_link_closure.py <lineage-tree> <device-dir> [options]

Starting from every staged vendor ELF that is NOT in the drop list (the blobs we keep), walk the
DT_NEEDED graph transitively and answer, for each soname, how Android 14 can put it where a vendor
process can find it:

  B. a staged blob that is not dropped         - PRODUCT_COPY_FILES already copies it (the Android 11
     copy, which is the ABI the blob was compiled against; keep it rather than Android 14's newer lib)
  C. a *public* library                         - listed in system/etc/linker.config.pb, and present in
     /system. linkerconfig builds the vendor namespace from that list, so /vendor processes load it
     straight out of /system: that is how Android 14 HALs get liblog.so, libc.so, libsync.so, libEGL.so
     without any copy in /vendor. Nothing to do.
  D. Android 14 defines a `<name>.vendor` / `<name>.vendor_32` module for it
     - add that module name to PRODUCT_PACKAGES, so Soong installs Android 14's own vendor variant into
       /vendor/lib64 (or /vendor/lib for 32-bit). This is the preferred answer: same tree, same ABI, and
       requesting it makes the file an install dependency of vendor.img - which is what build_image.py's
       file filter is generated from, so the image really contains it.
  A. already installed in /vendor              - nothing to do
  E. Android 14 builds it only for /system, it is not public, and no vendor variant exists
     - inject Android 14's compiled copy into the vendor staging directory
  F. Android 14 does not build it at all
     - inject whatever sits in <device-dir>/prebuilt_vendor_libs/<arch>/, extracted from a reference
       firmware partition by tools/extract_reference_libs.py
  G. nothing has it                            - reported; the blob that links it cannot load

Bionic (libc/libm/libdl/libpthread) is never copied into /vendor: a second libc.so would give a process
two copies of one library, and they are public libraries anyway.

Outputs, both regenerated from a real build and both gitignored:
  <device-dir>/vendor_modules_extra.mk   PRODUCT_PACKAGES += lines, included by device.mk
  <device-dir>/vendor_dest_keep.txt      <vendor-relative-path>\t<source>\t<reason> for
                                         scripts/inject_vendor_blobs.sh

Options: --product <dir> (default: the first dir under out/target/product), --modules <file>,
--keep <file>, --symbol-check (report undefined symbols of anything still injected that no file in
/vendor or /system defines). Exit code 1 only when a soname is unresolvable (G).
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import walk  # noqa: E402

BIONIC = {"libc.so", "libm.so", "libdl.so", "libpthread.so"}
SYSTEM_PARTS = ("system", "system_ext", "product", "odm")


def elf_needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^]]+)\]", out)


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def read_list(path):
    """A drop/skip list: one partition-relative path per line, comments after # allowed."""
    if not os.path.isfile(path):
        return set()
    return {line.split("#", 1)[0].split("\t")[0].strip() for line in open(path, errors="replace")
            if line.strip() and not line.strip().startswith("#")}


def public_libs(pdir):
    """Sonames the vendor namespace may load straight out of /system. The list lives in
    system/etc/linker.config.pb (protobuf; the names appear as plain strings) and linkerconfig turns it
    into ld.config.txt at boot. Anything in it needs no copy in /vendor."""
    pb = os.path.join(pdir, "system", "etc", "linker.config.pb")
    if not os.path.isfile(pb):
        return set()
    data = open(pb, "rb").read()
    return {m.decode() for m in re.findall(rb"[ -~]+\.so", data)}


def tree_paths(root):
    """{basename: [paths relative to root]} for a directory tree."""
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        for name in files:
            p = os.path.join(rel, name) if rel != "." else name
            out.setdefault(name, []).append(p)
    return out


def walk_files(root):
    """Every file under root, as paths relative to root. tree_paths() only gives the basenames, so
    iterating it loses the directory - which is how the built-library lookup stopped matching the
    public libraries in /system/lib64."""
    for dirpath, _dirs, files in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        for name in files:
            yield os.path.join(rel, name) if rel != "." else name


def image_paths(img):
    """{partition-relative path: basename} of a built ext4 image; sparse images are converted first."""
    if not os.path.isfile(img):
        return {}
    if open(img, "rb").read(4) == b"\x3a\xff\x26\xed":
        host = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(img)))))
        simg2img = os.path.join(host, "out", "host", "linux-x86", "bin", "simg2img")
        raw = img + ".raw"
        if os.path.isfile(simg2img):
            subprocess.run([simg2img, img, raw], capture_output=True)
            img = raw if os.path.isfile(raw) else img
    return {p.lstrip("/"): os.path.basename(p) for p in walk(img, "/", sizes=False,
                                                            pattern=None, dirs=False)}


def module_graph(tree):
    """Soong's module-info json as {module name: info}. Names carrying a variant suffix are requestable
    module names: libfoo.vendor installs the vendor variant into /vendor/lib64, libfoo.vendor_32 into
    /vendor/lib."""
    prod = os.path.join(tree, "out", "soong")
    for name in sorted(os.listdir(prod)) if os.path.isdir(prod) else []:
        if name.startswith("module-info-") and name.endswith(".json"):
            entries = json.loads(open(os.path.join(prod, name), errors="replace").read())
            graph = {}
            for e in entries:
                if isinstance(e, dict):
                    graph.update(e)
            return graph
    return {}


def arch_of(rel):
    """The directory the loader searches for a blob's sonames: a module in lib64/hw resolves its NEEDED
    entries against /vendor/lib64, not against lib64/hw itself."""
    d = os.path.dirname(rel)
    if d.startswith("lib64"):
        return "lib64"
    if d.startswith("lib"):
        return "lib"
    if d in ("bin/hw", "bin"):
        return "lib64" if d == "bin/hw" else "lib"
    return None


def elf_arch(path):
    """ELF class of a file: 0x02 at offset 4 is 64-bit, 0x01 is 32-bit. This beats the directory,
    because /vendor/bin and /vendor/bin/hw carry 64-bit *and* 32-bit executables on this vendor tree,
    and a 32-bit binary resolves its sonames in /vendor/lib, not /vendor/lib64."""
    try:
        with open(path, "rb") as f:
            magic = f.read(5)
    except OSError:
        return None
    if magic[:4] != b"\x7fELF":
        return None
    return "lib64" if magic[4] == 2 else "lib"


def exported_symbols(fp):
    out = subprocess.run(["nm", "-D", "--defined-only", fp], capture_output=True, text=True).stdout
    return {m.split()[-1] for m in re.findall(r"^\S+ [A-Za-z] (\S+)$", out, re.M)}


def undefined_symbols(fp):
    out = subprocess.run(["nm", "-D", "--undefined-only", fp], capture_output=True, text=True).stdout
    return {m.split()[-1] for m in re.findall(r"^\s*U (\S+)$", out, re.M)}


def main():
    tree, device_dir = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    pdir, symbol_check = None, "--symbol-check" in args
    modules_out = os.path.join(device_dir, "vendor_modules_extra.mk")
    keep_out = os.path.join(device_dir, "vendor_dest_keep.txt")
    i = 0
    while i < len(args):
        if args[i] == "--product":
            pdir, i = args[i + 1], i + 2
        elif args[i] == "--modules":
            modules_out, i = args[i + 1], i + 2
        elif args[i] == "--keep":
            keep_out, i = args[i + 1], i + 2
        else:
            i += 1
    if not pdir:
        prod = os.path.join(tree, "out", "target", "product")
        devices = sorted(os.listdir(prod)) if os.path.isdir(prod) else []
        if not devices:
            raise SystemExit("no built product dir under %s - run scripts/package.sh first" % prod)
        pdir = os.path.join(prod, devices[0])

    staged_root = os.path.join(tree, "vendor", "hct4", "tree", "vendor")
    if not os.path.isdir(staged_root):
        raise SystemExit("no staged vendor tree: %s (run scripts/prebuilt_vendor.sh)" % staged_root)
    dropped = read_list(os.path.join(device_dir, "vendor_build_wins.txt"))
    dropped |= read_list(os.path.join(device_dir, "vendor_dest_skip_extra.txt"))
    staged = tree_paths(staged_root)
    in_vendor = image_paths(os.path.join(pdir, "vendor.img"))
    public = public_libs(pdir)
    graph = module_graph(tree)
    if not graph:
        raise SystemExit("no module-info json in out/soong - run a build first")
    built = {}          # soname -> [(label, absolute path)] Android 14's own copies
    for part in SYSTEM_PARTS:
        d = os.path.join(pdir, part)
        if os.path.isdir(d):
            for rel in walk_files(d):
                built.setdefault(os.path.basename(rel), []).append(("/" + part, os.path.join(d, rel)))
    # Android 14 keeps bionic and TLS in APEXes (com.android.runtime's lib{,64}/bionic, conscrypt's
    # libssl/libcrypto). Nothing named libc.so exists in /system any more, so the unpacked apex
    # payload under the product dir is where these files actually are; the arch is the lib/lib64
    # component of the path inside the APEX.
    apex = os.path.join(pdir, "apex")
    if os.path.isdir(apex):
        for rel in walk_files(apex):
            arch = next((p for p in rel.split("/") if p in ("lib", "lib64")), None)
            if arch:
                built.setdefault(os.path.basename(rel), []).append(
                    ("APEX " + rel.split("/")[0] + "/" + arch, os.path.join(apex, rel)))
    prebuilt = os.path.join(device_dir, "prebuilt_vendor_libs")

    kept = [rel for rel in sorted(p for ps in staged.values() for p in ps)
            if rel not in dropped and is_elf(os.path.join(staged_root, rel))]
    print("kept vendor blobs: %d ; files in the built vendor.img: %d ; modules in the Soong graph: %d ; "
          "public libraries: %d" % (len(kept), len(in_vendor), len(graph), len(public)))

    todo = [(rel, lib) for rel in kept for lib in elf_needed(os.path.join(staged_root, rel))]
    modules = {}          # module name -> install paths Soong declares for it
    not_installed = []    # sonames whose vendor variant is not in /vendor yet -> rebuild needed
    inject = {}           # vendor-relative path -> (source, reason)
    unresolved, seen = [], set()
    while todo:
        from_rel, lib = todo.pop()
        if lib in BIONIC:
            continue
        from_path = os.path.join(staged_root, from_rel)
        arch = elf_arch(from_path) or arch_of(from_rel) or "lib64"
        if (lib, arch) in seen:
            continue
        seen.add((lib, arch))
        dest = "%s/%s" % (arch, lib)

        blob = [p for p in staged.get(lib, []) if p not in dropped and os.path.dirname(p) == arch]
        if blob:
            continue                                       # B: PRODUCT_COPY_FILES copies the staged blob
        if lib in public and any(os.path.dirname(p) == arch or arch in p.split("/")
                                 for _l, p in built.get(lib, [])):
            continue                                       # C: public library, loaded straight out of
                                                       # /system (or from an APEX, where Android 14
                                                       # keeps bionic and TLS)
        stem = lib[:-3]
        mod = "%s.vendor" % stem if arch == "lib64" else "%s.vendor_32" % stem
        if mod in graph:
            # Requested even when the file is already in /vendor: the request is what put it there, and
            # dropping it would stop the next build installing it.
            modules[mod] = graph[mod].get("installed") or []
            if dest not in in_vendor:
                not_installed.append(dest)
            # Soong resolves the vendor variant's own DT_NEEDED through the same install rule, so there
            # is nothing further to walk: its dependencies land as dependencies of this rule too.
            continue                                       # D: Android 14's own vendor variant
        if dest in in_vendor or lib in in_vendor.values():
            continue                                       # A: already in /vendor
        if lib in built:
            label, src = next(((l, p) for l, p in built[lib] if os.path.dirname(p) == arch),
                              built[lib][0])
            inject[dest] = (src, "Android 14 builds this for %s only, it is not a public library and "
                                 "no vendor variant module exists; injecting its own compiled copy" % label)
            todo.extend((dest, l) for l in elf_needed(inject[dest][0]))
            continue                                       # E
        pb_src = os.path.join(prebuilt, arch, lib)
        if os.path.isfile(pb_src):
            inject[dest] = (pb_src, "Android 14 does not build this; taken from the reference firmware "
                                    "image in prebuilt_vendor_libs/")
            todo.extend((dest, l) for l in elf_needed(pb_src))
            continue                                       # F
        unresolved.append((lib, from_rel))                 # G

    if modules:
        header = ("# Generated by tools/vendor_link_closure.py from a real build - do not edit.\n"
                  "# Android 14 vendor variants the kept Rockchip vendor blobs link and nothing else\n"
                  "# requests. device.mk includes this file, so Soong installs them into /vendor.\n"
                  "# Regenerate after every packaging pass:\n"
                  "#   tools/vendor_link_closure.py <tree> <device-dir>\n")
        with open(modules_out, "w") as f:
            f.write(header)
            for m in sorted(modules):
                f.write("PRODUCT_PACKAGES += %s\n" % m)
        print("\nwrote %s (%d vendor variant modules requested; %d of them are not in /vendor yet)"
              % (modules_out, len(modules), len(not_installed)))
        for m in sorted(modules)[:26]:
            inst = sorted({p.split("rk3399/")[-1] for p in (modules[m] or [])})[:1]
            print("   %-44s -> %s" % (m, ", ".join(inst) or "no install path"))
        if len(modules) > 26:
            print("   ... %d more" % (len(modules) - 26))
        if not_installed:
            print("\nnot installed yet (rebuild after device.mk picks them up): %s"
                  % ", ".join(sorted(not_installed)[:12]))
    else:
        print("\nno vendor variant modules to request")

    if inject:
        header = ("# Generated by tools/vendor_link_closure.py from a real build - do not edit.\n"
                  "# <vendor-relative-path>\t<source-file>\t<reason>\n"
                  "# scripts/inject_vendor_blobs.sh writes these into the vendor staging directory;\n"
                  "# they are libraries Android 14 does not install into /vendor and cannot request as\n"
                  "# a vendor variant, so they must be written after the install rules have run.\n")
        with open(keep_out, "w") as f:
            f.write(header)
            for rel in sorted(inject):
                src, why = inject[rel]
                f.write("%s\t%s\t%s\n" % (rel, src, why))
        print("wrote %s (%d libraries to inject into /vendor)" % (keep_out, len(inject)))
        for rel in sorted(inject)[:20]:
            print("   %-42s %s" % (rel, inject[rel][1][:64]))
        if len(inject) > 20:
            print("   ... %d more" % (len(inject) - 20))
    elif os.path.isfile(keep_out):
        os.remove(keep_out)
        print("removed %s (nothing needs injecting anymore)" % keep_out)

    if unresolved:
        print("\nCANNOT resolve %d soname(s):" % len(unresolved))
        for lib, from_rel in sorted(set(unresolved)):
            print("   %-44s needed by %s" % (lib, from_rel))
        print("   Neither Android 14's tree nor prebuilt_vendor_libs/ has it. Extract it from a\n"
              "   reference firmware partition with tools/extract_reference_libs.py, or declare the\n"
              "   blob that needs it a deviation in vendor_dest_deviations.txt.")

    if symbol_check and inject:
        print("\n=== undefined symbols of the injected files ===")
        # Keyed by partition-relative path: the 32-bit and 64-bit copies of one library export
        # different symbol sets (configureRpcThreadpool is unsigned int in lib/, unsigned long in
        # lib64/), so mixing them would report symbols the loader actually finds.
        tables = {}
        for root in ("vendor", "system"):
            d = os.path.join(pdir, root)
            for dp, _dirs, fs in os.walk(d):
                rel = os.path.relpath(dp, d)
                for f in fs:
                    if f.endswith(".so"):
                        fp = os.path.join(dp, f)
                        if is_elf(fp):
                            path = os.path.join(rel, f) if rel != "." else f
                            tables[path] = exported_symbols(fp)
        print("   libraries under /vendor and /system: %d" % len(tables))
        bad = 0
        for rel in sorted(inject):
            arch = os.path.dirname(rel)
            defined = set()
            for path, syms in tables.items():
                if os.path.dirname(path) == arch or (arch == "lib" and os.path.basename(path) in public):
                    defined |= syms
            miss = sorted(s for s in undefined_symbols(inject[rel][0]) if s not in defined)
            bad += len(miss)
            print("   %-42s [%s] unresolved: %d%s" % (rel, arch, len(miss),
                                                      "  " + ", ".join(miss[:4]) if miss else ""))
        if bad:
            print("   -> the injected library would not load; check its ABI against Android 14")

    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
