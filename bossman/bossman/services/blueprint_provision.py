"""Out-of-band credential provisioning for blueprints.

The connector can pass a provider's declared credentials to a consumer, but some
providers should MINT them: create a database + application user with a generated
password. This does that the same secret-safe way check-provisioning does
(services/provisioning): connect to the provider host, run the CREATE DATABASE/
USER SQL via the agent `command` module using admin credentials supplied for this
call only, generate the app password, and store it for the consumer as a
`vault:v1:` handle — the admin creds and the plaintext app password are never
persisted (only the vault handle is). No new agent module, no plaintext in any
plan.
"""
from __future__ import annotations

from typing import Any

from bossman.services import provisioning

# SQL to create a database + least-privilege app user, per backend family. The
# `{…}` placeholders are filled by provisioning.provision from admin params +
# the generated `app_password` (literal replace — safe for SQL braces/%).
_MYSQL_SQL = (
    "CREATE DATABASE IF NOT EXISTS `{db_name}`; "
    "CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{app_password}'; "
    "GRANT ALL PRIVILEGES ON `{db_name}`.* TO '{db_user}'@'%'; FLUSH PRIVILEGES;"
)

SUPPORTED_BACKENDS = ("mysql", "mariadb")


def build_recipe(backend: str, exec_mode: str, container: str | None) -> dict[str, Any] | None:
    """An inline provisioning recipe (provisioning.provision shape) that creates a
    DB + user on the provider. `exec_mode` "docker" wraps the client in
    `docker exec <container> …`; "local" runs it on the host directly. Returns None
    for an unsupported backend."""
    if backend not in SUPPORTED_BACKENDS:
        return None
    client_argv = ["mysql", "-u{admin_user}", "-p{admin_password}", "-e", _MYSQL_SQL]
    if exec_mode == "docker" and container:
        argv = ["docker", "exec", "-i", container] + client_argv
    else:
        argv = client_argv
    return {
        "admin_params": {"admin_user": "DB admin user", "admin_password": "DB admin password"},
        "secret_params": ["admin_password"],
        "generate": ["app_password"],
        "argv": argv,
        "produces": {"name": "{db_name}", "user": "{db_user}", "password": "{app_password}"},
    }


async def provision_database(
    client, *, backend: str, exec_mode: str, container: str | None,
    admin_user: str, admin_password: str, db_name: str, db_user: str,
) -> dict[str, Any]:
    """Create the DB + user on the provider host and return
    {ok, produced_params:{name,user,password}, output, error}. `password` is the
    freshly generated plaintext — the caller stores it as a vault handle and never
    returns it to a client."""
    recipe = build_recipe(backend, exec_mode, container)
    if recipe is None:
        return {"ok": False, "error": f"unsupported backend {backend!r} (supported: {', '.join(SUPPORTED_BACKENDS)})",
                "produced_params": {}, "output": ""}
    admin_params = {"admin_user": admin_user, "admin_password": admin_password,
                    "db_name": db_name, "db_user": db_user}
    return await provisioning.provision(client, recipe, admin_params)
