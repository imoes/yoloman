"""access_grants reference their subject by UID, not by name

Measured before this change: `subject_ref` held a NAME, `api_tokens.name` had no unique
constraint, and one grant on "mon-caller" therefore authorised 28 different tokens (18 for
"test-caller"). A token deleted and recreated under the same name silently inherited
`scope=all, permission=manage` from a run weeks earlier. For test names that was noise; for a real
token name it is a grant of rights nobody issued.

The shape follows LDAP, which the user pointed at: an entry has a hierarchical NAME (its DN) and
an immutable entryUUID, and a referential-integrity overlay keeps DN-valued references honest.
Here the uid is `api_tokens.id`, the reference is a real foreign key, and ON DELETE CASCADE is the
refint overlay's delete half — a grant cannot outlive its subject, so it cannot be inherited.

`subject_ref` stays: it is what a human reads in an audit line, and for `subject_kind='user'` it
remains the reference (a username IS the identity there — bossman_users has no separate uid the
grants could point at). The constraint below therefore binds only api_token grants.

At the time of writing every existing grant was test residue (990 rows, all `*-caller`, zero real
ones — verified before deleting them), so nothing had to be mapped: the column is added NOT NULL
for api_token grants from the start rather than backfilled with guesses.

Revision ID: c4f9b2e70a18
Revises: b3e7d1a48c52
Create Date: 2026-08-15 00:05:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = 'c4f9b2e70a18'
down_revision: Union[str, Sequence[str], None] = 'b3e7d1a48c52'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'access_grants',
        sa.Column('subject_token_id', postgresql.UUID(as_uuid=True),
                  sa.ForeignKey('api_tokens.id', ondelete='CASCADE'), nullable=True),
    )
    # Map what can be mapped unambiguously; a name shared by several tokens is exactly the
    # ambiguity this change removes, so it is not guessed at.
    op.execute(
        "UPDATE access_grants g SET subject_token_id = t.id FROM api_tokens t "
        "WHERE g.subject_kind = 'api_token' AND t.name = g.subject_ref "
        "AND (SELECT count(*) FROM api_tokens t2 WHERE t2.name = g.subject_ref) = 1"
    )
    # Anything left over would authorise by name — the very thing being removed.
    op.execute("DELETE FROM access_grants WHERE subject_kind = 'api_token' AND subject_token_id IS NULL")
    op.create_check_constraint(
        'ck_access_grants_token_uid',
        'access_grants',
        "(subject_kind <> 'api_token') OR (subject_token_id IS NOT NULL)",
    )


def downgrade() -> None:
    op.drop_constraint('ck_access_grants_token_uid', 'access_grants', type_='check')
    op.drop_column('access_grants', 'subject_token_id')
