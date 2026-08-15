"""The observation point for the ownership rule — falsifiability, not decoration.

tests/naming.py exists because two concurrent runs deleted each other's freshly seeded rows:
the teardown guards selected by "test-shaped name AND created_at >= my start", which cannot
tell one run's data from another's. Names now carry RUN_TAG so a teardown can recognise its OWN.

That fix is only as good as its adoption. A new test file that mints `f"web-{uuid4().hex[:8]}"`
by hand looks exactly like the old ones and reintroduces the defect silently — and silence is
precisely what we forbid elsewhere. This test is the tripwire: it fails on the pattern, names
the file and line, and says what to write instead.

It is deliberately a lint over source text rather than a runtime check. The defect lives in how
a name is CONSTRUCTED, and by the time a row exists the evidence is gone.
"""

import re
from pathlib import Path

TESTS_DIR = Path(__file__).parent

#: `f"web-{uuid.uuid4().hex[:8]}"` / `f"{prefix}-{uuid4().hex[:6]}"` — an unowned name.
#: The trailing slice is what distinguishes a NAME from a token or secret, which are built from
#: the full hex and are none of this test's business.
UNOWNED = re.compile(r'f"[^"]*\{uuid(?:\.uuid4|4)\(\)\.hex\[:\d+\]\}')

#: A bare suffix helper (`return uuid4().hex[:8]`) has the same effect one level down: every
#: call site that interpolates it produces an unowned name.
BARE_SUFFIX = re.compile(r'return\s+uuid(?:\.uuid4|4)\(\)\.hex\[:\d+\]\s*$')

HINT = (
    "use tests.naming.owned_name('<prefix>') (or run_suffix() for an existing _sfx helper) "
    "so the teardown can tell this run's rows from a concurrent run's"
)


def _offences():
    for path in sorted(TESTS_DIR.glob("*.py")):
        if path.name == "naming.py" or path.name == Path(__file__).name:
            continue  # the definition and this guard both quote the pattern on purpose
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if UNOWNED.search(line) or BARE_SUFFIX.search(line.rstrip()):
                yield f"{path.name}:{lineno}: {line.strip()}"


def test_no_test_mints_an_unowned_name():
    found = list(_offences())
    assert not found, (
        f"{len(found)} unowned name(s) — {HINT}:\n  " + "\n  ".join(found)
    )


def test_the_guard_can_actually_fail():
    """A guard that cannot fail proves nothing (petitio principii).

    So assert the patterns match the very shape they are meant to catch. Without this, a typo in
    the regex would turn the tripwire into a permanent green light.
    """
    assert UNOWNED.search('name=f"web-{uuid.uuid4().hex[:8]}"')
    assert UNOWNED.search("name=f\"{prefix}-{uuid4().hex[:6]}\"".replace("\\", ""))
    assert BARE_SUFFIX.search("    return uuid.uuid4().hex[:8]")
    # …and do NOT match the things that are legitimately raw randomness.
    assert not UNOWNED.search('token=f"t-{uuid.uuid4().hex}"')
    assert not BARE_SUFFIX.search("    return uuid.uuid4().hex")
