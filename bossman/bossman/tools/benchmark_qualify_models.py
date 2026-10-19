"""Which model should run the RedHat qualify pass? Measured on the same packages, the same code, the same sources.

    .venv-host/bin/python -m bossman.tools.benchmark_qualify_models \\
        --model qwen35b=https://llm.example.internal/qwen35b|Qwen3.6-35B-A3B-UD-Q4_K_XL \\
        --model qwen27b=https://llm.example.internal/qwen27b|qwen3.8-27b

WHAT IS COMPARED. Each model runs the REAL pipeline (`qualify_packages --family redhat --only …`) against its own
copy of configs/, so the production catalog is never touched and both models see the same starting state. The
metasearch is switched off for both: the web results of two runs minutes apart are not the same document, and a
comparison whose inputs differ measures the search engine. What remains — the RPM's own config, its documented
sample, its man page — is identical by construction.

WHAT IS MEASURED — all mechanical, no model judges another:
  template   the invariants of tools/template_invariants (renders · keeps the file · invents nothing · declared ·
             substitutes · configures · reproduces the shipped file with its own defaults), judged over ACTIVE
             lines (`ok_semantic`): the enrich stage adds documentation comments on purpose, and counting them as
             invented failed every enriched template of both models. The strict count is reported beside it.
  enrich     the five enrich gates passed (the pipeline reports it)
  enum       hallucination rate BEFORE the grounding gate: proposed values no source contains
  codec      on paths whose codec was measured at the bytes, the entry is hidden in the copy and the model's
             classification compared with the measurement
  directives coverage of the shipped file's active keys (tools/directive_coverage)
  robustness LLM failures; seconds per package

THE DECISION RULE is fixed before the run (see --max-gap): the faster model wins unless its invariant+gate pass
rate is more than --max-gap points below the other's or its enum hallucination rate is higher.

ONE MODEL AT A TIME. The endpoint is shared; the runs are sequential by design, never parallel.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

from bossman.tools import rpm_source
from bossman.tools._paths import configs_dir
from bossman.tools.directive_coverage import coverage
from bossman.tools.template_invariants import mechanical

CONFIGS = configs_dir(__file__)
SUFFIX = "-redhat"
#: The packages every comparison includes: well-known daemons whose files a reader can check by eye.
KNOWN = ("httpd-core", "chrony", "postfix", "openssh-server", "dnsmasq")


def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def pick_sample(n_freeform: int, n_codec: int, seed: int) -> dict:
    """{freeform: [pkg], codec_test: {pkg: path}} — deterministic for a seed.

    freeform    packages whose primary file was measured `codec: none` → they exercise template, enum, enrich.
                Includes the packages behind the hand-verified `-redhat` templates, which are REMOVED from the
                copy so the model has to write them; the curated ones are the baseline.
    codec_test  packages whose primary file has a measured parseable codec; the entry is hidden in the copy.
    """
    sys.argv = [sys.argv[0]]
    from bossman.tools import qualify_packages as Q  # noqa: PLC0415 — module reads argv-free config at import

    universe = _load(CONFIGS / "package_universe_real.json", {}).get("redhat", {})
    codecs = _load(CONFIGS / "config_codecs.json", {})
    primary = {}
    for pkg, info in universe.items():
        paths = info.get("config_paths") or []
        if paths:
            primary[pkg] = Q._pick_primary_config(paths, "", pkg)
    curated_targets = {}
    for d in (CONFIGS / "config_templates").iterdir():
        meta = _load(d / "meta.json", {}) if d.name.endswith(SUFFIX) else {}
        if meta.get("source") == "rh-parametrize" and meta.get("target_path"):
            curated_targets[meta["target_path"]] = d.name
    baseline = sorted(p for p, path in primary.items() if path in curated_targets)
    rng = random.Random(seed)
    free = sorted(p for p, path in primary.items()
                  if (codecs.get(path) or {}).get("codec") == "none" and (codecs.get(path) or {}).get("measured_family"))
    chosen = [p for p in KNOWN if p in primary] + [p for p in baseline if p not in KNOWN]
    rest = [p for p in free if p not in chosen]
    chosen += rng.sample(rest, min(n_freeform, len(rest)))
    parseable = sorted(p for p, path in primary.items()
                       if (codecs.get(path) or {}).get("codec") in ("keyvalue", "ini")
                       and (codecs.get(path) or {}).get("source") == "probe" and p not in chosen)
    codec_test = {p: primary[p] for p in rng.sample(parseable, min(n_codec, len(parseable)))}
    return {"freeform": chosen, "codec_test": codec_test, "curated": curated_targets, "primary": primary}


def prepare_copy(work: Path, sample: dict) -> Path:
    """A fresh configs/ for one model: the curated -redhat dirs of the sample removed, the codec-test entries hidden."""
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    copy = work / "configs"
    shutil.copytree(CONFIGS, copy, symlinks=True)
    for pkg in sample["freeform"]:
        owner = sample["curated"].get(sample["primary"].get(pkg, ""))
        if owner:
            shutil.rmtree(copy / "config_templates" / owner, ignore_errors=True)
    codecs = _load(copy / "config_codecs.json", {})
    for path in sample["codec_test"].values():
        codecs.pop(path, None)
    (copy / "config_codecs.json").write_text(json.dumps(codecs, indent=1, sort_keys=True) + "\n")
    return copy


def run_model(label: str, url: str, model: str, copy: Path, names: list[str], log: Path, results: Path) -> float:
    env = {
        **os.environ,
        "AGENTIC_CONFIGS_DIR": str(copy),
        "QUALIFY_NO_SEARXNG": "1",
        "YOLOMAN_SEARX_BASE": "",
        "PYTHONUNBUFFERED": "1",
    }
    argv = [sys.executable, "-u", "-m", "bossman.tools.qualify_packages", "--family", "redhat",
            "--only", ",".join(names), "--llm-url", url, "--llm-model", model,
            "--results-jsonl", str(results), "--concurrency", "1"]
    t0 = time.monotonic()
    with open(log, "w") as fh:
        subprocess.run(argv, env=env, stdout=fh, stderr=subprocess.STDOUT, check=False)
    return time.monotonic() - t0


_SHIPPED: dict[tuple[str, str], str | None] = {}


def shipped_text(pkg: str, path: str) -> str | None:
    """The file as the RPM ships it — fetched once and shared by every model's evaluation."""
    key = (pkg, path)
    if key not in _SHIPPED:
        tree = rpm_source.fetch(pkg)
        try:
            f = tree.root / path.lstrip("/")
            _SHIPPED[key] = f.read_text(errors="replace")[:60000] if tree.ok and f.is_file() else None
        finally:
            tree.cleanup()
    return _SHIPPED[key]


