"""A3: the version tag and the If-Match check — pure, no DB."""

import pytest
from fastapi import HTTPException

from bossman.api.etag import check_if_match, compute_version


class _Req:
    """Only the one attribute check_if_match reads."""

    def __init__(self, if_match=None):
        self.headers = {} if if_match is None else {"if-match": if_match}


def test_the_same_content_always_hashes_the_same():
    """Field order must not matter — a dict's order is not part of the object's identity."""
    assert compute_version({"a": 1, "b": 2}) == compute_version({"b": 2, "a": 1})


def test_different_content_hashes_differently():
    assert compute_version({"warn": 80}) != compute_version({"warn": 85})


def test_volatile_fields_do_not_change_the_version():
    """Otherwise a server-computed field would invent conflicts nobody caused.

    `active_now` flips as the clock moves and `service_states` follows the fleet, so if either
    were part of the tag, every save would fail with a conflict whose cause the operator
    cannot see or fix.
    """
    base = {"name": "business", "ranges": {"monday": [["08:00", "17:00"]]}}
    assert compute_version({**base, "active_now": True}) == compute_version({**base, "active_now": False})
    assert compute_version({**base, "service_states": {"Memory": "OK"}}) == compute_version(base)
    assert compute_version({**base, "version": "deadbeef"}) == compute_version(base)


def test_no_if_match_is_allowed_through():
    """Honoured-when-present, deliberately: requiring it would break every existing client."""
    check_if_match(_Req(), "abc123")


def test_a_matching_tag_passes():
    check_if_match(_Req("abc123"), "abc123")
    check_if_match(_Req('"abc123"'), "abc123"), "quoted, as an HTTP client sends it back"
    check_if_match(_Req('W/"abc123"'), "abc123"), "weak tag"


def test_a_star_matches_any_version():
    check_if_match(_Req("*"), "abc123")


def test_a_stale_tag_is_a_precondition_failure():
    with pytest.raises(HTTPException) as exc:
        check_if_match(_Req("oldtag"), "newtag")
    assert exc.value.status_code == 412
    assert "newtag" in exc.value.detail, "the current version belongs in the message"
    assert "re-read" in exc.value.detail, "and what to do about it"


def test_a_list_of_tags_passes_when_one_matches():
    """RFC 9110 allows a comma-separated list."""
    check_if_match(_Req('"other", "abc123"'), "abc123")
    with pytest.raises(HTTPException):
        check_if_match(_Req('"other", "another"'), "abc123")


def test_a_pydantic_model_is_accepted():
    from pydantic import BaseModel

    class M(BaseModel):
        name: str
        warn: int

    assert compute_version(M(name="x", warn=1)) == compute_version({"name": "x", "warn": 1})


def test_unserialisable_values_do_not_crash_the_tag():
    """A UUID or datetime in the payload must hash, not raise — `default=str` covers it."""
    import uuid
    from datetime import datetime, timezone

    v = compute_version({"id": uuid.uuid4(), "at": datetime.now(timezone.utc)})
    assert len(v) == 16
