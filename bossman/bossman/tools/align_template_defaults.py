"""Take each template field's default from the shipped file, not from the model's reading of it.

    python3 align_template_defaults.py <corpus.jsonl> [--only redhat] [--write]

THE ACCEPTANCE THIS SERVES: a template rendered with its own defaults must reproduce the file the package
ships. Anything else means applying the template to an unconfigured host CHANGES that host. Measured on the 14
RedHat templates, 12 already reproduce it exactly; the two that do not show the two ways a default goes wrong:

    dovecot   `#protocols = imap pop3 lmtp submission`  renders as  `protocols = imap pop3 lmtp submission`
              The setting ships COMMENTED OUT, and the extracted default is the example value — so the
              `{% if protocols %}` branch fires and the template ENABLES a setting the distribution disabled.
              (Its extracted default had also lost a character: `*, ::` became `, ::`.)

    bind9     `recursion yes;`                          renders as  `recursion True;`
              The default was stored as the JSON boolean true, and named.conf does not accept "True". A type
              that is right in the schema and wrong in the file.

BOTH ARE FIXED FROM THE FILE ITSELF, which is the only authority:

  activated settings   a `{% if var %}` line whose shipped counterpart is a COMMENT gets default "" — the
                       honest default for something the package ships switched off. The else branch then
                       renders the shipped comment verbatim.
  plain placeholders   the template line is turned into a pattern (everything escaped, the placeholder a
                       capture group) and matched against the shipped file. What the file has at that position
                       IS the default, as a string, so `yes` stays `yes`.

A field whose line cannot be matched is left alone and reported: guessing a default is what produced the two
defects above.
"""

from __future__ import annotations

import argparse
import json
import re

from bossman.tools._paths import configs_dir  # noqa: E402 — found, not counted (see _paths)

TEMPLATES = configs_dir(__file__) / "config_templates"

PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z_]\w*)\s*\}\}")
CONDITIONAL = re.compile(r"^\{%\s*if\s+([A-Za-z_]\w*)\s*%\}")


def default_from_shipped(line: str, shipped_lines: list[str]) -> tuple[str, str] | None:
    """(variable, value) read out of the shipped file for a single-placeholder line."""
    names = PLACEHOLDER.findall(line)
    if len(names) != 1 or "{%" in line:
        return None
    marked = PLACEHOLDER.sub("\x00", line, count=1)
    prefix, suffix = marked.split("\x00", 1)

    # ENOUGH CONTEXT TO IDENTIFY THE LINE. `    {{ notification_email_2 }}` has almost no prefix or suffix, so
    # a pattern built from it matches nearly every line — and taking the first match rewrote keepalived's
    # second notification address to its first one, dropping that template from 100% to 67%. A default guessed
    # from an ambiguous match is worse than no change.
    if len((prefix + suffix).strip()) < 3:
        return None

    pattern = re.compile("^" + re.escape(prefix) + r"(.*)" + re.escape(suffix) + "$")
    hits = [m.group(1) for m in (pattern.match(c) for c in shipped_lines) if m]
    # AND IT MUST BE UNIQUE. Several shipped lines matching one template line means the template line does not
    # identify a setting; abstain rather than pick.
    if len(set(hits)) != 1:
        return None
    return names[0], hits[0]


def unconditional_vars(body: str) -> set[str]:
    """Variables used on lines that render ALWAYS — as opposed to inside a `{% if %}` activation.

    The two need OPPOSITE defaults, which is why they have to be told apart:
      conditional    the setting ships commented out, so the default must be EMPTY or the template enables
                     something the distribution disabled.
      unconditional  the line renders no matter what, so an empty default renders an empty line — apache2
                     produced `<Directory "">` that way, after undoing a wrong activation left the "" behind.
    """
    out = set()
    for line in body.split("\n"):
        if line.lstrip().startswith("{%"):
            continue
        out.update(PLACEHOLDER.findall(line))
    return out


def unify_trailing_slash(body: str, schema: dict, shipped: str) -> tuple[str, list[str]]:
    """One variable, one value — when the file writes the same path with and without a trailing slash.

    httpd.conf uses the cgi-bin directory twice, actively, spelled differently:

        ScriptAlias /cgi-bin/ "/var/www/cgi-bin/"      with the slash
        <Directory "/var/www/cgi-bin">                 without it

    A single `{{ cgi_bin_dir }}` cannot satisfy both, so whichever default is chosen leaves one live line
    wrong — the last live-line difference left in these 14 templates. The fix keeps ONE field: the default
    becomes the form without the slash, and the template line that needs one gets it after the placeholder.
    """
    changes = []
    for var, entry in schema.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("default"), str):
            continue
        value = entry["default"]
        if not value.endswith("/") or len(value) < 2:
            continue
        bare = value.rstrip("/")
        if bare not in shipped or value not in shipped:
            continue                     # the file uses only one spelling: nothing to unify
        placeholder = "{{ " + var + " }}"
        needle = '"' + placeholder + '"'
        # Only the lines whose SHIPPED counterpart carried the slash get one appended.
        rebuilt = []
        touched = 0
        for line in body.split("\n"):
            if needle in line and (line.replace(needle, '"' + value + '"') in shipped):
                rebuilt.append(line.replace(needle, '"' + placeholder + '/"'))
                touched += 1
            else:
                rebuilt.append(line)
        if touched:
            body = "\n".join(rebuilt)
            entry["default"] = bare
            changes.append("{}: {!r} -> {!r}, and {} line(s) append the slash themselves".format(
                var, value, bare, touched))
    return body, changes


