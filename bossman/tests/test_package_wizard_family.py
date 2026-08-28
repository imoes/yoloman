"""Family resolution: every catalog entry lands in exactly one named state.

The defect this guards against was measured, not imagined. Two generators wrote the Debian
package name into a `redhat` branch as well, so 78 of 90 redhat branches were verbatim copies and
~15 were wrong (cron is `cronie`, ufw does not exist on RHEL). The old resolution —
`fams.get(family) or fams.get("debian")` — could not defend against it: a fabricated branch
satisfies `fams.get(family)`, so the fallback never ran and a guess was served as a curated fact.

The fix is that absence is allowed and *named*. These tests hold that line in both directions:
the four states must stay exhaustive (no entry may fall through unclassified), and an unavailable
entry must stay un-installable.
"""

import json
from pathlib import Path

import pytest

from bossman.api.package_wizard import _catalog, _resolve_family
from bossman.config import get_settings


def _real_catalog() -> dict:
    """The catalog the APP reads, resolved the app's own way.

    Not `parents[2]/configs/…`: in the test container the repo root is not above `tests/`, so that
    guess lands on `/configs/…` and the module fails to import — the same mistake that makes
    test_capabilities_db fail today. Going through `_catalog(get_settings())` means the test can
    only ever assert about the file that is actually served.
    """
    return _catalog(get_settings())


def _template_dir(tname: str):
    """Templates live beside the catalog — same resolution, so the test reads what the app reads."""
    from bossman.config import get_settings as _gs
    return Path(_gs().config_templates_dir) / tname


def _template_fields(tname: str) -> list[str]:
    f = _template_dir(tname) / "schema.json"
    if not f.is_file():
        return []
    try:
        schema = json.loads(f.read_text())
    except (OSError, ValueError):
        return []
    fields = schema.get("parameters") or schema.get("properties") or schema
    return [k for k, v in fields.items() if isinstance(v, dict)] if isinstance(fields, dict) else []


def _template_body(tname: str):
    f = _template_dir(tname) / "template.j2"
    return f.read_text(errors="replace") if f.is_file() else None


def test_own_branch_is_exact_and_explains_nothing():
    fams = {"debian": {"packages": ["apache2"]}, "redhat": {"packages": ["httpd"]}}
    branch, meta = _resolve_family(fams, "redhat")
    assert branch["packages"] == ["httpd"]
    assert meta["family_match"] == "exact"
    assert meta["installable"] is True
    assert meta["reason"] == ""  # nothing to justify: the catalog answers directly


def test_missing_branch_falls_back_but_says_so():
    """The whole point. Before, this returned the Debian names with no indication."""
    fams = {"debian": {"packages": ["prometheus"]}}
    branch, meta = _resolve_family(fams, "redhat")
    assert branch["packages"] == ["prometheus"]
    assert meta["family_match"] == "fallback"
    assert meta["family_used"] == "debian"
    assert meta["installable"] is True  # unknown is not impossible — 27 roles share their name
    assert "redhat" in meta["reason"] and "prometheus" in meta["reason"]


def test_unavailable_is_not_installable_and_names_the_substitute():
    """An impossible action is greyed out WITH its reason, not attempted and explained after."""
    fams = {"debian": {"packages": ["ufw"]},
            "redhat": {"unavailable": "not packaged for RHEL", "instead": "firewalld"}}
    branch, meta = _resolve_family(fams, "redhat")
    assert branch == {}                      # no names to offer
    assert meta["family_match"] == "unavailable"
    assert meta["installable"] is False
    assert meta["instead"] == "firewalld"
    assert meta["reason"]


def test_unavailable_never_leaks_into_a_fallback():
    """A named non-existence must not be stood in for by another family's names — that would
    answer 'does this exist here?' with a different family's yes."""
    fams = {"debian": {"packages": ["ntp"]}, "redhat": {"unavailable": "dropped after RHEL 7"}}
    _, meta = _resolve_family(fams, "redhat")
    assert meta["family_match"] == "unavailable"
    # …and the reverse: a family with NO branch may still fall back past an unavailable sibling.
    _, meta = _resolve_family({"redhat": {"unavailable": "x"}, "debian": {"packages": ["ntp"]}}, "suse")
    assert meta["family_match"] == "fallback" and meta["family_used"] == "debian"


def test_no_families_at_all_is_named_too():
    _, meta = _resolve_family({}, "redhat")
    assert meta["family_match"] == "unknown"
    assert meta["installable"] is False
    assert meta["reason"]


@pytest.mark.parametrize("family", ["debian", "redhat", "suse"])
def test_every_catalog_entry_is_classified(family):
    """Excluded middle, against the real catalog: no entry may end up in a fifth, unnamed state.

    Parameterised over suse deliberately — the catalog curates no suse branch at all, so every
    entry must come back as an explicit `fallback` rather than as a silent Debian answer.
    """
    catalog = _real_catalog()
    states = {"exact", "fallback", "unavailable", "unknown"}
    for name, entry in catalog.items():
        _, meta = _resolve_family(entry.get("families") or {}, family)
        assert meta["family_match"] in states, f"{name}: unclassified {meta}"
        # Whatever the state, it is either installable or it says why not.
        assert meta["installable"] or meta["reason"], f"{name}: refused without a reason"
        if meta["family_match"] == "fallback":
            assert meta["family_used"] != family


def test_the_catalog_no_longer_copies_debian_into_redhat():
    """The measurement that started this, kept as a test so the copies cannot come back.

    A redhat branch is allowed to be identical to Debian — 27 roles genuinely share a name. What
    is no longer allowed is an identical branch with no provenance: `source` records that someone
    (CORE, the RedHat universe, or the CORRECTIONS table) actually checked.
    """
    catalog = _real_catalog()
    unchecked = []
    for name, entry in catalog.items():
        fams = entry.get("families") or {}
        deb, rh = fams.get("debian") or {}, fams.get("redhat")
        if not isinstance(rh, dict) or rh.get("unavailable"):
            continue
        if rh.get("packages") == deb.get("packages") and not rh.get("source"):
            unchecked.append(name)
    assert not unchecked, (
        "redhat branches identical to debian with no `source` — copied, not checked. "
        "Run scripts/curate_family_branches.py:\n  " + "\n  ".join(sorted(unchecked))
    )


def test_no_role_offers_configure_with_a_template_that_configures_something_else():
    """Configure renders template.j2 as a WHOLE FILE to config_path. A template that does not
    configure that file therefore replaces it.

    Measured before the guard: 7 of 90 roles had a template mentioning not one of their own
    schema's field names, because the batch harvested the wrong file from the .deb. The worst was
    `sshd` — schema of 90 fields for /etc/ssh/sshd_config, template.j2 being /etc/pam.d/sshd.
    Applying it locks you out of the host. So an entry may keep its schema, but it may not keep the
    Configure action: `template` is null and the UI shows its existing "no template yet" branch.
    """
    catalog = _real_catalog()
    offenders = []
    for name, entry in catalog.items():
        tname = entry.get("template")
        if not tname:
            continue  # withdrawn, or never had one — both honest
        fields = _template_fields(tname)
        body = _template_body(tname)
        if fields and body is not None and not any(k in body for k in fields):
            path = (entry.get("families", {}).get("debian") or {}).get("config_path", "")
            offenders.append(f"{name} (template {tname} → would overwrite {path or 'nothing'})")
    assert not offenders, (
        "roles offering Configure with a template that configures a different file — "
        "run scripts/curate_catalog.py:\n  " + "\n  ".join(sorted(offenders))
    )
