"""The template invariants — facts about a generated template that code decides better than any model.

Moved here from scripts/verify_templates.py (which is untracked) because three callers now need the SAME
answer: the model benchmark (which model writes templates that hold?), the RedHat twin check (is the Debian
template already this file?) and the Debian target recovery (which shipped file does this template render?).
Three copies of "is this template that file" would be three answers to one question.

  renders          jinja2 parses and renders it with sample.json.
  keeps the file   the shipped file's lines survive in the template.
  invents nothing  every template line WITHOUT a placeholder appears in the shipped file (a line that matches only
                   after collapsing whitespace was REFLOWED, which is harmless; one that matches nothing was
                   INVENTED, which fails).
  declared         every {{ placeholder }} exists in schema.json — an undeclared one renders empty and silently
                   deletes a setting.
  substitutes      the sample's values actually appear in the render. Rendering is not substituting: a
                   mis-escaped template once emitted "{{ bind_directory; }}" verbatim into named.conf.
  own defaults     rendered with its OWN defaults, every line is in the shipped file — the template counterpart
                   of the codec round-trip, and the sharpest check (it caught a prose comment rendering as an
                   active Apache directive at 99.99% similarity).
  configures       at least one placeholder sits on a non-comment line; a knob inside a comment changes nothing.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

#: A placeholder's variable name — the first identifier inside {{ ... }}, ignoring filters and attributes.
PLACEHOLDER_NAME = re.compile(r"\{\{\s*([A-Za-z_]\w*)")
#: `{{ '{{' }}` is an escaped literal — the file's own brace, not a variable.
ESCAPED_LITERAL = re.compile(r"\{\{\s*'[^']*'\s*\}\}")


def keeps_the_file(shipped: str, template: str) -> tuple[bool, str]:
    """Is the template still THAT file? Most of the shipped file's substantial lines must survive, verbatim or
    as their first token (which is what a parametrized line looks like: `address {{ host_address }}`)."""
    original = [ln.strip() for ln in shipped.split("\n") if len(ln.strip()) > 3]
    if not original:
        return True, "the shipped file has no substantial lines to compare"
    kept = 0
    for line in original:
        if line in template:
            kept += 1
            continue
        head = line.split()[0] if line.split() else ""
        if len(head) > 2 and head in template:
            kept += 1
    ratio = kept / len(original)
    return ratio >= 0.5, f"{kept}/{len(original)} of the shipped file's lines survive ({ratio:.0%})"


def _load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _env():
    """jinja2 with the REAL ansible-core filters — the enriched templates are Ansible-safe (`| bool`,
    `| dict2items`), and a plain jinja2 environment reports them as broken when they are not. Same filter set as
    the enrich gate, so "renders" means the same thing in both places."""
    import jinja2

    from bossman.tools.enrich_gates import _ansible_filters

    env = jinja2.Environment(undefined=jinja2.ChainableUndefined, keep_trailing_newline=True)
    env.filters.update(_ansible_filters())
    return env


def _defaults(schema: dict) -> dict:
    """Each field's default. A null default is LEFT OUT, not passed as None: the template's own
    `| default(...)` is the fallback the enrich pass wrote for exactly that case, and None would override it
    (`{% for x in None %}` raises where an undefined iterates as empty)."""
    from bossman.services.schema_defaults import schema_defaults

    return schema_defaults(schema)


def render_with_defaults(tdir: Path) -> str | None:
    """The template rendered with its schema's own defaults, or None when it does not render."""
    body = (tdir / "template.j2").read_text(errors="replace") if (tdir / "template.j2").is_file() else ""
    if not body:
        return None
    try:
        return _env().from_string(body).render(**_defaults(_load_json(tdir / "schema.json")))
    except Exception:  # noqa: BLE001 — any parse/render failure means "does not render"
        return None


