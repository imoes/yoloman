"""Make a placeholder inside a commented-out example actually do something.

    python3 activate_commented_settings.py <corpus.jsonl> [--only redhat] [--write]

THE DEFECT, found by an invariant that came from an independent judge's remark. Three of the 14 RedHat
templates have every one of their placeholders on a COMMENT line:

    #Hostname    "{{ collectd_hostname }}"          collectd.conf   (26 fields, all inert)
    #protocols = {{ protocols }}                    dovecot.conf    (13 fields, all inert)
    #include "{{ nftables_main_conf_path }}"        nftables.conf   ( 1 field,  inert)

The model parametrized the file's commented EXAMPLES, which is a reasonable reading of "parametrize this
file" — those lines are where the settings are documented. But the result is a form with 40 knobs that change
nothing: setting collectd_hostname edits a comment. The apply would report success and the service would not
notice.

THE FIX IS NOT WITHDRAWAL. An operator genuinely wants to set those values; what the template lacks is the
step from "documented example" to "active setting". So a commented setting becomes conditional:

    {% if collectd_hostname %}Hostname    "{{ collectd_hostname }}"{% else %}#Hostname    "cool.example.com"{% endif %}

Value set -> the setting is live. Value unset -> the shipped comment line comes back VERBATIM, including its
original default, so a host with nothing configured keeps the file the package shipped. Both halves are
checked by verify_templates (renders, invents nothing, and now: at least one placeholder on a live line).

ONLY LINES THAT REALLY ARE SETTINGS are touched: `#Name = value` or `#Name value` with a placeholder in the
value. A prose comment that happens to contain a placeholder is left alone — and reported, because a
placeholder inside prose is a different defect and should not be hidden by this one's repair.
"""

from __future__ import annotations

import argparse
import json
import re

from bossman.tools._paths import configs_dir  # noqa: E402 — found, not counted (see _paths)

TEMPLATES = configs_dir(__file__) / "config_templates"

#: `#Name = {{ var }}` / `;Name {{ var }}` — a commented SETTING, not prose. Groups: indent, comment char,
#: name, separator, value (which must contain the placeholder).
#: An ESCAPED literal — `{{ '{{' }}` — is the FILE's own brace handed back verbatim, not a placeholder. Both
#: checks below have to ignore them, or exim4-redhat looks like it has 11 placeholders buried in prose when
#: what it really has is 11 escaped braces from its own `${if …}` expansions.
ESCAPED_LITERAL = re.compile(r"\{\{\s*'[^']*'\s*\}\}")


def real_placeholders(line: str) -> bool:
    return "{{" in ESCAPED_LITERAL.sub("", line)


#: NO SPACE AFTER THE COMMENT CHARACTER, and that one detail is the whole difference between a disabled
#: setting and a sentence. Config files write a commented-out setting as `#setting value` and prose as
#: `# some text`, and the convention held perfectly here: of 45 lines this script had activated, exactly ONE
#: had a space — apache2's `# Relax access to content within /var/www.`, which it had read as a directive
#: named "Relax". With the default set, that line rendered as `Relax access to content within /var/www.`
#: INSIDE httpd.conf: an invalid directive that would stop Apache from starting.
#:
#: None of my invariants saw it (the line carries a placeholder, so the invented-line check skips it, and it
#: renders fine); the independent judge did — on its third pass over an unchanged artefact, after two passes
#: had called the same file faithful.
COMMENTED_SETTING = re.compile(
    r"^(?P<indent>\s*)(?P<hash>[#;])(?P<name>[A-Za-z_][\w.-]*)"
    r"(?P<sep>\s*=\s*|\s+)(?P<value>[^\n]*\{\{\s*(?P<var>[A-Za-z_]\w*)\s*\}\}[^\n]*)$")

#: `# text` — a comment that is prose, not a disabled setting.
PROSE_COMMENT = re.compile(r"^\s*[#;]\s")


