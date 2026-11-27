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
import re
import subprocess
import sys

DEFAULT_PK8 = '/run/media/Daan/Opslagmonster/a14-work/keys/testkey.pk8'
DEFAULT_CERT = '/run/media/Daan/Opslagmonster/a14-work/keys/testkey.x509.pem'
MESSAGE = b'signed by SignApk'
TESTKEY_DER_SHA = 'a40da80a59d170ca'

# DER OID content bytes, computed from the arc lists (first two arcs are packed as first*40+second).
def oid_arcs(*arcs: int) -> bytes:
    """DER OID value: first two arcs packed into one byte, remaining arcs base-128 with the high bit."""
    head = arcs[0] * 40 + arcs[1]
    out = bytearray([head])
    for arc in arcs[2:]:
        chunk = arc
        enc = []
        while True:
            enc.append(chunk & 0x7f)
            chunk >>= 7
            if chunk == 0:
                break
        enc.reverse()
        for i, b in enumerate(enc):
            out.append(b | 0x80 if i < len(enc) - 1 else b)
    return bytes(out)


# sha256 = 2.16.840.1.101.3.4.2.1, rsaEncryption = 1.2.840.113549.1.1.1,
# pkcs7-signedData = 1.2.840.113549.1.7.2, pkcs7-data = 1.2.840.113549.1.7.1.
# Hardcoded hex for these was wrong before (it decoded as 1.2.840.113549.1.5.5.3.4.5.5), which is why
# openssl's PKCS7 parser refused the object: the digest algorithm must be sha256 for recovery to accept it.
OID_PKCS7_SIGNED_DATA = oid_arcs(1, 2, 840, 113549, 1, 7, 2)
OID_PKCS7_DATA = oid_arcs(1, 2, 840, 113549, 1, 7, 1)
OID_SHA256 = oid_arcs(2, 16, 840, 1, 101, 3, 4, 2, 1)
OID_RSA = oid_arcs(1, 2, 840, 113549, 1, 1, 1)
NULL = b'\x05\x00'


