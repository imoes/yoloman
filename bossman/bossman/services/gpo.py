"""GPO-style precedence resolution (Block L3a) — the single, pure, DB-free
implementation of "which rule wins for this host", shared by monitoring
(`resolve_effective_rule`) and the orchestration compiler
(`resolve_orchestration_assignments`).

Semantics verified against Microsoft Learn (Group Policy processing) and
mapped onto Bossman's scope levels — see docs/policy-orchestration-architecture.md
§4:

  * Processing is top-down; the level CLOSEST to the host wins normally.
    Bossman levels, weakest→strongest: global < group < OU(root→host) < host.
  * `enforced` (a link/rule property): an enforced rule at a HIGHER level
    can't be overridden by lower levels, and it's immune to block
    inheritance. Among enforced rules the HIGHEST level wins.
  * `block_inheritance` (an OU/container property): drops all NON-enforced
    rules inherited from levels ABOVE the blocking OU.
  * Ties within one level: lowest `link_order`, then newest `created_at`.
"""

from __future__ import annotations

from dataclasses import dataclass

# Level scale (higher = closer to the host = stronger under normal rules).
LEVEL_GLOBAL = 0
LEVEL_GROUP = 1
LEVEL_OU_BASE = 2  # an OU at ancestry depth d (0 = tenant root) has level LEVEL_OU_BASE + d
# A Site (subnet-scoped) sits ABOVE every OU depth but below the host itself:
# global < group < OU(any depth) < Site < host. High constant so no realistic OU
# tree depth can reach it — avoids renumbering LEVEL_OU_BASE and its call sites.
LEVEL_SITE = 500_000
LEVEL_HOST = 1_000_000


@dataclass
class GpoCandidate:
    """One rule/link normalized for precedence resolution. `obj` is the
    original ORM object the winner is read back from."""

    obj: object
    enforced: bool
    level: int
    link_order: int
    created_ts: float
    # Secondary within-level rank (only used for group nesting depth today:
    # a rule scoped to "Europe/Latvia" outranks one scoped to "Europe").
    subrank: int = 0


def resolve_winner(candidates: list[GpoCandidate], blocked_level: int | None = None):
    """Return the winning candidate's `obj` per GPO semantics, or None if the
    candidate set is empty (after block-inheritance filtering).

    `blocked_level` = the deepest OU level on the host's path that has
    block_inheritance set (None if no OU on the path blocks). Non-enforced
    candidates strictly above that level are discarded."""
    if blocked_level is not None:
        candidates = [c for c in candidates if c.enforced or c.level >= blocked_level]
    if not candidates:
        return None

    enforced = [c for c in candidates if c.enforced]
    if enforced:
        # Highest hierarchy wins → smallest level. Tie: lowest link_order,
        # then newest created_at.
        winner = min(enforced, key=lambda c: (c.level, c.link_order, -c.created_ts))
        return winner.obj

    # Normal: closest/deepest wins → largest level. Tie within a level:
    # deeper subrank, then lowest link_order, then newest created_at.
    winner = max(candidates, key=lambda c: (c.level, c.subrank, -c.link_order, c.created_ts))
    return winner.obj
