"""Unit tests for bossman.services.keys — no DB, no network."""

import os
import stat

from bossman.services import keys


def test_ensure_client_keypair_creates_files(tmp_path):
    key_path = tmp_path / "key.pem"
    cert_path = tmp_path / "cert.pem"

    keys.ensure_client_keypair(str(key_path), str(cert_path))

    assert key_path.exists()
    assert cert_path.exists()
    assert stat.S_IMODE(os.stat(key_path).st_mode) == 0o600


def test_ensure_client_keypair_is_idempotent(tmp_path):
    key_path = tmp_path / "key.pem"
    cert_path = tmp_path / "cert.pem"

    keys.ensure_client_keypair(str(key_path), str(cert_path))
    first_key, first_cert = key_path.read_bytes(), cert_path.read_bytes()

    keys.ensure_client_keypair(str(key_path), str(cert_path))
    second_key, second_cert = key_path.read_bytes(), cert_path.read_bytes()

    assert first_key == second_key
    assert first_cert == second_cert


def test_own_public_key_pem_matches_the_certs_own_key(tmp_path):
    key_path = tmp_path / "key.pem"
    cert_path = tmp_path / "cert.pem"
    keys.ensure_client_keypair(str(key_path), str(cert_path))

    pub_pem = keys.own_public_key_pem(str(cert_path))

    assert pub_pem.startswith(b"-----BEGIN PUBLIC KEY-----")
