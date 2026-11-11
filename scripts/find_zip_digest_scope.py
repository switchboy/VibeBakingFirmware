#!/usr/bin/python3
"""Which byte range of a signed OTA zip does recovery actually hash?

Ground truth is `diatsia fw/update(1).zip`: it passes recovery, so its PKCS#7 signature proves the
range. The comment is the legacy SignApk layout (measured Nov 11): "signed by SignApk" + NUL + PKCS#7 +
signature_start (u16) + 0xffff + total_size (u16). The PKCS#7 is detached (encapContentInfo absent) and
uses sha256, signed by HCT's cert (der-sha cf2ab3818595c4ed, present in the stock otacerts.zip).

Everything is derived from the zip itself into OUT, so the probe does not depend on scratch directories
that were moved to cold storage. signapk.jar cannot be run here (conscrypt native-library error under
both OpenJDK 27 and the tree's prebuilt jdk17), hence the empirical RSA verification:

  openssl dgst -sha256 -verify <signer pubkey> -signature <RSA block> <candidate bytes>

If a candidate verifies, recovery hashes exactly that range, and our own package must be signed over it.
"""
import hashlib
import pathlib
import struct
import subprocess
import sys
import zipfile

ZIP = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                   else '/run/media/Daan/Opslagmonster/VibeBakingFirmware/diatsia fw/update(1).zip')
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2
                   else '/run/media/Daan/Opslagmonster/a14-work/huzip')
OUT.mkdir(parents=True, exist_ok=True)


def read_len(b: bytes, i: int) -> tuple[int, int]:
    """DER length: short form, or long form (high bit set = number of following length bytes)."""
    if b[i] < 0x80:
        return b[i], i + 1
    n = b[i] - 0x80
    return int.from_bytes(b[i + 1:i + 1 + n], 'big'), i + 1 + n


def walk(b: bytes, off: int, found: list) -> int:
    """Walk one DER node from `off`, collecting (tag, value offset, length); return the node's end."""
    tag = b[off]
    ln, i = read_len(b, off + 1)
    end = i + ln
    found.append((tag, i, ln))
    if tag & 0x20:  # constructed: children follow back-to-back
        pos = i
        while pos < end:
            pos = walk(b, pos, found)
    return end


raw = ZIP.read_bytes()
comment = zipfile.ZipFile(ZIP).comment
n = len(raw)
cl = len(comment)

# Comment layout, per the SignApk source: message + NUL + PKCS#7, then a 6-byte trailer
# (signature_start u16, 0xff 0xff, total_size u16). total_size is the whole comment length, so
# signature_start = pkcs7_len + 6 and pkcs7 = comment[len(message)+1 : -6].
msg = b'signed by SignApk'
total_size = struct.unpack('<H', comment[-2:])[0]
sig_start = struct.unpack('<H', comment[-6:-4])[0]
pkcs7 = comment[len(msg) + 1:-6]

assert comment[:len(msg)] == msg, f'comment does not start with the SignApk message: {comment[:20]!r}'
assert comment[len(msg)] == 0, 'no NUL after the message'
assert comment[-4:-2] == b'\xff\xff', 'no 0xff 0xff marker in the trailer'
assert pkcs7[:2] == b'\x30\x82', f'no DER SEQUENCE at the start of the pkcs7 slice: {pkcs7[:4]!r}'
assert total_size == len(comment), f'total_size field {total_size} != comment length {len(comment)}'
assert sig_start == len(pkcs7) + 6, f'signature_start {sig_start} != pkcs7 length {len(pkcs7)} + 6'

(OUT / 'oem-pkcs7.der').write_bytes(pkcs7)
print(f'zip {n} B, comment {cl} B, total_size {total_size}, signature_start {sig_start}, pkcs7 {len(pkcs7)} B')

# Signer public key and cert der-sha, straight from the PKCS#7's certificate.
certs = subprocess.run(['openssl', 'pkcs7', '-inform', 'DER', '-in', str(OUT / 'oem-pkcs7.der'),
                        '-print_certs'], capture_output=True, text=True)
