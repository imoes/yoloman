"""A curation table with a key twice keeps only the LAST entry — silently. Found 2026-10-11: a second "frr" in
REDHAT_FIXES dropped the unit the first one named. Every dict literal at module level must have unique keys."""

import ast
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "bossman" / "tools" / "curate_catalog.py"


def test_no_curation_table_repeats_a_key():
    tree = ast.parse(SOURCE.read_text())
    repeats = []
    for node in tree.body:
        value = node.value if isinstance(node, (ast.Assign, ast.AnnAssign)) else None
        if not isinstance(value, ast.Dict):
            continue
        name = getattr(node.targets[0] if isinstance(node, ast.Assign) else node.target, "id", "?")
        seen = set()
        for key in value.keys:
            if isinstance(key, ast.Constant):
                if key.value in seen:
                    repeats.append(f"{name}[{key.value!r}]")
                seen.add(key.value)
    assert not repeats, f"repeated keys (the earlier entry is lost): {repeats}"