def shipped_original(shipped_lines: list[str], name: str, hash_char: str) -> str | None:
    """The file's own commented line for this setting — used verbatim as the else branch.

    IT MUST BE UNIQUE. Taking the first match put the WRONG line in collectd's else branches, and an
    independent judge found it: `#Interval` matched a wrapped comment-header line instead of `#Interval  10`,
    and `#File` matched the logfile plugin's example while the placeholder belonged to log_logstash. collectd
    repeats the same setting names inside different plugin blocks, so the name alone does not identify a line.
    An ambiguous name yields no else branch at all — the commented placeholder stays as it was, which is inert
    but honest, rather than rendering another plugin's value into an unconfigured host's file.
    """
    pattern = re.compile(r"^\s*" + re.escape(hash_char) + re.escape(name) + r"(\s*=|\s)")
    hits = [line for line in shipped_lines if pattern.match(line)]
    return hits[0] if len(hits) == 1 else None


#: An already-activated line: {% if var %}active{% else %}#shipped{% endif %}
ACTIVATED = re.compile(r"^\{%\s*if\s+(?P<var>[A-Za-z_]\w*)\s*%\}(?P<active>.*?)\{%\s*else\s*%\}"
                       r"(?P<other>.*?)\{%\s*endif\s*%\}$")


def fix_else_branches(body: str, shipped: str) -> tuple[str, int, int]:
    """Correct or undo an activation whose else branch is not the file's own line.

    Needed because the first version of shipped_original() took the FIRST line matching the setting name, and
    collectd repeats names across plugin blocks: `#File` matched the logfile plugin's example while the
    placeholder belonged to log_logstash. An independent judge found it. Two outcomes, no guessing:

      unique shipped line, different  -> the else branch is replaced by that line
      name is ambiguous               -> the activation is UNDONE (back to a commented placeholder). Inert,
                                         but it cannot render another plugin's value into a host's file.

    Returns (body, corrected, reverted).
    """
    shipped_lines = shipped.split("\n")
    out, corrected, reverted = [], 0, 0
    for line in body.split("\n"):
        match = ACTIVATED.match(line.strip())
        if not match:
            out.append(line)
            continue
        active, other = match.group("active"), match.group("other")
        name_match = re.match(r"^\s*([A-Za-z_][\w.-]*)", active)
        hash_char = other.strip()[:1] if other.strip()[:1] in "#;" else "#"
        if not name_match:
            out.append(line)
            continue
        if PROSE_COMMENT.match(other):
            # The shipped line is PROSE (space after the comment character), so this was never a setting.
            # Undo: put the sentence back exactly as the file has it.
            out.append(other)
            reverted += 1
            continue
        original = shipped_original(shipped_lines, name_match.group(1), hash_char)
        if original is None:
            # Ambiguous: undo. The commented form is the active text with the file's comment character.
            indent = re.match(r"^(\s*)", active).group(1)
            out.append("{}{}{}".format(indent, hash_char, active.lstrip()))
            reverted += 1
            continue
        if original != other:
            out.append("{{% if {} %}}{}{{% else %}}{}{{% endif %}}".format(
                match.group("var"), active, original))
            corrected += 1
            continue
        out.append(line)
    return "\n".join(out), corrected, reverted


#: An ACTIVE template line carrying a placeholder: `primary_hostname = {{ primary_hostname }}`.
ACTIVE_SETTING = re.compile(
    r"^(?P<indent>\s*)(?P<name>[A-Za-z_][\w.-]*)(?P<sep>\s*=\s*|\s+)"
    r"(?P<value>[^\n]*\{\{\s*(?P<var>[A-Za-z_]\w*)\s*\}\}[^\n]*)$")
#: The same, with filters on the variable — `compression = {{ compression | default('none') }}`, the form most
#: generated templates use. ACTIVE_SETTING alone missed every one of them (barman: three activated examples left).
ACTIVE_SETTING_FILTERED = re.compile(
    r"^(?P<indent>\s*)(?P<name>[A-Za-z_][\w.-]*)(?P<sep>\s*=\s*|\s+)"
    r"(?P<value>[^\n{]*\{\{-?\s*(?P<var>[A-Za-z_]\w*)\s*(?:\|[^}]*)?-?\}\}[^\n{]*)$")


_FOR_OPEN = re.compile(r"\{%-?\s*for\b")
_FOR_CLOSE = re.compile(r"\{%-?\s*endfor\b")


def _loop_depths(lines: list[str]) -> list[int]:
    """For each line, how many `{% for %}` blocks enclose it (counted from the lines before it)."""
    depth, out = 0, []
    for ln in lines:
        out.append(depth)
        depth = max(0, depth + len(_FOR_OPEN.findall(ln)) - len(_FOR_CLOSE.findall(ln)))
    return out


