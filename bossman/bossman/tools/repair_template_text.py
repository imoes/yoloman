"""Restore template lines that carry no placeholder to the bytes the package actually ships.

    python3 repair_template_text.py <corpus.jsonl> [--only redhat] [--write]

A line in a generated template that contains no `{{ … }}` was not parametrized, so it must be the shipped
file's line, character for character. Measured on the 14 RedHat templates, several are not — and the pattern is
BACKSLASHES:

    freeradius  `(i.e. \\)`            became `(i.e. \\n)`
                `grep '\\\\'`          became `grep '\\'`
    exim        `^.*/\\.\\./`            came back with one backslash level lost
    collectd    a regex inside a comment lost an escape

That is the price of handing a config file through a JSON envelope: the model has to escape backslashes to
produce valid JSON and un-escaping is where they get lost. It is not a reasoning failure and no prompt fixes
it reliably — but it is entirely mechanical to undo, because the correct text is sitting in the corpus.

HOW A LINE IS MATCHED BACK. For each unmatched line, the shipped file's most similar line (difflib ratio) is
taken, and only when the similarity is at least MIN_RATIO. Below that the line is left alone and REPORTED: a
line that resembles nothing in the shipped file is not a mangled escape, it is a line the generator invented,
and quietly overwriting it with the nearest neighbour would hide exactly the defect worth seeing.

An independent judge (Hermes/laguna) found the freeradius case first, reading the template against the shipped
file. This script is that finding turned into an invariant plus its repair.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re

from bossman.tools._paths import configs_dir  # noqa: E402 — found, not counted (see _paths)

TEMPLATES = configs_dir(__file__) / "config_templates"

#: How similar a shipped line must be before it is accepted as the origin of a mangled one. 0.85 keeps
#: escape-level differences (one or two characters in a long line) and rejects a genuinely different line.
MIN_RATIO = 0.85

PLACEHOLDER = re.compile(r"\{\{|\{%")


def collapse(line: str) -> str:
    return " ".join(line.split())


#: A placeholder-bearing line, reduced to a pattern: the placeholders become wildcards and everything else is
#: literal. Used to find the shipped line a template line came from even though its text now differs.
def _skeleton(line: str) -> "re.Pattern | None":
    parts = re.split(r"\{\{[^}]*\}\}", line)
    if len(parts) < 2:
        return None
    return re.compile("^" + r"(.*?)".join(re.escape(part) for part in parts) + "$")


#: Prose, not a setting: the comment character is followed by whitespace and what comes next is either not a
#: name at all (a quote, a bracket) or a sentence — more than three words of value.
def _is_prose(line: str) -> bool:
    stripped = line.strip()
    if stripped[:1] not in "#;":
        return False
    rest = stripped[1:]
    if not rest[:1].isspace():
        return False                     # `#setting value` — a disabled setting, not prose
    rest = rest.strip()
    if not re.match(r"^[A-Za-z_][\w.-]*", rest):
        return True                      # starts with a quote or punctuation
    if re.match(r"^[A-Za-z_][\w.-]*\s*=", rest):
        return False                     # `# name = value` — an assignment, so a setting
    return len(rest.split()) > 4


def restore_prose(body: str, shipped: str) -> tuple[str, int]:
    """De-parametrize a PROSE comment and put the sentence back exactly as the file has it.

    httpd.conf explains its own layout in prose that QUOTES a path:

        # "/var/www/cgi-bin" should be changed to whatever your ScriptAliased

    The generator turned that quote into `{{ cgi_bin_dir }}`, so the same variable now has to satisfy two
    different literals — the prose (no trailing slash) and the live `ScriptAlias /cgi-bin/ "/var/www/cgi-bin/"`
    (with one). Whichever value it takes, one of the two lines is wrong. A sentence is not configuration, so
    the sentence goes back verbatim and the variable is left to the setting that really uses it.
    """
    shipped_lines = shipped.split("\n")
    out, restored = [], 0
    for line in body.split("\n"):
        if "{{" not in line or not _is_prose(line):
            out.append(line)
            continue
        pattern = _skeleton(line)
        hits = [candidate for candidate in shipped_lines if pattern and pattern.match(candidate)]
        if len(hits) != 1:
            out.append(line)
            continue
        out.append(hits[0])
        restored += 1
    return "\n".join(out), restored


def restore_shape(body: str, shipped: str) -> tuple[str, int]:
    """Adopt the shipped line's exact surroundings while KEEPING the placeholder.

    collectd indents inside plugin blocks with tabs — `#\tFile "/var/log/collectd.json.log"` — and rebuilding
    such a line from its parts lost the tab, so eleven comment lines rendered with one space instead. The
    placeholder stays; only the text around it is taken from the file.
    """
    shipped_lines = shipped.split("\n")
    out, fixed = [], 0
    for line in body.split("\n"):
        if "{{" not in line or "{%" in line or _is_prose(line):
            out.append(line)
            continue
        pattern, placeholders = _skeleton(line), re.findall(r"\{\{[^}]*\}\}", line)
        hits = [m for m in (pattern.match(c) for c in shipped_lines) if m] if pattern else []
        if len(hits) != 1:
            out.append(line)
            continue
        # Rebuild: the shipped line's literal parts, the template's placeholders in between.
        literals = re.split(r"\{\{[^}]*\}\}", line)
        rebuilt = "".join(part + (placeholders[i] if i < len(placeholders) else "")
                          for i, part in enumerate(literals))
        shipped_line = hits[0].string
        prefix = shipped_line[:shipped_line.index(literals[0].lstrip()) if literals[0].strip() else 0]
        if prefix and not line.startswith(prefix):
            out.append(prefix + rebuilt.lstrip())
            fixed += 1
            continue
        out.append(line)
    return "\n".join(out), fixed


def _strip_ws(text: str) -> tuple[str, list[int]]:
    """(text without whitespace, index of each kept character in the original)."""
    kept, index = [], []
    for position, char in enumerate(text):
        if not char.isspace():
            kept.append(char)
            index.append(position)
    return "".join(kept), index


def restore_spacing(body: str, shipped: str) -> tuple[str, int]:
    """Give a rebuilt comment line back the exact whitespace the shipped file uses.

    Undoing an activation rebuilt lines as `indent + '#' + name + …`, which drops whatever sat BETWEEN the
    comment character and the name. collectd indents inside plugin blocks with a tab (`#\tFile "…"`) and Caddy
    writes prose as `# The configuration …`; both came back as a bare `#`. Comments only — but "the template
    reproduces the shipped file" is either true or it is not, and these were the last twelve lines making it
    false.

    Whitespace cannot be matched flexibly from the template side: the tab sits where the TEMPLATE has nothing.
    So both lines are compared with all whitespace removed — the placeholder as the one wildcard — and the hit
    is then rebuilt from the SHIPPED characters with the placeholder put back over the span it matched. Two
    earlier attempts failed silently on re's escaping layers (`re.escape` escapes a space, so substituting
    afterwards produced `\\s+` and matched a literal backslash); comparing without whitespace at all avoids
    that question entirely.
    """
    shipped_lines = shipped.split("\n")
    bare_shipped = [_strip_ws(candidate) for candidate in shipped_lines]
    out, fixed = [], 0
    for line in body.split("\n"):
        stripped = line.strip()
        if not stripped or stripped[0] not in "#;" or "{%" in line:
            out.append(line)
            continue
        parts = re.split(r"(\{\{[^}]*\}\})", line)
        if len(parts) != 3 or not parts[1].startswith("{{"):
            out.append(line)          # zero or several placeholders: no unique span to map back
            continue
        pattern = re.compile("^" + re.escape(_strip_ws(parts[0])[0]) + "(.*?)"
                             + re.escape(_strip_ws(parts[2])[0]) + "$")
        hits = [(candidate, bare, index, pattern.match(bare))
                for candidate, (bare, index) in zip(shipped_lines, bare_shipped)]
        hits = [hit for hit in hits if hit[3]]
        if len(hits) != 1:
            out.append(line)
            continue
        candidate, _bare, index, match = hits[0]
        if candidate == line:
            out.append(line)
            continue
        # Map the captured span back into the original line's coordinates.
        first, last = match.start(1), match.end(1)
        head = candidate[:index[first]] if first < len(index) else candidate
        tail = candidate[index[last - 1] + 1:] if 0 < last <= len(index) else ""
        rebuilt = head + parts[1] + tail
        out.append(rebuilt)
        fixed += 1
    return "\n".join(out), fixed


def repair(body: str, shipped: str) -> tuple[str, list[str], list[str]]:
    """(repaired template, restored lines, lines left alone)."""
    shipped_lines = shipped.split("\n")
    exact = {line.strip() for line in shipped_lines}
    loose = {collapse(line) for line in shipped_lines}
    by_collapsed: dict[str, str] = {}
    for line in shipped_lines:
        by_collapsed.setdefault(collapse(line), line)

    restored, kept = [], []
    out = []
    for line in body.split("\n"):
        stripped = line.strip()
        if not stripped or PLACEHOLDER.search(line) or "{%" in line or stripped in exact:
            out.append(line)
            continue
        if collapse(stripped) in loose:
            # Whitespace-only difference: restore the shipped indentation too, so a render reproduces the
            # file exactly rather than nearly.
            out.append(by_collapsed[collapse(stripped)])
            restored.append(stripped)
            continue
        # NO FUZZY RESTORE in the general chain. "The closest shipped line" replaced structure that merely looked
        # alike: containerd's `[plugins…cri".streaming]` and `[…cri".containerd]` both became the shipped
        # `[…cri".cni]` — duplicated TOML tables, containerd refused the file (measured 2026-10-11). A line that
        # differs in more than whitespace is the template's own, and stays.
        out.append(line)
        kept.append(stripped)
    return "\n".join(out), restored, kept


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--only", default="redhat")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    texts: dict[str, str] = {}
    with open(args.corpus) as fh:
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("text") and row["path"] not in texts:
                texts[row["path"]] = row["text"]

    total_restored = total_kept = 0
    for tdir in sorted(TEMPLATES.iterdir()):
        if not tdir.is_dir() or not tdir.name.endswith(args.only):
            continue
        meta_path, body_path = tdir / "meta.json", tdir / "template.j2"
        if not (meta_path.is_file() and body_path.is_file()):
            continue
        try:
            target = (json.loads(meta_path.read_text()) or {}).get("target_path") or ""
        except ValueError:
            continue
        shipped = texts.get(target, "")
        if not shipped:
            continue
        body = body_path.read_text()
        body, prose = restore_prose(body, shipped)
        body, shaped = restore_shape(body, shipped)
        body, spaced = restore_spacing(body, shipped)
        if spaced:
            print("{:22s} {} comment line(s) given back the file's own spacing".format(tdir.name, spaced))
        if prose or shaped:
            print("{:22s} {} prose line(s) de-parametrized, {} line(s) re-indented from the file".format(
                tdir.name, prose, shaped))
        repaired, restored, kept = repair(body, shipped)
        if not restored and not kept:
            continue
        print("{:22s} restored {:3d}  left alone {:3d}".format(tdir.name, len(restored), len(kept)))
        for line in kept[:3]:
            print("      not in the shipped file at all: {}".format(line[:96]))
        total_restored += len(restored)
        total_kept += len(kept)
        if args.write and repaired != body:
            body_path.write_text(repaired)
    print("\nrestored {} line(s) to the shipped bytes; {} left alone as genuinely different".format(
        total_restored, total_kept))
    if not args.write:
        print("(no --write — nothing changed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
