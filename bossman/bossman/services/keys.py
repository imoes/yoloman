"""Bossman's own TLS client identity — the certificate it presents to
every Duppy it polls (see docs/plan.md's Bossman plan, section B.4), and
the identity it hands out during enrollment (section B.3) so a Duppy can
pin it in its own tls.trusted_client_keys, exactly like a Selecta's client
certificate on the Go side (internal/tlsauth.PublicKeyPEMFromCertFile).

Generated once and persisted to disk rather than regenerated per process
start — a restart must keep the same identity, or every already-enrolled
agent's pinned key would suddenly stop matching. No automatic rotation in
v1 (see docs/plan.md's accepted trade-off): rotating means re-running
enrollment against every agent.
"""

from __future__ import annotations

import datetime
import os

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


def ensure_client_keypair(key_path: str, cert_path: str) -> None:
    """Generates a P-256 keypair + self-signed certificate at key_path/
    cert_path if they don't already exist. Idempotent: a second call (e.g.
    a subsequent process restart) reuses the existing files untouched."""
    if os.path.exists(key_path) and os.path.exists(cert_path):
        return

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "bossman")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .sign(key, hashes.SHA256())
    )

    key_dir = os.path.dirname(key_path)
    if key_dir:
        os.makedirs(key_dir, exist_ok=True)
    cert_dir = os.path.dirname(cert_path)
    if cert_dir:
        os.makedirs(cert_dir, exist_ok=True)

    with open(key_path, "wb") as f:
        f.write(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
    os.chmod(key_path, 0o600)

    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def own_public_key_pem(cert_path: str) -> bytes:
    """Extracts the PEM-encoded PKIX public key from cert_path — the
    Python-side counterpart of the Go node agent's
    tlsauth.PublicKeyPEMFromCertFile."""
    with open(cert_path, "rb") as f:
        cert = x509.load_pem_x509_certificate(f.read())
    return cert.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
