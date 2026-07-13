"""Unit tests for the secrets vault (bossman.services.vault). No DB — pure
crypto round-trip + masking + key persistence."""

import os

import pytest
from cryptography.fernet import Fernet

from bossman.services.vault import Vault, VaultError


def _vault(tmp_path, key=""):
    return Vault(key=key, key_path=str(tmp_path / "vault.key"))


def test_round_trip_with_explicit_key(tmp_path):
    v = _vault(tmp_path, key=Fernet.generate_key().decode())
    enc = v.encrypt("s3cr3t-pw")
    assert enc.startswith("vault:v1:")
    assert "s3cr3t-pw" not in enc  # plaintext must not appear
    assert v.decrypt(enc) == "s3cr3t-pw"


def test_is_encrypted_and_mask():
    assert Vault.is_encrypted("vault:v1:abc")
    assert not Vault.is_encrypted("plain")
    assert not Vault.is_encrypted(123)
    assert Vault.mask("anything") == Vault.mask()


def test_encrypt_is_idempotent(tmp_path):
    v = _vault(tmp_path, key=Fernet.generate_key().decode())
    once = v.encrypt("pw")
    twice = v.encrypt(once)  # already encrypted → unchanged
    assert once == twice
    assert v.decrypt(twice) == "pw"


def test_decrypt_passes_through_plaintext(tmp_path):
    v = _vault(tmp_path, key=Fernet.generate_key().decode())
    assert v.decrypt("not-encrypted") == "not-encrypted"


def test_key_is_generated_and_persisted(tmp_path):
    key_path = tmp_path / "vault.key"
    v1 = Vault(key="", key_path=str(key_path))
    enc = v1.encrypt("pw")
    assert key_path.exists()
    assert oct(os.stat(key_path).st_mode)[-3:] == "600"
    # A fresh Vault reading the same persisted key decrypts the old ciphertext.
    v2 = Vault(key="", key_path=str(key_path))
    assert v2.decrypt(enc) == "pw"


def test_wrong_key_fails_to_decrypt(tmp_path):
    a = _vault(tmp_path, key=Fernet.generate_key().decode())
    enc = a.encrypt("pw")
    b = Vault(key=Fernet.generate_key().decode(), key_path=str(tmp_path / "other.key"))
    with pytest.raises(VaultError):
        b.decrypt(enc)
