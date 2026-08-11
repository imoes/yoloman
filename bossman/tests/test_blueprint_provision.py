"""Offline tests for the blueprint DB-provisioning recipe builder (no host/LLM)."""
from bossman.services import blueprint_provision as bp


def test_local_mysql_recipe_argv():
    r = bp.build_recipe("mariadb", "local", None, generate=True)
    assert r is not None
    assert r["argv"][0] == "mysql"
    assert r["generate"] == ["app_password"]
    sql = r["argv"][-1]
    assert "CREATE DATABASE IF NOT EXISTS `{db_name}`" in sql
    assert "CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{app_password}'" in sql
    assert r["produces"] == {"name": "{db_name}", "user": "{db_user}", "password": "{app_password}"}


def test_docker_exec_wraps_client():
    r = bp.build_recipe("mysql", "docker", "db", generate=True)
    assert r["argv"][:4] == ["docker", "exec", "-i", "db"]
    assert r["argv"][4] == "mysql"


def test_unsupported_backend_is_none():
    assert bp.build_recipe("postgresql", "local", None, generate=True) is None


def test_custom_password_omits_generate():
    r = bp.build_recipe("mysql", "local", None, generate=False)
    assert r["generate"] == []
