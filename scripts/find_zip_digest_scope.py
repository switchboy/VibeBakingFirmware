#!/usr/bin/python3
"""Find which byte range of a signed OTA zip recovery hashes, using the OEM zip as ground truth."""
import pathlib, subprocess, zipfile

p = '/run/media/Daan/Opslagmonster/VibeBakingFirmware/diatsia fw/update(1).zip'
raw = pathlib.Path(p).read_bytes()
cl = len(zipfile.ZipFile(p).comment)
n = len(raw)
pub = '/var/tmp/huzip/oem-pub.pem'
sig = '/var/tmp/huzip/oem-sig.bin'

cands = {
    'whole': raw,
    'minus-eocd22': raw[:n - 22],
    'minus-eocd+comment': raw[:n - 22 - cl],
    'minus-comment': raw[:n - cl],
    'content+eocd-clen0': raw[:n - 22 - cl] + raw[n - 22:n - 2] + b'\x00\x00',
    'entries-concat-uncompressed': b''.join(
        zf.read(i) for zf in [zipfile.ZipFile(p)] for i in zf.namelist()
    ),
}

for k, v in cands.items():
    f = pathlib.Path('/var/tmp/huzip/cand-' + k + '.bin')
    f.write_bytes(v)
    r = subprocess.run(
        ['openssl', 'dgst', '-sha256', '-verify', pub, '-signature', sig, str(f)],
        capture_output=True, text=True,
    )
    print(f'{k:26s} {len(v):7d}B  {r.stdout.strip()[:55]} | {r.stderr.strip()[:55]}')
