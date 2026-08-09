"""In-app help / docs (Block G10): serve the README + docs as the Help page,
and make them searchable so the AI can answer "how does yolo-man work?"
questions and fall back to the docs when it's unsure.

Pure filesystem + string work — the README/docs are mounted read-only at
settings.help_root (README.md + docs/*.md)."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

_HEADING = re.compile(r"^(#{1,4})\s+(.*)$")


def read_readme(help_root: str | Path) -> str:
    """The README markdown (the Help page body). '' if not mounted."""
    p = Path(help_root) / "README.md"
    try:
        return p.read_text(encoding="utf-8")
    except OSError:
        return ""


def _doc_files(help_root: str | Path) -> list[Path]:
    root = Path(help_root)
    files: list[Path] = []
    readme = root / "README.md"
    if readme.exists():
        files.append(readme)
    docs = root / "docs"
    if docs.is_dir():
        files.extend(sorted(docs.glob("*.md")))
    return files


def _sections(text: str, source: str) -> list[dict[str, str]]:
    """Split a markdown doc into sections at ## / ### headings — each section
    is (title, body, source), so a search hit returns a self-contained chunk."""
    out: list[dict[str, str]] = []
    title = source
    buf: list[str] = []

    def flush() -> None:
        body = "\n".join(buf).strip()
        if body or title != source:
            out.append({"title": title, "content": body, "source": source})

    for line in text.splitlines():
        m = _HEADING.match(line)
        if m and len(m.group(1)) <= 3:  # split on #, ##, ### (not tiny ####)
            flush()
            title = m.group(2).strip()
            buf = []
        else:
            buf.append(line)
    flush()
    return out


# English stopwords + the interrogatives a "how do I …" query is full of. Dropping
# them is what stops a long section from winning purely on the frequency of "a/or/
# the/to" — the bug that buried the task-guide sections under "Hardware & Sensors".
_STOPWORDS = frozenset(
    "a an the to of and or in on for with by from as at is are be do does how do i you we my your "
    "this that it its can could should would what when where which who whom whose why into over under "
    "not no yes if then else via per set get use using make made new".split()
)


def search_help(help_root: str | Path, query: str, limit: int = 5) -> list[dict[str, Any]]:
    """Rank doc sections for a natural-language query. Scoring favours COVERAGE
    (how many of the query's distinct meaningful terms a section contains) and
    TITLE matches, with per-term frequency capped so a long section can't win on
    stopword counts alone. Stopwords/interrogatives are dropped so "how do I set a
    threshold" ranks the threshold section, not the longest one. Returns ≤ `limit`
    self-contained sections."""
    raw = [t for t in re.split(r"[^a-z0-9_]+", query.lower()) if t]
    terms = [t for t in raw if t not in _STOPWORDS and len(t) > 1] or raw
    if not terms:
        return []
    seen = set()
    terms = [t for t in terms if not (t in seen or seen.add(t))]  # de-dup, keep order
    scored: list[tuple[int, dict[str, str]]] = []
    for f in _doc_files(help_root):
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        src = f.name
        for sec in _sections(text, src):
            title_l = sec["title"].lower()
            body_l = sec["content"].lower()
            coverage = sum(1 for t in terms if t in title_l or t in body_l)
            if coverage == 0:
                continue
            title_hits = sum(1 for t in terms if t in title_l)
            freq = sum(min(body_l.count(t), 3) for t in terms)  # capped → no length bias
            score = coverage * 10 + title_hits * 25 + freq
            scored.append((score, sec))
    scored.sort(key=lambda s: s[0], reverse=True)
    return [
        {"title": s["title"], "source": s["source"], "content": s["content"][:1800]}
        for _, s in scored[:limit]
    ]
