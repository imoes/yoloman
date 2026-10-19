"""A man-page mirror that does not answer is skipped for the rest of the run (man7.org hung behind the proxy,
2026-10-16: every candidate waited out its timeout and one package took 199 s to be skipped)."""

import asyncio

import httpx

from bossman.tools import qualify_packages as Q


class _Mirrors:
    def __init__(self):
        self.calls = []

    async def fetch(self, url, max_chars=0):
        self.calls.append(url)
        if "man7.org" in url:
            raise httpx.ConnectTimeout("no answer")
        raise httpx.HTTPStatusError("404", request=None, response=None)


def test_a_mirror_that_does_not_answer_is_asked_once(monkeypatch):
    monkeypatch.setattr(Q, "_DEAD_MAN_HOSTS", set())
    m = _Mirrors()
    asyncio.run(Q._online_manpage(m, "sssd"))
    asyncio.run(Q._online_manpage(m, "chrony"))
    assert sum("man7.org" in u for u in m.calls) == 1
    # A 404 is an answer: the other mirror is still asked for every candidate.
    assert sum("manpages.debian.org" in u for u in m.calls) > 2