def tlv(tag: int, body: bytes) -> bytes:
    ln = len(body)
    if ln < 128:
        return bytes([tag, ln]) + body
    length = ln.to_bytes((ln.bit_length() + 7) // 8, 'big')
    # Long form: tag, 0x80|number-of-length-bytes, the length, then the body. Losing the body here is
    # what produced a 64-byte PKCS#7 with a 1,196-byte certificate "inside" it.
    return bytes([tag, 0x80 | len(length)]) + length + body


def seq(*items: bytes) -> bytes:
    return tlv(0x30, b''.join(items))


def oid(v: bytes) -> bytes:
    return tlv(0x06, v)


def explicit(num: int, body: bytes) -> bytes:
    return tlv(0xa0 | num, body)


def der_int(v: int) -> bytes:
    return tlv(0x02, v.to_bytes((v.bit_length() + 8) // 8, 'big'))


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
    # DER, not PEM: capture bytes, because text=True would try to utf-8-decode the certificate.
    r = subprocess.run(['openssl', 'x509', '-in', str(cert_path), '-outform', 'DER'],
                       capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f'cannot read certificate {cert_path}: {r.stderr.decode(errors="replace")[:150]}')
    return r.stdout


def children(b: bytes, val: int, ln: int) -> list:
    """The direct children of a constructed node, as (tag, header offset, value offset, length)."""
    out: list = []
    pos, end = val, val + ln
    while pos < end:
        tag = b[pos]
        child_ln, child_val = read_len(b, pos + 1)
        out.append((tag, pos, child_val, child_ln))
        pos = child_val + child_ln          # a node's span is its header plus its value
    return out


def issuer_and_serial(cert: bytes) -> tuple[bytes, bytes]:
    """The SignerInfo's issuer-and-serial pair, in the legacy PKCS#7 form openssl's template expects:
    the issuer Name DER plus the signer certificate's serial INTEGER.

    (An earlier version used issuer+subject, which is the CMS form; openssl's PKCS7_SIGNER_INFO parser
    rejects it with "Field=issuer_and_serial, wrong tag", and the OEM zip's SignerInfo carries a serial:
    asn1parse shows INTEGER 92A528C773D7A141 inside it.)

    Direct children of the tbs are: [0] version, serial INTEGER, signatureAlgorithm, issuer Name,
    validity, subject Name, subjectPublicKeyInfo, [3] extensions. A Name is a SEQUENCE whose direct
    children are RelativeName SETs (tag 0x31); validity's children are UTCTime (0x17), so the first
    such SEQUENCE is the issuer, not the subject.
    """
    nodes: list = []
    walk(cert, 0, nodes)
    outer, tbs = nodes[0], nodes[1]
    assert outer[0] == 0x30 and tbs[0] == 0x30 and tbs[1] == outer[2], 'unexpected certificate structure'
    kids = children(cert, tbs[2], tbs[3])
    # A node's DER is header + value (b[hdr:val+ln]). Slicing b[val:val+ln] drops the tag and length,
    # which is what made openssl reject the SignerInfo: the issuer and serial children of
    # issuer_and_serial must each be a complete DER node, not a headerless value.
    serial = next((cert[hdr:val + ln] for tag, hdr, val, ln in kids if tag == 0x02), None)
    names = [(hdr, val, ln) for tag, hdr, val, ln in kids
             if tag == 0x30 and any(c[0] == 0x31 for c in children(cert, val, ln))]
    if serial is None or len(names) != 2:
        raise SystemExit(f'cert tbs children: serial={serial is not None}, names={len(names)}')
    ih, iv, il = names[0]      # the issuer precedes the subject in the tbs, so names[0] is the issuer
    return cert[ih:iv + il], serial


def build_pkcs7(cert: bytes, sig: bytes) -> bytes:
    issuer, serial = issuer_and_serial(cert)
    signer_info = seq(
        der_int(1),
        # issuer_and_serial is its own SEQUENCE inside the SignerInfo; putting issuer and serial as
        # direct siblings makes openssl reject the object with Type=PKCS7_ISSUER_AND_SERIAL, wrong tag.
        seq(issuer, serial),
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
    """The archive comment, disambiguated the way zip readers do: rfind can land on a PK\\x05\\x06 that is
    inside the comment bytes (PKCS#7 contains arbitrary binary), so keep walking backwards until the
    declared comment length exactly accounts for the bytes after the EOCD."""
    i = raw.rfind(b'PK\x05\x06')
    while i >= 0:
        # comment_len is the LAST field of the 22-byte EOCD record: offset +20, not +16 (+16 is the
        # central-directory offset). Reading +16 made every signed zip look commentless.
        clen = int.from_bytes(raw[i + 20:i + 22], 'little')
        if i + 22 + clen == len(raw):
            return raw[i + 22:i + 22 + clen]
        i = raw.rfind(b'PK\x05\x06', 0, i)
    return b''


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


def rsa_unpad(block: bytes) -> bytes | None:
    """Strip PKCS#1 v1.5 padding and return the digest inside the DigestInfo, or None."""
    if len(block) < 11 or block[0] != 0x00 or block[1] != 0x01:
        return None
    sep = block.find(b'\x00', 2)
    if sep < 10 or block[2:sep] != b'\xff' * (sep - 2):
        return None
    di = block[sep + 1:]
    if di[0] != 0x30:
        return None
    found: list = []
    walk(di, 0, found)
    octs = [(val, ln) for t, hdr, val, ln in found if t == 0x04]
    if len(octs) != 1:
        return None
    i, ln = octs[0]
    return di[i:i + ln]


def public_key(pk8: pathlib.Path) -> tuple[int, int, int]:
    """(modulus, exponent, modulus byte length) derived from the PKCS#8 DER private key.

    `-text` prints the modulus over several indented colon-separated lines, so use `-modulus -noout`
    (one `Modulus=hex` line) and read the exponent separately from `-text`.
    """
    pub = subprocess.run(['openssl', 'pkey', '-in', str(pk8), '-inform', 'DER', '-pubout'],
                         capture_output=True, text=True)
    if pub.returncode != 0:
        raise SystemExit(f'cannot read key {pk8}: {pub.stderr.strip()[:150]}')
    mod = subprocess.run(['openssl', 'rsa', '-pubin', '-modulus', '-noout'],
                         input=pub.stdout, capture_output=True, text=True)
    if mod.returncode != 0:
        raise SystemExit(f'no RSA modulus derived from {pk8}: {mod.stderr.strip()[:150]}')
    hexstr = re.sub(r'[^0-9a-fA-F]', '', mod.stdout.split('Modulus=', 1)[1])
    txt = subprocess.run(['openssl', 'rsa', '-pubin', '-text', '-noout'],
                         input=pub.stdout, capture_output=True, text=True)
    m = re.search(r'Exponent: (\d+)', txt.stdout)
    if not m:
        raise SystemExit(f'no exponent found in the derived public key: {txt.stdout[:120]!r}')
    n_bytes = bytes.fromhex(hexstr)
    return int.from_bytes(n_bytes, 'big'), int(m.group(1)), len(n_bytes)


def self_check(pk8: pathlib.Path, content: bytes, sig: bytes, digest: bytes) -> tuple[bool, str]:
    """Recover the digest from our own signature with the public key - this is what minzip does, so it
    is the real test. `openssl dgst -verify` is NOT used: pkeyutl's padding choice is its own, and the
    OEM probe proved this RSA-unpad route works (the certificate's self-signature verifies this way)."""
    N, e, ln = public_key(pk8)
    if len(sig) != ln:
        return False, f'signature {len(sig)} B vs modulus {ln} B'
    m = int.from_bytes(sig, 'big')
    if m >= N:
        return False, 'signature larger than the modulus'
    recovered = rsa_unpad(pow(m, e, N).to_bytes(ln, 'big'))
    if recovered is None:
        return False, 'signature does not unpad as PKCS#1 v1.5'
    if recovered != digest:
        return False, f'recovered {recovered.hex()[:16]} != sha256(content) {digest.hex()[:16]}'
    return True, f'recovered digest == sha256({digest.hex()[:16]})'


def key_bytes(pk8: pathlib.Path) -> int:
    """Modulus length, via the public key derived from the PKCS#8 DER private key.

    SubjectPublicKeyInfo has no INTEGER at the top level (the modulus INTEGER is inside the BIT
    STRING), so openssl's `-modulus` hex is the simple and reliable way to get the length.
    """
    pub = subprocess.run(['openssl', 'pkey', '-in', str(pk8), '-inform', 'DER', '-pubout'],
                         capture_output=True, text=True)
    if pub.returncode != 0:
        raise SystemExit(f'cannot read key {pk8}: {pub.stderr.strip()[:150]}')
    mod = subprocess.run(['openssl', 'rsa', '-pubin', '-modulus', '-noout'],
                         input=pub.stdout, capture_output=True, text=True)
    if mod.returncode != 0:
        raise SystemExit(f'no RSA modulus derived from {pk8}: {mod.stderr.strip()[:150]}')
    hexstr = mod.stdout.split('Modulus=', 1)[1].strip()
    try:
        return len(bytes.fromhex(hexstr))
    except ValueError:
        raise SystemExit(f'openssl gave a non-hex modulus: {hexstr[:40]!r}')


def rsa_sign(pk8: pathlib.Path, content: bytes) -> bytes:
    """Signature = RSA PKCS#1 v1.5 over DigestInfo(sha256(content)). `openssl dgst -sha256 -sign` does
    exactly that; pkeyutl with a hand-built padded block hashes the block again, which is why an earlier
    self-check recovered sha256(padded block) instead of sha256(content)."""
    contentfile = pathlib.Path('/run/media/Daan/Opslagmonster/a14-work/scratch/sign-content.bin')
    contentfile.write_bytes(content)
    sigfile = pathlib.Path('/run/media/Daan/Opslagmonster/a14-work/scratch/sign.sig')
    r = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(pk8), '-keyform', 'DER',
                        '-out', str(sigfile), str(contentfile)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'openssl dgst -sign failed: {r.stderr.strip()[:200]}')
    return sigfile.read_bytes()


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
        print('  sh ~/.config/vbf/omv.sh "cat /srv/dev-disk-by-label-SSData/aospbuild/lineage21s/'
              'build/target/product/security/testkey.pk8" > /run/media/Daan/Opslagmonster/a14-work/keys/testkey.pk8')
        return 1
    if not cert_path.exists():
        print(f'ABORT: no certificate {cert_path} (pull testkey.x509.pem the same way)')
        return 1

    raw = pathlib.Path(args.zip).read_bytes()
    n = len(raw)
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
    sig = rsa_sign(pk8, content)
    if len(sig) != key_len:
        print(f'ABORT: signature is {len(sig)} B, key is {key_len} B')
        return 1

    pkcs7 = build_pkcs7(cert, sig)
    total = len(MESSAGE) + 1 + len(pkcs7) + 6
    if total > 0xffff:
        raise SystemExit('signature too big for a zip comment')
    comment = (MESSAGE + b'\x00' + pkcs7
               + (total - len(MESSAGE) - 1).to_bytes(2, 'little') + b'\xff\xff' + total.to_bytes(2, 'little'))

    # The EOCD's comment_len field must declare the comment, or zipfile/minzip reads a 0-length comment
    # and the signature is invisible. The field is the last 2 bytes of the 22-byte EOCD record.
    out = bytearray(raw[:n])
    out[n - 2:n] = len(comment).to_bytes(2, 'little')
    out += comment
    out_path = pathlib.Path(args.out)
    out_path.write_bytes(out)
    print(f'signed {out_path}: {n} B of zip + {len(comment)} B comment '
          f'(total_size {total}, signature_start {total - len(MESSAGE) - 1}, scope {args.scope})')
    print('sha256 of signed zip:', hashlib.sha256(out).hexdigest())

    ok, note = self_check(pk8, content, sig, digest)
    print('self-check (RSA-unpad, the way minzip verifies):', note)
    if not ok:
        print('ABORT: the signature does not carry the digest of the hashed range')
        return 1
    print('comment parses as a zip comment:', len(comment_from_raw(out)) == len(comment))
    return 0


if __name__ == '__main__':
    sys.exit(main())
