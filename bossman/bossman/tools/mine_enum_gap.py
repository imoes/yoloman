"""Mine enums for the templates that still have an ENUMERABLE string field without a dropdown.

    python -u -m bossman.tools.mine_enum_gap --check-only
    QUALIFY_LLM_URL=https://…/laguna QUALIFY_LLM_MODEL=laguna python -u -m bossman.tools.mine_enum_gap

WHY A SEPARATE RUNNER and not a PIPELINE_VERSION bump. The enum stage already ran: 9570 of 9584 packages are
at v6-enriched, and 2843 fields across 1371 templates DO carry an enum. Bumping the pipeline version to try
again would re-run codec, template and enrich for 9584 packages — days — to redo one stage. This asks the one
question that is still open, for the packages where it is still open, and is resumable at package
granularity.

WHAT THE GAP ACTUALLY IS, measured over configs/config_templates:

    28 760 string fields          of which  2 843 enumerated
     2 073 have an ENUM-ISH NAME and no enum (level/mode/protocol/backend/cipher/…) — 1217 templates
    11 548 have a free-text name (path/host/user/password/…) — correctly free text
    12 296 are neither, and a name is not evidence either way

So the worklist is the 1217, by NAME — a heuristic, and stated as one. It is used only to CHOOSE what to ask
about; nothing is accepted on the strength of a name. The acceptance rule is unchanged and lives in
qualify_packages._mine_enums: every value must appear verbatim in a fetched source (man page, the config the
.deb ships, official web docs), and fewer than two grounded values is a refusal, because a one-option
dropdown is not a choice.

That gate is also why the gap exists at all, and it should stay: the pass that produced these templates had
no man page and no shipped config for many packages, and an ungrounded enum is a wrong dropdown — worse than
a text box, because the operator cannot type the value the software actually wants. This run does not weaken
it; it re-asks with a different model and, where the primary sources are silent, one targeted per-field
search.

ONE PROCESS, always. The llama.cpp endpoint is shared with the other batches; concurrency there makes every
caller slower and the runs unrepeatable. Resumability is the substitute for parallelism, so a kill costs one
package.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from pathlib import Path

from bossman.tools._jsonio import write_catalog
from bossman.tools.qualify_packages import (
    CODECS, TEMPLATES_DIR, _config_path, _deb_config, _load, _mine_enums, _resolve_man, _web_docs,
    build_entry_map, llm_client, CATALOG, SEARXNG,
)
from bossman.services.websearch import SearxngClient

STATE = TEMPLATES_DIR.parent / ".enum_gap_state.json"

#: Names whose value set is plausibly finite. A HEURISTIC, used only to pick what to ask about — never to
#: accept a value. Derived from the field names that DID get enums, so it describes the observed shape of an
#: enumerable setting rather than a guess about one.
ENUMISH = re.compile(
    r"(^|_)(level|mode|driver|protocol|backend|algorithm|compression|scheme|auth|method|type|format|"
    r"encoding|policy|strategy|scheduler|state|action|cipher|version|facility|verbosity|severity|"
    r"style|order|family)($|_)")


def gap_fields(schema: dict) -> list[str]:
    """The enum-ish string fields of one schema that carry no enum."""
    props = schema.get("properties", schema) if isinstance(schema, dict) else {}
    if not isinstance(props, dict):
        return []
    return [k for k, v in props.items()
            if isinstance(v, dict) and v.get("type") == "string" and not v.get("enum")
            and not k.startswith("_") and ENUMISH.search(k.lower())]


def worklist() -> dict[str, list[str]]:
    """template name -> its gap fields, for every template that has any."""
    out: dict[str, list[str]] = {}
    for d in sorted(TEMPLATES_DIR.iterdir()):
        if not d.is_dir():
            continue
        try:
            schema = json.loads((d / "schema.json").read_text())
        except (OSError, ValueError):
            continue
        fields = gap_fields(schema)
        if fields:
            out[d.name] = sorted(fields)
    return out


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=0, help="process at most N templates this pass")
    ap.add_argument("--only", default="", help="comma-separated template names")
    ap.add_argument("--check-only", action="store_true", help="report the gap, ask nothing")
    ap.add_argument("--redo", action="store_true", help="clear the state for the selected names first")
    ap.add_argument("--llm-url", default=os.environ.get("QUALIFY_LLM_URL", ""))
    ap.add_argument("--llm-model", default=os.environ.get("QUALIFY_LLM_MODEL", ""))
    ap.add_argument("--llm-token", default=os.environ.get("QUALIFY_LLM_TOKEN", ""))
    ap.add_argument("--preset", default="laguna", help="fallback backend preset when no --llm-url is given")
    args = ap.parse_args()

    gap = worklist()
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    if only:
        gap = {k: v for k, v in gap.items() if k in only}
    state = _load(STATE, {})
    if args.redo:
        for name in list(gap):
            state.pop(name, None)
    pending = [n for n in gap if n not in state]

    total_fields = sum(len(v) for v in gap.values())
    print(f"enum gap: {len(gap)} template(s), {total_fields} enum-ish string field(s) without a dropdown — "
          f"{len(pending)} pending, {len(gap) - len(pending)} already asked", flush=True)
    if args.check_only:
        for name in pending[:20]:
            print(f"  {name}: {', '.join(gap[name][:6])}")
        return 0
    if args.limit:
        pending = pending[: args.limit]
    if not pending:
        print("nothing to do")
        return 0

    catalog = _load(CATALOG, {})
    entries = build_entry_map(catalog)
    codecs = _load(CODECS, {})
    qwen = llm_client(args.llm_url, args.llm_model, args.llm_token, args.preset)
    searx = SearxngClient(SEARXNG)
    print(f"backend: {args.llm_model or args.preset} @ {args.llm_url or 'preset'}", flush=True)

    added_total = 0
    for index, name in enumerate(pending, 1):
        entry = entries.get(name) or {"name": name}
        fam = (entry.get("families") or {}).get("debian") or {}
        cfg = fam.get("config_path") or _config_path(name, entry, None, codecs)
        cfg_base = cfg.rsplit("/", 1)[-1] if cfg else ""
        try:
            man_text = await _resolve_man(searx, name, cfg_base)
            web_text = await _web_docs(searx, entry.get("label", name), name, cfg_base)
            # The shipped config's comments are the strongest source for allowed values ("# allowed: a, b").
            # Blocking (apt/dpkg), so off the loop.
            pkgs = fam.get("packages") or [name]
            sample = ""
            for candidate in pkgs[:3]:
                shipped, _ships, _real = await asyncio.to_thread(_deb_config, candidate, cfg_base, name, cfg)
                if shipped:
                    sample = shipped
                    break
            added = await _mine_enums(name, entry, man_text, web_text, sample, searx, qwen)
        except Exception as exc:  # noqa: BLE001 — one bad package must not end the pass
            print(f"[{index}/{len(pending)}] {name}: ERROR {str(exc)[:140]}", flush=True)
            continue
        added_total += added
        # Recorded even at 0: "asked, and nothing grounded" is an answer, and without it the next pass asks
        # the same question again forever. The per-field REASON is in schema_enum_abstentions.json.
        state[name] = {"asked": True, "added": added, "fields": len(gap[name]),
                       "sources": [k for k, v in (("man", man_text), ("deb", sample), ("web", web_text)) if v]}
        write_catalog(STATE, state, sort=False)
        if added or index % 10 == 0:
            print(f"[{index}/{len(pending)}] {name}: +{added} (total {added_total})", flush=True)
    print(f"\npass complete: +{added_total} enum field(s) over {len(pending)} template(s)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
