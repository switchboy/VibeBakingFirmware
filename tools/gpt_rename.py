#!/usr/bin/env python3
"""tools/gpt_rename.py - rename GPT partition names offline, from extracted blobs.

This tool never opens a block device and never talks to the head unit. It works on two
extracted blobs of the card:

  --head  the first 34 sectors (protective MBR, primary GPT header at LBA1,
          primary partition entry array at LBA2..)
  --tail  the last 33 sectors (backup partition entry array, backup GPT header at the
          last sector)

For every --rename N:OLD:NEW it refuses unless entry N holds exactly OLD in BOTH the
primary and the backup entry array, writes NEW as UTF-16LE zero-padded to the name field
(bytes 56..entry_size-1), recomputes the partition-entry-array CRC32 and the header CRC32
for BOTH headers, and then self-verifies before/after writing:

  (a) the input blobs parse and their stored CRCs are valid;
  (b) the primary and backup entry arrays are byte-identical, before and after;
  (c) the only bytes that differ between input and output are the two renamed name fields
      (in both arrays) and the two CRC fields of each header (header CRC at header offset
      16, entry-array CRC at header offset 88);
  (d) the output blobs re-parse with valid CRCs and the new names;
  (e) the protective MBR (sector 0) is untouched.

Header layout is the one GPT fdisk / this card use (header_size 92): my_lba@24,
alt_lba@32, first_usable@40, last_usable@48, disk GUID@56, flags@72, entry count@80,
entry size@84, entry-array CRC@88. Partition entries are the standard 128-byte struct:
type GUID@0, unique GUID@16, first LBA@32, last LBA@40, attributes@48, name@56..127.

Python 3 stdlib only: argparse, hashlib, struct, sys, zlib.

  gpt_rename.py --head head34.bin --tail tail33.bin --disk-sectors 15523840 \
      --rename 12:metadata:sd_metadata --rename 14:super:sd_super \
      --out-head new-head34.bin --out-tail new-tail33.bin
  gpt_rename.py --verify head34.bin tail33.bin            (parse + CRC check only)

Exit status: 0 ok, 1 refused, 2 bad usage.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import zlib

SECTOR = 512
GPT_SIG = b"EFI PART"
MBR_SIG = b"\x55\xAA"
PROTECTIVE_MBR_TYPE = 0xEE
NULL_GUID = b"\x00" * 16

HDR_SIZE_OFF = 12
HDR_CRC_OFF = 16
RESERVED_OFF = 20
MY_LBA_OFF = 24
ALT_LBA_OFF = 32
FIRST_USABLE_OFF = 40
LAST_USABLE_OFF = 48
DISK_GUID_OFF = 56
FLAGS_OFF = 72
COUNT_OFF = 80
ENTRY_SIZE_OFF = 84
ENTRIES_CRC_OFF = 88

NAME_OFF = 56
NAME_BYTES = 72
MAX_NAME_CHARS = 36

# Entry fields, standard 128-byte GPT partition entry.
ENTRY_FIRST_LBA_OFF = 32
ENTRY_LAST_LBA_OFF = 40
ENTRY_ATTRS_OFF = 48


class Refuse(Exception):
    """Anything that must stop the tool before a byte is written."""


def u32(block: bytes, off: int) -> int:
    return struct.unpack_from("<I", block, off)[0]


def u64(block: bytes, off: int) -> int:
    return struct.unpack_from("<Q", block, off)[0]


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def header_crc(block: bytes, hdr_size: int) -> int:
    """CRC32 over header_size bytes with the 4-byte CRC field at offset 16 zeroed."""
    return crc32(block[:HDR_CRC_OFF] + b"\x00" * 4 + block[HDR_CRC_OFF + 4:hdr_size])


def decode_name(entry: bytes, entry_size: int) -> str:
    raw = entry[NAME_OFF:entry_size]
    if len(raw) % 2:
        raise Refuse("name field is not a whole number of UTF-16 code units")
    try:
        text = raw.decode("utf-16-le")
    except UnicodeDecodeError as exc:
        raise Refuse(f"name field is not valid UTF-16LE: {exc}") from exc
    return text.rstrip("\x00")


def encode_name(new_name: str, entry_size: int) -> bytes:
    if not new_name:
        raise Refuse("new name must not be empty")
    if len(new_name) > MAX_NAME_CHARS:
        raise Refuse(
            f"new name {new_name!r} is {len(new_name)} chars, the limit is "
            f"{MAX_NAME_CHARS} UTF-16 code units in the {entry_size - NAME_OFF}-byte name field"
        )
    if any(ord(ch) > 127 for ch in new_name):
        raise Refuse(f"new name {new_name!r} is not pure ASCII")
    field = entry_size - NAME_OFF
    encoded = new_name.encode("utf-16-le")
    if len(encoded) > field:
        raise Refuse(
            f"new name {new_name!r} needs {len(encoded)} bytes, name field is {field} bytes"
        )
    if len(encoded) == field:
        print(f"warning: {new_name!r} fills the name field, there is no terminating NUL")
    return encoded + b"\x00" * (field - len(encoded))


class Card:
    """The two blobs, parsed."""

    def __init__(self, head: bytes, tail: bytes, disk_sectors: int | None, head_name: str, tail_name: str):
        self.head_name = head_name
        self.tail_name = tail_name
        self.disk_sectors = disk_sectors
        self.head = head
        self.tail = tail
        self.mbr = head[:SECTOR]
        self.phdr = head[SECTOR:2 * SECTOR]
        self.pe = head[2 * SECTOR:]
        self.bhdr = tail[len(tail) - SECTOR:]
        self.be = tail[:len(tail) - SECTOR]

    # -- structural -------------------------------------------------------

    def _check_header(self, block: bytes, label: str) -> dict:
        if block[:8] != GPT_SIG:
            raise Refuse(f"{label}: signature is {block[:8]!r}, not {GPT_SIG!r}")
        rev = u32(block, 8)
        if rev not in (0x00010000, 0x00000001):
            raise Refuse(f"{label}: unexpected GPT revision 0x{rev:08x}")
        hdr_size = u32(block, HDR_SIZE_OFF)
        if hdr_size < 92 or hdr_size > SECTOR:
            raise Refuse(f"{label}: header_size {hdr_size} outside 92..{SECTOR}")
        if ENTRIES_CRC_OFF + 4 > hdr_size:
            raise Refuse(f"{label}: header_size {hdr_size} does not cover the entry-array CRC field at 88")
        if u32(block, RESERVED_OFF) != 0:
            raise Refuse(f"{label}: reserved field at offset 20 is {u32(block, RESERVED_OFF)}, must be 0")
        stored = u32(block, HDR_CRC_OFF)
        computed = header_crc(block, hdr_size)
        if stored != computed:
            raise Refuse(f"{label}: header CRC {stored:#010x} != computed {computed:#010x} (over {hdr_size} bytes)")
        return {"rev": rev, "hdr_size": hdr_size, "crc": stored}

    def parse(self) -> None:
        head_len = len(self.head)
        tail_len = len(self.tail)
        if head_len < 2 * SECTOR:
            raise Refuse(f"{self.head_name}: {head_len} bytes, too short to hold MBR + header")
        if tail_len < SECTOR:
            raise Refuse(f"{self.tail_name}: {tail_len} bytes, too short to hold a header")
        self.entries_len = head_len - 2 * SECTOR
        if self.entries_len <= 0 or self.entries_len % SECTOR:
            raise Refuse(
                f"{self.head_name}: entry area is {self.entries_len} bytes, must be a whole "
                f"number of {SECTOR}-byte sectors"
            )
        if tail_len != self.entries_len + SECTOR:
            raise Refuse(
                f"{self.tail_name}: {tail_len} bytes, expected {self.entries_len + SECTOR} "
                f"(entry area {self.entries_len} + one header sector)"
            )

        self.pinfo = self._check_header(self.phdr, f"{self.head_name} primary header (sector 1)")
        self.binfo = self._check_header(self.bhdr, f"{self.tail_name} backup header (last sector)")
        self.num_entries = u32(self.phdr, COUNT_OFF)
        self.entry_size = u32(self.phdr, ENTRY_SIZE_OFF)
        self.entry_sectors = self.entries_len // SECTOR

        if self.num_entries != u32(self.bhdr, COUNT_OFF) or self.entry_size != u32(self.bhdr, ENTRY_SIZE_OFF):
            raise Refuse(
                f"entry count/size differ between headers: primary {self.num_entries}x{self.entry_size}, "
                f"backup {u32(self.bhdr, COUNT_OFF)}x{u32(self.bhdr, ENTRY_SIZE_OFF)}"
            )
        if self.num_entries < 1 or self.entry_size < 128:
            raise Refuse(f"implausible entry geometry: {self.num_entries} entries x {self.entry_size} bytes")
        if self.num_entries * self.entry_size != self.entries_len:
            raise Refuse(
                f"geometry mismatch: {self.num_entries} x {self.entry_size} = "
                f"{self.num_entries * self.entry_size} bytes but the entry area is {self.entries_len} bytes"
            )
        if self.entry_size <= NAME_OFF:
            raise Refuse(f"entry size {self.entry_size} has no room for the name field at {NAME_OFF}")

        if self.phdr[DISK_GUID_OFF:DISK_GUID_OFF + 16] != self.bhdr[DISK_GUID_OFF:DISK_GUID_OFF + 16]:
            raise Refuse(
                "disk GUID differs between primary and backup headers: "
                f"{self.phdr[DISK_GUID_OFF:DISK_GUID_OFF + 16].hex()} vs {self.bhdr[DISK_GUID_OFF:DISK_GUID_OFF + 16].hex()}"
            )

        p_crc = u32(self.phdr, ENTRIES_CRC_OFF)
        b_crc = u32(self.bhdr, ENTRIES_CRC_OFF)
        pe_crc = crc32(self.pe)
        be_crc = crc32(self.be)
        if p_crc != pe_crc:
            raise Refuse(
                f"{self.head_name}: primary entry-array CRC {p_crc:#010x} != computed {pe_crc:#010x} "
                f"(over {self.entries_len} bytes)"
            )
        if b_crc != be_crc:
            raise Refuse(
                f"{self.tail_name}: backup entry-array CRC {b_crc:#010x} != computed {be_crc:#010x} "
                f"(over {self.entries_len} bytes)"
            )
        if self.pe != self.be:
            raise Refuse(
                "primary and backup entry arrays are not byte-identical: "
                f"they differ at offset {next(i for i in range(self.entries_len) if self.pe[i] != self.be[i])}"
            )

        self._check_mbr()
        self._check_lbas()

    def _check_mbr(self) -> None:
        mbr = self.mbr
        if mbr[510:512] != MBR_SIG:
            raise Refuse(f"{self.head_name}: sector 0 has MBR signature {mbr[510:512]!r}, not 0x55AA")
        if mbr[446 + 4] != PROTECTIVE_MBR_TYPE:
            raise Refuse(
                f"{self.head_name}: sector 0 partition record 1 type is "
                f"0x{mbr[446 + 4]:02x}, not the protective 0xEE"
            )
        count = u32(mbr, 446 + 8 + 4)
        if self.disk_sectors is not None and count not in (0xFFFFFFFF, min(self.disk_sectors - 1, 0xFFFFFFFF)):
            print(f"warning: protective MBR covers {count} sectors, disk is {self.disk_sectors}")

    def _check_lbas(self) -> None:
        """Cross-check the header LBAs against the blob sizes / the disk size (fatal)."""
        p_my = u64(self.phdr, MY_LBA_OFF)
        p_alt = u64(self.phdr, ALT_LBA_OFF)
        b_my = u64(self.bhdr, MY_LBA_OFF)
        b_alt = u64(self.bhdr, ALT_LBA_OFF)
        if p_my != 1:
            raise Refuse(f"primary header my_lba is {p_my}, expected 1")
        if b_alt != 1:
            raise Refuse(f"backup header alt_lba is {b_alt}, expected 1")
        if p_alt != b_my:
            raise Refuse(f"primary alt_lba {p_alt} != backup my_lba {b_my}")
        if u64(self.phdr, FIRST_USABLE_OFF) != u64(self.bhdr, FIRST_USABLE_OFF):
            raise Refuse("first usable LBA differs between the two headers")
        if u64(self.phdr, LAST_USABLE_OFF) != u64(self.bhdr, LAST_USABLE_OFF):
            raise Refuse("last usable LBA differs between the two headers")
        first = u64(self.phdr, FIRST_USABLE_OFF)
        last = u64(self.phdr, LAST_USABLE_OFF)
        if self.disk_sectors is None:
            return
        want_backup_header = self.disk_sectors - 1
        want_first = 2 + self.entry_sectors
        want_last = self.disk_sectors - 2 - self.entry_sectors
        if p_alt != want_backup_header:
            raise Refuse(
                f"backup header LBA {p_alt} != disk_sectors-1 ({want_backup_header}); the tail blob "
                f"is not the last sectors of a {self.disk_sectors}-sector disk"
            )
        if first != want_first:
            raise Refuse(f"first usable LBA {first} != {want_first} for LBA1 header + {self.entry_sectors} entry sectors")
        if last != want_last:
            raise Refuse(f"last usable LBA {last} != {want_last} for a {self.disk_sectors}-sector disk")
        if b_my != want_backup_header:
            raise Refuse(f"backup header my_lba {b_my} != {want_backup_header}")

    # -- rename -----------------------------------------------------------

    def parse_rename(self, spec: str) -> tuple[int, str, str]:
        parts = spec.split(":")
        if len(parts) != 3:
            raise Refuse(f"--rename {spec!r}: expected N:OLD:NEW")
        idx_s, old, new = parts
        try:
            idx = int(idx_s)
        except ValueError as exc:
            raise Refuse(f"--rename {spec!r}: partition number {idx_s!r} is not an integer") from exc
        if idx < 1 or idx > self.num_entries:
            raise Refuse(f"--rename {spec!r}: partition {idx} outside 1..{self.num_entries}")
        if not old:
            raise Refuse(f"--rename {spec!r}: old name must not be empty")
        return idx, old, new

    def entry(self, arr: bytes, idx: int) -> bytes:
        return arr[(idx - 1) * self.entry_size:idx * self.entry_size]

    def apply(self, renames: list[tuple[int, str, str]]) -> tuple[bytes, bytes, list[str]]:
        seen: set[int] = set()
        head_out = bytearray(self.head)
        tail_out = bytearray(self.tail)
        notes: list[str] = []
        for idx, old, new in renames:
            if idx in seen:
                raise Refuse(f"two --rename specs both target partition {idx}")
            seen.add(idx)
            p_name = decode_name(self.entry(self.pe, idx), self.entry_size)
            b_name = decode_name(self.entry(self.be, idx), self.entry_size)
            if p_name != old:
                raise Refuse(f"partition {idx}: primary array holds {p_name!r}, not {old!r}")
            if b_name != old:
                raise Refuse(f"partition {idx}: backup array holds {b_name!r}, not {old!r}")
            field = self.entry_size - NAME_OFF
            new_field = encode_name(new, self.entry_size)
            base_head = 2 * SECTOR + (idx - 1) * self.entry_size + NAME_OFF
            base_tail = (idx - 1) * self.entry_size + NAME_OFF
            head_out[base_head:base_head + field] = new_field
            tail_out[base_tail:base_tail + field] = new_field
            notes.append(f"partition {idx}: {old!r} -> {new!r}")
        # Recompute CRCs: entry array first, then the header that covers it.
        pe_out = bytes(head_out[2 * SECTOR:])
        be_out = bytes(tail_out[:self.entries_len])
        if pe_out != be_out:
            raise Refuse("primary and backup entry arrays diverged while renaming")
        new_entries_crc = crc32(pe_out)
        head_out[SECTOR + ENTRIES_CRC_OFF:SECTOR + ENTRIES_CRC_OFF + 4] = struct.pack("<I", new_entries_crc)
        tail_out[self.entries_len + ENTRIES_CRC_OFF:self.entries_len + ENTRIES_CRC_OFF + 4] = struct.pack("<I", new_entries_crc)
        new_hdr_crc_p = header_crc(bytes(head_out[SECTOR:2 * SECTOR]), self.pinfo["hdr_size"])
        new_hdr_crc_b = header_crc(bytes(tail_out[self.entries_len:]), self.binfo["hdr_size"])
        head_out[SECTOR + HDR_CRC_OFF:SECTOR + HDR_CRC_OFF + 4] = struct.pack("<I", new_hdr_crc_p)
        tail_out[self.entries_len + HDR_CRC_OFF:self.entries_len + HDR_CRC_OFF + 4] = struct.pack("<I", new_hdr_crc_b)
        notes.append(f"entry-array CRC {u32(self.phdr, ENTRIES_CRC_OFF):#010x} -> {new_entries_crc:#010x} (both headers)")
        notes.append(f"primary header CRC {self.pinfo['crc']:#010x} -> {new_hdr_crc_p:#010x}")
        notes.append(f"backup header CRC {self.binfo['crc']:#010x} -> {new_hdr_crc_b:#010x}")
        return bytes(head_out), bytes(tail_out), notes

    # -- reporting --------------------------------------------------------

    def table(self, head: bytes | None = None, tail: bytes | None = None) -> list[str]:
        head = self.head if head is None else head
        tail = self.tail if tail is None else tail
        pe = head[2 * SECTOR:]
        be = tail[:self.entries_len]
        lines = []
        for i in range(self.num_entries):
            e = pe[i * self.entry_size:(i + 1) * self.entry_size]
            if e[:16] == NULL_GUID:
                continue
            first = u64(e, ENTRY_FIRST_LBA_OFF)
            last = u64(e, ENTRY_LAST_LBA_OFF)
            attrs = u64(e, ENTRY_ATTRS_OFF)
            name = decode_name(e, self.entry_size)
            backup_same = decode_name(be[i * self.entry_size:(i + 1) * self.entry_size], self.entry_size) == name
            lines.append(
                f"  p{i + 1:<3} sectors {first}..{last} ({last - first + 1}) attrs={attrs:#x} "
                f"name={name!r} backup={'same' if backup_same else 'DIFFERENT'}"
            )
        return lines

    def crc_report(self, head: bytes, tail: bytes) -> tuple[bool, list[str]]:
        """Re-parse output blobs (d) and report CRC validity."""
        lines = []
        ok = True
        ph = head[SECTOR:2 * SECTOR]
        bh = tail[len(tail) - SECTOR:]
        for label, block in (("primary", ph), ("backup", bh)):
            hdr_size = u32(block, HDR_SIZE_OFF)
            stored = u32(block, HDR_CRC_OFF)
            computed = header_crc(block, hdr_size)
            ent_stored = u32(block, ENTRIES_CRC_OFF)
            ent_computed = crc32(head[2 * SECTOR:] if label == "primary" else tail[:self.entries_len])
            good = stored == computed and ent_stored == ent_computed
            ok = ok and good
            lines.append(
                f"  {label} header: hdr_size={hdr_size} stored header CRC {stored:#010x} computed {computed:#010x} "
                f"({'OK' if stored == computed else 'BAD'}) | entry-array CRC stored {ent_stored:#010x} "
                f"computed {ent_computed:#010x} ({'OK' if ent_stored == ent_computed else 'BAD'})"
            )
        return ok, lines


def allowed_diff_ranges(card: Card, renames: list[tuple[int, str, str]]) -> list[tuple[int, int, str]]:
    """Half-open byte ranges the rewrite is allowed to touch."""
    ranges: list[tuple[int, int, str]] = []
    field = card.entry_size - NAME_OFF
    for idx, _old, _new in renames:
        ranges.append((2 * SECTOR + (idx - 1) * card.entry_size + NAME_OFF,
                       2 * SECTOR + (idx - 1) * card.entry_size + NAME_OFF + field,
                       f"head: partition {idx} name field (primary entry array)"))
        ranges.append(((idx - 1) * card.entry_size + NAME_OFF,
                       (idx - 1) * card.entry_size + NAME_OFF + field,
                       f"tail: partition {idx} name field (backup entry array)"))
    ranges.append((SECTOR + HDR_CRC_OFF, SECTOR + HDR_CRC_OFF + 4, "head: primary header CRC field (header offset 16)"))
    ranges.append((SECTOR + ENTRIES_CRC_OFF, SECTOR + ENTRIES_CRC_OFF + 4, "head: primary header entry-array CRC field (header offset 88)"))
    tb = len(card.tail) - SECTOR
    ranges.append((tb + HDR_CRC_OFF, tb + HDR_CRC_OFF + 4, "tail: backup header CRC field (header offset 16)"))
    ranges.append((tb + ENTRIES_CRC_OFF, tb + ENTRIES_CRC_OFF + 4, "tail: backup header entry-array CRC field (header offset 88)"))
    return ranges


def diff_ranges(a: bytes, b: bytes) -> list[tuple[int, int]]:
    """Half-open ranges of differing bytes, byte-by-byte."""
    if len(a) != len(b):
        raise Refuse(f"length changed: {len(a)} -> {len(b)} bytes")
    out = []
    start = None
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            if start is None:
                start = i
        elif start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(a)))
    return out


def check_only_expected_diffs(card: Card, out_head: bytes, out_tail: bytes, renames: list[tuple[int, str, str]]) -> list[str]:
    """(c) nothing outside the name fields and the two CRC fields may change."""
    allowed = allowed_diff_ranges(card, renames)
    allowed_bytes = set()
    for lo, hi, _label in allowed:
        allowed_bytes.update(range(lo, hi))
    report = []
    for blob_name, before, after in ((card.head_name, card.head, out_head), (card.tail_name, card.tail, out_tail)):
        ranges = diff_ranges(before, after)
        if not ranges:
            report.append(f"{blob_name}: no bytes changed")
        for lo, hi in ranges:
            if hi - lo == 0:
                continue
            inside = all(i in allowed_bytes for i in range(lo, hi))
            label = next((lbl for a_lo, a_hi, lbl in allowed if lo >= a_lo and hi <= a_hi), None)
            report.append(
                f"{blob_name}: bytes {lo}..{hi - 1} ({hi - lo} bytes) "
                f"{label or 'NOT ALLOWED - outside the name/CRC fields'}"
            )
            if not inside:
                raise Refuse(f"{blob_name}: changed bytes {lo}..{hi - 1} are outside the allowed fields")
        if len(ranges) == 0:
            raise Refuse(f"{blob_name}: nothing changed at all (the rename did not alter any byte)")
    if out_head[:SECTOR] != card.head[:SECTOR]:
        raise Refuse("(e) protective MBR (sector 0) changed")
    report.append("head sector 0 (protective MBR): unchanged")
    return report


def read(path: str) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError as exc:
        raise Refuse(f"cannot read {path}: {exc}") from exc


def write(path: str, data: bytes) -> None:
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def cmd_verify(args: argparse.Namespace) -> int:
    head = read(args.verify[0])
    tail = read(args.verify[1])
    card = Card(head, tail, args.disk_sectors, args.verify[0], args.verify[1])
    try:
        card.parse()
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    print(f"head {args.verify[0]}: {len(head)} bytes ({len(head) // SECTOR} sectors)")
    print(f"tail {args.verify[1]}: {len(tail)} bytes ({len(tail) // SECTOR} sectors)")
    print(f"disk GUID {card.phdr[DISK_GUID_OFF:DISK_GUID_OFF + 16].hex()} | {card.num_entries} entries x {card.entry_size} bytes "
          f"| entry area {card.entry_sectors} sectors")
    print(f"first usable {u64(card.phdr, FIRST_USABLE_OFF)} | last usable {u64(card.phdr, LAST_USABLE_OFF)}")
    ok, lines = card.crc_report(head, tail)
    print("CRCs:")
    for line in lines:
        print(line)
    print("partitions:")
    for line in card.table():
        print(line)
    print("CRC VALID" if ok else "CRC INVALID")
    return 0 if ok else 1


def cmd_rename(args: argparse.Namespace) -> int:
    head = read(args.head)
    tail = read(args.tail)
    if args.out_head == args.head or args.out_tail == args.tail:
        raise Refuse("output path must not be an input path")
    if args.out_head == args.tail or args.out_tail == args.head:
        raise Refuse("output path must not be the other input path")
    if args.out_head == args.out_tail:
        raise Refuse("--out-head and --out-tail must differ")
    card = Card(head, tail, args.disk_sectors, args.head, args.tail)
    try:
        card.parse()  # (a)
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    print(f"parsed {len(head)}+{len(tail)} bytes: {card.num_entries} entries x {card.entry_size}, "
          f"entry area {card.entry_sectors} sectors, header_size {card.pinfo['hdr_size']}")
    print("input CRCs valid: primary header %s, backup header %s, entry array %s"
          % (f"{card.pinfo['crc']:#010x}", f"{card.binfo['crc']:#010x}", f"{u32(card.phdr, ENTRIES_CRC_OFF):#010x}"))
    print("primary and backup entry arrays are byte-identical (before)")

    renames = [card.parse_rename(spec) for spec in args.rename]
    try:
        out_head, out_tail, notes = card.apply(renames)  # (b) is enforced inside apply()
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    for note in notes:
        print(note)

    try:
        diff_report = check_only_expected_diffs(card, out_head, out_tail, renames)  # (c)
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    print("byte-diff ranges (input -> output):")
    for line in diff_report:
        print(f"  {line}")
    out_pe = out_head[2 * SECTOR:]
    out_be = out_tail[:card.entries_len]
    if out_pe != out_be:
        print("REFUSED: primary and backup entry arrays are not byte-identical after the rename", file=sys.stderr)
        return 1
    print("primary and backup entry arrays are byte-identical (after)")

    write(args.out_head, out_head)
    write(args.out_tail, out_tail)

    try:
        check_head = read(args.out_head)
        check_tail = read(args.out_tail)
    except Refuse as exc:
        print(f"REFUSED: cannot read back what was written: {exc}", file=sys.stderr)
        return 1
    if check_head != out_head or check_tail != out_tail:
        print("REFUSED: written bytes differ from what was verified", file=sys.stderr)
        return 1
    out_card = Card(check_head, check_tail, args.disk_sectors, args.out_head, args.out_tail)
    try:
        out_card.parse()
    except Refuse as exc:
        print(f"REFUSED: output does not re-parse cleanly: {exc}", file=sys.stderr)
        return 1
    ok, lines = out_card.crc_report(check_head, check_tail)
    if not ok:
        print("REFUSED: output CRCs are not valid", file=sys.stderr)
        return 1
    print("output CRCs:")
    for line in lines:
        print(line)
    for idx, _old, new in renames:
        p_name = decode_name(out_card.entry(out_card.pe, idx), out_card.entry_size)
        b_name = decode_name(out_card.entry(out_card.be, idx), out_card.entry_size)
        if p_name != new or b_name != new:
            print(f"REFUSED: partition {idx} name is primary={p_name!r} backup={b_name!r}, expected {new!r}", file=sys.stderr)
            return 1
        print(f"partition {idx} renamed to {new!r} in both arrays")
    print("partitions after:")
    for line in out_card.table():
        print(line)
    print(f"sha256 {args.out_head}: {sha256_of(check_head)}")
    print(f"sha256 {args.out_tail}: {sha256_of(check_tail)}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="rename GPT partition names in extracted head/tail blobs")
    ap.add_argument("--head", help="first 34 sectors blob (MBR + primary header + entries)")
    ap.add_argument("--tail", help="last 33 sectors blob (backup entries + backup header)")
    ap.add_argument("--disk-sectors", type=int, help="total sectors of the card, e.g. 15523840")
    ap.add_argument("--rename", action="append", metavar="N:OLD:NEW",
                    help="rename partition N from OLD to NEW (repeatable)")
    ap.add_argument("--out-head", help="write the new head blob here")
    ap.add_argument("--out-tail", help="write the new tail blob here")
    ap.add_argument("--verify", nargs=2, metavar=("FILEHEAD", "FILETAIL"),
                    help="only parse these two blobs and print the table with CRC validity")
    args = ap.parse_args(argv)

    try:
        if args.verify:
            if args.rename or args.out_head or args.out_tail:
                raise Refuse("--verify does not rename or write")
            return cmd_verify(args)
        if not args.head or not args.tail or not args.out_head or not args.out_tail:
            raise Refuse("rename mode needs --head, --tail, --out-head and --out-tail")
        if not args.rename:
            raise Refuse("rename mode needs at least one --rename N:OLD:NEW")
        if args.disk_sectors is None:
            raise Refuse("rename mode needs --disk-sectors so the header LBAs can be checked")
        return cmd_rename(args)
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
