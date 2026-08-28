#!/usr/bin/env python3
"""Generate the frontend presentation: every screen yoloman has, grouped as the navigation groups it.

WHY GENERATED. The UI has 56 routes in five workspaces, and 51 of its 54 lazy-loaded components already carry
a doc comment above `@Component` explaining what the screen is for — written when the screen was built, by
whoever built it. A hand-written presentation would be a second set of explanations, and the second set is the
one that goes stale. This reads the routes, the navigation groups and those comments, and renders them.

    ./generate-frontend-presentation.py            # writes docs/frontend-presentation.html

THE GAPS ARE PART OF THE OUTPUT. A screen whose component has no doc comment appears with "undocumented" in
place of prose rather than being left out — a presentation that silently omitted three screens would be a
presentation nobody can trust to be complete, and the list of what is missing is the to-do list for whoever
writes them.
"""

from __future__ import annotations

import argparse
import datetime
import html
import pathlib
import re

UI = pathlib.Path(__file__).resolve().parent.parent / "bossman-ui" / "src" / "app"
OUT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "frontend-presentation.html"


def read_routes() -> list[dict]:
    """Every lazy route: its path, its component and the file behind it."""
    text = (UI / "app.routes.ts").read_text()
    routes = []
    # One entry per `path: … loadComponent: () => import('…').then((m) => m.X)` block, in file order, which is
    # also the order a reader of the routes file meets them.
    pattern = re.compile(
        r"path:\s*'([^']*)'.*?import\('([^']+)'\)\.then\(\(m\)\s*=>\s*m\.(\w+)\)",
        re.DOTALL,
    )
    for match in pattern.finditer(text):
        path, module, component = match.groups()
        routes.append({
            "path": path,
            "component": component,
            "file": (UI / (module.lstrip("./") + ".ts")),
        })
    return routes


def read_nav() -> tuple[list[dict], dict[str, str]]:
    """The workspaces and which screen sits in which, straight from the navigation definition."""
    text = (UI / "app.ts").read_text()
    workspaces = []
    for match in re.finditer(
        r"id:\s*'(\w+)',\s*\n\s*label:\s*'([^']+)',\s*\n\s*icon:\s*'[^']*',\s*\n\s*hint:\s*'([^']*)',\s*\n\s*items:\s*\[(.*?)\n\s*\],",
        text, re.DOTALL,
    ):
        wid, label, hint, body = match.groups()
        items = [
            {"path": path, "label": item_label, "admin": "adminOnly: true" in line}
            for line in body.splitlines()
            for path, item_label in re.findall(r"path:\s*'/([^']*)',\s*label:\s*'([^']+)'", line)
        ]
        workspaces.append({"id": wid, "label": label, "hint": hint, "items": items})
    placement = {item["path"]: ws["label"] for ws in workspaces for item in ws["items"]}
    return workspaces, placement


def doc_comment(path: pathlib.Path) -> str:
    """The component's own explanation: the last block comment before `@Component`.

    Taken from the source rather than restated here, because the person who built the screen wrote it while
    building it — and because a description kept in two places is a description that will disagree with
    itself."""
    if not path.exists():
        return ""
    text = path.read_text()
    cut = text.find("@Component")
    if cut <= 0:
        return ""
    blocks = re.findall(r"/\*\*(.*?)\*/", text[:cut], re.DOTALL)
    if not blocks:
        return ""
    body = blocks[-1]
    lines = [re.sub(r"^\s*\*ateway?\s?", "", line).strip().lstrip("*").strip() for line in body.splitlines()]
    return " ".join(line for line in lines if line)


