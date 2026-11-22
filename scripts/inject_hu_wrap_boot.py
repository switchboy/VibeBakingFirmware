#!/usr/bin/env python3
"""Inject the arm-early wrapper into a boot image's ramdisk (D92). Builds only; nothing is flashed.

  python3 scripts/inject_hu_wrap_boot.py <base_boot> <wrapper_bin> <out> [--work DIR]
                                         [--cmdline-append " tokens"] [--partition-size N]

Why no extraction. The ramdisk cpio is a 13-field newc variant (measured: 110-byte headers, namesize
at header offset 94, filesize at 54, devmajor/devminor at 78/86). `cpio -idm` refuses it as a
non-root user (`dev/console: mknod() is not permitted`), and GNU cpio's own newc reader expects an
86-byte header, so extract-and-repack both loses device nodes and changes every header. This instead
walks the archive byte-by-byte: untouched entries are copied verbatim, the entry named `init` is
renamed to `init.real` with only its namesize/name bytes changed, and one new entry for `init`
holding the wrapper is inserted in place of the renamed one. Inodes, modes, devmajors/devminors,
uids/gids/nlinks and mtimes of everything else are carried unchanged.

Layout follows tools/rebuild_boot_faithful.py (**D60**): header page at 0..2047, kernel at 2048,
ramdisk at roundup(2048 + kernel_size), `second` at roundup(ramdisk_offset + ramdisk_size); from the
rebuilt content end onward the base image's own bytes verbatim. The header may differ only in
`ramdisk_size` (bytes 16..19) and, if asked for, inside the 512-byte cmdline field at 64..575; the
20-byte field at 576 is carried verbatim.

Self-checks: the repacked cpio re-parses with the same layout and the expected entry list; every
untouched entry is byte-identical; device nodes survive with their devmajor/devminor; components are
readable at the offsets a Rockchip loader computes; the tail is carried verbatim; DTBs inside
`second` move by the ramdisk delta while tail DTBs stay put; tail resource entries' SHA1s verify.
"""
import argparse
import gzip
import hashlib
import io
import os
import re
import struct
import sys

PAGE = 2048
CMDLINE_OFF, CMDLINE_LEN = 64, 512
DTB_MAGIC = re.compile(re.escape(b'\xd0\x0d\xfe\xed'))
RESOURCE_MAGIC = re.compile(re.escape(b'RSCE'))
ENTRY_RECORD = 512
ENTRY_NAME_OFF, ENTRY_HASH_OFF, ENTRY_HASH_LEN_OFF, ENTRY_OFF_OFF, ENTRY_SIZE_OFF = 4, 224, 256, 260, 264

# measured cpio header layout (see docstring)
CPIO_MAGIC = b'070701'
CPIO_HDR = 110
F_INODE, F_MODE, F_UID, F_GID, F_NLINK = 6, 14, 22, 30, 38
F_SIZE_HI, F_SIZE, F_UNK7, F_MTIME, F_DEVMJ, F_DEVMN, F_NAMESIZE, F_UNK12 = 46, 54, 62, 70, 78, 86, 94, 102
TRAILER = 'TRAILER!!!'
DEFAULT_PARTITION_SIZE = 33554432