(OUT / 'signer.pem').write_text(certs.stdout)
pub = subprocess.run(['openssl', 'x509', '-in', str(OUT / 'signer.pem'), '-pubkey', '-noout'],
                     capture_output=True, text=True)
(OUT / 'oem-pub.pem').write_text(pub.stdout)
der = subprocess.run(['openssl', 'x509', '-in', str(OUT / 'signer.pem'), '-outform', 'DER'],
                     capture_output=True)
(OUT / 'signer.der').write_bytes(der.stdout)
print('signer subject:', certs.stdout.strip().splitlines()[0] if certs.stdout.strip() else 'none')
print('signer cert der-sha:', hashlib.sha256(der.stdout).hexdigest()[:16])

found: list = []
walk(pkcs7, 0, found)
print('der nodes (tag, value offset, length):',
      [(hex(t), i, ln) for t, i, ln in found])

# SignerInfo.signature is a BIT STRING of 256 bits (DER: 1 unused-bits byte + 256 bytes). SignerInfo
# comes before the certificate set, so the FIRST such node is the RSA block; the certificate's public
# key is also a BIT STRING of 256 bits, and an OCTET STRING of 256 bytes shows up inside the cert too.
bit256 = [(i, ln) for t, i, ln in found if t == 0x03 and ln in (256, 257)]
oct256 = [(i, ln) for t, i, ln in found if t == 0x04 and ln == 256]

sig_candidates: list[tuple[str, bytes]] = []
for i, ln in bit256:
    # ln 257 = unused-bits byte + 256 value bytes; ln 256 = the value only.
    sig_candidates.append((f'bitstring@{i}', pkcs7[i + 1:i + 257] if ln == 257 else pkcs7[i:i + 256]))
for i, ln in oct256:
    sig_candidates.append((f'octetstring@{i}', pkcs7[i:i + 256]))
if not sig_candidates:
    print('ABORT: no 256-byte signature candidate found - pkcs7 is not RSA-sha256 as assumed')
    sys.exit(1)

# Measured on Nov 11: SignerInfo version 1, digest sha256, rsaEncryption, NO signed attributes
# (no tag 0xA0 node), so the RSA block signs the content digest directly and raw-byte verification of
# candidate ranges is meaningful. If signed attributes appear, the signature is over their DER instead.
if any(t == 0xA0 for t, _, _ in found):
    print('NOTE: a context [0] node exists (signed attributes) - raw-range verification does not apply')

eocd = raw[n - 22:n]
candidates = {
    'whole-file': raw,
    'minus-EOCD-22': raw[:n - 22],
    'minus-EOCD-and-comment': raw[:n - 22 - cl],
    'minus-comment': raw[:n - cl],
    'content-plus-EOCD-clen0': raw[:n - 22 - cl] + eocd[:20] + b'\x00\x00',
    'content-only': raw[:n - 22 - cl],
}

for name, sig in sig_candidates:
    sigfile = OUT / f'sig-{name}.bin'
    sigfile.write_bytes(sig)
    print(f'\nsignature candidate {name} ({len(sig)} B):')
    for k, v in candidates.items():
        f = OUT / f'cand-{k}.bin'
        f.write_bytes(v)
        r = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(OUT / 'oem-pub.pem'),
                            '-signature', str(sigfile), str(f)],
                           capture_output=True, text=True)
        verdict = (r.stdout + r.stderr).strip()[:70]
        print(f'  {k:26s} {len(v):10d} B  {verdict}')
        if 'Signature OK' in (r.stdout + r.stderr):
            print(f'  >>> recovery hashes exactly {k}; our package must be signed over that range <<<')
            sys.exit(0)

print('\nno signature candidate verifies over any candidate range:')
print('the signature is not over the zip bytes themselves - re-read the PKCS#7 structure')
sys.exit(1)
