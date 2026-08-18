"""main_config_path — "what is this package's MAIN /etc config file", pinned.

Every case here is a MEASURED mistake, not an invented one. The function replaced a codecs-only lookup
that returned "" for 30 of 89 catalog roles, and each rule below exists because dropping it produced a
wrong answer on the real catalog:

  * seed BEFORE registry     — registry-first answered /etc/sudo.conf (the plugin config) for sudo,
                               where the seed says /etc/sudoers. The two sources answer different
                               questions; the seed answers the one being asked.
  * a directory is not a file — the stem rule accepted /etc/restic, the package's config DIRECTORY.
                               config_path feeds template_render, which writes one whole file.
  * ancillary dirs excluded  — /etc/default/etcd is a SysV variables file, not etcd's config.
  * refuted claims stay out  — both sources agreed on /etc/crm/crm.conf for pacemaker; the Debian
                               archive says crmsh ships it. Verified with apt-get download + dpkg-deb.
  * stem as a path COMPONENT — a bare basename match once picked /etc/ufw/applications.d/samba (a ufw
                               profile file literally named "samba") over smb.conf.

The fixtures are synthetic on purpose: these are statements about the RULES. Pinning them against the
live configs/ would make the test fail whenever the catalog grows, which teaches everyone to ignore it.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_package_catalog import main_config_path  # noqa: E402


def _seed(pkg: str, path: str) -> dict:
    """A package_seed.json entry. Note the UNDERSCORED key — that is the seed's own convention, and
    the underscore/hyphen split is exactly what once produced 278 duplicate template dirs."""
    return {pkg.replace("-", "_"): {"families": {"debian": {"config_path": path}}}}


def test_seed_claim_wins_over_a_registry_stem_match():
    """sudo: the registry knows both /etc/sudo.conf (plugin config, matches <stem>.conf) and
    /etc/sudoers (the real thing). Registry-first got this wrong."""
    codecs = {"/etc/sudo.conf": {"packages": ["sudo"]}, "/etc/sudoers": {"packages": ["sudo"]}}
    assert main_config_path("sudo", codecs, _seed("sudo", "/etc/sudoers")) == "/etc/sudoers"


def test_a_seed_claim_needs_the_registry_as_a_witness():
    """The seed alone is a model claim. Unwitnessed → empty, which the wizard resolves at runtime."""
    assert main_config_path("mosquitto", {}, _seed("mosquitto", "/etc/mosquitto/mosquitto.conf")) == ""


def test_the_registry_alone_still_answers_when_the_seed_is_silent():
    codecs = {"/etc/nginx/nginx.conf": {"packages": ["nginx"]}}
    assert main_config_path("nginx", codecs, {}) == "/etc/nginx/nginx.conf"


def test_a_config_directory_is_not_a_config_path():
    """/etc/restic is the package's config DIRECTORY. template_render writes a whole FILE, so a
    directory is not a near miss — it is an unwritable target."""
    codecs = {"/etc/restic": {"packages": ["restic"]}}
    assert main_config_path("restic", codecs, {}) == ""


def test_the_stem_directory_form_still_works_with_a_file_in_it():
    """The other side of that line: /etc/<stem>/<something> is exactly what the rule is for."""
    codecs = {"/etc/rspamd/rspamd.conf": {"packages": ["rspamd"]}}
    assert main_config_path("rspamd", codecs, {}) == "/etc/rspamd/rspamd.conf"


def test_ancillary_directories_are_never_the_main_config():
    """Both sources are filtered by it, so the seed cannot smuggle in what the registry rules out."""
    codecs = {"/etc/default/etcd": {"packages": ["etcd"]}}
    assert main_config_path("etcd", codecs, _seed("etcd", "/etc/default/etcd")) == ""


def test_a_refuted_seed_claim_is_not_used_even_though_the_path_exists():
    """pacemaker: seed and registry agreed, the Debian archive refuted it. The refutation is recorded
    in _SEED_PATH_REFUTED with its reason, so it cannot be re-litigated by accident."""
    codecs = {"/etc/crm/crm.conf": {"packages": ["crmsh"]}}
    assert main_config_path("pacemaker", codecs, _seed("pacemaker", "/etc/crm/crm.conf")) == ""


def test_a_bare_basename_match_does_not_count():
    """The ufw trap: ufw ships application profiles named after OTHER packages, so a file literally
    called "samba" under /etc/ufw/ must never beat smb.conf. Guarded twice — /etc/ufw/ is ancillary
    AND the stem must be a real path component."""
    codecs = {"/etc/ufw/applications.d/samba": {"packages": ["samba"]},
              "/etc/samba/smb.conf": {"packages": ["samba"]}}
    assert main_config_path("samba", codecs, {}) == "/etc/samba/smb.conf"


def test_a_path_outside_etc_is_refused():
    """The seed offers ~/.config/containers/containers.conf for podman — a per-user file, which is not
    a host config this catalog can manage."""
    seed = _seed("podman", "~/.config/containers/containers.conf")
    assert main_config_path("podman", {"~/.config/containers/containers.conf": {}}, seed) == ""


def test_empty_is_a_real_answer_and_not_an_error():
    """No source, no path — and that is a NAMED state, not a failure: the wizard resolves the path
    from the installed package at runtime. curate_catalog reports the remainder by name so that
    "we found none" cannot be mistaken for "nobody looked"."""
    assert main_config_path("something-nobody-knows", {}, {}) == ""