def roundup(n: int) -> int:
    return ((n + PAGE - 1) // PAGE) * PAGE


def offsets(d: bytes):
    ks = struct.unpack_from('<I', d, 8)[0]
    rs = struct.unpack_from('<I', d, 16)[0]
    ss = struct.unpack_from('<I', d, 24)[0]
    ro = roundup(PAGE + ks)
    so = roundup(ro + rs)
    return ks, rs, ss, ro, so


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def hex_field(d: bytearray, off: int, val: int) -> None:
    d[off:off + 8] = b'%08x' % val


def read_field(d: bytes, off: int) -> int:
    return int(d[off:off + 8], 16)


def parse_cpio(raw: bytes):
    """Walk the archive; entries carry their header bytes, name bytes and data bytes verbatim."""
    out = []
    p = 0
    while True:
        if raw[p:p + 6] != CPIO_MAGIC:
            raise SystemExit(f"cpio: no magic at {p:,} ({raw[p:p+12]!r})")
        hdr = bytearray(raw[p:p + CPIO_HDR])
        ns = read_field(hdr, F_NAMESIZE)
        fs = read_field(hdr, F_SIZE)
        if ns == 0 or ns > 256 or fs > len(raw):
            raise SystemExit(f"cpio: implausible header at {p:,} (namesize={ns}, filesize={fs:,})")
        name_raw = raw[p + CPIO_HDR:p + CPIO_HDR + ns]
        if len(name_raw) != ns:
            raise SystemExit(f"cpio: name truncated at {p:,}")
        name = name_raw.rstrip(b'\x00').decode(errors='replace')
        if not all(32 <= c < 127 or c == 0 for c in name_raw):
            raise SystemExit(f"cpio: non-printable name at {p:,}: {name_raw!r}")
        ds = ((p + CPIO_HDR + ns + 3) // 4) * 4
        pad = raw[p + CPIO_HDR + ns:ds]
        data = raw[ds:ds + fs]
        if len(data) != fs:
            raise SystemExit(f"cpio: entry {name!r} at {p:,} claims {fs:,} B but only {len(data):,} B remain")
        out.append({'off': p, 'hdr': hdr, 'name': name, 'data': data, 'pad': pad,
                    'inode': read_field(hdr, F_INODE), 'mode': read_field(hdr, F_MODE),
                    'devmj': read_field(hdr, F_DEVMJ), 'devmn': read_field(hdr, F_DEVMN),
                    'size': fs, 'namesize': ns})
        p = ((ds + fs + 3) // 4) * 4
        if name == TRAILER:
            break
        if p > len(raw):
            raise SystemExit(f"cpio: ran past the end of the archive at {p:,}")
    return out, raw[p:]


def build_cpio(entries: list, trailer_tail: bytes) -> bytes:
    b = bytearray()
    for e in entries:
        name = e['name'].encode() + b'\x00'
        hdr = bytearray(e['hdr'])
        hex_field(hdr, F_NAMESIZE, len(name))
        hex_field(hdr, F_SIZE, len(e['data']))
        b += hdr + name
        pad_len = ((len(b) + 3) // 4) * 4 - len(b)
        b += b'\x00' * pad_len
        b += e['data']
        pad_len = ((len(b) + 3) // 4) * 4 - len(b)
        b += b'\x00' * pad_len
    return bytes(b) + trailer_tail


def swap_init(raw: bytes, wrapper: bytes):
    """Rename `init` -> `init.real` in place and insert the wrapper as `init` at that position."""
    entries, tail = parse_cpio(raw)
    if len(entries) < 2 or entries[-1]['name'] != TRAILER:
        raise SystemExit("cpio: no trailer entry")
    idx = [i for i, e in enumerate(entries) if e['name'] == 'init']
    if len(idx) != 1:
        raise SystemExit(f"cpio: expected exactly one /init entry, found {len(idx)}")
    i = idx[0]
    orig = entries[i]
    if orig['mode'] & 0xF000 != 0x8000:
        raise SystemExit(f"cpio: /init is not a regular file (mode {oct(orig['mode'])})")
    renamed = dict(orig)
    renamed['hdr'] = bytearray(orig['hdr'])
    renamed['name'] = 'init.real'
    renamed['data'] = orig['data']
    renamed['namesize'] = len('init.real') + 1
    wrap = dict(orig)
    wrap['hdr'] = bytearray(orig['hdr'])
    wrap['name'] = 'init'
    wrap['data'] = wrapper
    wrap['mode'] = 0o100755
    wrap['inode'] = max(e['inode'] for e in entries) + 1
    wrap['size'] = len(wrapper)
    wrap['devmj'] = 0
    wrap['devmn'] = 0
    wrap['namesize'] = len('init') + 1
    hex_field(wrap['hdr'], F_MODE, wrap['mode'])
    hex_field(wrap['hdr'], F_INODE, wrap['inode'])
    hex_field(wrap['hdr'], F_SIZE_HI, 0)
    hex_field(wrap['hdr'], F_SIZE, wrap['size'])
    hex_field(wrap['hdr'], F_DEVMJ, 0)
    hex_field(wrap['hdr'], F_DEVMN, 0)
    # the wrapper sits before the renamed real init, matching how init resolves /init first
    new_entries = entries[:i] + [wrap, renamed] + entries[i + 1:]
    out = build_cpio(new_entries, tail)
    return out, new_entries, orig


def gzip_deterministic(payload: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', mtime=0, filename='') as g:
        g.write(payload)
    return buf.getvalue()


def gunzip(span: bytes) -> bytes:
    if span[:2] != b'\x1f\x8b':
        raise SystemExit(f"ramdisk span is not gzip (magic {span[:4].hex()})")
    return gzip.decompress(span)


def dtb_positions(d: bytes):
    out = []
    for m in DTB_MAGIC.finditer(d):
        total = struct.unpack_from('>I', d, m.start() + 4)[0]
        if total and m.start() + total <= len(d):
            out.append((m.start(), total))
    return out


def resource_entries(d: bytes, base: int):
    n = struct.unpack_from('<I', d, base + 12)[0]
    out = []
    for i in range(n):
        e = base + ENTRY_RECORD * (i + 1)
        if d[e:e + 4] != b'ENTR':
            continue
        name = d[e + ENTRY_NAME_OFF:e + ENTRY_NAME_OFF + 220].split(b'\x00')[0].decode(errors='replace')
        declared = d[e + ENTRY_HASH_OFF:e + ENTRY_HASH_OFF + 20]
        blocks = struct.unpack_from('<I', d, e + ENTRY_OFF_OFF)[0]
        size = struct.unpack_from('<I', d, e + ENTRY_SIZE_OFF)[0]
        pos = base + blocks * 512
        data = d[pos:pos + size]
        h = hashlib.sha1(data).hexdigest()
        out.append({'name': name, 'pos': pos, 'size': size, 'declared': declared.hex(), 'sha1': h, 'ok': h == declared.hex()})
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('base'); ap.add_argument('wrapper'); ap.add_argument('out')
    ap.add_argument('--work', default='/run/media/Daan/Opslagmonster/a14-work/tmp/hu-wrap-inject')
    ap.add_argument('--cmdline-append', default='')
    ap.add_argument('--partition-size', type=int, default=DEFAULT_PARTITION_SIZE)
    a = ap.parse_args(argv[1:])

    base = open(a.base, 'rb').read()
    wrapper = open(a.wrapper, 'rb').read()
    if base[:8] != b'ANDROID!':
        raise SystemExit("base image does not carry the ANDROID! magic")
    if wrapper[:4] != b'\x7fELF':
        raise SystemExit("wrapper is not an ELF binary")

    ks, rs, ss, ro, so = offsets(base)
    content_end = roundup(so + ss)
    kernel = base[PAGE:PAGE + ks]
    second = base[so:so + ss]
    rd_span = base[ro:roundup(ro + rs)]
    old_raw = gunzip(rd_span)

    res_positions = [m.start() for m in RESOURCE_MAGIC.finditer(base) if m.start() >= content_end]
    tail_res_start = min(res_positions) if res_positions else None
    if tail_res_start is None:
        print(f"note: base carries no RSCE header at or after its content end ({content_end:,} B); the tail is carried verbatim only")

    new_raw, entries, orig = swap_init(old_raw, wrapper)
    new_rd = gzip_deterministic(new_raw)
    rd_span_new = new_rd + b'\x00' * (roundup(len(new_rd)) - len(new_rd))

    # gate: repacked archive re-parses, untouched entries byte-identical, device nodes preserved
    re_entries, re_tail = parse_cpio(new_raw)
    key = lambda es: [(e['name'], e['mode'], e['inode'], e['devmj'], e['devmn'], e['size'], e['data']) for e in es]
    if key(re_entries) != key(entries):
        raise SystemExit("self-check failed: repacked archive does not re-parse to the expected entry list")
    old_entries, old_tail = parse_cpio(old_raw)
    if re_tail != old_tail:
        raise SystemExit(f"self-check failed: trailing bytes after the trailer changed ({len(old_tail)} -> {len(re_tail)})")
    old_by_name = {e['name']: e for e in old_entries}
    new_by_name = {e['name']: e for e in entries}
    if 'init.real' not in new_by_name or new_by_name['init.real']['data'] != old_by_name['init']['data']:
        raise SystemExit("self-check failed: /init.real is not the original /init bytes")
    if new_by_name['init']['data'] != wrapper:
        raise SystemExit("self-check failed: /init is not the wrapper bytes")
    if new_by_name['init']['mode'] != 0o100755:
        raise SystemExit(f"self-check failed: /init mode {oct(new_by_name['init']['mode'])}, expected 0o100755")
    changed = {'init', 'init.real'}
    for e in old_entries:
        if e['name'] in changed or e['name'] == TRAILER:
            continue
        n = new_by_name[e['name']]
        if n['data'] != e['data'] or n['mode'] != e['mode'] or n['inode'] != e['inode'] \
           or n['devmj'] != e['devmj'] or n['devmn'] != e['devmn']:
            raise SystemExit(f"self-check failed: entry {e['name']!r} changed")
    dev_nodes = [e['name'] for e in old_entries if e['devmj'] or e['devmn']]
    for name in dev_nodes:
        if name not in new_by_name:
            raise SystemExit(f"self-check failed: device node {name} lost")
    if old_tail:
        print(f"note: base cpio carries {len(old_tail)} bytes after its trailer entry; they are carried verbatim")
    names = [e['name'] for e in entries]
    print(f"ramdisk entries {len(entries)}: {names}")
    print(f"         device nodes carried: {dev_nodes or '(none)'}")

    hdr = bytearray(base[:PAGE])
    struct.pack_into('<I', hdr, 16, len(new_rd))
    if a.cmdline_append:
        cur = hdr[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN].split(b'\x00')[0]
        s = cur + a.cmdline_append.encode()
        if len(s) > CMDLINE_LEN:
            raise SystemExit(f"cmdline would be {len(s)} B, past the {CMDLINE_LEN} B field")
        hdr[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = s + b'\x00' * (CMDLINE_LEN - len(s))

    new_ro = roundup(PAGE + ks)
    new_so = roundup(new_ro + len(rd_span_new))
    new_content_end = roundup(new_so + ss)
    if new_content_end > a.partition_size:
        raise SystemExit(f"components reach {new_content_end:,} B, past the partition's {a.partition_size:,} B")
    if tail_res_start is not None and new_content_end > tail_res_start:
        raise SystemExit(f"components reach {new_content_end:,} B, past the tail resource header at {tail_res_start:,} B")

    body = bytearray(hdr) + kernel
    body += b'\x00' * (new_ro - len(body))
    body += rd_span_new
    body += b'\x00' * (new_so - len(body)) + second
    body += b'\x00' * (new_content_end - len(body))
    if len(body) != new_content_end:
        raise SystemExit(f"assembled content is {len(body):,} B, not the loader's content end {new_content_end:,} B")

    if len(base) < new_content_end:
        raise SystemExit(
            f"base image ends at {len(base):,} B, before the new content end {new_content_end:,} B. "
            f"Zero-filling that span would overwrite partition bytes the boot chain reads, so this is refused. "
            f"Rebuild the base with tools/rebuild_boot_faithful.py (**D67**) so the tail is carried verbatim, "
            f"then inject into that image.")
    out = bytes(body) + base[new_content_end:]
    if len(out) > a.partition_size:
        raise SystemExit(f"content plus the base tail is {len(out):,} B, past the partition's {a.partition_size:,} B")
    out += b'\x00' * (a.partition_size - len(out))
    tail_note = f"tail carried verbatim from {new_content_end:,} B ({len(base) - new_content_end:,} B), padded to {a.partition_size:,} B"
    k2, r2, s2, ro2, so2 = offsets(out)
    if out[PAGE:PAGE + ks] != kernel or out[so2:so2 + ss] != second or out[ro2:ro2 + len(rd_span_new)] != rd_span_new:
        raise SystemExit("self-check failed: a component is not readable at its computed offset")
    if len(base) > new_content_end and out[new_content_end:len(base)] != base[new_content_end:]:
        raise SystemExit("self-check failed: the tail is not carried verbatim from the new content end")
    found = dtb_positions(out)
    in_second = [(p, t) for p, t in dtb_positions(base) if so <= p < so + ss]
    tail_dtbs = [(p, t) for p, t in dtb_positions(base) if tail_res_start is not None and p >= tail_res_start]
    expected = sorted([(new_so + (p - so), t) for p, t in in_second] + tail_dtbs)
    if sorted(found) != expected:
        raise SystemExit(f"DTB positions changed: expected {expected} vs rebuilt {sorted(found)}")
    entries_res = resource_entries(out, tail_res_start) if tail_res_start is not None else []
    if entries_res and any(not e['ok'] for e in entries_res):
        raise SystemExit(f"tail resource entries failed: {[(e['name'], e['declared'][:12], e['sha1'][:12]) for e in entries_res]}")

    allowed = [(16, 19)] + ([(CMDLINE_OFF, CMDLINE_OFF + CMDLINE_LEN - 1)] if a.cmdline_append else [])
    bad, start, last = [], None, None
    for i in range(PAGE):
        if base[i] != out[i]:
            start = i if start is None else start
            last = i
        elif start is not None:
            if not any(al <= start and last <= ab for al, ab in allowed):
                bad.append((start, last))
            start = None
    if start is not None and not any(al <= start and last <= ab for al, ab in allowed):
        bad.append((start, last))
    if bad:
        raise SystemExit(f"header changed outside the allowed fields: {bad}")

    print(f"base     size {len(base):,} sha256 {sha(base)[:12]}  kernel {sha(kernel)[:12]}  second {sha(second)[:12]}")
    print(f"         ramdisk gz {rs:,} B @{ro:,} sha256 {sha(rd_span)[:12]}  cpio {len(old_raw):,} B")
    print(f"wrapper  size {len(wrapper):,} sha256 {sha(wrapper)}")
    print(f"new      ramdisk gz {len(new_rd):,} B sha256 {sha(new_rd)[:12]}  cpio {len(new_raw):,} B @{new_ro:,}"
          f"  second @{new_so:,}  content end {new_content_end:,}")
    print(f"out      size {len(out):,} sha256 {sha(out)}")
    print(f"         {tail_note}")
    if tail_res_start is not None:
        for e in entries_res:
            print(f"         tail entry {e['name']} @{e['pos']:,} {e['size']:,} B sha1 {e['sha1'][:12]} {'MATCHES declared' if e['ok'] else 'MISMATCH'}")
    if a.cmdline_append:
        s = out[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN].split(b'\x00')[0]
        print(f"         cmdline field now: {s.decode()}")
    print(f"         header diff ranges: ramdisk_size bytes 16..19 only" +
          (", plus cmdline 64..575" if a.cmdline_append else ""))
    print("self-check OK: entry list preserved, untouched entries byte-identical, device nodes kept, "
          "components readable, tail verbatim, DTBs and resource entries verified")
    open(a.out, 'wb').write(out)
    print(f"wrote {a.out}")


if __name__ == '__main__':
    main(sys.argv)
