#!/usr/bin/env python3
"""Coupling gate: does the boot image actually pair with the vendor partition that ships with it?

  tools/payload_coupling_check.py <built-vendor.img> <boot.img> [--tree <lineage-tree>]
      [--staged-tree <extracted vendor dir>] [--simg2img <path>]
      [--expect-libs libion.so,libaudioroute.so,...] [--expect-files lib/hw/gps.default.so,...]
      [--manifest-target-level N]

This turns "kernel, modules and manifest move together" (D46) into a pass/fail check on the finished
artifacts, which is what the owner made the safety net before the first eMMC write (**D47**). Four
things are read out of the images themselves, not out of a recipe:

  1. the kernel banner in boot.img (the payload sits at page_size, kernel_size bytes) and the
     vermagic of every .ko in vendor.img's /lib/modules. A mismatch means every module refuses at
     insmod time - WiFi, USB HID, iAP and the virtual touchpad vanish with no visible cause.
  2. boot.img's layout: kernel/ramdisk/second offsets computed the way a boot loader computes them,
     the first-stage fstab in the ramdisk (D34), and the DTB magic inside `second` (D38).
  3. the libraries Android 14 does not build at all (libion, libaudioroute, libaudioutils,
     libspeexresampler) present in /vendor for both arches - screen and audio input depend on them
     (docs/findings.md, "Shape A checked against Android 14's actual code").
  4. the criterion-coupled HAL files that must survive staging - for GPS (**D49**) the OEM GNSS trio -
     and the manifest's target-level, with no <kernel> tag (libvintf only checks kernel compatibility
     when the manifest declares one).

vendor.img may be Android sparse (magic 0xED26FF3A, which reads `3a ff 26 ed`); debugfs cannot read
that at all, so it is converted with the build tree's simg2img first. --staged-tree is the fallback
source for the module list when the built image cannot be read, and is reported as a fallback rather
than as a check of the image.
"""
import argparse
import gzip
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_ls import dump_file, list_dir  # noqa: E402

SPARSE_MAGIC = b'\x3a\xff\x26\xed'   # Android sparse header, little-endian 0xED26FF3A
DTB_MAGIC = b'\xd0\x0d\xfe\xed'
PAGE_SIZES = (2048, 4096, 8192, 16384, 32768)
# The libraries Android 14 does not build at all: the three extracted from a reference firmware
# partition (libion for composer/camera/OMX, libaudioroute + libspeexresampler for the audio HAL)
# plus libaudioutils, which Android 14 builds as a vendor variant. Checked in /lib64 AND /lib, because
# a 32-bit HAL process needs its own copy.
DEFAULT_LIBS = ('libion.so,libaudioroute.so,libaudioutils.so,libspeexresampler.so,'
                # the two sonames kept Android 10 blobs ask for by name and Android 14 installs only
                # under versioned names or not at all (docs/decisions.md D52): protobuf's plain soname
                # for the DRM/webrtc blobs, and the soft-OMX plugin the OMX service dlopen's, which no
                # DT_NEEDED walk can see.
                'libprotobuf-cpp-lite.so,libstagefright_softomx_plugin.so')

# The criterion files, spelled as exact paths because each HAL is either 32-bit or 64-bit here.
# GPS is a hard criterion (D49); sound input reaches audio.primary.rk30board.so and CANBUS reaches the
# MTC/CarPlay service; the screen criterion needs the gralloc blob *and* the mapper/allocator impls
# that wrap it (D52) - Android 14's libui dies with "gralloc-mapper is missing" without them; battery
# info comes from Android 14's own health@2.1 service, not the Android 10 2.0 blob (D52b).
DEFAULT_FILES = ('bin/hw/android.hardware.gnss@1.0-service,'
                 'lib/hw/android.hardware.gnss@1.0-impl.so,lib/hw/gps.default.so,'
                 'bin/hw/android.hardware.mtc.mfi@1.0-service,'
                 'lib/hw/android.hardware.mtc.mfi@1.0-impl.so,lib/hw/mfi.default.so,'
                 'lib/hw/audio.primary.rk30board.so,'
                 'lib/hw/gralloc.rk30board.so,'
                 'lib/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so,'
                 'lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so,'
                 'lib/hw/android.hardware.graphics.allocator@2.0-impl.so,'
                 'lib64/hw/android.hardware.graphics.allocator@2.0-impl.so,'
                 'bin/hw/android.hardware.graphics.allocator@2.0-service,'
                 'bin/hw/android.hardware.media.omx@1.0-service,'
                 'bin/hw/android.hardware.health@2.1-service')


