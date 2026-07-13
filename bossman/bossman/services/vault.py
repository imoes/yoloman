"""A small symmetric secrets vault so no password/API-key is stored in
plaintext at rest (docs/zabbix-gap-analysis.md's deferred "vault" gap).

Scope, deliberately narrow: yolo-man needs NO connection credentials — the
agent (Duppy) is already reachable over mTLS + bearer token and runs as root
locally. What we DO store are sensitive *values inside variables* — a DB
password a runbook writes into a config, an API key a template renders — held
in ScopeVars / plan params. Those are the values this vault encrypts.

Mechanism: Fernet (AES-128-CBC + HMAC-SHA256, the `cryptography` library's
authenticated symmetric primitive). One key, from BOSSMAN_VAULT_KEY, or —
when unset — generated once and persisted to disk like the TLS keypair
(services/keys.py), so a restart keeps the same key and existing ciphertexts
stay decryptable. No automatic key rotation in v1 (rotating means re-encrypting
every stored secret); that's an accepted trade-off, matching keys.py.

Encrypted values are stored as the sentinel string ``vault:v1:<token>`` so a
value's encrypted-ness is self-describing wherever it lands (JSONB, YAML) —
no separate "is this column encrypted" bookkeeping. Decryption happens only at
run time, immediately before the value is handed to the agent; the UI and
audit rows only ever see the masked form.
"""

from __future__ import annotations

import os
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

# Sentinel prefix marking a Fernet-encrypted value. v1 pins the scheme so a
# future rotation/upgrade can be recognised by prefix.
_PREFIX = "vault:v1:"
_MASK = "••••••••"


class VaultError(Exception):
    """Raised when a vault key is missing/invalid or a value can't be decrypted."""


def _load_or_create_key(key: str, key_path: str) -> bytes:
    """Return the Fernet key bytes: prefer the explicit key, else read/create
    a persisted key file (like services.keys). A generated key is written with
    0600 so a restart reuses it and existing ciphertexts stay decryptable."""
    if key:
        return key.encode()
    if os.path.exists(key_path):
        with open(key_path, "rb") as fh:
            return fh.read().strip()
    generated = Fernet.generate_key()
    os.makedirs(os.path.dirname(key_path) or ".", exist_ok=True)
    # Write 0600 from the start (never a window where it's world-readable).
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(generated)
    return generated


@lru_cache(maxsize=8)
def _fernet(key: str, key_path: str) -> Fernet:
    try:
        return Fernet(_load_or_create_key(key, key_path))
    except (ValueError, TypeError) as exc:
        raise VaultError(f"invalid vault key: {exc}") from exc


class Vault:
    """Encrypt/decrypt sensitive values with a single persisted Fernet key.

    Construct once from settings (``Vault(settings.vault_key,
    settings.vault_key_path)``) and reuse; the underlying Fernet is cached by
    (key, key_path)."""

    def __init__(self, key: str = "", key_path: str = "/etc/bossman/vault.key") -> None:
        self._key = key
        self._key_path = key_path

    def encrypt(self, plaintext: str) -> str:
        """Encrypt a plaintext string into the ``vault:v1:<token>`` sentinel.
        Idempotent: an already-encrypted value is returned unchanged, so
        re-saving a form that still shows the mask doesn't double-encrypt."""
        if self.is_encrypted(plaintext):
            return plaintext
        token = _fernet(self._key, self._key_path).encrypt(plaintext.encode())
        return _PREFIX + token.decode()

    def decrypt(self, value: str) -> str:
        """Decrypt a ``vault:v1:<token>`` value back to plaintext. A value that
        isn't encrypted is returned as-is (so mixed plaintext/encrypted var
        dicts decrypt uniformly)."""
        if not self.is_encrypted(value):
            return value
        try:
            return _fernet(self._key, self._key_path).decrypt(value[len(_PREFIX):].encode()).decode()
        except InvalidToken as exc:
            raise VaultError("value could not be decrypted (wrong key or corrupt token)") from exc

    @staticmethod
    def is_encrypted(value: object) -> bool:
        return isinstance(value, str) and value.startswith(_PREFIX)

    @staticmethod
    def mask(_value: object = None) -> str:
        """The placeholder shown in UI/audit in place of any secret value."""
        return _MASK