def deactivate_model_activations(body: str, shipped: str, vars_out: list | None = None,
                                 schema: dict | None = None) -> tuple[str, int]:
    """Put back the comment where the MODEL enabled a setting the distribution ships disabled.

    exim.conf ships `# primary_hostname =` — commented. The generated template has
    `primary_hostname = {{ primary_hostname }}` ACTIVE, so applying it to an unconfigured host writes an empty
    primary_hostname into a live exim configuration. This is not my activation pass (which only touches
    commented lines); it is the model reading a commented example as a setting to parametrize.

    The repair is the same conditional the activation uses, so the two agree: value set -> the setting is
    live, value unset -> the shipped COMMENT verbatim, tabs and spacing included. Only when the shipped file
    has that name UNIQUELY as a comment and nowhere as an active setting — otherwise the file itself sets it
    and the template is right to.
    """
    shipped_lines = shipped.split("\n")
    out, changed = [], 0
    body_lines = body.split("\n")
    depths = _loop_depths(body_lines)
    for line, depth in zip(body_lines, depths):
        match = ACTIVE_SETTING.match(line) or ACTIVE_SETTING_FILTERED.match(line)
        # Inside a loop the "variable" is the loop's item, not a field (postfix: `{{ key }}` of a dict loop).
        if (not match or line.lstrip().startswith(("{%", "#", ";")) or depth
                or (schema is not None and match.group("var") not in schema)):
            out.append(line)
            continue
        name = match.group("name")
        active_elsewhere = re.compile(r"^\s*" + re.escape(name) + r"(\s*=|\s)")
        if any(active_elsewhere.match(ln) for ln in shipped_lines):
            out.append(line)                     # the file sets it too: the template is right
            continue
        # TWO TIERS, because a sentence can begin with a setting's name. exim.conf has both
        #     `# primary_hostname =`                                  the disabled setting
        #     `# primary_hostname value is used for qualification.`   a sentence about it
        # so a single pattern found two hits and this pass abstained. The ASSIGNMENT form identifies the
        # setting: `#name =`, optionally with a value. Only if that is ambiguous too is there nothing to do.
        assignment = re.compile(r"^\s*[#;]\s*" + re.escape(name) + r"\s*=")
        commented = re.compile(r"^\s*[#;]\s*" + re.escape(name) + r"(\s*=|\s)")
        hits = [ln for ln in shipped_lines if assignment.match(ln)]
        if len(hits) != 1:
            hits = [ln for ln in shipped_lines if commented.match(ln)]
        if len(hits) != 1:
            out.append(line)                     # not uniquely a commented setting: leave it alone
            continue
        # present(), not a bare `if var`: a field with a default is always truthy, so the bare test kept the line
        # active exactly when nobody set anything; and gonja reads `[] != []` as true. The caller sets the field's
        # default to null (vars_out), so unset renders the shipped comment.
        out.append("{{% if {} %}}{}{{% else %}}{}{{% endif %}}".format(
            present(match.group("var")), line, hits[0]))
        if vars_out is not None:
            vars_out.append(match.group("var"))
        changed += 1
    return "\n".join(out), changed


#: `key = {{ var | default('') }}` written unconditionally — an empty default ACTIVATES a setting with no value.
EMPTY_ACTIVE = re.compile(r"^(?P<indent>\s*)(?P<name>[A-Za-z_][\w.-]*)(?P<sep>\s*=\s*)"
                          r"\{\{\s*(?P<var>[A-Za-z_]\w*)\s*(?:\|\s*default\([^)]*\)\s*)?\}\}\s*$")


