"""Read every installed .deb package's declared config files (dpkg conffiles),
and for each one that has a config-file man page, let qwen79b read that man page
(+ a sample of the file) and classify the codec: which structured format it is
(keyvalue / ini / json / yaml / xml / toml) and its parameters (separator,
comment marker, sections), or "none" for free-form (Class-B template territory).

The result is a codec registry (configs/config_codecs.json) mapping config
files to a codec spec — what the agent's config module needs to round-trip
them into the server-as-a-document state, learned from the docs instead of
guessed.

Run on a host with dpkg + man installed (uses the bossman venv for the LLM):
    .venv/bin/python scripts/classify_config_codecs.py [--limit N] [--only sshd_config crontab]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # the dir holding the `bossman` package —
# correct in both layouts (unlike the configs path, which is why _paths exists)

from bossman.tools._paths import configs_dir, repo_root  # noqa: E402

from bossman.services.chat_client import ChatClient  # noqa: E402

QWEN79B = (os.environ.get("YOLOMAN_LLM_BASE", "") + "/laguna", "laguna")

_SCHEMA = {
    "type": "object",
    "properties": {
        "codec": {"type": "string", "enum": ["keyvalue", "ini", "json", "yaml", "xml", "toml", "none"]},
        "separator": {"type": "string"},
        "comment": {"type": "string"},
        "sections": {"type": "boolean"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "notes": {"type": "string"},
    },
    "required": ["codec", "confidence"],
}

_SYSTEM = (
    "You are given a Linux config file (a sample) and its man page. Classify how the file is "
    "structured so a generic codec can parse+serialize it:\n"
    "- codec: keyvalue (KEY<sep>VALUE lines), ini (sections of key=value), json, yaml, xml, toml, "
    "or none (free-form/custom grammar like nginx/apache/bind — no generic codec fits).\n"
    "- separator: for keyvalue this is REQUIRED and must be non-empty — the exact key/value "
    "separator, one of \" \" (space), \"=\", or \":\".\n"
    "- comment: the comment marker (\"#\", \";\", \"//\").\n"
    "- sections: true if the file is organized into [sections] (ini-style).\n"
    "- confidence: high/medium/low. Judge from the man page's documented syntax, not just the sample.\n"
    "Return only the classification JSON."
)


def conffiles_by_package() -> list[tuple[str, str]]:
    """(package, path) for every declared conffile under /etc, read from
    /var/lib/dpkg/info/*.conffiles (one path per line, authoritative — the
    ${Conffiles} query field is multi-line and awkward to parse)."""
    pairs = []
    info = Path("/var/lib/dpkg/info")
    for f in sorted(info.glob("*.conffiles")):
        pkg = f.name[: -len(".conffiles")].split(":")[0]  # strip arch (:amd64)
        for line in f.read_text(errors="replace").splitlines():
            path = line.strip()
            if path.startswith("/etc/"):
                pairs.append((pkg, path))
    return pairs


def man_page(cands: list[str]) -> tuple[str, str] | None:
    """Plain-text man page (section 5) for the first candidate name that has
    one. Returns (candidate_key, text) or None."""
    seen = set()
    for cand in cands:
        for c in (cand, cand.rsplit(".", 1)[0]):
            if not c or c in seen:
                continue
            seen.add(c)
            if subprocess.run(["man", "-w", "5", c], capture_output=True).returncode == 0:
                env = {**os.environ, "MANWIDTH": "100", "MANPAGER": "cat", "PAGER": "cat"}
                txt = subprocess.run(["man", "5", c], capture_output=True, text=True, env=env).stdout
                if txt.strip():
                    return c, txt
    return None


def looks_binary_or_script(path: str) -> bool:
    return (
        path.startswith(("/etc/cron.", "/etc/init.d/", "/etc/rc", "/etc/profile.d/", "/etc/network/if-"))
        or path.endswith((".d", "/"))
    )


def wellknown(path: str) -> dict | None:
    """Directories whose format is known without a man page: /etc/default and
    /etc/sysconfig are shell KEY=value environment files."""
    if path.startswith(("/etc/default/", "/etc/sysconfig/")):
        return {"codec": "keyvalue", "separator": "=", "comment": "#", "sections": False,
                "confidence": "high", "notes": "shell environment file (well-known dir)"}
    return None


def dropin_service(path: str) -> str | None:
    """A conf.d / *.d drop-in fragment inherits its parent service's format, so
    classify it via the PARENT's man page. Returns a service name to look up,
    e.g. /etc/nginx/conf.d/x.conf -> nginx, /etc/sysctl.d/x.conf -> sysctl.conf,
    /etc/sudoers.d/x -> sudoers, /etc/modprobe.d/x.conf -> modprobe.d."""
    parts = path.split("/")
    for i, p in enumerate(parts):
        if p == "conf.d" and i >= 1:
            return parts[i - 1]  # /etc/<svc>/conf.d/... -> <svc>
        if p.endswith(".d") and p != "conf.d":
            base = p[:-2]  # sysctl.d -> sysctl, sudoers.d -> sudoers
            return base
    return None


# Important /etc configs that are NOT dpkg conffiles (created by maintainer
# scripts, not shipped-and-tracked), so conffiles_by_package() never sees them.
# Each has a section-5 man page, so it flows through the normal man-documented
# classification path below. Seed them explicitly so the codec universe isn't
# limited to what dpkg happens to mark as a conffile.
CURATED_EXTRAS: list[tuple[str, str]] = [
    ("libc6", "/etc/nsswitch.conf"),
    ("libnss-myhostname", "/etc/nsswitch.conf"),
]

# Configs whose codec the LLM can't infer because it's a bespoke columnar/table
# format the agent decodes with a dedicated codec (not keyvalue/ini/…). Written
# verbatim into the registry AFTER classification, so neither a normal run nor
# --force can mis-pin them. key -> full codec spec (paths/packages filled here).
PINNED: dict[str, dict] = {
    "fstab": {
        "codec": "fstab", "separator": "", "comment": "#", "sections": False,
        "confidence": "high",
        "notes": "Columnar mount table (device mountpoint fstype options dump pass); decoded to a list of entries. Not a dpkg conffile.",
        "dropin": False, "packages": ["mount"], "paths": ["/etc/fstab"],
    },
}


async def run(args) -> None:
    pairs = conffiles_by_package()
    # Merge the curated non-conffile extras, keeping only paths that exist on
    # this classifying host (so a run on a box without the package just skips it).
    pairs += [(pkg, p) for pkg, p in CURATED_EXTRAS if Path(p).exists()]
    only = set(args.only) if args.only else None
    # Well-known dirs (/etc/default, /etc/sysconfig) are classified with no man
    # page / no LLM; everything else groups by the man page that documents it
    # (a conf.d/*.d drop-in uses its parent service's man page).
    known: dict[str, dict] = {}
    by_man: dict[str, dict] = {}
    for pkg, path in pairs:
        if looks_binary_or_script(path):
            continue
        base = os.path.basename(path)
        svc = dropin_service(path)
        if only and base not in only and (svc or "") not in only:
            continue

        wk = wellknown(path)
        if wk is not None:
            key = os.path.dirname(path).rstrip("/") + "/*"
            e = known.setdefault(key, {"spec": wk, "packages": set(), "paths": set()})
            e["packages"].add(pkg)
            e["paths"].add(path)
            continue

        cands = [svc, (svc + ".conf") if svc else "", (svc + ".d") if svc else "", base] if svc else [base]
        found = man_page([c for c in cands if c])
        if found is None:
            continue
        mankey, man = found
        entry = by_man.setdefault(mankey, {"man": man, "packages": set(), "paths": set(), "dropin": bool(svc)})
        entry["packages"].add(pkg)
        entry["paths"].add(path)

    # Resume: skip man keys already in the registry so a re-run only spends the
    # LLM on NEW configs (from newly-installed packages), not the whole set
    # again. --force re-classifies everything; --only <names> always wins.
    dest_path = configs_dir(__file__) / "config_codecs.json"
    already = set(json.loads(dest_path.read_text())) if dest_path.exists() else set()
    keys = sorted(by_man)
    if not args.force and not only:
        skipped = [k for k in keys if k in already]
        keys = [k for k in keys if k not in already]
        if skipped:
            print(f"resume: skipping {len(skipped)} already-classified man keys")
    if args.limit:
        keys = keys[: args.limit]
    print(f"{len(pairs)} conffiles → {len(known)} well-known dirs + {len(by_man)} man-documented; "
          f"classifying {len(keys)} via LLM")

    registry: dict[str, dict] = {}
    # Well-known dirs: no LLM needed.
    for key, e in known.items():
        registry[key] = {**e["spec"], "packages": sorted(e["packages"]), "paths": sorted(e["paths"])}
        print(f"[wk] {key}: {e['spec']['codec']} sep={e['spec']['separator']!r}")

    chat = ChatClient(QWEN79B[0], QWEN79B[1], timeout=600.0)
    for i, key in enumerate(keys, 1):
        e = by_man[key]
        sample_path = sorted(e["paths"])[0]
        try:
            sample = Path(sample_path).read_text(errors="replace")[:4000]
        except OSError:
            sample = ""
        user = f"Config file: {key}\n=== sample ({sample_path}) ===\n{sample}\n=== man page ===\n{e['man'][:16000]}"
        try:
            cls = await chat.complete_json(
                [{"role": "system", "content": _SYSTEM}, {"role": "user", "content": user}],
                _SCHEMA, "codec_classification",
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[{i}/{len(keys)}] {key}: ERROR {str(exc)[:100]}")
            continue
        registry[key] = {
            "codec": cls.get("codec"),
            "separator": cls.get("separator", ""),
            "comment": cls.get("comment", ""),
            "sections": cls.get("sections", False),
            "confidence": cls.get("confidence"),
            "notes": cls.get("notes", ""),
            "dropin": e.get("dropin", False),
            "packages": sorted(e["packages"]),
            "paths": sorted(e["paths"]),
        }
        print(f"[{i}/{len(keys)}] {key}: {cls.get('codec')} sep={cls.get('separator','')!r} ({cls.get('confidence')})")

    outdir = configs_dir(__file__)
    outdir.mkdir(parents=True, exist_ok=True)
    dest = outdir / "config_codecs.json"
    existing = {}
    if dest.exists():
        existing = json.loads(dest.read_text())
    existing.update(registry)
    # Pinned bespoke-codec configs always win (the LLM can't produce these).
    existing.update(PINNED)
    dest.write_text(json.dumps(existing, indent=2, sort_keys=True))
    print(f"\nwrote {dest} ({len(existing)} entries total)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--force", action="store_true", help="re-classify even keys already in the registry")
    asyncio.run(run(ap.parse_args()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
