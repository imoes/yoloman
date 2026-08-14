"""A3: optimistic locking on writes — `version` + `If-Match`.

The problem: two operators editing the same rule silently overwrite each other. Whoever
saves last wins and the first change is gone without a trace. Checkmk solves it with the
standard HTTP edit-conflict dance (`cmk/gui/openapi/README.md`): a GET returns an `ETag`, the
PUT sends it back in `If-Match`, and the server refuses if the object moved in between.

Two deliberate differences from that contract, both forced by our API's shape:

1. **The tag is also a FIELD on the object** (`version`), not only a response header. Checkmk
   has a single-resource GET per object to hang an `ETag` header on; ours are collection
   endpoints — the UI lists rules and edits one from that list, and HTTP headers cannot carry
   a per-item tag for a collection. Putting it in the payload is the only way the client can
   know an item's version without an extra round trip per row. The `ETag` header is still set
   on single-object responses, so a client that does re-read gets it the standard way.

2. **`If-Match` is honoured when present, not required.** Checkmk rejects a write that omits
   it. Doing that here would break every existing client the moment this shipped, including
   our own UI and any operator scripts. So the guarantee is: a client that sends the header
   cannot clobber a concurrent change. Making it mandatory is a follow-up once the clients
   are known to comply — worth doing, because until then a caller that forgets the header
   still overwrites silently.

The tag is a hash of the object's own content, not a timestamp: our rows have `created_at`
but no `updated_at`, and a content hash needs no migration and cannot go stale after a
restore or a manual DB fix.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from fastapi import HTTPException, Request
from pydantic import BaseModel

# Fields that must not influence the version: the tag itself, and anything the server
# recomputes for presentation rather than storing (an aggregate's live state, "is this window
# active right now"). Including those would make the version change without anyone editing
# the object, so every save would fail with a conflict that has no cause.
#
# Server-assigned provenance belongs here too (`template_id`,
# `source_template_rule_id`): a client cannot edit it, so it is not "editable content" —
# and hashing it would mean that merely *exposing* provenance invalidates every version
# tag clients already hold, turning the next save into a conflict with no cause.
_VOLATILE = frozenset({
    "version", "active_now", "service_states", "nodes", "timezone", "created_at",
    "template_id", "source_template_rule_id",
})


def compute_version(payload: Any) -> str:
    """A stable tag for this object's editable content.

    Canonical JSON (sorted keys, no whitespace) so the same content always hashes the same
    regardless of field order, and truncated to 16 hex chars — enough that a collision needs
    ~2^32 distinct versions of one object, and short enough to read in a log.
    """
    if isinstance(payload, BaseModel):
        payload = payload.model_dump(mode="json")
    if isinstance(payload, dict):
        payload = {k: v for k, v in payload.items() if k not in _VOLATILE}
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def check_if_match(request: Request, current: str) -> None:
    """412 when the caller holds a stale version; silent pass when it holds none.

    A weak/quoted ETag (`W/"abc"`, `"abc"`) is accepted as its bare value, because that is
    what an HTTP client library will send back after reading our header. `*` means "any
    version", the standard way to say "I know this exists, I do not care which version".
    """
    header = request.headers.get("if-match")
    if not header:
        return
    for raw in header.split(","):
        tag = raw.strip()
        if tag.startswith("W/"):
            tag = tag[2:].strip()
        tag = tag.strip('"')
        if tag in (current, "*"):
            return
    raise HTTPException(
        status_code=412,
        detail=(
            f"the object was modified by someone else (its version is now {current!r}); "
            "re-read it and re-apply your change"
        ),
    )
