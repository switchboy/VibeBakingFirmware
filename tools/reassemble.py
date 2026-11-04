#!/usr/bin/env python3
"""Reassemble Rockchip/AOSP blockimgdiff partition images.

The firmware update.zip ships partition payloads as:
  <part>.transfer.list   block commands (block size 4096, lines "new <count>,<a>,<b> ...")
  <part>.new.dat         raw payload: concatenation of every `new` chunk, in command order
  <part>.patch.dat       empty in this package (full flash, no diff)

Reconstruction rules (mirrors update_engine's blockimgdiff target config):
  new  <count>,<start>,<end> [more ranges]  -> take (end-start) blocks from new.dat, write at start
  zero <count>,<start>,<end> ...            -> write zeroes
  copy <count>,<src...>,<tgt...>            -> copy from the old partition (unsupported here)
  erase <count>,<start>,<end> ...           -> leave the region untouched (zeros in our output)

Usage:
  reassemble.py --dir <extracted update.zip> --out <outdir> [--partition system] [--size 1442840576]
"""
import argparse
import os
import sys
from pathlib import Path

BLOCK = 4096


def parse_transfer_list(path: Path):
    lines = [ln.strip() for ln in path.read_text().splitlines() if ln.strip()]
    version = int(lines[0])
    header = lines[1:4]
    body = lines[4:] if version >= 3 else lines[1:]
    commands = []
    for line in body:
        kind, rest = line.split(None, 1)
        numbers = [int(x) for x in rest.split(",")]
        count, values = numbers[0], numbers[1:]
        if count != len(values):
            raise ValueError(f"{path}: count {count} != {len(values)} values in '{line}'")
        ranges = [(values[i], values[i + 1]) for i in range(0, len(values), 2)]
        commands.append((kind, ranges))
    return version, header, commands


def reassemble(part: str, src_dir: Path, out_dir: Path, size: int | None = None):
    tl = src_dir / f"{part}.transfer.list"
    dat = src_dir / f"{part}.new.dat"
    if not tl.exists() or not dat.exists():
        print(f"skip {part}: missing transfer.list or new.dat")
        return None

    version, header, commands = parse_transfer_list(tl)

    new_blocks = sum(b - a for kind, ranges in commands if kind == "new" for a, b in ranges)
    dat_blocks = dat.stat().st_size // BLOCK
    if new_blocks != dat_blocks:
        raise ValueError(f"{part}: new.dat has {dat_blocks} blocks, transfer list wants {new_blocks}")

    span = max((b for kind, ranges in commands if kind != "erase" for a, b in ranges), default=0)
    image_size = size or (span * BLOCK)
    if size and span * BLOCK > size:
        raise ValueError(f"{part}: transfer list spans {span * BLOCK} > partition {size}")

    out = out_dir / f"{part}.img"
    out.parent.mkdir(parents=True, exist_ok=True)

    f = dat.open("rb")
    pos = 0
    written = 0
    with out.open("wb") as o:
        o.truncate(image_size)
        for kind, ranges in commands:
            if kind == "new":
                for start, end in ranges:
                    n = (end - start) * BLOCK
                    o.seek(start * BLOCK)
                    f.seek(pos)
                    chunk = f.read(n)
                    if len(chunk) != n:
                        raise ValueError(f"{part}: truncated payload at block {start}")
                    o.write(chunk)
                    pos += n
                    written += n
            elif kind == "zero":
                for start, end in ranges:
                    o.seek(start * BLOCK)
                    o.write(b"\0" * ((end - start) * BLOCK))
            elif kind == "copy":
                raise ValueError(f"{part}: transfer list contains 'copy'; a source image is required")
            elif kind == "erase":
                pass  # region stays zero-filled in our fresh image
            else:
                raise ValueError(f"{part}: unknown command '{kind}'")
        if pos != dat.stat().st_size:
            raise ValueError(f"{part}: {dat.stat().st_size - pos} payload bytes left unconsumed")
    f.close()
    print(f"{part}: version={version} header={header} image={out} size={image_size} "
          f"written={written} ({written / image_size:.1%})")
    return out


def read_resize_sizes(op_list: Path):
    """Parse dynamic_partitions_op_list 'resize <part> <bytes>' lines."""
    sizes = {}
    if op_list.exists():
        for line in op_list.read_text().splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] == "resize":
                sizes[parts[1]] = int(parts[2])
    return sizes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="extracted update.zip", help="extracted update.zip directory")
    ap.add_argument("--out", default="analysis/images/assembled", help="output directory")
    ap.add_argument("--partition", action="append", help="only reassemble these partitions")
    ap.add_argument("--size", type=int, help="force image size (applies to all partitions)")
    args = ap.parse_args()

    src = Path(args.dir)
    out = Path(args.out)
    sizes = read_resize_sizes(src / "dynamic_partitions_op_list")

    parts = args.partition or ["system", "vendor", "product", "odm"]
    for part in parts:
        reassemble(part, src, out, args.size or sizes.get(part))
    return 0


if __name__ == "__main__":
    sys.exit(main())
