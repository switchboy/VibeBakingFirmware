#!/usr/bin/python3
"""Sign an OTA zip the way this head unit's recovery expects: the legacy SignApk zip-comment format.

signapk.jar cannot run here (conscrypt native-library error under both OpenJDK 27 and the tree's prebuilt
jdk17), so the PKCS#7 is assembled by hand. The shape is measured from `diatsia fw/update(1).zip`, whose
signature RSA-unpads cleanly (scripts/recover_zip_digest.py):

  signedData, version 1, digestAlgorithms sha256, encapContentInfo pkcs7-data with d.data ABSENT
  (detached), one certificate, one SignerInfo (version 1, that cert's issuer+subject, digest sha256,
  rsaEncryption), signature = PKCS#1 v1.5 over DigestInfo(sha256(<hashed range>)).

The comment appended to the zip is, in order:
  "signed by SignApk" (17 B) + NUL + PKCS#7 + signature_start u16 + 0xff 0xff + total_size u16
with total_size = comment length and signature_start = total_size - 17 - 1 = len(pkcs7) + 6.

The --scope flag decides which bytes are hashed and MUST match what recovery hashes; that is settled by
scripts/recover_zip_digest.py, which recovers the digest from the OEM signature and compares it against
candidate ranges. Do not change the scope without re-running that probe.

Keys: sign with the AOSP testkey (cert der-sha a40da80a59d170ca) - it is the cert in our dual
otacerts.zip. `platform` (c8a2e9bccf597c2f) is trusted by nothing we ship, so it would be rejected.
"""
import argparse
import hashlib
import pathlib
import subprocess
import sys
import zipfile

DEFAULT_PK8 = '/run/media/Daan/Opslagmonster/a14-work/keys/testkey.pk8'
DEFAULT_CERT = '/run/media/Daan/Opslagmonster/a14-work/keys/testkey.x509.pem'
MESSAGE = b'signed by SignApk'
TESTKEY_DER_SHA = 'a40da80a59d170ca'

OID_PKCS7_SIGNED_DATA = bytes.fromhex('2a864886f70d010702')
OID_PKCS7_DATA = bytes.fromhex('2a864886f70d010701')
OID_SHA256 = bytes.fromhex('2a864886f70d01050503040505')
OID_RSA = bytes.fromhex('2a864886f70d01010105')
NULL = b'\x05\x00'


