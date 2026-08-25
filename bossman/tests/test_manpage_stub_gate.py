"""A navigation stub is not a man page.

`_online_manpage` accepted anything over 800 characters. Measured on 15 packages, SEVEN fetches came back as
site chrome that passed: manpages.debian.org answers /ddclient with a 1548-character index page, /nginx with
4271 and /smb with 4065 — while the real smb.conf(5) runs to 200 kB.

The grounding gate then works perfectly and rejects every correct value the model proposed, because a table of
contents does not contain them. Not a hallucination — a silent UNDER-grounding that reads as "this package
documents no values", and part of what looked like a systemd-directive problem earlier.

Raising the floor also RECOVERS pages: the loop no longer stops at the first thin hit, so smb went from a
4 kB stub to the real 200 kB page.
"""

import pytest

from bossman.tools.qualify_packages import _MAN_MIN_CHARS, _online_manpage


class _Mirror:
    """A fake fetcher: {url_substring: text}. Anything unlisted raises, like a 404."""

    def __init__(self, pages: dict[str, str]):
        self.pages = pages
        self.asked: list[str] = []

    async def fetch(self, url: str, max_chars: int = 0) -> str:
        self.asked.append(url)
        for needle, text in self.pages.items():
            if needle in url:
                return text
        raise RuntimeError("404")


async def test_a_stub_is_skipped_and_the_next_candidate_wins():
    """The real failure and the real fix in one: the thin page must not end the search."""
    real = "SMB.CONF(5)\n" + ("directive documentation " * 2000)
    mirror = _Mirror({"man7.org/linux/man-pages/man5/smb.5.html": "Index About Manpages FAQ " * 60,
                      "manpages.debian.org/smb.conf": real})
    got = await _online_manpage(mirror, "smb", "smb.conf")
    assert got == real
    assert len(got) > _MAN_MIN_CHARS


async def test_only_stubs_means_no_page_rather_than_a_stub():
    """Falling back to the shipped .deb config and the web docs is strictly better than grounding on chrome."""
    mirror = _Mirror({"ddclient": "ddclient(8) — Debian Manpages — Skip Quicknav Index About Manpages"})
    assert await _online_manpage(mirror, "ddclient", "ddclient.conf") is None


async def test_a_real_page_is_accepted_even_though_it_carries_the_same_navigation():
    """NO CHROME TEST: manpages.debian.org wraps every page in that navigation, so its presence says nothing.
    A version of this gate that rejected on it threw away redis (43 kB), dnsmasq (138 kB) and ntp (60 kB)."""
    real = "Skip Quicknav Index About Manpages\nREDIS.CONF(5)\n" + ("loglevel debug verbose " * 3000)
    mirror = _Mirror({"redis": real})
    assert await _online_manpage(mirror, "redis", "redis.conf") == real


@pytest.mark.parametrize("body, expected_none", [
    ("no such page", True),          # the mirror's own 404 text, in the first 400 characters
    ("Not Found", True),
    ("x" * (_MAN_MIN_CHARS - 1), True),
    ("y" * (_MAN_MIN_CHARS + 1), False),
])
async def test_the_acceptance_boundary(body, expected_none):
    mirror = _Mirror({"thing": body})
    got = await _online_manpage(mirror, "thing", "thing.conf")
    assert (got is None) is expected_none
