"""The mechanical repairs every parametrized template gets — in the order docs/batch-pipelines.md gives them.

They used to run only in scripts/rh_make_templates.py, i.e. for 14 RedHat role templates. The main generator
(qualify_packages._parametrize_config) wrote ~4000 templates without them, and the package e2e measured the result:
rendered with its own defaults, 606 of 709 tested templates did not reproduce the file the package ships — commented
settings the model had switched on (dovecot's `protocols`, `listen`), literal braces read as Jinja, mangled lines.

  1. drop stray terminators, escape the file's own brace sequences      (escape_template_literals)
     put back newlines an earlier pass ate after a one-line if-block       (split_merged_blocks)
  2. restore lines the JSON envelope mangled to the shipped bytes          (repair_template_text)
  3. `#Key {{ v }}` → `{% if v %}Key …{% else %}#shipped{% endif %}`       (activate_commented_settings.activate)
  4. put back the comment where the MODEL enabled a disabled setting       (…deactivate_model_activations)
  5. correct else-branches that do not reproduce the shipped line          (…fix_else_branches)
  6. take every default from the shipped file; one trailing-slash form     (align_template_defaults)
     … and an undeclared variable's INLINE default from the shipped line    (align_inline_defaults)

Each step is idempotent and abstains where it cannot identify a line uniquely. No model is involved.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from bossman.tools.activate_commented_settings import (activate, deactivate_model_activations, fix_else_branches,
                                                        guard_empty_activations, activate_expressions)
from bossman.tools.align_template_defaults import align, unify_trailing_slash
from bossman.tools.escape_template_literals import drop_stray_terminators, escape
from bossman.tools.repair_template_text import repair as restore_shipped_text


_ONE_LINE_BLOCK = re.compile(r"^(?P<block>\{%-?\s*if\b.*?\{%-?\s*else\s*-?%\}(?P<orig>[^{\n]*)\{%-?\s*endif\s*-?%\})"
                             r"(?P<rest>[^\n]+)$")


def split_merged_blocks(body: str, shipped: str) -> tuple[str, int]:
    """Put back the newline an earlier pass ate after a one-line `{% if %}…{% else %}<shipped>{% endif %}` block.

    activate_expressions joined its output assuming every line ending in `{% endif %}` carried its newline inside
    (its own multi-line blocks do), so a one-line block from another pass was glued to the next line:
    `…{% else %};parallel_jobs = 1{% endif %}log_level = {{ log_level }}`. Split only when BOTH halves are shipped:
    the else branch is a whole line of the shipped file and the rest begins like one (up to its first expression).
    """
    shipped_lines = {ln.rstrip() for ln in shipped.split("\n")}
    out, n = [], 0
    for line in body.split("\n"):
        m = _ONE_LINE_BLOCK.match(line)
        if m and m.group("orig").rstrip() in shipped_lines:
            head = m.group("rest").split("{{", 1)[0].split("{%", 1)[0]
            if head.strip() and any(sl.startswith(head) for sl in shipped_lines if sl):
                out.append(m.group("block"))
                out.append(m.group("rest"))
                n += 1
                continue
        out.append(line)
    return "\n".join(out), n


_INLINE_DEFAULT = re.compile(r"^(?P<pre>[^{\n]*?)\{\{\s*(?P<var>[A-Za-z_]\w*)\s*\|\s*default\(\s*(?P<lit>'[^']*'|\"[^\"]*\"|-?[\d.]+|true|false|True|False)\s*\)\s*\}\}(?P<post>[^{\n]*)$")


def align_inline_defaults(body: str, schema: dict, shipped: str) -> tuple[str, int]:
    """Take an INLINE default (`{{ v | default(30) }}`) from the shipped line, where the schema gives the field none.

    align_template_defaults works on schema fields; a variable the model used with an inline default and never
    declared kept the model's guess — arpalert rendered `dump inter = 30` where the package ships `dump inter = 5`.
    Only for a line whose literal text before and after the expression matches exactly ONE shipped line; the
    shipped value replaces the literal (numbers stay numbers, everything else becomes a quoted string)."""
    shipped_lines = [ln for ln in shipped.split("\n")]
    out, n = [], 0
    for line in body.split("\n"):
        m = _INLINE_DEFAULT.match(line)
        spec = schema.get(m.group("var")) if m else None
        lit_value = m.group("lit").strip("'\"") if m else None
        # A schema default is align's business — unless it is the SAME model guess as the inline literal: align matches
        # `key = value` lines and missed a key with a space (arpalert's `dump inter`), so both stayed 30 where the
        # package ships 5. Then both take the shipped value.
        same_guess = isinstance(spec, dict) and spec.get("default") is not None and str(spec["default"]) == lit_value
        if m and (same_guess or not (isinstance(spec, dict) and spec.get("default") is not None)) and m.group("pre").strip():
            rx = re.compile("^" + re.escape(m.group("pre")) + r"(.+?)" + re.escape(m.group("post")) + "$")
            hits = [h.group(1) for h in (rx.match(ln) for ln in shipped_lines) if h]
            lit = m.group("lit").strip("'\"")
            if len(hits) == 1 and hits[0] != lit and "{" not in hits[0]:
                val = hits[0]
                new_lit = val if re.fullmatch(r"-?\d+(\.\d+)?", val) else "'" + val.replace("'", "\\'") + "'"
                line = line[:m.start("lit")] + new_lit + line[m.end("lit"):]
                if same_guess:
                    spec["default"] = (int(val) if re.fullmatch(r"-?\d+", val)
                                       else float(val) if re.fullmatch(r"-?\d+\.\d+", val) else val)
                n += 1
        out.append(line)
    return "\n".join(out), n


def _renders(body: str) -> bool:
    """Does the template parse? (jinja2 here: a parse check, not the agent's render — the caller re-renders.)"""
    import jinja2
    try:
        jinja2.Environment().parse(body)
        return True
    except jinja2.TemplateSyntaxError:
        return False


def repair_template(tdir: Path, shipped: str, write: bool = True) -> dict:
    """Run the chain on the template in `tdir` against the shipped file text; returns what each step changed."""
    body_p, schema_p, sample_p = tdir / "template.j2", tdir / "schema.json", tdir / "sample.json"
    if not body_p.is_file() or not shipped:
        return {"skipped": "no template or no shipped text"}
    body = body_p.read_text()
    try:
        schema = json.loads(schema_p.read_text()) if schema_p.is_file() else {}
        sample = json.loads(sample_p.read_text()) if sample_p.is_file() else {}
    except ValueError:
        return {"skipped": "schema/sample not JSON"}
    report: dict = {}
    # Escaping is for a template that does NOT parse because of the file's own braces. Run on one that renders, it
    # took valid control blocks with nested braces for literals — containerd's
    # `{% set runtimes_list = runtimes | default([{'name': …}]) %}` became text (measured 2026-10-11).
    renders_before = _renders(body)
    body, report["terminators"] = drop_stray_terminators(body)
    if renders_before:
        report["escaped"] = 0
    else:
        body, report["escaped"] = escape(body)
    body, report["unglued"] = split_merged_blocks(body, shipped)
    body, restored, _ = restore_shipped_text(body, shipped)
    report["restored"] = len(restored) if isinstance(restored, list) else restored
    body, report["activated"], _ = activate(body, shipped)
    deactivated_vars: list[str] = []
    body, report["deactivated"] = deactivate_model_activations(body, shipped, deactivated_vars,
                                                               schema if isinstance(schema, dict) else None)
    body, report["empty_guarded"] = guard_empty_activations(body, shipped)
    body, corrected, reverted = fix_else_branches(body, shipped)
    report["else_corrected"], report["else_reverted"] = corrected, reverted
    if isinstance(schema, dict) and schema:
        schema, fixed, _ = align(body, schema, shipped, sample if isinstance(sample, dict) else None)
        report["defaults_aligned"] = len(fixed) if isinstance(fixed, list) else fixed
        body, report["inline_defaults"] = align_inline_defaults(body, schema, shipped)
        body, slash = unify_trailing_slash(body, schema, shipped)
        report["slash"] = len(slash) if isinstance(slash, list) else slash
        # Last, after align: a commented setting with ANY expression (`#DSHELL={{ dshell | default(…) }}`) is a knob
        # that changes nothing — 18 catalog forms were made only of those (2026-10-11). It becomes live when set; its
        # default goes to null so the defaults still render the shipped file (align would otherwise have given it the
        # example's value, and an activated example is a change nobody asked for).
        body, activated, _left = activate_expressions(body, shipped, schema)
        # a setting put back behind its comment is live only when SET: its default must not switch it on
        for var in [*activated, *deactivated_vars]:
            if isinstance(schema.get(var), dict):
                schema[var]["default"] = None
        report["expressions_activated"] = len(activated)
    if write:
        body_p.write_text(body)
        if isinstance(schema, dict) and schema:
            schema_p.write_text(json.dumps(schema, indent=2) + "\n")
    return report
