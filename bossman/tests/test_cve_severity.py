"""Debian tracker urgency -> our severity vocabulary.

Every case here is a counted fact from the cached tracker (trixie), because two of the
mappings were wrong in ways that only show up at scale:

    not yet assigned  42968   used to become ""  -> UI showed "unknown", i.e.
                              indistinguishable from "we failed to look it up"
    unimportant        8361   used to become "low" -> 8361 entries Debian says have NO
                              security impact were presented as minor vulnerabilities
    low                2714
    medium              658
    high                133
"""

import pytest

from bossman.services.cve_feed import _debian_severity


def test_real_urgencies_map_to_our_vocabulary():
    assert _debian_severity("high") == "important"
    assert _debian_severity("medium") == "moderate"
    assert _debian_severity("low") == "low"


def test_unimportant_is_not_low():
    """Debian's "unimportant" means no security impact as shipped — not a small one."""
    assert _debian_severity("unimportant") == "unimportant"


def test_not_yet_assigned_is_reportable_not_empty():
    """~80% of Debian CVEs land here; "" would render as "unknown" (no data)."""
    assert _debian_severity("not yet assigned") == "untriaged"


def test_end_of_life_is_not_a_severity():
    assert _debian_severity("end-of-life") == "untriaged"


def test_unknown_future_value_does_not_vanish():
    """A new urgency word must surface as untriaged, not silently become no-data."""
    assert _debian_severity("catastrophic-but-new") == "untriaged"


def test_absent_urgency_stays_empty():
    """No urgency field at all is genuinely "no data" — distinct from untriaged."""
    assert _debian_severity("") == ""
    assert _debian_severity(None) == ""


def test_asterisk_suffix_is_stripped():
    """The tracker writes e.g. "high**" for unconfirmed judgements."""
    assert _debian_severity("high**") == "important"
    assert _debian_severity(" HIGH ") == "important"


def test_ranking_puts_unimportant_below_untriaged():
    """An unjudged CVE outranks one the distro says does not affect it."""
    from bossman.api.security import _SEV_RANK

    assert _SEV_RANK["important"] > _SEV_RANK["low"] > _SEV_RANK["untriaged"] > _SEV_RANK["unimportant"] > _SEV_RANK[""]


def test_ui_severity_ranking_covers_the_backend_vocabulary():
    """The UI keeps its own copy of the ranking, and the two drifted — this catches that.

    A package row in the Security view shows the worst severity among the CVEs it
    fixes, chosen with the UI's own `sevRank`. That table was not extended when
    `untriaged`/`unimportant` were added, so both scored 0 like "no data": the
    comparison `sevRank(cve) > sevRank(group)` was `0 > 0`, the group's severity
    stayed empty, and all 47 package rows read "unknown" while the summary card
    above them correctly showed 1679 untriaged findings.

    Asserting across the language boundary is deliberate: nothing else connects the
    two tables, and the failure is silent in both.
    """
    import re
    from pathlib import Path

    from bossman.api.security import _SEV_RANK

    ui = Path(__file__).resolve().parents[2] / "bossman-ui/src/app/features/security/security.component.ts"
    if not ui.exists():
        pytest.skip("bossman-ui not present in this checkout")

    body = re.search(r"private sevRank\(s: string\): number \{\s*return \{(.*?)\}\[", ui.read_text(), re.S)
    assert body, "could not locate sevRank's lookup table — was it renamed?"
    ui_rank = {k: int(v) for k, v in re.findall(r"(\w+):\s*(\d+)", body.group(1))}

    # Every severity the backend can emit must be known to the UI ("" is the
    # deliberate no-data case and stays absent, hitting the UI's ?? 0 default).
    missing = {s for s in _SEV_RANK if s} - set(ui_rank)
    assert not missing, f"UI sevRank is missing backend severities: {sorted(missing)}"

    # And the shared keys must agree on order, not on absolute numbers.
    shared = sorted((s for s in _SEV_RANK if s and s in ui_rank), key=lambda s: _SEV_RANK[s])
    assert shared == sorted(shared, key=lambda s: ui_rank[s]), (
        f"UI and backend disagree on severity order: backend {shared}, "
        f"UI {sorted(shared, key=lambda s: ui_rank[s])}"
    )

    # The bug in one line: an untriaged CVE must beat "no severity at all".
    assert ui_rank["untriaged"] > 0 and ui_rank["unimportant"] > 0
