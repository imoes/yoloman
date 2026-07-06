"""Pure helpers for the Block-G8 translation pipeline (no I/O): build the
deterministic metadata YAML from a dumped module source (the G1-generator
light — the LLM only ever translates *logic*, never invents argspecs),
derive stub-run sample params from the argspec, and construct the
translation/retry prompts. Kept in services/ so the logic is unit-tested
like everything else; the MCP/LLM wiring lives in scripts/.
"""

from __future__ import annotations

import json
from typing import Any

import yaml

# Both endpoints expose a 256K context, so the source is never the budget
# constraint — the module code (the payload) is returned as raw text, not
# wrapped in a JSON-schema envelope (which would only force the model to
# escape every newline/quote of the code into a string, error-prone and
# token-wasteful for a single code blob — see docs/plan.md Block G8).

# Original module sources can exceed the useful context budget —
# community.general has multi-thousand-line modules. The doc/argspec
# carries the behavioral contract; the source is supporting evidence, so
# it gets truncated, not the argspec.
SOURCE_CHAR_BUDGET = 40_000


def extract_star_code(text: str) -> str:
    """Pulls the Starlark module out of a raw completion: strips a
    ```python/```starlark/``` fence if the model added one, otherwise
    returns the text as-is. Idempotent and fence-optional."""
    s = text.strip()
    if "```" in s:
        # Take the content of the first fenced block.
        after = s.split("```", 1)[1]
        # Drop an optional language tag on the fence's first line.
        if "\n" in after:
            first_line, rest = after.split("\n", 1)
            if first_line.strip().lower() in ("python", "starlark", "star", "py", ""):
                after = rest
        s = after.split("```", 1)[0]
    return s.strip() + "\n"


def build_metadata_yaml(record: dict[str, Any]) -> str:
    """The module's catalog metadata (G1 schema), derived 1:1 from the
    ansible-doc dump — deterministic, never LLM-authored."""
    doc = record.get("doc") or {}
    options = {}
    for name, spec in sorted((doc.get("options") or {}).items()):
        opt: dict[str, Any] = {"type": spec.get("type", "str")}
        if spec.get("required"):
            opt["required"] = True
        if "default" in spec and spec["default"] is not None:
            opt["default"] = spec["default"]
        if spec.get("choices"):
            opt["choices"] = spec["choices"]
        if spec.get("aliases"):
            opt["aliases"] = spec["aliases"]
        desc = spec.get("description")
        if isinstance(desc, list):
            desc = " ".join(str(d) for d in desc)
        if desc:
            opt["description"] = str(desc)
        options[name] = opt

    description = doc.get("description")
    if isinstance(description, list):
        description = " ".join(str(d) for d in description)

    name = record["name"]
    meta = {
        "name": name,
        "fqcn": record["fqcn"],
        "collection": record["collection"],
        "short_description": record.get("short_description") or doc.get("short_description") or "",
        "description": description or "",
        "options": options,
        "writes": not (name.endswith("_info") or name.endswith("_facts")),
        "runtime": "starlark",
        "source": "translated",
    }
    examples = record.get("examples")
    if examples:
        meta["examples"] = examples
    return yaml.safe_dump(meta, sort_keys=False, allow_unicode=True, width=100)


def sample_params(record: dict[str, Any]) -> dict[str, Any]:
    """Plausible arguments for the validator's stub run: every required
    option filled with a type-appropriate dummy (first choice wins)."""
    params: dict[str, Any] = {}
    for name, spec in ((record.get("doc") or {}).get("options") or {}).items():
        if not spec.get("required"):
            continue
        if spec.get("choices"):
            params[name] = spec["choices"][0]
            continue
        typ = spec.get("type", "str")
        params[name] = {
            "str": "example",
            "path": "/tmp/example",
            "int": 1,
            "float": 1.0,
            "bool": False,
            "list": ["example"],
            "dict": {},
            "raw": "example",
        }.get(typ, "example")
    return params


def build_translation_messages(contract: str, record: dict[str, Any]) -> list[dict[str, str]]:
    """The initial prompt: the full authoring contract as system prompt
    (static across all modules — prompt-cache friendly), the per-module
    template as the user message."""
    doc = record.get("doc") or {}
    source = record.get("source_py") or ""
    truncated = len(source) > SOURCE_CHAR_BUDGET
    if truncated:
        source = source[:SOURCE_CHAR_BUDGET]

    system = (
        "You translate Ansible modules into Starlark modules for the yolo-man agent.\n"
        "Follow this contract EXACTLY:\n\n"
        f"{contract}\n\n"
        "Rules for your answer:\n"
        "- Output ONLY the Starlark module code — no prose, no explanation, no JSON. "
        "A single ```python fenced block is fine; nothing else.\n"
        "- Reproduce the original module's behavior for its common cases: same option names, "
        "same idempotency, same check_mode semantics. Prefer a faithful core over exotic corner cases; "
        "if an option cannot be supported, fail() with a clear message when it is passed.\n"
        "- Starlark is NOT Python: no imports, no try/except, no classes, no f-strings, no while-True, "
        "no regex — use str methods (split, find, strip, startswith) instead.\n"
        "- Interact with the system ONLY through ctx.* builtins. Never invent builtins.\n"
        "- Keep it focused: typically 30-120 lines."
    )
    user = (
        f"Translate this Ansible module to a Starlark module.\n\n"
        f"FQCN: {record['fqcn']}\n"
        f"Short description: {record.get('short_description', '')}\n\n"
        f"Argspec (the params dict your main() receives, same option names):\n"
        f"{json.dumps(doc.get('options') or {}, indent=1, sort_keys=True)[:8000]}\n\n"
        f"Original Python implementation{' (truncated)' if truncated else ''}:\n"
        f"```python\n{source}\n```"
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def build_retry_messages(
    messages: list[dict[str, str]], star_code: str, validation: dict[str, Any]
) -> list[dict[str, str]]:
    """Extends the conversation with the validator's structured findings
    so the model can repair its own output."""
    errors = json.dumps(validation.get("errors") or [], indent=1)
    return messages + [
        {"role": "assistant", "content": star_code},
        {
            "role": "user",
            "content": (
                "The validator rejected this module. Fix every finding and return the FULL corrected "
                f"Starlark module again (code only).\n\nValidator findings:\n{errors}"
            ),
        },
    ]
