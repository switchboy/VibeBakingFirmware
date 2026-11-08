#!/usr/bin/env python3
"""Which certificate signs an APK - the v1 (JAR) signature, from META-INF/*.RSA.

`android:sharedUserId="android.uid.system"` is only honoured when the apk carries the same signing
certificate as the platform (`android` / framework-res.apk). Two apks with one sharedUserId and
different certificates are refused outright by PackageManager, so the decision "sign the kept HCT apps
with our platform key" has to be checked by comparing certificate digests, not by trusting a module
property. And `sha256(apk)` changes when an apk is re-signed, so the digest of the *certificate* is the
thing that is stable across a re-sign and therefore the thing to compare before and after.

  tools/hu_apk_cert.py <apk> [<apk> ...] [<x509.pem> ...]

One line per input: <sha256 of the certificate DER>\t<subject>\t<file>. Only openssl is needed, so it
runs the same way on the workstation and on the NAS (no java, so apksigner cannot be used here).
"""
import hashlib
import os
import subprocess
import sys
import zipfile


def certs_from_pkcs7(der: bytes) -> list[str]:
    """PEM blocks out of a PKCS7 SignedData blob (Android's META-INF/CERT.RSA)."""
    res = subprocess.run(["openssl", "pkcs7", "-inform", "DER", "-print_certs"],
                         input=der, capture_output=True)
    out = res.stdout.decode(errors="replace")
    blocks = []
    cur = []
    for line in out.splitlines():
        if line.startswith("-----BEGIN"):
            cur = [line]
        elif cur:
            cur.append(line)
            if line.endswith("-----END CERTIFICATE-----"):
                blocks.append("\n".join(cur))
                cur = []
    return blocks


def cert_digest(pem: str) -> tuple[str, str]:
    """(sha256 of the DER, subject) for one PEM certificate.

    `input=` must be bytes because the subprocesses are not in text mode - Python 3.13 rejects bytes
    input when `text=True`, so the output is decoded here instead.
    """
    der = subprocess.run(["openssl", "x509", "-outform", "DER"],
                         input=pem.encode(), capture_output=True).stdout
    subj = subprocess.run(["openssl", "x509", "-subject", "-noout"],
                          input=pem.encode(), capture_output=True).stdout.decode().strip()
    return hashlib.sha256(der).hexdigest(), subj.replace("subject=", "").strip()


def apk_certificates(apk: str):
    z = zipfile.ZipFile(apk)
    rsa = [n for n in z.namelist() if n.startswith("META-INF/") and n.endswith(".RSA")]
    if not rsa:
        return []
    return [cert_digest(p) for p in certs_from_pkcs7(z.read(rsa[0]))]


def main():
    for path in sys.argv[1:]:
        if path.endswith(".pem"):
            pem = open(path).read()
            digest, subject = cert_digest(pem)
            print(f"{digest}\t{subject}\t{path}")
            continue
        certs = apk_certificates(path)
        if not certs:
            print(f"nosig\t-\t{path} (no v1 signature: v2/v3 only, or unsigned)")
            continue
        for digest, subject in certs:
            print(f"{digest}\t{subject}\t{os.path.basename(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