def align(body: str, schema: dict, shipped: str, sample: dict | None = None) -> tuple[dict, list[str], list[str]]:
    shipped_lines = shipped.split("\n")
    fixed, unmatched = [], []
    from_active: set[str] = set()

    # ACTIVE LINES FIRST, and a comment may never overwrite what one of them established. httpd.conf holds
    # both `    ScriptAlias /cgi-bin/ "/var/www/cgi-bin/"` and, in prose,
    # `# "/var/www/cgi-bin" should be changed to whatever your ScriptAliased` — the same directory quoted
    # WITHOUT its trailing slash. Processing lines in file order let the comment win, and the template then
    # rendered a ScriptAlias one character short of the shipped one. The live setting is the authority.
    ordered = ([ln for ln in body.split("\n") if not ln.lstrip().startswith(("#", ";"))]
               + [ln for ln in body.split("\n") if ln.lstrip().startswith(("#", ";"))])
    for raw in ordered:
        conditional = CONDITIONAL.match(raw.strip())
        if conditional:
            # The shipped line is the else branch's text, which is a comment: the setting is OFF by default.
            var = conditional.group(1)
            entry = schema.get(var)
            if isinstance(entry, dict) and entry.get("default") not in ("", None):
                entry["default"] = ""
                fixed.append("{} -> \"\" (ships commented out)".format(var))
            continue
        found = default_from_shipped(raw, shipped_lines)
        if found is None:
            if PLACEHOLDER.search(raw) and "{%" not in raw:
                unmatched.append(raw.strip()[:80])
            continue
        var, value = found
        entry = schema.get(var)
        if not isinstance(entry, dict):
            continue
        from_comment = raw.lstrip().startswith(("#", ";"))
        if from_comment and var in from_active:
            continue                     # an active line already said what this value is
        if entry.get("default") != value:
            fixed.append("{}: {!r} -> {!r}{}".format(
                var, entry.get("default"), value, " (from a comment)" if from_comment else ""))
            entry["default"] = value
        if not from_comment:
            from_active.add(var)

    # LAST RESORT for a field the matcher had to abstain on: the sample value. `<Directory "…">` occurs twice
    # in httpd.conf with different paths, so the match is genuinely ambiguous and abstaining was right — but
    # leaving the default empty renders `<Directory "">`, which is worse than the model's extraction. The
    # sample is the model's reading of that same file, and for these four it is exactly the shipped value
    # (apache2 '/var/www', caddy 80). Only for UNCONDITIONAL lines: a conditional one must stay empty.
    for var in unconditional_vars(body):
        entry = schema.get(var)
        if not isinstance(entry, dict) or entry.get("default") not in ("", None):
            continue
        fallback = (sample or {}).get(var)
        if fallback in ("", None):
            continue
        entry["default"] = fallback
        fixed.append("{}: <empty> -> {!r} (from the sample; the line is unconditional)".format(var, fallback))
    return schema, fixed, unmatched


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

    total, unmatched_total = 0, 0
    for tdir in sorted(TEMPLATES.iterdir()):
        if not tdir.is_dir() or not tdir.name.endswith(args.only):
            continue
        meta_path, body_path, schema_path = tdir / "meta.json", tdir / "template.j2", tdir / "schema.json"
        if not all(p.is_file() for p in (meta_path, body_path, schema_path)):
            continue
        try:
            target = (json.loads(meta_path.read_text()) or {}).get("target_path") or ""
            schema = json.loads(schema_path.read_text()) or {}
        except ValueError:
            continue
        shipped = texts.get(target, "")
        if not shipped:
            continue
        sample = {}
        sample_path = tdir / "sample.json"
        if sample_path.is_file():
            try:
                sample = json.loads(sample_path.read_text()) or {}
            except ValueError:
                sample = {}
        body = body_path.read_text()
        schema, fixed, unmatched = align(body, schema, shipped, sample)
        body, slash_changes = unify_trailing_slash(body, schema, shipped)
        if slash_changes and args.write:
            body_path.write_text(body)
        fixed += slash_changes
        if not fixed and not unmatched:
            continue
        print("{:22s} {:3d} default(s) taken from the file, {:3d} line(s) unmatched".format(
            tdir.name, len(fixed), len(unmatched)))
        for change in fixed[:4]:
            print("      {}".format(change[:100]))
        total += len(fixed)
        unmatched_total += len(unmatched)
        if args.write and fixed:
            schema_path.write_text(json.dumps(schema, indent=2) + "\n")
    print("\n{} default(s) aligned with the shipped bytes; {} line(s) could not be matched".format(
        total, unmatched_total))
    if not args.write:
        print("(no --write — nothing changed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
