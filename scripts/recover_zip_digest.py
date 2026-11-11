#!/usr/bin/python3
"""Recover the digest an OEM OTA zip was signed over, then find which byte range hashes to it.

`openssl dgst -verify` only tells us yes/no per candidate. Instead we RSA-public the PKCS#7 signature
and strip the PKCS#1 v1.5 padding, which hands us the digest the signer actually hashed. Then hashing
candidate byte ranges and comparing against that digest settles the scope directly.

Provenance is checked first: the certificate is self-signed (issuer == subject), so the cert's own
signature over its tbsCertificate DER must RSA-unpad to sha256(tbs). If that works, the modulus, the
exponent and the unpadding code are all correct, and the zip digest we recover afterwards is trustworthy.
"""
import hashlib
import pathlib
import re
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
    if b[i] < 0x80:
        return b[i], i + 1
    n = b[i] - 0x80
    return int.from_bytes(b[i + 1:i + 1 + n], 'big'), i + 1 + n


def walk(b: bytes, off: int, found: list) -> int:
    """Collect (tag, header offset, value offset, length) for every DER node; return the node's end."""
    tag = b[off]
    ln, i = read_len(b, off + 1)
    end = i + ln
    found.append((tag, off, i, ln))
    if tag & 0x20:
        pos = i
        while pos < end:
            pos = walk(b, pos, found)
    return end


def der_bytes(b: bytes, node: tuple) -> bytes:
    """Full DER bytes of a recorded node, header included."""
    tag, hdr, val, ln = node
    return b[hdr:val + ln]


def rsa_unpad(block: bytes) -> bytes | None:
    """Strip PKCS#1 v1.5 padding and return the DigestInfo body's digest, or None."""
    if len(block) < 11 or block[0] != 0x00 or block[1] != 0x01:
        return None
    sep = block.find(b'\x00', 2)
    if sep < 10 or block[2:sep] != b'\xff' * (sep - 2):
        return None
    di = block[sep + 1:]
    # DigestInfo = SEQUENCE { SEQUENCE { OID, NULL }, OCTET STRING digest }
    if di[0] != 0x30:
        return None
    found: list = []
    walk(di, 0, found)
    octs = [(val, ln) for t, hdr, val, ln in found if t == 0x04]
    if len(octs) != 1:
        return None
    i, ln = octs[0]
    return di[i:i + ln]


raw = ZIP.read_bytes()
comment = zipfile.ZipFile(ZIP).comment
n = len(raw)
cl = len(comment)
msg = b'signed by SignApk'
pkcs7 = comment[len(msg) + 1:-6]
assert pkcs7[:2] == b'\x30\x82', f'no DER at the pkcs7 slice: {pkcs7[:4]!r}'
(OUT / 'oem-pkcs7.der').write_bytes(pkcs7)

nodes: list = []
walk(pkcs7, 0, nodes)

# SignerInfo.signature: an OCTET STRING of 256 bytes, the LAST child of the SignerInfo SET (which comes
# after the certificate set). The certificate's signatureValue is a BIT STRING, its public key too.
sig_octets = [(val, ln) for t, hdr, val, ln in nodes if t == 0x04 and ln == 256]
if not sig_octets:
    print('ABORT: no 256-byte OCTET STRING in the pkcs7')
    sys.exit(1)
sig_i, _ = sig_octets[-1]
sig = pkcs7[sig_i:sig_i + 256]
print(f'zip {n} B, comment {cl} B, pkcs7 {len(pkcs7)} B, signature OCTET STRING at {sig_i}')

cert_pem = subprocess.run(['openssl', 'pkcs7', '-inform', 'DER', '-in', str(OUT / 'oem-pkcs7.der'),
                           '-print_certs'], capture_output=True, text=True).stdout
(OUT / 'signer.pem').write_text(cert_pem)
cert_der = subprocess.run(['openssl', 'x509', '-in', str(OUT / 'signer.pem'), '-outform', 'DER'],
                          capture_output=True).stdout
(OUT / 'signer.der').write_bytes(cert_der)
print('signer cert der-sha:', hashlib.sha256(cert_der).hexdigest()[:16])

pub_pem = subprocess.run(['openssl', 'x509', '-in', str(OUT / 'signer.pem'), '-pubkey', '-noout'],
                         capture_output=True, text=True).stdout
(OUT / 'oem-pub.pem').write_text(pub_pem)
mod = subprocess.run(['openssl', 'rsa', '-pubin', '-in', str(OUT / 'oem-pub.pem'),
                     '-modulus', '-noout'], capture_output=True, text=True).stdout
n_hex = re.sub(r'[^0-9a-fA-F]', '', mod.replace('Modulus=', ''))
ntxt = subprocess.run(['openssl', 'rsa', '-pubin', '-in', str(OUT / 'oem-pub.pem'),
                      '-text', '-noout'], capture_output=True, text=True).stdout
e = int(re.search(r'Exponent: (\d+)', ntxt).group(1))
N = int(n_hex, 16)
print(f'RSA modulus {len(n_hex) // 2} bytes, exponent {e}')


def public(m_bytes: bytes) -> bytes | None:
    m = int.from_bytes(m_bytes, 'big')
    if m >= N:
        return None
    return pow(m, e, N).to_bytes(len(m_bytes), 'big')


# 1. Provenance: the cert is self-signed, so its signatureValue must unpad to sha256(tbsCertificate).
# Cert = SEQUENCE { tbsCertificate SEQUENCE, signatureAlgorithm SEQUENCE, signatureValue BIT STRING },
# so walk() lists the outer SEQUENCE first and the tbs right after it, at the outer's value offset.
cert_nodes: list = []
walk(cert_der, 0, cert_nodes)
outer, tbs = cert_nodes[0], cert_nodes[1]
assert outer[0] == 0x30 and tbs[0] == 0x30 and tbs[1] == outer[2], 'unexpected certificate structure'
cert_sig = next((c for c in cert_nodes if c[0] == 0x03 and c[3] in (256, 257)), None)
if cert_sig:
    _, _, val, ln = cert_sig
    cs = cert_der[val + 1:val + 257] if ln == 257 else cert_der[val:val + 256]
    d = rsa_unpad(public(cs))
    want = hashlib.sha256(der_bytes(cert_der, tbs)).digest()
    print(f'cert self-signature: recovered {d.hex() if d else "no padding"} '
          f'vs sha256(tbs) {want.hex()} -> {"OK" if d == want else "MISMATCH"}')
    if d != want:
        print('ABORT: the public key or the unpadding is wrong - nothing recovered later is trustworthy')
        sys.exit(1)

# 2. Recover the digest the zip was signed over.
d = rsa_unpad(public(sig))
if not d:
    print('ABORT: the pkcs7 signature does not unpad as PKCS#1 v1.5')
    sys.exit(1)
print(f'zip digest recovered from the signature: {d.hex()}')

eocd = raw[n - 22:n]
ranges = {
    'whole-file': raw,
    'minus-EOCD-22': raw[:n - 22],
    'minus-EOCD-and-comment': raw[:n - 22 - cl],
    'minus-comment': raw[:n - cl],
    'content-plus-EOCD-clen0': raw[:n - 22 - cl] + eocd[:20] + b'\x00\x00',
    'content-only': raw[:n - 22 - cl],
    'zip-entries-concat': b''.join(zipfile.ZipFile(ZIP).read(i) for i in zipfile.ZipFile(ZIP).namelist()),
}
for k, v in ranges.items():
    h = hashlib.sha256(v).digest()
    print(f'  {k:26s} {len(v):10d} B  {h.hex()}  {"MATCH <<<" if h == d else ""}')
