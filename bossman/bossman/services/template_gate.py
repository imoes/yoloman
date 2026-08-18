"""Does a config template actually configure the file its schema describes?

ONE definition, in the package rather than in scripts/, because BOTH sides need it and only one
direction of import is possible: the server cannot import scripts/, while scripts/ already imports the
package (classify_roles_features pulls services.chat_client). It used to live in
scripts/build_package_catalog.py, which is why the template INDEX shipped without it — and measured, 437
of 3488 codec-sourced index entries pointed at a template this rule refuses. Every one of those offered
"Edit via template" on a file whose template is a shell script or an unparameterised text.

Why it matters that this is a gate and not a hint: Configure's write path is template_render — WHOLE
FILE, no merge, straight to the config path. A template that does not configure that file does not look
odd, it REPLACES a live config.

THE RULE IS ASYMMETRIC ON PURPOSE. What says "no" is broader than what says "yes", because a
wrongly-withheld editor costs a click and a wrongly-offered one costs the host. Three refusals:

  1. the template is an executable — SysV header or a shell/perl/python interpreter line. Caught 12
     roles the field test missed, among them spamassassin, whose script has a one-field schema and that
     field occurs in the script text. Deliberately NOT any shebang: /etc/nftables.conf genuinely starts
     with `#!/usr/sbin/nft -f` and that IS its own format.
  2. the template is a ufw application profile. Caught openssh-server, whose profile was aimed at
     /etc/ssh/sshd_config — five lines of firewall profile over the SSH daemon config locks everyone out.
  3. the template PLACES none of its schema's fields (see `placed`).

And one narrow "yes": rule 3 passing counts as True only above two schema fields. Below that it is a
coincidence — `port` appears in a ufw profile, an init script, almost any file — so the answer is None:
leave the editor alone without CLAIMING the template is right. 19 of 89 catalog roles have a schema that
small and all 19 "passed" before this.

None also covers "cannot be judged" (no template dir, unreadable schema). Callers must keep None and
False apart: an unknown must not silently withdraw a working editor, but it must not be presented as
verified either.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

#: A shell/init/perl/python interpreter line — an executable, not a config.
_SCRIPT_SHEBANG = re.compile(r"^#!\s*/(usr/)?s?bin/(env\s+)?(sh|bash|dash|ksh|zsh|perl|python\d?)\b")

#: A ufw APPLICATION PROFILE — `[Name]` followed by title=/description=/ports=. These live in
#: /etc/ufw/applications.d/ and are never a service's own configuration.
_UFW_PROFILE = re.compile(r"^\[[^\]]+\]\s*\n\s*title\s*=", re.M)


def placed(field: str, body: str) -> bool:
    """Is this field actually PLACED by the template — inside {{ }} or {% %} — not merely mentioned?

    The distinction became load-bearing when the templates were regenerated as self-documenting: every
    setting is now preceded by a comment naming it, so "the name appears in the text" is satisfied by
    the field's own DOCUMENTATION and says nothing about whether its value is ever written. The
    convention the project adopted quietly disarmed the old test.

    Measured: three catalog roles passed the mention test while placing not one field — squid (15
    fields; the body is the shipped example squid.conf, "WELCOME TO SQUID 6.13", no placeholders at
    all), opendkim (5 fields; the body says of itself "not used by the opendkim systemd service"), and
    lighttpd (6 fields; it has placeholders, but for names absent from its schema). Pressing Apply on
    such a form writes a fixed text over the live config.
    """
    return re.search(r"\{\{[^}]*\b" + re.escape(field) + r"\b|\{%[^%]*\b" + re.escape(field) + r"\b",
                     body) is not None


def directive_key(name: str) -> str:
    """A config directive's name, reduced to what two catalogs can be compared on.

    Case and the dash/underscore split are cosmetic (`host-name` vs `host_name`). The LAST DOTTED SEGMENT
    is the substantive part: a template schema for an ini file qualifies its fields by section, so
    `server.host_name` is the very same directive as the catalog's `host-name` under `[server]`, and the
    settings editor flattens nested values with exactly that dot.

    THIS COST ME A ROLLBACK. Comparing whole strings, the repaired avahi-daemon template — parametrized
    from the real 1807-byte shipped file — shared "nothing" with the 41 known directives of
    /etc/avahi/avahi-daemon.conf and was reverted as a failed repair. Comparing last segments, 3 of its 4
    fields match. The test was rejecting section prefixes, not wrong content.
    """
    return name.lower().replace("-", "_").replace(" ", "_").split(".")[-1]


def describes_file(fields: set[str], directive_names) -> bool | None:
    """Do these template fields describe a file with THESE directives? None when there is nothing to compare.

    The bar is ONE field in common, matching the gate's own generosity: a template may legitimately name
    things differently, and a strict threshold would withdraw working editors. Zero overlap against a known
    directive list is the unambiguous case — and it is what separates "a template for this file" from "a
    template for some other file that happens to be named like this package".
    """
    if not fields or not directive_names:
        return None
    return bool({directive_key(f) for f in fields} & {directive_key(d) for d in directive_names})


def template_configures(templates_dir: str | Path, name: str) -> bool | None:
    """True / False / None for the template directory `name` under `templates_dir`."""
    tdir = Path(templates_dir) / name
    body_file, schema_file = tdir / "template.j2", tdir / "schema.json"
    if not body_file.is_file() or not schema_file.is_file():
        return None

    head = body_file.read_text(errors="replace")[:400]
    if _UFW_PROFILE.search(head) and "ports" in head:
        return False
    if "BEGIN INIT INFO" in head or _SCRIPT_SHEBANG.match(head):
        return False

    try:
        schema = json.loads(schema_file.read_text())
    except (OSError, ValueError):
        return None
    # Three shapes in the wild: {"parameters": …}, {"properties": …}, and — what the generated template
    # schemas actually use — a bare mapping of field name -> spec.
    fields = schema.get("parameters") or schema.get("properties") or schema
    if not isinstance(fields, dict):
        return None
    fields = {k: v for k, v in fields.items() if isinstance(v, dict)}
    if not fields:
        # READABLE AND EMPTY IS A NO, not an unknown. A template with zero fields cannot express any
        # input at all, so Apply renders a CONSTANT file over whatever the host has — the same damage as
        # the ufw profile aimed at sshd_config, minus the clue. Measured: 169 templates have an empty
        # schema and 84 of them were reachable, i.e. offering an editor with nothing to edit.
        #
        # The unreadable/missing cases above still return None: "we cannot judge this" and "there is
        # nothing here to configure" are different answers, and only the second one is a verdict.
        return False

    body = body_file.read_text(errors="replace")
    if not any(placed(key, body) for key in fields):
        return False
    return True if len(fields) > 2 else None