def mechanical(tdir: Path, shipped: str) -> dict:
    """All invariants for the template in `tdir` against the file the package ships. `ok` is their conjunction."""
    body = (tdir / "template.j2").read_text(errors="replace") if (tdir / "template.j2").is_file() else ""
    schema = _load_json(tdir / "schema.json")
    sample = _load_json(tdir / "sample.json")

    used = set(PLACEHOLDER_NAME.findall(ESCAPED_LITERAL.sub("", body)))
    declared = set(schema)
    result: dict = {
        "template": tdir.name,
        "renders": False,
        "render_error": "",
        "undeclared": sorted(used - declared),
        "unplaced": sorted(declared - used),
        "fields": len(declared),
    }
    kept, why = keeps_the_file(shipped, body)
    result["keeps_the_file"], result["kept_detail"] = kept, why

    def collapse(line: str) -> str:
        return " ".join(line.split())

    exact = {line.strip() for line in shipped.split("\n")}
    loose = {collapse(line) for line in shipped.split("\n")}
    invented, reflowed = [], []
    for line in body.split("\n"):
        stripped = line.strip()
        if not stripped or "{{" in line or "{%" in line:
            continue
        if stripped in exact:
            continue
        (reflowed if collapse(stripped) in loose else invented).append(stripped)
    result["invented_lines"] = len(invented)
    result["invented_sample"] = invented[:4]
    result["reflowed_lines"] = len(reflowed)

    live = [line for line in body.split("\n")
            if "{{" in ESCAPED_LITERAL.sub("", line)
            and not line.lstrip().startswith(("#", ";", "//"))]
    result["live_placeholder_lines"] = len(live)
    try:
        out = _env().from_string(body).render(**{k: v for k, v in sample.items() if v is not None})
        result["renders"] = bool(out.strip())
        result["rendered_bytes"] = len(out)
        wanted = [str(v) for v in sample.values() if isinstance(v, (str, int, float)) and len(str(v)) > 2]
        result["values_reaching_output"] = sum(1 for v in wanted if v in out)
        result["values_expected"] = len(wanted)
    except Exception as exc:  # noqa: BLE001 — any parse/render failure is a failure
        result["render_error"] = str(exc)[:120]

    with_defaults = render_with_defaults(tdir)
    if with_defaults is None:
        result["default_render_diff"] = ["render with defaults failed"]
    else:
        shipped_set = {line.rstrip() for line in shipped.split("\n")}
        result["default_render_diff"] = [line.rstrip() for line in with_defaults.split("\n")
                                         if line.strip() and line.rstrip() not in shipped_set]

    # THE SEMANTIC READING. The enrich stage makes a template self-documenting on purpose: it ADDS comment lines.
    # Counted as "invented", those failed every enriched template (measured: 15 of 15 in the model benchmark) for
    # a change no service reads. So the same two checks are also reported over ACTIVE lines only — a line that is
    # not a comment — and `ok_semantic` is the conjunction a configuration can be judged by. `ok` keeps the strict
    # meaning for a template that should reproduce the shipped bytes.
    def active(line: str) -> bool:
        stripped = line.strip()
        return bool(stripped) and not stripped.startswith(("#", ";", "//"))

    result["invented_active_lines"] = sum(1 for line in invented if active(line))
    # Whitespace-collapsed, like the "reflowed" tier above: the enrich stage re-indents active lines (BackupPC's
    # `AuthType Basic` came back indented inside its block), which changes no setting of a whitespace-insensitive
    # file. Templates are the freeform route; YAML/JSON files take the codec route, where indentation would matter.
    shipped_active = {collapse(line) for line in shipped.split("\n") if active(line)}
    result["default_render_diff_active"] = [line for line in result["default_render_diff"]
                                            if active(line) and collapse(line) not in shipped_active]

    # "Is it still that file", judged on the file's SETTINGS: enrich rewrites the shipped comments into its own
    # documentation (GConf2: 10 of 27 lines survive, all settings among them).
    shipped_settings = "\n".join(line for line in shipped.split("\n") if active(line))
    result["keeps_the_settings"], _ = keeps_the_file(shipped_settings, body)

    substituted = (result.get("values_expected", 0) == 0
                   or result.get("values_reaching_output", 0) >= max(1, result["values_expected"] // 2))
    result["substitutes"] = substituted
    result["ok"] = bool(result["renders"] and result["keeps_the_file"]
                        and not result["undeclared"] and substituted
                        and not result["invented_lines"]
                        and result["live_placeholder_lines"] > 0
                        and not result["default_render_diff"])
    result["ok_semantic"] = bool(result["renders"] and result["keeps_the_settings"]
                                 and not result["undeclared"] and substituted
                                 and not result["invented_active_lines"]
                                 and result["live_placeholder_lines"] > 0
                                 and not result["default_render_diff_active"])
    return result


def same_file(rendered: str, shipped: str) -> bool:
    """Do two texts carry the same lines (trailing whitespace and blank lines ignored)? The twin test: a
    template rendered with its defaults that equals another distribution's shipped file IS that file too."""
    def norm(text: str) -> list[str]:
        return [ln.rstrip() for ln in text.split("\n") if ln.strip()]
    return norm(rendered) == norm(shipped)


def ensure_final_newline(tdir: Path) -> bool:
    """Give the template a final newline when what it renders would end without one; True when it changed.

    The agent keeps the template's last character exactly (agent 0.57.75, Ansible's semantics), so a template
    without a trailing LF writes a config file without one — measured 2026-10-10: 5246 of 5754 templates, and
    nftables refused /etc/sysconfig/nftables.conf ("syntax error, unexpected junk" on its last comment line).
    Decided on the RENDERED text: a template ending in `{% endif %}` after a line that already ends in LF renders
    a final LF and is left alone (appending one would add a blank line)."""
    f = tdir / "template.j2"
    if not f.is_file():
        return False
    body = f.read_text(errors="replace")
    if not body or body.endswith("\n"):
        return False
    rendered = render_with_defaults(tdir)
    if rendered is not None and (rendered == "" or rendered.endswith("\n")):
        return False
    f.write_text(body + "\n")
    return True