def tlv(tag: int, body: bytes) -> bytes:
    ln = len(body)
    if ln < 128:
        return bytes([tag, ln]) + body
    head = bytes([tag, 0x80 | len(b := ln.to_bytes((ln.bit_length() + 7) // 8, 'big'))])
    return head + b


def seq(*items: bytes) -> bytes:
    return tlv(0x30, b''.join(items))


def oid(v: bytes) -> bytes:
    return tlv(0x06, v)


def explicit(num: int, body: bytes) -> bytes:
    return tlv(0xa0 | num, body)


def der_int(v: int) -> bytes:
    return tlv(0x02, v.to_bytes((v.bit_length() + 8) // 8, 'big'))


def sha256_digest_info(digest: bytes) -> bytes:
    """DigestInfo = SEQUENCE { SEQUENCE { sha256 OID, NULL }, OCTET STRING digest }."""
    return seq(seq(oid(OID_SHA256), NULL), tlv(0x04, digest))


def pkcs1_v1_5(key_len: int, digest_info: bytes) -> bytes:
    pad = key_len - len(digest_info) - 3
    if pad < 8:
        raise SystemExit('key too small for a DigestInfo')
    return b'\x00\x01' + b'\xff' * pad + b'\x00' + digest_info


def read_len(b: bytes, i: int) -> tuple[int, int]:
    if b[i] < 0x80:
        return b[i], i + 1
    k = b[i] - 0x80
    return int.from_bytes(b[i + 1:i + 1 + k], 'big'), i + 1 + k


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


def cert_der(cert_path: pathlib.Path) -> bytes:
    r = subprocess.run(['openssl', 'x509', '-in', str(cert_path), '-outform', 'DER'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'cannot read certificate {cert_path}: {r.stderr.strip()[:150]}')
    return r.stdout


def issuer_and_subject(cert: bytes) -> tuple[bytes, bytes]:
    """The tbsCertificate's issuer and subject Name DER, copied verbatim into the SignerInfo.

    Direct children of the tbs are: [0] version, serial, signatureAlgorithm, issuer, validity,
    subject, subjectPublicKeyInfo, [3] extensions. An issuer/subject Name is a SEQUENCE whose children
    are RelativeName SETs (tag 0x31), so pick the two tbs children of tag 0x30 containing a 0x31 child.
    """
    nodes: list = []
    walk(cert, 0, nodes)
    outer, tbs = nodes[0], nodes[1]
    assert outer[0] == 0x30 and tbs[0] == 0x30 and tbs[1] == outer[2], 'unexpected certificate structure'
    inside = [n for n in nodes if tbs[2] <= n[1] < tbs[2] + tbs[3]]
    # A direct child of the tbs is not contained in another node that is itself inside the tbs.
    direct = [n for n in inside if not any(o[1] <= n[1] < o[2] + o[3] and o[1] > tbs[2] for o in inside)]
    names = []
    for tag, hdr, val, ln in direct:
        if tag == 0x30 and any(c[0] == 0x31 for c in nodes if val <= c[1] < val + ln):
            names.append((hdr, val, ln))
    if len(names) != 2:
        raise SystemExit(f'found {len(names)} Name structures in the tbs, expected issuer+subject')
    (ih, iv, il), (sh, sv, sl) = names
    return cert[ih:iv + il], cert[sh:sv + sl]


def build_pkcs7(cert: bytes, sig: bytes) -> bytes:
    issuer, subject = issuer_and_subject(cert)
    signer_info = seq(
        der_int(1),
        issuer,
        subject,
        seq(oid(OID_SHA256), NULL),
        seq(oid(OID_RSA), NULL),
        tlv(0x04, sig),
    )
    signed_data = seq(
        der_int(1),
        tlv(0x31, seq(oid(OID_SHA256), NULL)),          # digestAlgorithms SET
        seq(oid(OID_PKCS7_DATA)),                        # detached: no content octet string
        explicit(0, cert),                               # certificates [0] EXPLICIT
        tlv(0x31, signer_info),                          # signerInfos SET
    )
    return seq(oid(OID_PKCS7_SIGNED_DATA), explicit(0, signed_data))


def comment_from_raw(raw: bytes) -> bytes:
    i = raw.rfind(b'PK\x05\x06')
    if i < 0:
        return b''
    ln = int.from_bytes(raw[i + 16:i + 18], 'little')
    return raw[i + 22:i + 22 + ln]


def hashed_range(raw: bytes, scope: str) -> bytes:
    n = len(raw)
    cl = len(comment_from_raw(raw))
    eocd = raw[n - 22:n]
    if scope == 'whole-file':
        return raw
    if scope == 'minus-EOCD-22':
        return raw[:n - 22]
    if scope == 'minus-comment':
        return raw[:n - cl]
    if scope == 'minus-EOCD-and-comment':
        return raw[:n - 22 - cl]
    if scope == 'content-plus-EOCD-clen0':
        # The commentless archive: EOCD kept, comment length field zeroed.
        return raw[:n - 22 - cl] + eocd[:20] + b'\x00\x00'
    if scope == 'content-only':
        return raw[:n - 22 - cl]
    raise SystemExit(f'unknown scope: {scope}')


def key_bytes(pk8: pathlib.Path) -> int:
    """Modulus length, via the public key derived from the PKCS#8 DER private key."""
    pub = subprocess.run(['openssl', 'pkey', '-in', str(pk8), '-inform', 'DER', '-pubout'],
                         capture_output=True, text=True)
    if pub.returncode != 0:
        raise SystemExit(f'cannot read key {pk8}: {pub.stderr.strip()[:150]}')
    mod = subprocess.run(['openssl', 'rsa', '-pubin', '-outform', 'DER'],
                         input=pub.stdout.encode(), capture_output=True)
    nodes: list = []
    walk(mod.stdout, 0, nodes)
    bits = next((ln for t, _, _, ln in nodes if t == 0x02), None)
    if bits is None:
        raise SystemExit('no RSA modulus found in the derived public key')
    return bits


def rsa_sign(pk8: pathlib.Path, block: bytes) -> bytes:
    tmp = pathlib.Path('/tmp/opencode/sign-block.der')
    tmp.write_bytes(block)
    r = subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(pk8), '-inform', 'DER',
                        '-rawin', '-in', str(tmp)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'openssl pkeyutl failed: {r.stderr.strip()[:200]}')
    out = subprocess.run(['openssl', 'base64', '-d'], input=r.stdout.encode(), capture_output=True)
    if out.returncode != 0:
        raise SystemExit(f'cannot decode the signature: {out.stderr.strip()[:150]}')
    return out.stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('zip', help='unsigned zip to sign (must not already have an archive comment)')
    ap.add_argument('out', help='signed zip to write')
    ap.add_argument('--pk8', default=DEFAULT_PK8)
    ap.add_argument('--cert', default=DEFAULT_CERT)
    ap.add_argument('--scope', default='content-plus-EOCD-clen0',
                    help='byte range to hash; must match scripts/recover_zip_digest.py')
    args = ap.parse_args()

    pk8, cert_path = pathlib.Path(args.pk8), pathlib.Path(args.cert)
    if not pk8.exists():
        print(f'ABORT: no private key {pk8}. Pull it from the build tree over the askpass ssh wrapper:')
        print('  sh /tmp/opencode/omv.sh "cat /srv/dev-disk-by-label-SSData/aospbuild/lineage21s/'
              'build/target/product/security/testkey.pk8" > /run/media/Daan/Opslagmonster/a14-work/keys/testkey.pk8')
        return 1
    if not cert_path.exists():
        print(f'ABORT: no certificate {cert_path} (pull testkey.x509.pem the same way)')
        return 1

    raw = pathlib.Path(args.zip).read_bytes()
    if comment_from_raw(raw):
        print('ABORT: the zip already has an archive comment - sign the un-commented zip')
        return 1

    cert = cert_der(cert_path)
    der_sha = hashlib.sha256(cert).hexdigest()[:16]
    print('cert der-sha:', der_sha)
    if der_sha != TESTKEY_DER_SHA:
        print('WARNING: this cert is not the testkey. Recovery only accepts certs that are inside '
              '/system/etc/security/otacerts.zip (HCT cf2ab3818595c4ed + testkey a40da80a59d170ca).')

    key_len = key_bytes(pk8)
    content = hashed_range(raw, args.scope)
    digest = hashlib.sha256(content).digest()
    sig = rsa_sign(pk8, pkcs1_v1_5(key_len, sha256_digest_info(digest)))
    if len(sig) != key_len:
        print(f'ABORT: signature is {len(sig)} B, key is {key_len} B')
        return 1

    pkcs7 = build_pkcs7(cert, sig)
    total = len(MESSAGE) + 1 + len(pkcs7) + 6
    if total > 0xffff:
        raise SystemExit('signature too big for a zip comment')
    comment = (MESSAGE + b'\x00' + pkcs7
               + (total - len(MESSAGE) - 1).to_bytes(2, 'little') + b'\xff\xff' + total.to_bytes(2, 'little'))

    out_path = pathlib.Path(args.out)
    out_path.write_bytes(raw + comment)
    print(f'signed {out_path}: {len(raw)} B of zip + {len(comment)} B comment '
          f'(total_size {total}, signature_start {total - len(MESSAGE) - 1}, scope {args.scope})')
    print('sha256 of signed zip:', hashlib.sha256(out_path.read_bytes()).hexdigest())

    # Self-check: the signature must verify over exactly the hashed range with the cert's public key.
    pub = subprocess.run(['openssl', 'pkey', '-in', str(pk8), '-inform', 'DER', '-pubout'],
                         capture_output=True, text=True)
    pubfile = pathlib.Path('/tmp/opencode/sign-selfcheck-pub.pem')
    pubfile.write_text(pub.stdout)
    contentfile = pathlib.Path('/tmp/opencode/sign-selfcheck-content.bin')
    contentfile.write_bytes(content)
    sigfile = pathlib.Path('/tmp/opencode/sign-selfcheck-sig.bin')
    sigfile.write_bytes(sig)
    v = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(pubfile),
                        '-signature', str(sigfile), str(contentfile)], capture_output=True, text=True)
    print('self-check over', args.scope, ':', (v.stdout + v.stderr).strip()[:90])
    return 0 if 'Signature OK' in (v.stdout + v.stderr) else 1


if __name__ == '__main__':
    sys.exit(main())