def evaluate(copy: Path, results: Path, sample: dict, measured_codecs: dict) -> dict:
    rows = {}
    for line in results.read_text().splitlines() if results.is_file() else []:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        rows[r["name"]] = r
    codecs = _load(copy / "config_codecs.json", {})
    directives = _load(copy / "config_directives.json", {})
    per_pkg = {}
    for pkg in sample["freeform"] + list(sample["codec_test"]):
        name = pkg + SUFFIX
        r = rows.get(name, {"status": "missing"})
        out = {"status": r.get("status"), "seconds": r.get("seconds"),
               "llm_errors": len(r.get("llm_errors") or []), "enum_stats": r.get("enum_stats") or {},
               "enriched": bool(r.get("enriched")), "template_written": bool(r.get("template")),
               "twin_of": r.get("twin_of"), "owner": r.get("template_owner")}
        path = r.get("path") or sample["primary"].get(pkg, "")
        text = shipped_text(pkg, path) if path else None
        tdir = copy / "config_templates" / name
        if pkg in sample["freeform"] and (tdir / "template.j2").is_file() and text:
            inv = mechanical(tdir, text)
            out["invariants_ok"] = inv["ok_semantic"]
            out["invariants_strict_ok"] = inv["ok"]
            out["invariants"] = {k: inv[k] for k in ("renders", "keeps_the_file", "undeclared", "invented_lines",
                                                     "invented_active_lines", "substitutes",
                                                     "live_placeholder_lines", "fields")}
            out["default_render_diff"] = len(inv["default_render_diff"])
            out["default_render_diff_active"] = len(inv["default_render_diff_active"])
        if pkg in sample["codec_test"]:
            want = (measured_codecs.get(path) or {}).get("codec")
            got = (codecs.get(path) or {}).get("codec")
            out["codec"] = {"measured": want, "model": got, "match": want == got}
        if text and path in directives:
            sep = (codecs.get(path) or measured_codecs.get(path) or {}).get("separator") or "="
            out["directive_coverage"] = coverage(text, directives[path], sep)
        per_pkg[pkg] = out
    return per_pkg


