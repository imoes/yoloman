"""Resource generations are pruned, and a pruned rollback target says so.

Nothing removed a row from `resource_generations` until 2026-08-31: every resource apply added one and
none were ever deleted, so a resource applied on a cycle grew the table without bound. The rows are
small, which is precisely why it went unnoticed — the cost only shows up as a table nobody can explain.

Two properties are pinned here, and the second one matters more than the first:

  1. only the newest MAX_GENERATIONS survive, and the numbering keeps climbing (a rollback reference
     must never be reused for a different spec),
  2. a rollback to a generation that WAS there and got dropped says "pruned", not "no such
     generation" — otherwise a trimmed history is indistinguishable from a typo.
"""

from sqlalchemy import delete, select

from bossman.db.models import ResourceGeneration
from bossman.services.resources import base


async def _record(db_session, key: str, n: int) -> list[int]:
    return [await base.record_generation(db_session, key, "test", {"i": i}, note=f"n{i}")
            for i in range(n)]


async def _generations(db_session, key: str) -> list[int]:
    return sorted((await db_session.scalars(
        select(ResourceGeneration.generation).where(ResourceGeneration.resource_key == key))).all())


async def test_only_the_newest_are_kept_and_numbering_keeps_climbing(db_session):
    key = "test:prune:newest"
    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()

    over = base.MAX_GENERATIONS + 5
    returned = await _record(db_session, key, over)

    # The numbers handed out never restart: 1..35 even though only 30 rows survive. A reused number
    # would point a stored rollback reference at a different spec.
    assert returned == list(range(1, over + 1))

    kept = await _generations(db_session, key)
    assert len(kept) == base.MAX_GENERATIONS
    assert kept == list(range(over - base.MAX_GENERATIONS + 1, over + 1))

    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()


async def test_a_pruned_rollback_target_says_pruned(db_session):
    key = "test:prune:reason"
    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()
    await _record(db_session, key, base.MAX_GENERATIONS + 3)

    gone = await base.no_such_generation(db_session, key, 1, "thing")
    assert gone["ok"] is False
    assert "pruned" in gone["error"] and str(base.MAX_GENERATIONS) in gone["error"]

    # A number that never existed is a DIFFERENT answer — the two must not read alike.
    never = await base.no_such_generation(db_session, key, 9999, "thing")
    assert never["ok"] is False
    assert "pruned" not in never["error"]

    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()


async def test_under_the_cap_nothing_is_pruned(db_session):
    """The guard must not start deleting before there is anything to make room for."""
    key = "test:prune:under"
    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()

    await _record(db_session, key, 5)
    assert await _generations(db_session, key) == [1, 2, 3, 4, 5]

    await db_session.execute(delete(ResourceGeneration).where(ResourceGeneration.resource_key == key))
    await db_session.commit()