def boot_layout(b):
    """Header block padded to page_size, then each component aligned to page_size (measured Nov 15)."""
    ks = struct.unpack('<I', b[8:12])[0]
    rs = struct.unpack('<I', b[16:20])[0]
    ss = struct.unpack('<I', b[24:28])[0]
    pg = struct.unpack('<I', b[56:60])[0]
    if pg not in PAGE_SIZES:
        pg = 2048
    ko = pg
    ro = ko + ((ks + pg - 1) // pg) * pg
    so = ro + ((rs + pg - 1) // pg) * pg
    dtb_size = struct.unpack('<I', b[1648:1652])[0] if len(b) > 1652 else 0
    return pg, ks, rs, ss, ko, ro, so, dtb_size


def listing(image, path):
    """Names in a partition directory, or None if debugfs cannot read it."""
    try:
        return [n for n, _m, _s, is_dir in list_dir(image, path) if not is_dir]
    except Exception as e:
        sys.stderr.write('debugfs ls %s: %s\n' % (path, str(e)[:160]))
        return None


def read_cat(image, path):
    try:
        res = subprocess.run(['debugfs', '-R', 'cat "%s"' % path, image],
                             capture_output=True, text=True, errors='replace')
        return res.stdout if res.returncode == 0 and res.stdout else None
    except Exception:
        return None


def to_raw(image, tree, simg2img, work):
    """debugfs-readable ext4 copy: converts Android sparse, else returns the path unchanged."""
    with open(image, 'rb') as f:
        if f.read(8) != SPARSE_MAGIC:
            return image
    cands = [c for c in ([simg2img] if simg2img else [])
             + ([os.path.join(tree, 'out', 'host', 'linux-x86', 'bin', 'simg2img')] if tree else [])
             + ([shutil.which('simg2img')] if shutil.which('simg2img') else [])]
    out = os.path.join(work, 'vendor-raw.img')
    for c in cands:
        if os.path.exists(c):
            r = subprocess.run([c, image, out], capture_output=True, text=True)
            if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0:
                print('  sparse vendor.img converted with %s (%d B raw)' % (c, os.path.getsize(out)))
                return out
            sys.stderr.write('simg2img %s failed: %s\n' % (c, (r.stderr or '')[:200]))
    raise SystemExit('%s is Android sparse and simg2img was not found (pass --simg2img or --tree)' % image)


def module_vermagics(image, work):
    """{name: vermagic} for the partition's /lib/modules; None if the directory cannot be read."""
    names = listing(image, '/lib/modules')
    if names is None:
        return None
    found = {}
    for n in names:
        if not n.endswith('.ko'):
            continue
        dst = os.path.join(work, n)
        try:
            dump_file(image, '/lib/modules/%s' % n, dst)
        except Exception as e:
            sys.stderr.write('dump %s: %s\n' % (n, str(e)[:160]))
            continue
        with open(dst, 'rb') as f:
            m = re.search(rb'vermagic=(\S+)', f.read())
        if m:
            found[n] = m.group(1).decode(errors='replace')
    return found


def insmod_list(path):
    """The modules hu_insmod.sh actually loads - those are the ones the criteria depend on."""
    text = open(path, encoding='utf-8', errors='replace').read()
    out = []
    m = re.search(r'for\s+m\s+in\s+(.*?)\s*do', text, flags=re.S)
    if not m:
        return out
    for tok in m.group(1).split():
        tok = tok.strip().rstrip('\\').strip()
        tok = tok.rstrip(';,})')
        if tok.endswith('.ko'):
            tok = tok[:-3]
        if tok and not tok.startswith('#'):
            out.append(tok)
    return out


def staged_vermagics(tree):
    found = {}
    for root, _dirs, files in os.walk(os.path.join(tree, 'lib', 'modules')):
        for f in files:
            if not f.endswith('.ko'):
                continue
            with open(os.path.join(root, f), 'rb') as fh:
                m = re.search(rb'vermagic=(\S+)', fh.read())
            if m:
                found[f] = m.group(1).decode(errors='replace')
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('vendor', help='built vendor.img (raw ext4 or Android sparse)')
    ap.add_argument('boot', help='boot image that ships with it')
    ap.add_argument('--tree', help='lineage tree, to locate out/host/linux-x86/bin/simg2img')
    ap.add_argument('--staged-tree', help='extracted vendor dir to fall back on for the module list')
    ap.add_argument('--simg2img', default=None)
    ap.add_argument('--expect-libs', default=DEFAULT_LIBS)
    ap.add_argument('--expect-files', default=DEFAULT_FILES)
    ap.add_argument('--manifest-target-level', default=None,
                    help='expected target-level: 4 for shape A, 5 for shape B')
    ap.add_argument('--insmod-file', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                          '..', 'device', 'rk3399-px6-hct4', 'configs',
                                                          'hu_insmod.sh'),
                    help='the boot script whose module list must match the kernel (WiFi/HID/iAP)')
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix='coupling-')
    fails = []
    try:
        boot = open(args.boot, 'rb').read()
        pg, ks, rs, ss, ko, ro, so, dtb_size = boot_layout(boot)
        kernel, ramdisk, second = boot[ko:ko + ks], boot[ro:ro + rs], boot[so:so + ss] if ss else b''
        print('boot: page %d, kernel %s B @%d, ramdisk %s B @%d, second %s B @%d, header dtb_size %d'
              % (pg, f'{ks:,}', ko, f'{rs:,}', ro, f'{ss:,}', so, dtb_size))
        m = re.search(rb'Linux version (\S+)', kernel)
        ver = m.group(1).decode(errors='replace') if m else None
        if not ver:
            fails.append('no "Linux version ..." banner in the kernel payload at %d' % ko)
        else:
            print('  kernel version: %s' % ver)
        if kernel[:8] == b'\x00' * 8:
            fails.append('kernel payload at %d is padding' % ko)
        if ramdisk[:2] != b'\x1f\x8b' and ramdisk[:4] not in (b'0707', b'\x04\x22\x50\x44'):
            fails.append('ramdisk at %d is not gzip/cpio/lz4 (signature %s)' % (ro, ramdisk[:4].hex()))
        blob = ramdisk
        if ramdisk[:2] == b'\x1f\x8b':
            try:
                blob = gzip.decompress(ramdisk)
            except Exception:
                pass
        if b'first_stage_ramdisk/fstab.rk30board' not in blob:
            fails.append('boot.img ramdisk has no first_stage_ramdisk/fstab.rk30board (D34: black screen)')
        if ss:
            if second[:8] == b'\x00' * 8:
                fails.append('second stage at %d is padding; the board DTB lives inside it (D38)' % so)
            else:
                i = second.find(DTB_MAGIC)
                if i < 0:
                    fails.append('no DTB magic inside the %s B second stage (D38)' % f'{ss:,}')
                else:
                    size = struct.unpack('>I', second[i + 4:i + 8])[0]
                    if not 200 < size < 4_000_000:
                        fails.append('DTB blob inside second at +%d claims size %d' % (i, size))
                    else:
                        print('  DTB inside second at +%d, size %d' % (i, size))

        raw_vendor = to_raw(args.vendor, args.tree, args.simg2img, work)
        mods = module_vermagics(raw_vendor, work)
        source = 'vendor.img'
        if mods is None and args.staged_tree:
            mods = staged_vermagics(args.staged_tree)
            source = 'the staged tree (fallback, vendor.img was unreadable)'
        if mods is None:
            fails.append('cannot read /lib/modules - debugfs missing, or sparse vendor.img without simg2img')
        elif not mods:
            print('  no .ko in /lib/modules (all drivers built-in is legitimate)')
        else:
            vm = sorted(set(mods.values()))
            print('  %d .ko from %s, vermagic: %s' % (len(mods), source, ', '.join(vm)))
            # A stock vendor partition ships leftovers from older kernels (the A10 tree has GPU .ko at
            # vermagic 4.4.167 and aic8800-era ones at 4.19.101+); hu_insmod.sh never attempts those and
            # insmod refuses them harmlessly. What must match the kernel is the list the boot script
            # loads - WiFi, USB HID and iAP - because those are the owner's criteria (D49/D46).
            if args.insmod_file:
                want = insmod_list(args.insmod_file)
                absent = [m for m in want if m + '.ko' not in mods]
                wrong = sorted(m + '.ko' for m in want if m + '.ko' in mods and mods[m + '.ko'] != ver)
                print('  hu_insmod list: %d module(s), %d present, %d absent, %d wrong vermagic'
                      % (len(want), len(want) - len(absent), len(absent), len(wrong)))
                if absent:
                    print('    not in vendor.img: %s' % ', '.join(absent))
                if wrong:
                    fails.append('module(s) hu_insmod.sh loads have the wrong vermagic: %s (kernel %s)'
                                 % (', '.join(wrong), ver))
            else:
                if ver not in vm:
                    fails.append('no module has vermagic %s (found %s): every .ko would refuse at insmod (D46)'
                                 % (ver, ', '.join(vm)))
                mismatch = sorted(n for n, v in mods.items() if v != ver)
                if mismatch:
                    print('  %d module(s) would not load against this kernel (advisory): %s'
                          % (len(mismatch), ', '.join(mismatch[:8]) + (' ...' if len(mismatch) > 8 else '')))

        want_libs = [x for x in args.expect_libs.split(',') if x]
        for arch in ('lib64', 'lib'):
            names = listing(raw_vendor, '/%s' % arch)
            if names is None:
                fails.append('cannot list /%s in vendor.img' % arch)
                continue
            missing = [s for s in want_libs if s not in names]
            if missing:
                fails.append('/%s missing %s (Android 14 builds none of them; inject both arches, docs/findings.md)'
                             % (arch, ', '.join(missing)))
            else:
                print('  /%s carries the injected libraries: %s' % (arch, ', '.join(want_libs)))

        want_files = [x for x in args.expect_files.split(',') if x]
        gone = []
        for path in want_files:
            d = os.path.dirname(path)
            names = listing(raw_vendor, '/%s' % d if d else '/')
            if names is None or os.path.basename(path) not in names:
                gone.append(path)
        if gone:
            fails.append('criterion HAL file(s) missing from vendor.img: %s' % ', '.join(gone))
        else:
            print('  criterion HAL files present: %s' % ', '.join(want_files))

        text = read_cat(raw_vendor, '/etc/vintf/manifest.xml')
        if text is None:
            fails.append('cannot read /etc/vintf/manifest.xml from vendor.img')
        else:
            level = re.search(r'target-level="(\d+)"', text)
            version = re.search(r'version="([\d.]+)"', text)
            # Android 10 manifests write `<hal format="hidl">`, Android 11 `<hal>`, so count both forms:
            # one block per declared HAL. Fragments in /etc/vintf/manifest/ are counted separately.
            hal = len(re.findall(r'<hal[^>]*>', text))
            print('  vendor manifest: version=%s target-level=%s, %d inline HAL declarations%s'
                  % (version.group(1) if version else '?', level.group(1) if level else '?', hal,
                     ', no <kernel> tag' if '<kernel' not in text else ', DECLARES <kernel>'))
            if '<kernel' in text:
                # The Android 11 stock manifest declares <kernel target-level="5"/>; the Android 10 one
                # declares none. Shape A must not gain a <kernel> tag (D46), so it is fatal only when the
                # declared level is not the level this payload is supposed to be - otherwise it is a
                # fact to report, because libvintf then checks the kernel's features against that matrix.
                klevel = re.search(r'<kernel[^>]*target-level="(\d+)"', text)
                print('  manifest declares <kernel target-level=%s (libvintf checks kernel features)'
                      % (klevel.group(1) if klevel else '?'))
                if args.manifest_target_level and (not klevel or klevel.group(1) != args.manifest_target_level):
                    fails.append('<kernel> declares target-level %s while this payload expects %s'
                                 % (klevel.group(1) if klevel else 'none', args.manifest_target_level))
            if args.manifest_target_level and level and level.group(1) != args.manifest_target_level:
                fails.append('manifest target-level %s != expected %s (kernel/modules/manifest couple, D46)'
                             % (level.group(1), args.manifest_target_level))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if fails:
        print('FAIL')
        for f in fails:
            print('  ! %s' % f)
        return 1
    print('PASS: boot image and vendor partition in this payload agree')
    return 0


if __name__ == '__main__':
    sys.exit(main())