def guard_empty_activations(body: str, shipped: str) -> tuple[str, int]:
    """A setting the shipped file only COMMENTS stays commented while its value is unset or empty.

    The model parametrized `#threads = ` as `threads = {{ threads | default('') }}`: with nothing set the file
    gained `threads = `, and snapserver refused to start ("missing argument for --server.threads") — after its
    regeneration from the shipped file, which had been meant to fix it. Measured: 44 catalog templates render
    137 such lines. Guarded only where the shipped file has the key commented and not active (an empty assignment
    can be meaningful where the file itself writes one — resolved.conf's DNS=)."""
    shipped_lines = shipped.split("\n")
    out, changed = [], 0
    for line in body.split("\n"):
        m = EMPTY_ACTIVE.match(line)
        if m:
            name = m.group("name")
            active_in_shipped = any(re.match(r"^\s*" + re.escape(name) + r"\s*=", ln) for ln in shipped_lines)
            original = None
            for hash_char in ("#", ";"):
                original = original or shipped_original(shipped_lines, name, hash_char) \
                    or next((ln for ln in shipped_lines if re.match(r"^\s*" + re.escape(hash_char) + r"\s*"
                                                                      + re.escape(name) + r"\s*=", ln)), None)
            if original is not None and not active_in_shipped:
                var = m.group("var")
                # Any inline default: the SCHEMA's default reaches the template first, and an empty one ("") wrote
                # `threads = ` even under `| default(-1)`. Unset or empty → the shipped comment.
                out.append("{{% if {var} is defined and {var} is not none and {var} != '' %}}{indent}{name}{sep}"
                           "{{{{ {var} }}}}{{% else %}}{original}{{% endif %}}".format(
                    var=var, indent=m.group("indent"), name=name, sep=m.group("sep"), original=original))
                changed += 1
                continue
        out.append(line)
    return "\n".join(out), changed


def activate(body: str, shipped: str) -> tuple[str, int, list[str]]:
    shipped_lines = shipped.split("\n")
    out, changed, prose = [], 0, []
    for line in body.split("\n"):
        match = COMMENTED_SETTING.match(line)
        if not match:
            if real_placeholders(line) and line.lstrip().startswith(("#", ";", "//")):
                prose.append(line.strip())
            out.append(line)
            continue
        original = shipped_original(shipped_lines, match.group("name"), match.group("hash"))
        if original is None:
            # No matching line in the shipped file: this comment was not the file's own example, so leave it.
            out.append(line)
            continue
        var = match.group("var")
        active = "{indent}{name}{sep}{value}".format(
            indent=match.group("indent"), name=match.group("name"),
            sep=match.group("sep"), value=match.group("value"))
        out.append("{{% if {var} %}}{active}{{% else %}}{original}{{% endif %}}".format(
            var=var, active=active, original=original))
        changed += 1
    return "\n".join(out), changed, prose


#: A commented setting carrying ANY placeholder expression: `#DSHELL={{ dshell | default('/bin/bash') }}`,
#: `# loglevel = {{ log_level }}` (comment character, optional ONE space, key, separator, value with `{{`).
COMMENTED_EXPR = re.compile(r"^(?P<indent>\s*)(?P<hash>[#;]+[ \t]?)(?P<key>[A-Za-z_][\w.-]*)(?P<sep>\s*=\s*|[ \t]+)"
                            r"(?P<value>.*\{\{.*)$")
_FIRST_VAR = re.compile(r"\{\{\s*([A-Za-z_]\w*)")


def present(var: str) -> str:
    """The guard "this field has a value", written so the agent's gonja and the pipeline's jinja2 agree.

    `v != []` is TRUE for an empty list in gonja (measured 2026-10-11 with render-check: `[] != []` → T), so an
    empty list activated `KillOnlyUsers=` for the agent while jinja2 kept the comment — the parity test caught it.
    `length` answers the same in both; numbers and booleans are values even when 0/false."""
    return f"{var} is defined and {var} is not none and ({var} is number or {var} is boolean or {var} | length > 0)"


def _shipped_line(shipped_lines: list[str], hash_: str, key: str, sep: str) -> str | None:
    """The file's own commented line for `key`, unique, or None. Where the key is also NAMED in prose
    (ucf.conf: "only one of conf_force_conffold and conf_force_conffnew should be set"), an `=` setting prefers the
    lines that assign."""
    pat = re.compile(r"^\s*" + re.escape(hash_.strip()) + r"[ \t]?" + re.escape(key) + r"(\s*=|[ \t])")
    hits = [ln for ln in shipped_lines if pat.match(ln)]
    if len(hits) > 1 and "=" in sep:
        hits = [ln for ln in hits if re.match(r"^\s*[#;]+[ \t]?" + re.escape(key) + r"\s*=", ln)]
    return hits[0] if len(hits) == 1 else None


