"""man_lookup: the agent's manpage module behind man_search, with named errors."""

import pytest

from bossman.services.manpages import man_lookup


class _Client:
    def __init__(self, result=None, error=None):
        self.result, self.error, self.calls = result, error, []

    async def call_tool(self, name, params):
        self.calls.append((name, params))
        if self.error:
            raise RuntimeError(self.error)
        return self.result


@pytest.mark.asyncio
async def test_lookup_forwards_the_arguments_and_returns_the_data():
    c = _Client({"data": {"results": [{"page": "sshd_config"}]}})
    out = await man_lookup(c, {"query": "ssh daemon", "page": "", "full_text": False, "host": "h1"})
    assert out == {"results": [{"page": "sshd_config"}]}
    assert c.calls == [("manpage", {"query": "ssh daemon", "max_chars": 8000})]   # empty/False/host not forwarded


@pytest.mark.asyncio
async def test_an_old_agent_is_named():
    out = await man_lookup(_Client(error="unknown tool: manpage"), {"page": "crontab"})
    assert "has no `manpage` module" in out["error"]


@pytest.mark.asyncio
async def test_nothing_to_look_up_is_refused():
    assert "give `query`" in (await man_lookup(_Client({}), {}))["error"]
