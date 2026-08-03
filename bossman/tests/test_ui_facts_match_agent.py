"""The UI's variable list must match the facts the agent actually gathers.

This spans three languages, which is exactly why it drifted: `internal/modules/setup.go` (Go) gathers the
facts, `bossman-ui/.../blockly/ansibleFacts.js` (JS) lists them for the Variables panel, and nothing checked
that the two agreed. They did not — the JS list was inherited from awx-ng and named ~80 facts in the
`ansible_facts['x']` form, which the agent did not emit at all, so every variable the operator picked out of
the panel silently failed to resolve against the StrictUndefined template engine.

A variable offered in the UI is a promise that it resolves on the host. This test is that promise.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
SETUP_GO = REPO / "internal" / "modules" / "setup.go"
FACTS_JS = REPO / "bossman-ui" / "src" / "app" / "features" / "runbooks" / "blockly" / "ansibleFacts.js"


def _agent_facts() -> set[str]:
    """The bare fact names setup.go emits (it writes them as `"ansible_<name>"` keys). `ansible_facts` itself
    is the nested dict, not a fact."""
    return {m for m in re.findall(r'"ansible_([a-z_0-9]+)"', SETUP_GO.read_text())} - {"facts"}


def _ui_facts() -> set[str]:
    """The bare names the UI lists — read out of the GATHERED table rather than by executing JS, so the test
    needs no node/bundler and runs in the normal pytest pass."""
    text = FACTS_JS.read_text()
    table = text[text.index("const GATHERED = ["):text.index("];", text.index("const GATHERED = ["))]
    return set(re.findall(r"^\s*\['([a-z_0-9]+)',", table, re.MULTILINE))


@pytest.mark.skipif(not SETUP_GO.exists() or not FACTS_JS.exists(), reason="needs the full repo checkout")
def test_ui_lists_exactly_the_facts_the_agent_gathers():
    agent, ui = _agent_facts(), _ui_facts()
    assert agent, "parsed no facts out of setup.go — the regex or the file layout changed"
    assert ui - agent == set(), (
        f"the UI offers variables the agent does not gather: {sorted(ui - agent)}. "
        "They would not resolve on a host — remove them, or gather them in setup.go.")
    assert agent - ui == set(), (
        f"the agent gathers facts the UI never offers: {sorted(agent - ui)}. "
        f"Add them to GATHERED in {FACTS_JS.name}.")


@pytest.mark.skipif(not SETUP_GO.exists(), reason="needs the full repo checkout")
def test_agent_emits_the_modern_ansible_facts_form():
    """`ansible_facts['distribution']` is the form imported upstream roles use, and importing them is a
    headline promise — so the nested dict has to exist, not just the flat aliases."""
    assert 'facts["ansible_facts"] = nested' in SETUP_GO.read_text(), (
        "setup.go no longer builds the nested ansible_facts dict — imported roles templating "
        "ansible_facts['x'] will fail against StrictUndefined")