def activate_expressions(body: str, shipped: str, schema: dict) -> tuple[str, set[str], list[str]]:
    """The general form of `activate`, for templates whose EVERY placeholder sat on a comment line.

    Measured 2026-10-11: 18 catalog templates had a form whose fields changed nothing (adduser 17 fields, connman 29,
    logind 11, spamassassin 11 …) — `activate` matched only a bare `{{ var }}` and read `# key = …` as prose. Here a
    commented setting with any expression becomes `{% if <present> %}live line{% else %}shipped line{% endif %}`,
    when the shipped file has that commented setting exactly once (ambiguous keys — i2pd's per-section `port` — stay
    as they are). A schema field the template never places is wired to the file's own `#field=value` line the same
    way. Returns (body, activated variables, lines left alone). The caller sets the activated fields' defaults to
    null: unset keeps the shipped file, so the defaults still render it."""
    shipped_lines = shipped.split("\n")
    out, activated, left = [], set(), []
    body_lines = body.split("\n")
    depths = _loop_depths(body_lines)
    for line, depth in zip(body_lines, depths):
        m = COMMENTED_EXPR.match(line)
        if not m or "{%" in line or depth:
            # Inside a loop a commented line with an expression is a COMMENT about the item — postfix's
            # `# TLS setting: {{ key }}` was switched on as a setting and postfix refused main.cf (measured).
            out.append(line)
            continue
        found = _FIRST_VAR.search(ESCAPED_LITERAL.sub("", m["value"]))
        if found and found.group(1) not in (schema or {}):
            left.append(line.strip())       # not a field of this template: nothing an operator could set
            out.append(line)
            continue
        original = _shipped_line(shipped_lines, m["hash"], m["key"], m["sep"]) if found else None
        if original is None:   # ambiguous, not the file's own line, or only an escaped literal (`{{ '{{' }}`)
            left.append(line.strip())
            out.append(line)
            continue
        var = found.group(1)
        out.append("{%% if %s %%}%s%s%s%s\n{%% else %%}%s\n{%% endif %%}"
                   % (present(var), m["indent"], m["key"], m["sep"], m["value"], original))
        activated.add(var)
    used = set(_FIRST_VAR.findall("\n".join(out)))
    for var in [k for k in schema if k not in used]:
        pat = re.compile(r"^(\s*)([#;]+[ \t]?)" + re.escape(var) + r"(\s*=\s*)(.*)$")
        idx = [i for i, ln in enumerate(out) if "{" not in ln and pat.match(ln)]
        if len(idx) == 1:
            m2 = pat.match(out[idx[0]])
            out[idx[0]] = "{%% if %s %%}%s%s%s{{ %s }}\n{%% else %%}%s\n{%% endif %%}" % (
                present(var), m2.group(1), var, m2.group(3), var, out[idx[0]])
            activated.add(var)
    text = ""
    # The newline lives inside both branches of THIS pass's blocks (they span lines); none after their {% endif %}.
    # A one-line block from an earlier pass (`{% if v %}a{% else %}#a{% endif %}`) keeps its newline outside — testing
    # only `endswith("{% endif %}")` joined it to the next line (measured in the repair chain: barman's
    # `;parallel_jobs = 1{% endif %}log_level = …`).
    for i, ln in enumerate(out):
        own_block = ln.endswith("{% endif %}") and "\n" in ln
        text += ln if own_block else ln + ("\n" if i < len(out) - 1 else "")
    return text, activated, left


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

    total, prose_total = 0, 0
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
        activated, changed, prose = activate(body, shipped)
        activated, deactivated = deactivate_model_activations(activated, shipped)
        if deactivated:
            print("{:22s} {} setting(s) the model had ENABLED put back behind a condition".format(
                tdir.name, deactivated))
        activated, corrected, reverted = fix_else_branches(activated, shipped)
        if corrected or reverted:
            print("{:22s} else-branch: {} corrected, {} activation(s) undone as ambiguous".format(
                tdir.name, corrected, reverted))
        if not changed and not prose and not corrected and not reverted:
            continue
        print("{:22s} activated {:3d} commented setting(s){}".format(
            tdir.name, changed,
            "; {} placeholder(s) left inside prose".format(len(prose)) if prose else ""))
        for line in prose[:2]:
            print("      prose: {}".format(line[:96]))
        total += changed
        prose_total += len(prose)
        if args.write and activated != body:
            body_path.write_text(activated)
    print("\nactivated {} setting(s); {} placeholder(s) remain inside prose comments".format(
        total, prose_total))
    if not args.write:
        print("(no --write — nothing changed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
