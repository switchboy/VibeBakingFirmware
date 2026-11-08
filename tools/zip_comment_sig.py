#!/usr/bin/env python3
"""Read the OTA-package signature a Rockchip/HCT recovery verifies: the zip EOCD comment.

  tools/zip_comment_sig.py <zip> [<zip> ...]

The OEM packages put SignApk's PKCS#7 SignedData in the zip *comment* (prefixed with
"signed by SignApk\0"), not in META-INF/. Our payload currently has an empty comment, which is why the
unit's recovery prints "footer is wrong" / "Signature verification failed" (error 21).

Prints, per zip: comment length, the prefix, the signer certificate chain (subject, issuer,
sha256 fingerprint of each DER cert) and the digest algorithms inside the SignedData - so the
fingerprints can be compared against the key material in the build tree
(testkey / platform / Lineage release / the OEM key the reference payload used). Read-only.
"""
import base64
import subprocess
import sys


def eocd_comment(data: bytes) -> bytes:
    i = data.rfind(b"PK\x05\x06")
    if i < 0:
        raise SystemExit("no EOCD found")
    clen = int.from_bytes(data[i + 20:i + 22], "little")
    return data[i + 22:i + 22 + clen]


def openssl(args, blob: bytes) -> str:
    # bytes in, bytes out, decoded here: subprocess with text=True rejects bytes input
    p = subprocess.run(["openssl"] + args, input=blob, capture_output=True)
    return p.stdout.decode(errors="replace") + p.stderr.decode(errors="replace")


def cert_fingerprints(pem_out: str) -> list[str]:
    fps = []
    for chunk in pem_out.split("-----BEGIN CERTIFICATE-----")[1:]:
        body = chunk.split("-----END CERTIFICATE-----")[0]
        der = base64.b64decode(body.split("\n", 1)[1].replace("\n", ""))
        fp = openssl(["x509", "-inform", "DER", "-fingerprint", "-sha256", "-noout"], der)
        fps.append(fp.split("=")[-1].strip().lower())
    return fps


def describe(path: str) -> None:
    with open(path, "rb") as f:
        data = f.read()
    comment = eocd_comment(data)
    print(f"\n== {path}  ({len(data):,} B) ==")
    print(f"comment length: {len(comment)}")
    if not comment:
        print("EMPTY COMMENT -> the recovery sees no signature/footer at all")
        return
    prefix, sep, blob = comment.partition(b"\0")
    print(f"prefix: {prefix!r}  sep: {bool(sep)}  blob: {len(blob)} B")
    if not blob or blob[0] != 0x30:
        print("comment is not a DER PKCS#7 blob")
        return
    certs = openssl(["pkcs7", "-inform", "DER", "-print_certs"], blob)
    subject = issuer = None
    for line in certs.splitlines():
        if line.startswith("subject="):
            subject = line.split("=", 1)[1].strip()
        elif line.startswith("issuer="):
            issuer = line.split("=", 1)[1].strip()
    print(f"subject: {subject}")
    print(f"issuer:  {issuer}")
    for fp in cert_fingerprints(certs):
        print(f"cert sha256: {fp}")
    asn = openssl(["asn1parse", "-inform", "DER", "-noout"], blob)
    algos = sorted({line.split(":")[-1].strip() for line in asn.splitlines()
                    if "OID" in line and ("sha" in line.lower() or "md5" in line.lower())})
    print("digest/OID strings:", "; ".join(algos[:10]) or "none parsed")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for p in sys.argv[1:]:
        describe(p)
    sys.exit(0)