def paragraphs(text: str) -> list[str]:
    """Split a long doc comment into readable paragraphs at sentence boundaries, keeping it verbatim."""
    if not text:
        return []
    sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z(`])", text)
    chunks, current = [], ""
    for sentence in sentences:
        if len(current) + len(sentence) > 320 and current:
            chunks.append(current.strip())
            current = sentence
        else:
            current += " " + sentence
    if current.strip():
        chunks.append(current.strip())
    return chunks


def render(routes: list[dict], workspaces: list[dict], placement: dict[str, str]) -> str:
    today = datetime.date.today().isoformat()
    documented = [r for r in routes if doc_comment(r["file"])]
    undocumented = [r for r in routes if not doc_comment(r["file"])]

    by_workspace: dict[str, list[dict]] = {ws["label"]: [] for ws in workspaces}
    by_workspace["Not in the navigation"] = []
    for route in routes:
        label = placement.get(route["path"], "Not in the navigation")
        by_workspace.setdefault(label, []).append(route)

    nav_labels = {item["path"]: item["label"] for ws in workspaces for item in ws["items"]}

    parts: list[str] = [f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>yoloman — every screen</title>
<style>
  :root {{
    color-scheme: light dark;
    --ink: #16181d; --dim: #5b6270; --line: #d9dde5; --bg: #fbfcfe; --card: #ffffff;
    --accent: #1d4ed8; --accent-soft: #eaefff; --warn: #a8580a;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --ink: #e8eaf0; --dim: #9aa3b4; --line: #2a2f3a; --bg: #12141a; --card: #191c24;
             --accent: #7aa2ff; --accent-soft: #1b2438; --warn: #e0a458; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--ink);
    font: 16px/1.6 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }}
  header {{ padding: 56px 24px 32px; max-width: 1100px; margin: 0 auto; }}
  h1 {{ font-size: clamp(28px, 5vw, 44px); margin: 0 0 10px; letter-spacing: -0.02em; }}
  .lede {{ font-size: 18px; color: var(--dim); max-width: 70ch; }}
  .meta {{ margin-top: 18px; font-size: 13px; color: var(--dim); }}
  .counts {{ display: flex; gap: 10px; flex-wrap: wrap; margin: 22px 0 0; }}
  .pill {{ font-size: 13px; padding: 4px 12px; border-radius: 999px; background: var(--accent-soft);
    color: var(--accent); border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent); }}
  main {{ max-width: 1100px; margin: 0 auto; padding: 0 24px 80px; }}
  section {{ margin: 46px 0 0; }}
  h2 {{ font-size: 24px; margin: 0 0 4px; }}
  .hint {{ color: var(--dim); margin: 0 0 18px; }}
  .grid {{ display: grid; gap: 14px; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); }}
  article {{ background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px; }}
  article h3 {{ margin: 0 0 2px; font-size: 17px; }}
  .route {{ font-family: ui-monospace, monospace; font-size: 12px; color: var(--accent); }}
  .badge {{ font-size: 11px; padding: 1px 8px; border-radius: 999px; border: 1px solid var(--line);
    color: var(--dim); margin-left: 6px; }}
  article p {{ margin: 10px 0 0; font-size: 14.5px; }}
  article p.missing {{ color: var(--warn); }}
  code {{ font-family: ui-monospace, monospace; font-size: 0.92em;
    background: color-mix(in srgb, var(--ink) 7%, transparent); padding: 1px 5px; border-radius: 5px; }}
  footer {{ max-width: 1100px; margin: 0 auto; padding: 0 24px 60px; color: var(--dim); font-size: 14px; }}
  a {{ color: var(--accent); }}
</style>
</head>
<body>
<header>
  <h1>yoloman — every screen</h1>
  <p class="lede">
    One page per thing you can look at. The screens are grouped exactly as the product groups them, and each
    description is the one the screen's own source carries — so this page cannot quietly disagree with the
    application it documents.
  </p>
  <div class="counts">
    <span class="pill">{len(routes)} screens</span>
    <span class="pill">{len(workspaces)} workspaces</span>
    <span class="pill">{len(documented)} documented in their own source</span>
    <span class="pill">{len(undocumented)} still undocumented</span>
  </div>
  <p class="meta">
    Generated by <code>scripts/generate-frontend-presentation.py</code> from
    <code>app.routes.ts</code>, <code>app.ts</code> and the components' own doc comments, {today}.
    Undocumented screens are listed as such rather than left out: a presentation that silently omitted three
    screens would be one nobody can trust to be complete.
  </p>
</header>
<main>
"""]

    order = [ws["label"] for ws in workspaces] + ["Not in the navigation"]
    hints = {ws["label"]: ws["hint"] for ws in workspaces}
    hints["Not in the navigation"] = ("Reachable by link or by drilling in — a host's detail page, an editor, "
                                     "a wizard step. They have no nav entry because you arrive at them from "
                                     "somewhere else.")

    for label in order:
        screens = by_workspace.get(label) or []
        if not screens:
            continue
        parts.append(f'<section>\n<h2>{html.escape(label)}</h2>\n'
                     f'<p class="hint">{html.escape(hints.get(label, ""))}</p>\n<div class="grid">\n')
        for route in sorted(screens, key=lambda r: r["path"]):
            title = nav_labels.get(route["path"]) or route["component"].replace("Component", "")
            doc = doc_comment(route["file"])
            body = "".join(f"<p>{html.escape(chunk)}</p>" for chunk in paragraphs(doc)[:3]) if doc else (
                '<p class="missing">Undocumented: this screen\'s component carries no doc comment, so this '
                'page has nothing of its own to say about it. That is a gap in the source, not in the '
                'generator.</p>')
            admin = ' <span class="badge">admin only</span>' if any(
                item["path"] == route["path"] and item["admin"] for ws in workspaces for item in ws["items"]
            ) else ""
            parts.append(
                f'<article>\n<h3>{html.escape(title)}{admin}</h3>\n'
                f'<div class="route">/{html.escape(route["path"])}</div>\n{body}\n</article>\n')
        parts.append("</div>\n</section>\n")

    parts.append(f"""</main>
<footer>
  <p>
    The screens above are the readers. What they read and write is documented next door:
    <a href="https://github.com/imoes/yoloman/blob/main/docs/modules-windows.md">Windows modules</a>,
    <a href="https://github.com/imoes/yoloman/blob/main/docs/modules-linux.md">Linux modules</a> — both generated from what the agents themselves
    publish. Those links leave this site on purpose: GitHub Pages serves this folder as files and does not
    render markdown, so a local link would return raw text and look like a broken page.
  </p>
  <p>
    Regenerate this page with <code>scripts/generate-frontend-presentation.py</code>. It has no network
    dependency: everything here comes from the UI sources in this repository.
  </p>
</footer>
</body>
</html>
""")
    return "".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, default=OUT)
    args = parser.parse_args()

    routes = read_routes()
    workspaces, placement = read_nav()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(routes, workspaces, placement))

    missing = [r["path"] or "(root)" for r in routes if not doc_comment(r["file"])]
    print(f"{args.out}: {len(routes)} screens in {len(workspaces)} workspaces")
    if missing:
        print(f"undocumented components ({len(missing)}), listed on the page as such: "
              + ", ".join(sorted(missing)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
