"""Escape a config file's OWN braces so the template engine stops reading them as its own.

    python3 escape_template_literals.py <template.j2> [--write]

Exim's configuration language uses `${...}` string expansions, and some of them nest:

    server_condition = ${if saslauthd{{$2}{$3}{smtp}} {1}}

That `{{` is exim syntax, but gonja (and Jinja) read it as an expression opener and then fail on `$2` —
"strconv.ParseInt: parsing \"$2\": invalid syntax". The generated exim4-redhat template parametrized the file
faithfully, kept 884 of its 887 lines, and could not be PARSED at all. keeps_the_file did not catch it because
it asks whether the file survived, not whether the result is a valid template; the render test caught it.

WHAT THIS DOES: everything that is not a real placeholder gets escaped. A placeholder is `{{ name }}` (with
optional filters) or a `{% ... %}` control block — the only constructs the parametrizing prompt produces. Every
other `{{`, `}}`, `{%` or `{#` is the FILE's own text and becomes a literal via `{{ '{{' }}`, which renders back
to exactly the original characters.

The check that matters is downstream and already exists: after escaping, `go test -run
TestConfigTemplatesRenderWithSample/<name>` must parse and render the template. An escape that does not achieve
that is not a fix.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

#: A real placeholder: {{ name }}, {{ name.attr }}, {{ name | default(3) }} — what the generator emits.
PLACEHOLDER = re.compile(r"\{\{\s*[A-Za-z_][\w.\[\]'\"-]*\s*(\|[^{}]*)?\}\}")
#: A control block: {% if x %}, {% for a in b %}, {% endfor %}.
CONTROL = re.compile(r"\{%[^{}]*%\}")

#: Sequences the engine claims. Everything outside a placeholder or control block that looks like one of these
#: belongs to the configuration file and has to be handed back verbatim.
LITERAL = {"{{": "{{ '{{' }}", "}}": "{{ '}}' }}", "{%": "{{ '{%' }}", "{#": "{{ '{#' }}"}
CLAIMED = re.compile(r"\{\{|\}\}|\{%|\{#")


#: `{{ name; }}` — the config file's statement terminator swallowed INTO the placeholder. Measured across all
#: 5461 templates: exactly one has it, bind9-redhat, 15 times, from this generation run. Jinja2 rejects it
#: outright ("expected token 'end of print statement', got ';'"); gonja tolerates it, which is worse — the
#: production renderer accepting a construct the canonical dialect refuses is a bet, not a guarantee.
STRAY_TERMINATOR = re.compile(r"(\{\{[^{}]*?)\s*;\s*(\}\})")


def drop_stray_terminators(template: str) -> tuple[str, int]:
    """Move a swallowed `;` out of the placeholder. The file's own terminator is already outside it."""
    fixed, count = STRAY_TERMINATOR.subn(r"\1 \2", template)
    return fixed, count


#: An already-escaped literal, as produced by this very function.
ESCAPED = re.compile(r"\{\{\s*'([^']*)'\s*\}\}")


def unescape(template: str) -> str:
    """Undo escaping, repeatedly, so escaping can be applied again without nesting.

    NOT IDEMPOTENT WAS A REAL BUG, and an independent judge found its output in exim4-redhat:

        ${if inlist {$received_port}{587:465} {:}{*}{{{ '{{' }} '{{ '}}' }}' {{ '}}' }}

    `{{ '{{' }}` contains `{{`, and the placeholder pattern below only recognises `{{ name }}` — so a second
    pass treated the escape's own braces as the FILE's and escaped them again. Running the repair chain twice
    therefore corrupted what the first run had fixed. Unescaping first makes the whole step idempotent.
    """
    previous = None
    while previous != template:
        previous = template
        template = ESCAPED.sub(lambda m: m.group(1), template)
    return template


def escape(template: str) -> tuple[str, int]:
    """Return (escaped template, how many literals were escaped). Idempotent: see unescape()."""
    template = unescape(template)
    keep: list[tuple[int, int]] = []
    for pattern in (PLACEHOLDER, CONTROL):
        keep.extend((m.start(), m.end()) for m in pattern.finditer(template))
    keep.sort()

    def inside(index: int) -> bool:
        return any(start <= index < end for start, end in keep)

    out, last, count = [], 0, 0
    for match in CLAIMED.finditer(template):
        if inside(match.start()):
            continue
        out.append(template[last:match.start()])
        out.append(LITERAL[match.group(0)])
        last = match.end()
        count += 1
    out.append(template[last:])
    return "".join(out), count


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("template")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    path = Path(args.template)
    original = path.read_text()
    # ORDER MATTERS, and getting it wrong damaged a template: escaping runs on what is already well-formed.
    # `{{ bind_directory; }}` is not a placeholder by the pattern below (the ';' is not a name character), so
    # escaping FIRST turned all 15 of bind9-redhat's placeholders into literal text — the template still
    # rendered, still kept every line, and would have written the string "{{ bind_directory; }}" into
    # named.conf. Both of my invariants passed it. Terminators out first, then escape what is left.
    escaped, stray = drop_stray_terminators(original)
    escaped, count = escape(escaped)
    print("{}: {} literal brace sequence(s) escaped, {} stray terminator(s) moved out".format(
        path.name, count, stray))
    count += stray
    if count and not args.write:
        for line in escaped.splitlines():
            if "'{{'" in line or "'}}'" in line:
                print("   {}".format(line[:120]))
                break
    if args.write and count:
        path.write_text(escaped)
        print("wrote {}".format(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
