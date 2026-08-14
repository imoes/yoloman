"""Row names a test run can recognise as its OWN.

The residue guards in conftest used to select by "test-shaped name AND created_at >= my start
time". That cannot tell this run's rows from a concurrent run's — and it was measured doing
exactly that: three test files pass alone but produced 10 and 12 failures when two runs started
together, because each teardown deleted the other's freshly seeded hosts.

So names carry an ownership marker. `RUN_TAG` is minted once per process; `owned_name(prefix)`
produces `<prefix>-<RUN_TAG><4 hex>`, which keeps the `<prefix>-<8 hex>` shape the guards already
recognise while making the owner readable from the name alone.

A suite that has not adopted this yet is not endangered by another run: its rows are neither
owned nor old enough to be swept, so they are left alone and cleaned later as orphans. Residue
delayed is the safe failure direction; another run's data destroyed is not.
"""

import uuid

#: One marker per test process, embedded in every name minted here.
RUN_TAG = uuid.uuid4().hex[:8]


def owned_name(prefix: str) -> str:
    """`<prefix>-<RUN_TAG><4 hex>`.

    NOT called `test_name`: pytest collects every module-level callable whose name starts with
    `test_`, so that spelling turned the helper itself into a failing test case (it took a
    required argument). Caught by the collector, not by reading.
    """
    return f"{prefix}-{RUN_TAG}{uuid.uuid4().hex[:4]}"