def summarize(per_pkg: dict, wall: float) -> dict:
    tpl = [v for v in per_pkg.values() if "invariants_ok" in v]
    attempted = [v for k, v in per_pkg.items() if v.get("status") != "missing"]
    proposed = sum(v["enum_stats"].get("proposed", 0) for v in per_pkg.values())
    ungrounded = sum(v["enum_stats"].get("ungrounded", 0) for v in per_pkg.values())
    codec = [v["codec"]["match"] for v in per_pkg.values() if "codec" in v]
    cov = [v["directive_coverage"] for v in per_pkg.values() if v.get("directive_coverage", {}).get("keys")]
    secs = [v["seconds"] for v in per_pkg.values() if isinstance(v.get("seconds"), (int, float))]
    passed = [v for v in tpl if v["invariants_ok"] and v["enriched"]]
    return {
        "packages": len(per_pkg),
        "templates_evaluated": len(tpl),
        "invariants_ok": sum(1 for v in tpl if v["invariants_ok"]),
        "invariants_strict_ok": sum(1 for v in tpl if v.get("invariants_strict_ok")),
        "enriched": sum(1 for v in tpl if v["enriched"]),
        "invariants_and_gates_rate": round(100.0 * len(passed) / len(tpl), 1) if tpl else None,
        "enum_values_proposed": proposed,
        "enum_values_ungrounded": ungrounded,
        "enum_hallucination_rate": round(100.0 * ungrounded / proposed, 1) if proposed else None,
        "codec_matches": f"{sum(codec)}/{len(codec)}",
        "directive_coverage": (f"{sum(c['covered'] for c in cov)}/{sum(c['keys'] for c in cov)}" if cov else None),
        "llm_failures": sum(v["llm_errors"] for v in per_pkg.values()),
        "failed_packages": sum(1 for v in attempted if v.get("status") == "failed"),
        "seconds_median": round(statistics.median(secs), 1) if secs else None,
        "seconds_total": round(sum(secs), 1),
        "wall_seconds": round(wall, 1),
    }


def decide(summary: dict, max_gap: float) -> dict:
    """The rule fixed before the run: the faster model wins unless it is more than max_gap points worse on
    invariants+gates, or hallucinates more enum values."""
    labels = list(summary)
    if len(labels) != 2:
        return {"winner": None, "why": "the rule compares exactly two models"}
    a, b = sorted(labels, key=lambda m: summary[m]["seconds_total"] or float("inf"))
    fa, fb = summary[a], summary[b]
    qa, qb = fa["invariants_and_gates_rate"] or 0.0, fb["invariants_and_gates_rate"] or 0.0
    ha, hb = fa["enum_hallucination_rate"] or 0.0, fb["enum_hallucination_rate"] or 0.0
    if qb - qa > max_gap:
        return {"winner": b, "why": f"{a} is faster but {qb - qa:.1f} points worse on invariants+gates (> {max_gap})"}
    if ha > hb:
        return {"winner": b, "why": f"{a} is faster but hallucinates more enum values ({ha}% vs {hb}%)"}
    return {"winner": a, "why": f"{a} is faster ({fa['seconds_total']}s vs {fb['seconds_total']}s) and within "
                                f"{max_gap} points on invariants+gates ({qa}% vs {qb}%), enum hallucination "
                                f"{ha}% vs {hb}%"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", action="append", required=True, help="label=URL|MODEL_ID, given once per model")
    ap.add_argument("--freeform", type=int, default=8, help="random freeform packages added to the fixed sample")
    ap.add_argument("--codec", type=int, default=8, help="parseable packages whose measured codec is hidden")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--max-gap", type=float, default=5.0, help="percentage points the faster model may lose")
    ap.add_argument("--workdir", default="/data1/agentic-dev-tmp/bench/models")
    ap.add_argument("--out", default=str(CONFIGS / "model_benchmark_qualify.json"))
    ap.add_argument("--evaluate-only", action="store_true",
                    help="re-measure existing runs in --workdir (no LLM call); e.g. after an invariant is refined")
    args = ap.parse_args()

    sample = pick_sample(args.freeform, args.codec, args.seed)
    names = [p + SUFFIX for p in sample["freeform"] + list(sample["codec_test"])]
    measured = _load(CONFIGS / "config_codecs.json", {})
    print(f"sample: {len(sample['freeform'])} freeform + {len(sample['codec_test'])} codec-test packages", flush=True)

    report = {"sample": {"freeform": sample["freeform"], "codec_test": sample["codec_test"]},
              "rule": f"faster model wins unless > {args.max_gap} points worse on invariants+gates "
                      f"or higher enum hallucination rate",
              "models": {}, "per_package": {}}
    for spec in args.model:
        label, _, rest = spec.partition("=")
        url, _, model_id = rest.partition("|")
        work = Path(args.workdir) / label
        if args.evaluate_only:
            if not (work / "results.jsonl").is_file():
                print(f"[{label}] no run in {work} — skipped", flush=True)
                continue
            copy = work / "configs"
            prev = (_load(Path(args.out), {}).get("models") or {}).get(label) or {}
            wall = prev.get("wall_seconds") or 0.0
        else:
            copy = prepare_copy(work, sample)
            print(f"[{label}] running {len(names)} packages against {url} ({model_id}) …", flush=True)
            wall = run_model(label, url, model_id, copy, names, work / "run.log", work / "results.jsonl")
        per_pkg = evaluate(copy, work / "results.jsonl", sample, measured)
        report["per_package"][label] = per_pkg
        report["models"][label] = {"url": url, "model": model_id, **summarize(per_pkg, wall)}
        print(f"[{label}] {json.dumps(report['models'][label])}", flush=True)
        Path(args.out).write_text(json.dumps(report, indent=2) + "\n")

    report["decision"] = decide(report["models"], args.max_gap)
    Path(args.out).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["decision"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
