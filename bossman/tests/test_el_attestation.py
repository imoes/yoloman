"""What counts as evidence that an EL package exists — and what does not.

`curate_catalog` drops a role's `redhat` branch when it is identical to Debian and unattested, because a
fabricated branch satisfies `fams.get(family)` and the wizard's honest `family_match="fallback"` never runs.
The rule is right; the EVIDENCE it asked was wrong twice over, and both are pinned here:

  * it asked `package_universe_real.json["redhat"]` — 1902 entries built from two Rocky repos and then
    filtered to *configurable-service candidates*. So "absent" meant "not a service candidate in BaseOS or
    AppStream" and was read as "does not exist on RHEL". Measured: neither `sssd` (BaseOS) nor `nginx`
    (AppStream) is in it. `nginx` survived only via the builder's CORE table; `sssd`'s branch was dropped.
  * the fix must NOT simply be "all of EL": EPEL ships `apt` and `ufw`, so counting EPEL as attestation would
    keep exactly the copied Debian branches this pass removes.
"""

import json

import pytest

from bossman.tools import curate_catalog as cc


@pytest.fixture
def records(tmp_path, monkeypatch):
    """Point the module at throwaway records — it reads them at CALL time, not import time."""
    monkeypatch.setattr(cc, "EL_NAMES", tmp_path / "package_names_el.json")
    monkeypatch.setattr(cc, "UNIVERSE", tmp_path / "package_universe_real.json")
    return tmp_path


def _write(records, el: dict | None, universe: dict | None):
    if el is not None:
        (records / "package_names_el.json").write_text(json.dumps({"_meta": {"repos": ["baseos"]}, "names": el}))
    if universe is not None:
        (records / "package_universe_real.json").write_text(json.dumps({"redhat": universe}))


def test_a_distribution_package_attests(records):
    _write(records, {"sssd": ["baseos"], "nginx": ["appstream"], "gtest": ["crb"]}, {})
    names, sources = cc._attested_el_names()
    assert {"sssd", "nginx", "gtest"} <= names
    assert any("baseos" in s or "names" in s for s in sources)


def test_epel_alone_does_NOT_attest(records):
    """The question is whether a role's redhat branch is a real translation, not whether something can be
    installed. `apt` and `ufw` are in EPEL — counting that would keep the copied branches."""
    _write(records, {"apt": ["epel"], "ufw": ["epel"], "fail2ban": ["epel"], "sssd": ["baseos"]}, {})
    names, _ = cc._attested_el_names()
    assert "sssd" in names
    for epel_only in ("apt", "ufw", "fail2ban"):
        assert epel_only not in names, f"{epel_only} is EPEL-only and must not attest"


def test_a_package_in_both_still_attests(records):
    """Present in the distribution AND in EPEL is still present in the distribution."""
    _write(records, {"redis": ["appstream", "epel"]}, {})
    names, _ = cc._attested_el_names()
    assert "redis" in names


def test_the_two_records_are_UNIONED(records):
    """The old service-candidate listing keeps attesting whatever it attested — it is a different question,
    and dropping it would trade one blind spot for another."""
    _write(records, {"sssd": ["baseos"]}, {"only-in-the-candidate-listing": {}})
    names, sources = cc._attested_el_names()
    assert {"sssd", "only-in-the-candidate-listing"} <= names
    assert len(sources) == 2


def test_no_attestation_at_all_is_reported_not_defaulted(records, capsys):
    """With nothing attesting, only CORRECTIONS and CORE survive — every other redhat branch is dropped.
    That must never happen quietly."""
    names, sources = cc._attested_el_names()
    assert names == set() and sources == []
    err = capsys.readouterr().err
    assert "NOTHING attests" in err
    assert "record_el_package_names" in err


def test_an_unparsable_record_is_not_an_empty_one(records, capsys):
    (records / "package_names_el.json").write_text("{not json")
    _write(records, None, {"httpd": {}})
    names, sources = cc._attested_el_names()
    assert names == {"httpd"}, "a broken name record must not take the candidate listing down with it"
    assert "record_el_package_names" in capsys.readouterr().err


def test_the_unavailable_claims_match_the_measurement():
    """UNAVAILABLE states that a package is not on EL. The measured record is what can contradict it — and
    did: `ufw` IS in EPEL, so "not packaged for RHEL" was false as written. A claim an operator disproves
    with one `dnf install` costs every other claim here its credibility."""
    try:
        el = json.loads(cc.EL_NAMES.read_text())["names"]
    except (OSError, ValueError, KeyError):
        pytest.skip("no measured EL record in this checkout")
    for name, claim in cc.UNAVAILABLE.items():
        repos = el.get(name) or []
        in_distro = [r for r in repos if r != "epel"]
        assert not in_distro, f"{name} is in {in_distro} but UNAVAILABLE claims it is not on EL"
        if repos:  # EPEL-only: the wording must say so rather than "not packaged"
            assert "EPEL" in claim["unavailable"], (
                f"{name} is in EPEL, so {claim['unavailable']!r} overstates the absence")
