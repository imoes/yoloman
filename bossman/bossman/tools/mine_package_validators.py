"""How does a package check its own configuration, and how is its daemon started in the foreground?

    .venv-host/bin/python -m bossman.tools.mine_package_validators [--family debian|redhat] [--only a,b]
        [--limit N] --llm-url URL --llm-model ID

Writes configs/package_validators.json: per family and package a `check_cmd` (e.g. `nginx -t -c {path}`) and a
`daemon_cmd` (e.g. `nginx -g 'daemon off;' -c {path}`), or the reason there is none. `{path}` is the config file the
e2e writes. Read by the package e2e and by build_package_catalog (one source for validate_cmd — the catalog used to
carry nine hand-written ones).

GROUNDED, the same rule as the enum gate: the model reads the man1/man8 pages of the package's OWN binaries and
proposes commands; a command is kept only if
  * its program is a binary this package ships (a checker from another package would be "not found" in the pod,
    which reads as a broken config), and
  * every option it uses (`-t`, `--test-config`, `configtest` …) appears verbatim in that program's man page.
Nothing documented → nothing proposed → an abstention with its reason. Never a guess.

ONE PROCESS against the LLM endpoint; resumable — written after every package.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import shlex

from bossman.services.chat_client import ChatClient, ChatClientError
from bossman.tools import qualify_packages as Q
from bossman.tools import validators_store as VS
from bossman.tools.package_tree import binaries, man_pages, unpacked

OUT = Q._CONFIGS / "package_validators.json"
WORKLIST = Q._CONFIGS / "package_e2e_worklist.json"
VERSION = "val-v1"

_SYSTEM = (
    "You read the manual pages of a Linux package's own programs and answer two questions, using ONLY what the "
    "pages document.\n"
    "1. check_cmd: a command that checks the configuration file for errors WITHOUT starting the service "
    "(syntax/config test). Use the placeholder {path} for the config file when the program takes a config-file "
    "option; otherwise omit it. Empty string if the pages document no such mode.\n"
    "2. daemon_cmd: a command that starts the service in the FOREGROUND (not detaching), using {path} the same "
    "way. Empty string if the pages document no foreground mode or the package has no daemon.\n"
    "Use only programs from the given list and only options written in their pages. Do not invent options."
)
_SCHEMA = {
    "type": "object",
    "properties": {
        "check_cmd": {"type": "string"},
        "daemon_cmd": {"type": "string"},
        "evidence": {"type": "string", "description": "the option text quoted from the man page"},
    },
    "required": ["check_cmd", "daemon_cmd", "evidence"],
}
_OPTION = re.compile(r"^--?[A-Za-z][\w-]*")
#: Sections of a man page worth showing: the ones that mention configuration checking or the foreground.
_RELEVANT = re.compile(r"config|syntax|test|check|foreground|daemon|detach|fork|nodaemon|debug", re.I)


def excerpt(text: str, limit: int = 12000) -> str:
    """The paragraphs of a page that talk about config/test/foreground — whole pages blow the prompt for
    packages with dozens of programs, and these are where the answer is."""
    paras = re.split(r"\n\s*\n", text)
    keep = [p for p in paras[:3]] + [p for p in paras[3:] if _RELEVANT.search(p)]
    return "\n\n".join(keep)[:limit]


def grounded(cmd: str, bins: list[str], pages: dict[str, str]) -> tuple[bool, str]:
    """Is every part of `cmd` documented? Returns (ok, reason)."""
    if not cmd.strip():
        return False, "empty"
    try:
        argv = shlex.split(cmd)
    except ValueError as exc:
        return False, f"unparseable: {exc}"
    prog = argv[0]
    names = {b.rsplit("/", 1)[-1]: b for b in bins}
    if prog.rsplit("/", 1)[-1] not in names:
        return False, f"{prog} is not a binary of this package"
    page = pages.get(prog.rsplit("/", 1)[-1]) or ""
    if not page:
        return False, f"{prog} has no man page in this package"
    for tok in argv[1:]:
        m = _OPTION.match(tok)
        if m and not re.search(r"(?<![\w-])" + re.escape(m.group(0)) + r"(?![\w-])", page):
            return False, f"option {m.group(0)} is not in {prog}'s man page"
        if not tok.startswith("-") and tok not in ("{path}",) and re.fullmatch(r"[a-z][a-z-]+", tok) \
                and tok not in page:
            return False, f"word {tok!r} is not in {prog}'s man page"
    return True, "grounded"


async def mine(family: str, pkg: str, path: str, qwen: ChatClient) -> dict:
    with unpacked(family, pkg) as root:
        if root is None:
            # A fact about the package on this mirror, not an LLM failure: recorded, not retried every pass.
            return {"status": "ok", "check_cmd": None, "daemon_cmd": None, "reason": "package could not be fetched"}
        bins = binaries(root)
        pages = man_pages(root)
    if not bins:
        return {"status": "ok", "check_cmd": None, "daemon_cmd": None, "reason": "the package ships no program"}
    relevant = {k: v for k, v in pages.items() if k in {b.rsplit("/", 1)[-1] for b in bins}}
    if not relevant:
        return {"status": "ok", "check_cmd": None, "daemon_cmd": None,
                "reason": "none of its programs has a man page in the package"}
    user = (f"Package: {pkg} ({family})\nConfiguration file: {path}\nPrograms: {', '.join(bins)}\n\n"
            + "\n\n".join(f"=== man page: {k} ===\n{excerpt(v)}" for k, v in relevant.items())[:60000])
    try:
        out = await qwen.complete_json([{"role": "system", "content": _SYSTEM}, {"role": "user", "content": user}],
                                       _SCHEMA, "package_validators", extra_body=Q._NO_THINK)
    except ChatClientError as exc:
        return {"status": "failed", "reason": f"llm: {str(exc)[:200]}"}
    res: dict = {"status": "ok", "evidence": (out.get("evidence") or "")[:400]}
    for key in ("check_cmd", "daemon_cmd"):
        cmd = (out.get(key) or "").strip()
        ok, why = grounded(cmd, bins, relevant) if cmd else (False, "none proposed")
        res[key] = cmd if ok else None
        if not ok:
            res[f"{key}_abstained"] = {"proposed": cmd, "reason": why}
    return res


async def main_async(args) -> int:
    worklist = Q._load(WORKLIST, {}).get("families", {})
    out = Q._load(OUT, {})
    # No client timeout (plan F1: the GPU is shared and slow). But the attempts per PACKAGE are bounded: the nginx
    # gateway answers 504 after ~15 min, and for some requests EVERY time — nextepc-hss got 504 twice in a row
    # (22:13→22:28→22:43, 2026-10-16), so unbounded retries would hold the whole miner on one package forever.
    # After 3 attempts the package is recorded `failed` with the reason and retried on the next run (main_async
    # redoes everything that is not `ok`), and the miner moves on.
    qwen = ChatClient(args.llm_url, args.llm_model, token="", timeout=None, max_attempts=3)
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    todo = []
    for fam in args.family or ["debian", "redhat"]:
        for pkg, row in sorted(worklist.get(fam, {}).items()):
            if row["route"] in ("no-config",) or (only and pkg not in only):
                continue
            prev = (out.get(fam) or {}).get(pkg) or {}
            if prev.get("version") == VERSION and prev.get("status") == "ok" and not only:
                continue
            if VS.decided(prev):
                # Judged on a test host — verified (by hand or probe) or rejected. A new model guess must not replace
                # it: re-mining the rejected ones erased 69 probe decisions on 2026-10-16.
                continue
            todo.append((fam, pkg, row.get("path", "")))
    if args.limit:
        todo = todo[: args.limit]
    print(f"mine_package_validators: {len(todo)} package(s) — {args.llm_model}", flush=True)
    if args.check_only:
        return 0
    for i, (fam, pkg, path) in enumerate(todo, 1):
        res = await mine(fam, pkg, path, qwen)
        res["version"] = VERSION
        out.setdefault(fam, {})[pkg] = res
        # One entry, written into the CURRENT file under the lock — never this process's stale copy of it.
        VS.update(lambda doc, fam=fam, pkg=pkg, res=res: doc.setdefault(fam, {}).__setitem__(pkg, res), OUT)
        print(f"[{i}/{len(todo)}] {fam}/{pkg}: check={res.get('check_cmd')!r} daemon={res.get('daemon_cmd')!r}"
              + (f" ({res.get('reason')})" if res.get("reason") else ""), flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--check-only", action="store_true", help="print how many packages are pending, call nothing")
    ap.add_argument("--llm-url", required=True)
    ap.add_argument("--llm-model", required=True)
    return asyncio.run(main_async(ap.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
