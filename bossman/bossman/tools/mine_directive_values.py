"""ADMX equivalent — mine each codec'd config file's man page for the per-DIRECTIVE
value catalog: what values each key accepts (enum options, bool, int range),
its default, and a one-line description. This is the layer the gpedit editor
needs to offer a real per-directive listbox (e.g. sshd_config PermitRootLogin ->
yes/no/prohibit-password/forced-commands-only) instead of guessing a yes/no
family from the current value.

Complements the codec registry (config_codecs.json = per-file grammar) and the
config templates (whole-file Class-B render): this is the per-key value schema,
keyed the same way as the codec registry. Only files WITH a codec are mined —
codec:"none" files are template territory (their schema.json already carries the
values). The result is configs/config_directives.json.

Runs on a host with `man` installed (uses the bossman venv for the LLM):
    .venv/bin/python scripts/mine_directive_values.py [--limit N] [--only sshd_config crontab]
"""

from __future__ import annotations

import os
import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # the dir holding the `bossman` package —
# correct in both layouts (unlike the configs path, which is why _paths exists)

from bossman.tools._paths import configs_dir, repo_root  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling import

from classify_config_codecs import man_page  # noqa: E402 — reuse the exact man-page lookup
from bossman.services.chat_client import ChatClient  # noqa: E402

QWEN79B = (os.environ.get("YOLOMAN_LLM_BASE", "") + "/laguna", "laguna")

_SCHEMA = {
    "type": "object",
    "properties": {
        "directives": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "type": {"type": "string", "enum": ["enum", "bool", "int", "string", "list"]},
                    "values": {"type": "array", "items": {"type": "string"}},
                    "default": {"type": "string"},
                    "min": {"type": "integer"},
                    "max": {"type": "integer"},
                    "description": {"type": "string"},
                },
                "required": ["name", "type"],
            },
        },
    },
    "required": ["directives"],
}

_SYSTEM = (
    "You are given a Linux config file's man page (section 5). Extract the catalog of its "
    "configuration DIRECTIVES so an editor can render the right input control per directive:\n"
    "- name: the directive/key name exactly as written in the file.\n"
    "- type: enum (a fixed set of allowed keywords), bool (yes/no-style true/false toggle), "
    "int (a number, optionally with a range), string (free text), or list.\n"
    "- values: for type=enum, the EXACT allowed keywords from the man page (e.g. for "
    "PermitRootLogin: yes, no, prohibit-password, forced-commands-only). Required for enum.\n"
    "- default: the documented default value, if any.\n"
    "- min/max: for type=int, the documented bounds, if any.\n"
    "- description: one short line on what the directive does.\n"
    "Only include directives the man page actually documents. Prefer enum/bool/int where the "
    "man page lists concrete allowed values; use string only when values are genuinely free-form. "
    "Return only the directives JSON."
)


async def mine_one(key: str, doc: str, chat: ChatClient) -> dict[str, dict]:
    """Mine ONE config file's documentation (its man page and/or web docs) into
    the per-directive value catalog: {directive: {type, values?, default?, min?,
    max?, description?}}. `doc` is any grounding text — a section-5 man page, an
    online man page, or concatenated web docs. Raises on LLM failure so the
    caller decides retry vs skip (the qualify pipeline registers it as a failure;
    the standalone runner skips the file and continues)."""
    user = f"Config file: {key}\n=== documentation ===\n{doc[:60000]}"
    out = await chat.complete_json(
        [{"role": "system", "content": _SYSTEM}, {"role": "user", "content": user}],
        _SCHEMA, "directive_catalog",
    )
    # TWO ENGINES, TWO SHAPES. llama.cpp enforces the schema as a GRAMMAR, so the answer is always
    # {"directives": [...]}. OpenRouter's json_schema mode is best-effort for some models, and
    # poolside/laguna-s-2.1 returns the bare ARRAY — which raised 'list' object has no attribute 'get' on
    # every path. Normalising the shape here is the caller's job: the model was asked for a list of
    # directives and gave one, in a different wrapper.
    if isinstance(out, list):
        items = out
    elif isinstance(out, dict):
        items = out.get("directives")
        if not isinstance(items, list):
            # A single list value under some other key ({"result": [...]}) is the same answer again.
            lists = [v for v in out.values() if isinstance(v, list)]
            items = lists[0] if len(lists) == 1 else []
    else:
        items = []
    directives: dict[str, dict] = {}
    for d in items:
        if not isinstance(d, dict):
            continue
        name = (d.get("name") or "").strip()
        if not name:
            continue
        entry: dict = {"type": d.get("type", "string")}
        if d.get("values"):
            entry["values"] = d["values"]
        if d.get("default") not in (None, ""):
            entry["default"] = d["default"]
        if isinstance(d.get("min"), int):
            entry["min"] = d["min"]
        if isinstance(d.get("max"), int):
            entry["max"] = d["max"]
        if d.get("description"):
            entry["description"] = d["description"]
        directives[name] = entry
    return directives


async def run(args) -> None:
    root = repo_root(__file__)
    codecs_path = root / "configs" / "config_codecs.json"
    if not codecs_path.exists():
        print("no config_codecs.json — run classify_config_codecs.py first")
        return
    codecs = json.loads(codecs_path.read_text())

    only = list(dict.fromkeys(args.only)) if args.only else None
    if only:
        # Targeted: mine exactly the requested names via their man page, even if
        # the codec registry missed them (e.g. sshd_config) — an explicit ask
        # shouldn't be gated on registry completeness.
        candidates = only
    else:
        # Bulk: mine codec'd, man-documented files. codec:"none" is template
        # territory (values live in the template's schema.json); well-known dirs
        # like /etc/default/* have no man page and arbitrary keys.
        candidates = sorted(
            key for key, spec in codecs.items()
            if isinstance(spec, dict) and spec.get("codec") not in (None, "none")
        )

    dest = root / "configs" / "config_directives.json"
    existing = json.loads(dest.read_text()) if dest.exists() else {}
    keys = candidates
    if not args.force and not only:
        before = len(keys)
        keys = [k for k in keys if k not in existing]
        if before - len(keys):
            print(f"resume: skipping {before - len(keys)} already-mined files")
    if args.limit:
        keys = keys[: args.limit]
    print(f"{len(candidates)} codec'd files; mining {len(keys)} via LLM")

    chat = ChatClient(QWEN79B[0], QWEN79B[1], timeout=900.0)
    for i, key in enumerate(keys, 1):
        found = man_page([key, key.rsplit(".", 1)[0]])
        if found is None:
            print(f"[{i}/{len(keys)}] {key}: no man page, skip")
            continue
        _mankey, man = found
        # Big man pages (sshd_config ~90 KB) must not be cut before later
        # directives (PermitRootLogin is past the middle); give qwen a wide
        # window + a large output budget so the whole catalog comes back.
        try:
            directives = await mine_one(key, man, chat)
        except Exception as exc:  # noqa: BLE001
            print(f"[{i}/{len(keys)}] {key}: ERROR {str(exc)[:100]}")
            continue
        existing[key] = directives
        # Persist after each file so a restart resumes at file granularity
        # (a 92-file pass is hours of LLM work — don't risk losing it all).
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(existing, indent=2, sort_keys=True))
        print(f"[{i}/{len(keys)}] {key}: {len(directives)} directives")

    print(f"\nwrote {dest} ({len(existing)} files)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--force", action="store_true", help="re-mine even files already in the catalog")
    asyncio.run(run(ap.parse_args()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
