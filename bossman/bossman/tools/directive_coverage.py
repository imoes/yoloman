"""Does the directive catalog describe the settings the shipped file actually uses?

Moved here from scripts/check_directive_coverage.py so the model benchmark and that script ask the SAME question.

A directive catalog mined from documentation can be large and still useless: 72 entries for chrony.conf are worth
nothing if none of them is a key that appears in the file a host really has. The settings editor looks each key of
the OBSERVED file up in this catalog, so the number that matters is "how many of the file's own keys are described".

  covered   the file's active keys that the catalog describes — what the editor gains.
  extra     catalog entries the file does not currently use. NOT an error (a documented directive absent from the
            default config is what an editor should offer to ADD), but a wildly higher count is what a
            hallucination would look like.
"""

from __future__ import annotations

import re

_COMMENT = ("#", ";", "//")


def active_keys(text: str, separator: str) -> set[str]:
    """The keys the file actually sets. A NESTED document is addressed by dotted path, not by line."""
    nested = _dotted(text)
    if nested is not None:
        return nested
    return _line_keys(text, separator)


def _dotted(text: str) -> set[str] | None:
    try:
        import yaml  # noqa: PLC0415
        tree = yaml.safe_load(text)
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(tree, dict) or not any(isinstance(v, (dict, list)) for v in tree.values()):
        return None
    out: set[str] = set()

    def walk(node, prefix: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f"{prefix}.{key}" if prefix else str(key))
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{prefix}.{index}")
        elif prefix:
            out.add(prefix)

    walk(tree, "")
    return out or None


def _line_keys(text: str, separator: str) -> set[str]:
    """The keys the file actually sets, split the way its codec would split them."""
    keys = set()
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith(_COMMENT) or stripped.startswith("["):
            continue
        if separator == " ":
            parts = re.split(r"[ \t]+", stripped, maxsplit=1)
        else:
            parts = stripped.split(separator or "=", 1)
        key = parts[0].strip()
        if key:
            keys.add(key)
    return keys


def coverage(text: str, specs: dict, separator: str) -> dict:
    """{keys, covered, extra} for one file. Case-insensitive on purpose: plenty of files disagree with their
    documentation on case alone, and that is not a miss."""
    keys = active_keys(text, separator or "=")
    lowered = {k.lower() for k in specs or {}}
    covered = {k for k in keys if k.lower() in lowered}
    return {"keys": len(keys), "covered": len(covered), "extra": len(specs or {}) - len(covered)}
