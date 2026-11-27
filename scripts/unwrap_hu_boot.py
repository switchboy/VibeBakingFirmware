#!/usr/bin/env python3
"""Remove the PID-1 wrapper (tools/hu_card_arm.c) from a card boot image: the reverse of inject_hu_wrap_boot.py.
Builds only; nothing is flashed.

Why (owner, Nov 27): the wrapper arms the card BCB on every boot, so every power cycle (ignition) lands in the card
recovery, and its dead-man build panics at 600 s unless disarmed over adb. For field testing every boot must go straight
to Android 14; the restore route is booting Android 10 (stock eMMC).

What it does: in the ramdisk cpio, drop the wrapper entry `init` and rename `init.real` back to `init` (same position,
same data, mode, inode). Kernel, second stage, header fields other than the ramdisk size, cmdline and the image tail
are carried byte-for-byte. Self-checks: the new /init is the old /init.real bytes; every other entry is unchanged;
the cpio re-parses; the kernel and tail bytes are identical to the input.

    python3 scripts/unwrap_hu_boot.py <wrapped boot.img> <out.img>
"""
import struct
import sys

sys.path.insert(0, __import__('os').path.dirname(__file__))
import inject_hu_wrap_boot as W  # noqa: E402  (shares the cpio + layout code with the injector)


def unwrap_cpio(raw: bytes):
    entries, tail = W.parse_cpio(raw)
    names = [e['name'] for e in entries]
    if names.count('init') != 1 or names.count('init.real') != 1:
        raise SystemExit(f"cpio: expected one init and one init.real, found {names.count('init')} / {names.count('init.real')}"
                         " - is this a wrapped image?")
    wrapper = entries[names.index('init')]
    real = entries[names.index('init.real')]
    restored = dict(real)
    restored['hdr'] = bytearray(real['hdr'])
    restored['name'] = 'init'
    restored['namesize'] = len('init') + 1
    new_entries = [restored if e is real else e for e in entries if e is not wrapper]
    return W.build_cpio(new_entries, tail), new_entries, entries, wrapper, real


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    base = open(argv[1], 'rb').read()
    if base[:8] != b'ANDROID!':
        raise SystemExit("input does not carry the ANDROID! magic")
    ks, rs, ss, ro, so = W.offsets(base)
    content_end = W.roundup(so + ss)
    kernel = base[W.PAGE:W.PAGE + ks]
    second = base[so:so + ss]
    old_raw = W.gunzip(base[ro:W.roundup(ro + rs)])

    new_raw, entries, old_entries, wrapper, real = unwrap_cpio(old_raw)

    # gates
    re_entries, re_tail = W.parse_cpio(new_raw)
    key = lambda es: [(e['name'], e['mode'], e['inode'], e['devmj'], e['devmn'], e['size'], e['data']) for e in es]
    if key(re_entries) != key(entries):
        raise SystemExit("self-check failed: repacked archive does not re-parse to the expected entry list")
    if re_tail != W.parse_cpio(old_raw)[1]:
        raise SystemExit("self-check failed: trailing bytes after the cpio trailer changed")
    by_name = {e['name']: e for e in entries}
    if 'init.real' in by_name or by_name['init']['data'] != real['data'] or by_name['init']['mode'] != real['mode']:
        raise SystemExit("self-check failed: /init is not the former /init.real")
    for e in old_entries:
        if e['name'] in ('init', 'init.real', W.TRAILER):
            continue
        n = by_name[e['name']]
        if (n['data'], n['mode'], n['inode'], n['devmj'], n['devmn']) != (e['data'], e['mode'], e['inode'], e['devmj'], e['devmn']):
            raise SystemExit(f"self-check failed: entry {e['name']!r} changed")

    new_rd = W.gzip_deterministic(new_raw)
    rd_span = new_rd + b'\x00' * (W.roundup(len(new_rd)) - len(new_rd))
    hdr = bytearray(base[:W.PAGE])
    struct.pack_into('<I', hdr, 16, len(new_rd))
    new_ro = W.roundup(W.PAGE + ks)
    new_so = W.roundup(new_ro + len(rd_span))
    new_end = W.roundup(new_so + ss)
    if new_end > content_end:
        # the unwrapped ramdisk is smaller, so this cannot happen unless the input is not what we think
        raise SystemExit(f"unwrapped content ({new_end:,} B) is larger than the wrapped one ({content_end:,} B)")
    body = bytearray(hdr) + kernel
    body += b'\x00' * (new_ro - len(body)) + rd_span
    body += b'\x00' * (new_so - len(body)) + second
    body += b'\x00' * (content_end - len(body))       # zero the space the larger wrapped ramdisk occupied
    out = bytes(body) + base[content_end:]            # tail (resources etc.) verbatim
    if len(out) != len(base) or out[W.PAGE:W.PAGE + ks] != kernel or out[content_end:] != base[content_end:]:
        raise SystemExit("self-check failed: size, kernel or tail differ from the input")
    open(argv[2], 'wb').write(out)
    print(f"removed wrapper /init ({len(wrapper['data']):,} B sha256 {W.sha(wrapper['data'])[:12]}); "
          f"/init = former /init.real ({len(real['data']):,} B sha256 {W.sha(real['data'])[:12]})")
    print(f"ramdisk {rs:,} -> {len(new_rd):,} B; image {len(out):,} B sha256 {W.sha(out)}")


if __name__ == '__main__':
    main(sys.argv)
