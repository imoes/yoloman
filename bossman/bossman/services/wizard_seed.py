"""Block 2 — seed one "installation wizard" runbook per catalog package that has
a config template. Each runbook is a three(+)-step procedure — install packages →
render the config from the template → (validate) → enable & restart the service —
with a TYPED `parameters` block (the wizard's input mask) derived from the
template schema (types/defaults/descriptions), enriched with enum values +
authoritative defaults from config_directives.json where the directive name
matches, plus hidden `_packages/_dest/_service` runtime variables.

Idempotent: the generated doc carries a `meta.source_hash`; a package is
re-seeded only when its inputs changed. Callable from a CLI script or app startup.
"""

from __future__ import annotations

import asyncio
import hashlib
import time
import json
import re
import logging
from pathlib import Path
from typing import Any
from uuid import UUID

import yaml
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.services.schema_defaults import default_of
from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Runbook
from bossman.services import ansible_playbook

WIZARD_FOLDER = "wizards"


def _configs_root(settings: Settings) -> Path:
    return Path(settings.config_templates_dir).parent


def _playbooks_dir(settings: Settings) -> Path:
    return _configs_root(settings) / "wizard_playbooks"


def _infer_type(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "object"
    return "string"


def _enum_meta(spec: dict[str, Any]) -> dict[str, Any]:
    """The two enum annotations a dropdown needs beyond the values themselves — carried from a schema field
    (or a config directive) into the wizard's parameter mask, the same way /config-fields carries them.

    `enum_labels` says what each opaque value MEANS (a log_level of 0..3); `enum_open` says the values are
    suggestions, not the whole legal range, so the form keeps a free input with a datalist. Dropping either
    here made the wizard show bare numbers and close a list the catalog had marked open. Both spellings of
    the label map are accepted (`value_labels` is the directive catalog's name for it)."""
    out: dict[str, Any] = {}
    labels = spec.get("enum_labels") or spec.get("value_labels")
    if isinstance(labels, dict) and labels:
        out["enum_labels"] = {str(k): str(v) for k, v in labels.items()}
    if spec.get("enum_open"):
        out["enum_open"] = True
    return out


#: An enum lists SCALAR values; it cannot describe a list or an object. Measured: the enum enricher matched the
#: hostapd directive `macaddr_acl` (0/1/2) to the schema's `macaddr_acl` — the list of MAC addresses — so the
#: wizard offered a 0/1/2 dropdown for a MAC list whose default [] was in no option.
_COMPOUND = frozenset({"list", "object", "array"})


def _enum_member(value: Any, enum: list[Any]) -> Any:
    """`value` as the member of `enum` it denotes, or `value` unchanged when it denotes none.

    YAML 1.1 reads an unquoted `On`/`Off`/`yes`/`no` as a boolean, so a playbook var `keepalive: On` arrived as
    `True` next to the enum ["On", "Off"] — a default outside its own value set, and a dropdown with no valid
    initial selection. A bool maps to the member that spells it; anything else matches by string form
    (3 vs "3")."""
    if value in enum:
        return value
    if isinstance(value, bool):
        spellings = {True: ("on", "yes", "true", "1"), False: ("off", "no", "false", "0")}[value]
        for member in enum:
            if str(member).lower() in spellings:
                return member
        return value
    for member in enum:
        if str(member) == str(value):
            return member
    return value


def _params_from_play_vars(play_vars: dict[str, Any], schema_params: dict[str, Any],
                           template_body: str | None = None) -> dict[str, Any]:
    """The wizard input mask: the TEMPLATE's fields, with the playbook's `vars:` as defaults.

    One source of truth for "what can be configured": the template's schema. A play var for a schema field sets
    that field's default (a playbook may be opinionated); `_`-prefixed vars stay hidden runtime values. A play var
    the template references but the schema lacks stays (a schema gap — dropping it would lose a working setting).
    A play var the template never reads is NOT offered: measured 2026-10-10, 94 such fields in 8 roles (samba's
    `workgroup`, fail2ban's `bantime`, …) appeared in the form and changed nothing — while schema fields missing
    from the vars block were not offered at all. Without a template body (legacy callers) every var is kept."""
    params: dict[str, Any] = {k: dict(v) for k, v in schema_params.items() if isinstance(v, dict)}
    for name, value in play_vars.items():
        sp = schema_params.get(name)
        if not name.startswith("_") and sp is None and template_body is not None \
                and not re.search(r"\b" + re.escape(name) + r"\b", template_body):
            continue
        p: dict[str, Any] = {"type": _infer_type(value), "default": value}
        if name.startswith("_"):
            p["hidden"] = True
        if isinstance(sp, dict):
            p = {**sp, "default": value}
            if sp.get("enum") and _infer_type(value) not in _COMPOUND:
                p["enum"] = sp["enum"]
                p.update(_enum_meta(sp))
                p["default"] = _enum_member(value, sp["enum"])
                p["type"] = _infer_type(p["default"])
            else:
                p["type"] = _infer_type(value) if sp.get("type") is None else sp["type"]
        params[name] = p
    return params


def _fam(entry: dict) -> dict:
    fams = entry.get("families", {})
    return fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})


# The native template render (`ansible.builtin.template` / `template`) can't be
# used as-is: the .j2 lives in Bossman's config-template catalog, not on the
# agent. Re-map such steps to the Bossman `config_template` module (the working
# render path), with vars wired to the runbook parameters so the wizard form
# actually flows into the rendered config.
_TEMPLATE_MODULES = {"template", "ansible.builtin.template"}


def _remap_template_step(step: dict[str, Any], template: str | None = None) -> dict[str, Any]:
    """`template` is the catalog's template for the role. When given it WINS over the playbook's `src`:
    the catalog is the one place that says which template renders the role's file (curated, aliased, gated),
    and a generated playbook naming another one rendered the wrong file — measured: install-chrony rendered
    `chrony` (/etc/default/chrony, one DAEMON_OPTS line) over /etc/chrony/chrony.conf, install-memcached
    rendered `memcached` (ENABLE_MEMCACHED=yes) over /etc/memcached.conf."""
    args = step.get("args") or {}
    src = str(args.get("src", ""))
    if step.get("module") not in _TEMPLATE_MODULES or not src.endswith(".j2"):
        return step
    if template and src[:-3] != template:
        logger.warning("wizard seed: %s renders %r, the catalog's template is %r — using the catalog's",
                       step.get("name", ""), src[:-3], template)
        src = template + ".j2"
    # No per-param `vars` overlay: the engine already merges ALL runbook variables
    # (form values + parameter defaults) into the render values, so every param —
    # including dotted ones like `devices.sysfs_scan` that can't be expressed as a
    # Jinja reference — flows to the template as-is.
    out: dict[str, Any] = {
        "name": step.get("name", ""), "module": "config_template",
        "args": {"template": src[:-3], "dest": args.get("dest") or "{{ _dest }}"},
    }
    for key in ("when", "loop", "register", "ignore_errors", "become", "tags", "notify"):
        if key in step and step[key] not in (None, [], {}, False):
            out[key] = step[key]
    return out


_PACKAGE_MODULES = {"package", "apt", "dnf", "yum", "ansible.builtin.package", "ansible.builtin.apt",
                    "ansible.builtin.dnf", "ansible.builtin.yum"}
_SERVICE_MODULES = {"service", "systemd", "ansible.builtin.service", "ansible.builtin.systemd",
                    "ansible.builtin.systemd_service"}


def _bind_family_runtime(step: dict[str, Any]) -> dict[str, Any]:
    """An install-<role> playbook's package, service and destination bound to the HOST FAMILY's catalog values.

    The hand-written playbooks named literals — `docker-ce`, `bind9`, `redis-server`, /etc/bind/named.conf — so on
    RedHat they installed Debian names, and a catalog correction (docker-ce → docker.io) never reached the wizard:
    measured in the Bossman-path e2e, install-docker-daemon still ran `apt-get install docker-ce` a day after the
    catalog said docker.io. The catalog's branch for the host's family is the one source of package, unit and
    file (`_packages`/`_service`/`_dest`, from catalog_runtime); a family-specific module becomes `package`."""
    module = step.get("module")
    args = dict(step.get("args") or {})
    if module in _PACKAGE_MODULES and args.get("state", "present") in ("present", "latest", "installed"):
        args = {k: v for k, v in args.items() if k in ("state",)}
        args["name"] = "{{ _packages }}"
        return {**step, "module": "package", "args": args}
    if module in _SERVICE_MODULES and args.get("state") in ("started", "restarted", "reloaded"):
        # A unit the package installs MASKED (Debian's hostapd) refuses every start; running it is what the role
        # asks for, so the mask is lifted first (agent ≥ 0.57.77; older agents ignore the key).
        args.setdefault("masked", False)
        if args.get("enabled") is True:
            # Boot enablement follows the catalog (`families.<f>.enable`): dnscache's SysV script has no runlevels and
            # `systemctl enable` fails, though the daemon runs — the role then starts it without enabling it.
            args["enabled"] = "{{ _enable }}"
    if module in _SERVICE_MODULES and isinstance(args.get("name"), str) and "{{" not in args["name"]:
        args["name"] = "{{ _service }}"
        out = {**step, "module": "service", "args": args}
        out["when"] = "_service" if not step.get("when") else f"({step['when']}) and _service"
        return out
    if module in _SERVICE_MODULES:
        out = {**step, "args": args}
        if args.get("name") == "{{ _service }}" and "_service" not in str(step.get("when") or ""):
            # A playbook that already names `{{ _service }}` had no guard: a role with no unit for the family
            # (adminer: a PHP page) ran `systemctl restart .service` and failed (Bossman-path e2e).
            out["when"] = "_service" if not step.get("when") else f"({step['when']}) and _service"
        return out
    if module == "config_template" and isinstance(args.get("dest"), str) and "{{" not in args["dest"]:
        args["dest"] = "{{ _dest }}"
        return {**step, "args": args}
    return step


def _with_files(steps: list[dict], params: dict[str, Any], entry: dict) -> list[dict]:
    """A role's SECOND files — site values that are whole files (G2): ctdb's node list, the exporter's .my.cnf.

    The catalog declares them per family: `families.<f>.files: [{path, field, mode, owner, group, description,
    secret}]`. Each becomes a form field (multi-line text; masked when `secret`) tagged with the families that have
    it, and a `copy` step right after the configuration is rendered that writes it only when the field is set and
    the host is of such a family. Before this, ctdb never started ("unmet condition ConditionFileNotEmpty=
    /etc/ctdb/nodes") and mysqld-exporter found "no configuration" — the value lived in a file no form could reach."""
    decl: dict[str, dict] = {}
    for fam, branch in (entry.get("families") or {}).items():
        for f in (branch or {}).get("files") or [] if isinstance(branch, dict) else []:
            if not isinstance(f, dict) or not f.get("path") or not f.get("field"):
                continue
            d = decl.setdefault(f["field"], {"spec": f, "families": {}})
            d["families"][fam] = f["path"]
    if not decl:
        return steps
    at = next((i + 1 for i, s in enumerate(steps) if s.get("module") == "config_template"), len(steps))
    new_steps = []
    for field, d in sorted(decl.items()):
        f = d["spec"]
        params.setdefault(field, {
            "type": "string", "widget": "text", "secret": bool(f.get("secret")), "default": None,
            "families": sorted(d["families"]),
            "description": (f.get("description") or field) + " — written to " + ", ".join(
                f"{p} ({fam})" for fam, p in sorted(d["families"].items()))})
        for fam, path in sorted(d["families"].items()):
            args = {"dest": path, "content": "{{ %s }}" % field}
            for k in ("mode", "owner", "group"):
                if f.get(k):
                    args[k] = f[k]
            new_steps.append({"name": f"Write {path}", "module": "copy", "args": args,
                              "when": f"{field} is defined and {field} and _family == '{fam}'"})
    return [*steps[:at], *new_steps, *steps[at:]]


def _with_init(steps: list[dict], params: dict[str, Any], entry: dict) -> list[dict]:
    """Insert the family's one-time initialisation right after the install step, when the catalog names one
    (`families.<f>.init`, e.g. RedHat postgresql: `postgresql-setup --initdb` — Debian's postinst does that itself,
    EL's does not, so the unit refused to start on every fresh host). The command must be idempotent itself
    (`test -f … || …`): the step runs on every apply, and detection skips commands."""
    params.setdefault("_init", {"type": "string", "hidden": True, "default": _fam(entry).get("init", "")})
    params.setdefault("_enable", {"type": "bool", "hidden": True, "default": _fam(entry).get("enable", True) is not False})
    if any(s.get("run") == "{{ _init }}" for s in steps):
        return steps
    at = next((i + 1 for i, s in enumerate(steps) if s.get("module") == "package"), 0)
    return [*steps[:at], {"name": f"Initialise {entry.get('label', '')}".strip(), "run": "{{ _init }}",
                          "when": "_init"}, *steps[at:]]


def _doc_from_playbook(pkg: str, text: str, entry: dict, schema_params: dict[str, Any],
                       template_body: str | None = None) -> dict:
    """Parse a generated Ansible playbook into the canonical runbook doc: steps +
    handlers from the playbook, the input mask from its play vars. The native
    template step is re-mapped to `config_template`, and the hidden runtime vars
    (_packages/_dest/_service) are guaranteed from the catalog so `{{ _packages }}`
    style references always resolve."""
    rb = ansible_playbook.parse_playbook(text)
    raw = yaml.safe_load(text)
    play = raw[0] if isinstance(raw, list) else raw
    play_vars = (play or {}).get("vars", {}) if isinstance(play, dict) else {}
    params = _params_from_play_vars(play_vars, schema_params, template_body)
    # Hidden runtime vars from the catalog (Debian family) — fill any the
    # playbook referenced but didn't define, so StrictUndefined never trips.
    fam = _fam(entry)
    params.setdefault("_packages", {"type": "list", "hidden": True, "default": fam.get("packages", [])})
    params.setdefault("_dest", {"type": "string", "hidden": True, "default": fam.get("config_path", "")})
    params.setdefault("_service", {"type": "string", "hidden": True, "default": fam.get("service", "")})
    steps = [_bind_family_runtime(_remap_template_step(s.to_dict(), entry.get("template"))) for s in rb.steps]
    steps = _with_files(_with_init(steps, params, entry), params, entry)
    doc: dict[str, Any] = {
        "kind": "runbook", "name": f"install-{pkg}", "targets": None,
        "parameters": params, "steps": steps,
    }
    if rb.handlers:
        doc["handlers"] = [h.to_dict() for h in rb.handlers]
    return doc


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def _norm_type(t: Any) -> str:
    t = str(t or "string").lower()
    return "bool" if t == "boolean" else t


def _build_parameters(schema: dict, directives: dict, entry: dict) -> dict[str, Any]:
    """schema {var: {type,default,description,items?}} → typed parameter specs,
    enriched from config_directives (enum values + authoritative default) where a
    directive of the same name exists."""
    params: dict[str, Any] = {}
    for var, spec in schema.items():
        if not isinstance(spec, dict):
            continue
        p: dict[str, Any] = {"type": _norm_type(spec.get("type"))}
        if spec.get("description"):
            p["description"] = spec["description"]
        if default_of(spec) is not None:
            p["default"] = default_of(spec)   # an object's default may live in its properties (fastnetmon `main`)
        if isinstance(spec.get("properties"), dict):
            p["properties"] = spec["properties"]
        if isinstance(spec.get("items"), dict):
            p["items"] = spec["items"]
        # A value only the site has (a tunnel address, a realm, a passphrase): the preview refuses without it and names
        # the field (role_deployments._validate_parameters), instead of deploying a daemon that cannot start.
        if spec.get("required") is True:
            p["required"] = True
        # Schema-level enum is authoritative (enrich_schema_enums already merged
        # ADMX + curated choices into the schema) — carry it into the mask so the
        # wizard renders a dropdown.
        if spec.get("enum") and p["type"] not in _COMPOUND:
            p["enum"] = spec["enum"]
            p.update(_enum_meta(spec))
            if "default" in p:
                p["default"] = _enum_member(p["default"], spec["enum"])
        # Enrich from the directive catalog (best-effort exact-name match) for
        # any field the schema didn't already mark.
        d = directives.get(var)
        if isinstance(d, dict):
            if not p.get("enum") and d.get("type") == "enum" and d.get("values"):
                p["enum"] = d["values"]
                p.update(_enum_meta(d))
            if p.get("default") is None and d.get("default") not in (None, ""):
                p["default"] = d["default"]
            if not p.get("description") and d.get("description"):
                p["description"] = d["description"]
        params[var] = p
    # Hidden runtime variables — Debian defaults (the wizard overrides per family).
    fams = entry.get("families", {})
    fam = fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})
    params["_packages"] = {"type": "list", "hidden": True, "default": fam.get("packages", [])}
    params["_dest"] = {"type": "string", "hidden": True, "default": fam.get("config_path", "")}
    params["_service"] = {"type": "string", "hidden": True, "default": fam.get("service", "")}
    return params


def _build_doc(pkg: str, entry: dict, params: dict, template: str) -> dict:
    """The canonical runbook doc: install → render → (validate) → service."""
    # No per-field `vars`: the config_template step hands the template every run variable already (nt_engine
    # values = variables + vars). An identity map `{v: "{{ v }}"}` added nothing but a failure — a field without a
    # default and without a supplied value made the SUBSTITUTION raise before the template's own `| default(...)`
    # could apply (14 catalog roles in the Bossman-path e2e: `unresolved variable reference in '{{ ssl_port }}'`).
    steps: list[dict] = [
        {"name": f"Install {entry.get('label', pkg)}", "module": "package",
         "args": {"name": "{{ _packages }}", "state": "present"}},
        {"name": "Render configuration", "module": "config_template",
         "args": {"template": template, "dest": "{{ _dest }}"}},
    ]
    if entry.get("validate_cmd"):
        # Runs after the config is written; a non-zero exit aborts the runbook
        # (default ignore_errors=false) BEFORE the service is restarted, so a bad
        # config can't take the service down.
        steps.append({"name": "Validate configuration", "run": entry["validate_cmd"]})
    # Only when the family's branch names a unit: 36 catalog roles have none for some family, and the step then
    # ran `systemctl restart .service` and failed the role (Bossman-path e2e baseline: verdict "no-unit").
    steps.append({"name": f"Enable and restart {entry.get('label', pkg)}", "module": "service",
                  "args": {"name": "{{ _service }}", "state": "restarted", "enabled": "{{ _enable }}", "masked": False},
                  "when": "_service"})
    return {"kind": "runbook", "name": f"install-{pkg}", "targets": None,
            "parameters": params, "steps": _with_files(_with_init(steps, params, entry), params, entry)}


def _hash(doc: dict) -> str:
    payload = {k: v for k, v in doc.items() if k != "meta"}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def wizard_doc(pkg: str, entry: dict, tdir: Path, pbdir: Path,
               directives: dict) -> tuple[dict, str] | None:
    """The install-<pkg> runbook doc for one catalog entry, and what it was built from ("playbook" or
    "wizard_seed"); None when the entry has no template, or neither a playbook nor a schema. Pure — no DB —
    so the whole catalog's masks can be checked by a test."""
    template = entry.get("template")
    if not template:
        return None
    # Schema drives the input mask for the fallback build and enriches the
    # playbook's params; it's optional when a generated playbook exists (the
    # playbook carries its own vars).
    schema = _load_json(tdir / template / "schema.json")
    schema_params = _build_parameters(schema, directives.get(_dir_key(entry), {}), entry) if schema else {}
    _add_family_fields(schema_params, entry, template, tdir, directives)
    pbfile = pbdir / f"install-{pkg}.yml"
    # Prefer the generated Ansible playbook (the adopted source of truth).
    if pbfile.is_file():
        try:
            tfile = tdir / template / "template.j2"
            body = tfile.read_text(errors="replace") if tfile.is_file() else None
            doc = _doc_from_playbook(pkg, pbfile.read_text(), entry, schema_params, body)
            # The playbook's vars are the role's (Debian) file; the family templates' own fields join them.
            for var, spec in schema_params.items():
                if isinstance(spec, dict) and spec.get("families"):
                    doc.setdefault("parameters", {}).setdefault(var, spec)
            for spec in (doc.get("parameters") or {}).values():
                if isinstance(spec, dict):
                    _coerce_default(spec)
            return doc, "playbook"
        except Exception:  # noqa: BLE001 — a bad playbook falls back, never crashes seeding
            logger.warning("wizard seed: playbook %s unusable, falling back to build", pbfile.name, exc_info=True)
    if not schema:
        return None   # no usable playbook and no schema → nothing to seed
    for spec in schema_params.values():
        if isinstance(spec, dict):
            _coerce_default(spec)
    return _build_doc(pkg, entry, schema_params, template), "wizard_seed"


def family_templates(tdir: Path) -> dict[tuple[str, str], str]:
    """{(family, target path): template name} for every template whose meta.json records a family — the template a
    role renders on hosts of that family (nt_engine `@<family>:<path>`). Cached per directory for a minute."""
    hit = _FAMILY_TEMPLATES.get(str(tdir))
    if hit and time.monotonic() - hit[0] < 60:
        return hit[1]
    out: dict[tuple[str, str], str] = {}
    for meta in tdir.glob("*/meta.json"):
        m = _load_json(meta)
        if m.get("family") and isinstance(m.get("target_path"), str):
            out[(m["family"], m["target_path"])] = meta.parent.name
    _FAMILY_TEMPLATES[str(tdir)] = (time.monotonic(), out)
    return out


_FAMILY_TEMPLATES: dict[str, tuple[float, dict]] = {}


def _add_family_fields(params: dict[str, Any], entry: dict, template: str, tdir: Path, directives: dict) -> None:
    """Add the fields only a FAMILY template has, marked with that family.

    The form used to be the role's (Debian) template only. On AlmaLinux the role renders the family's own template,
    and a field of the role that file lacks is greyed out — measured, 9 of 26 such roles shared NO field with their
    EL template (clamav, freeradius, exim4, bind9, …) and squid lacked 205 of 207: the role was not configurable
    there at all. The form is now the union: the role's fields, plus each family template's own, each tagged
    `families: [...]`, so the wizard on a host offers exactly the fields of the file that host will get and greys
    out the rest with the reason. A field both files have (the same directive name) stays one field."""
    fams = (entry.get("families") or {})
    ftpl = family_templates(tdir)
    for fam, branch in fams.items():
        path = (branch or {}).get("config_path") if isinstance(branch, dict) else None
        own = ftpl.get((fam, path)) if path else None
        if not own or own == template:
            continue
        fschema = _load_json(tdir / own / "schema.json")
        fparams = _build_parameters(fschema, directives.get(path, {}), entry) if fschema else {}
        for var, spec in fparams.items():
            if var.startswith("_") or not isinstance(spec, dict) or spec.get("hidden"):
                continue
            if var in params:
                continue
            spec = dict(spec)
            # Not required for the role as a whole: one deployment may target hosts of both families, and a Debian
            # host must not be asked for a value only the EL file has.
            spec.pop("required", None)
            spec["families"] = sorted(set(spec.get("families") or []) | {fam})
            spec["description"] = (spec.get("description") or var) + f" (only in the {fam} file, {path})"
            params[var] = spec
        # a field already added for another family that this family's template also has
        for var in fparams:
            if isinstance(params.get(var), dict) and params[var].get("families") and fam not in params[var]["families"]:
                params[var]["families"] = sorted(set(params[var]["families"]) | {fam})


_TRUE, _FALSE = ("on", "yes", "true", "1", "enabled"), ("off", "no", "false", "0", "disabled")


def _coerce_default(spec: dict[str, Any]) -> None:
    """Make a parameter's default a value its own validation accepts, or drop it and say why.

    role_deployments._validate_parameters checks the merged defaults against type and enum, so a default that fails
    them refuses the role at preview with nothing the operator did wrong — measured in the Bossman-path e2e:
    docker (`plugins` a string, typed object), fapolicyd (`permissive` "1", typed bool), gammu (`database_driver`
    "sqlite", enum ends "sqlite3"), ipmiseld (`driver-type` not in its enum). A value that converts is converted; one
    that does not is removed and the reason kept in `default_dropped`, so the field is simply empty, not wrong."""
    if "default" not in spec or spec["default"] is None:
        return
    value, kind = spec["default"], spec.get("type")
    if isinstance(spec.get("enum"), list) and spec["enum"] and _enum_member(value, spec["enum"]) in spec["enum"]:
        spec["default"] = _enum_member(value, spec["enum"])   # the enum decides first: True → "On", 3 → "3"
        return
    if kind == "bool" and not isinstance(value, bool):
        low = str(value).strip().lower()
        value = True if low in _TRUE else False if low in _FALSE else None
    elif kind in ("number", "int") and (isinstance(value, bool) or not isinstance(value, (int, float))):
        try:
            value = int(str(value)) if kind == "int" or str(value).strip().lstrip("-").isdigit() else float(str(value))
        except ValueError:
            value = None
    elif kind == "object" and not isinstance(value, dict):
        value = None
    elif kind == "list" and not isinstance(value, list):
        value = [value] if isinstance(value, (str, int, float)) and str(value) != "" else None
    elif kind == "string" and not isinstance(value, str):
        value = str(value).lower() if isinstance(value, bool) else str(value)
    if value is not None and isinstance(spec.get("enum"), list) and spec["enum"]:
        value = _enum_member(value, spec["enum"])
        if value not in spec["enum"]:
            value = None
    if value is None:
        spec["default_dropped"] = f"shipped default {spec['default']!r} is not a valid {kind or 'value'}" + (
            f" of {spec['enum']}" if spec.get("enum") else "")
        del spec["default"]
    else:
        spec["default"] = value


async def seed_wizard_runbooks(session: AsyncSession, settings: Settings) -> int:
    """Upsert install-<pkg> runbooks for every catalog package with a template,
    and prune seed-managed wizards whose package left the catalog. Returns the
    number created / updated / pruned."""
    root = _configs_root(settings)
    catalog = _load_json(root / "package_catalog.json")
    directives = _load_json(root / "config_directives.json")
    tdir = Path(settings.config_templates_dir)
    pbdir = _playbooks_dir(settings)
    tenant = UUID(str(DEFAULT_TENANT_ID))
    changed = 0
    # Every wizard we still expect to exist (catalog packages with a template) —
    # anything else in the folder is an orphan from a since-removed package.
    live_names = {f"install-{p}" for p, e in catalog.items() if e.get("template")}
    for pkg, entry in catalog.items():
        built = wizard_doc(pkg, entry, tdir, pbdir, directives)
        if built is None:
            continue
        doc, source = built
        doc["meta"] = {"source_hash": _hash(doc), "generated": source}
        name = doc["name"]
        existing = await session.scalar(
            select(Runbook).where(Runbook.tenant_id == tenant, Runbook.name == name)
        )
        if existing is None:
            session.add(Runbook(tenant_id=tenant, name=name, kind="runbook",
                                folder=WIZARD_FOLDER, doc=doc, created_by="wizard-seed"))
            changed += 1
        elif (existing.doc or {}).get("meta", {}).get("source_hash") != doc["meta"]["source_hash"]:
            existing.doc = doc
            existing.folder = WIZARD_FOLDER
            changed += 1
    # Prune orphaned seed wizards (package removed from the catalog). Guarded on a
    # non-empty catalog so a transient/failed catalog load never wipes the folder;
    # only touches rows we created (created_by="wizard-seed"), never user runbooks.
    if live_names:
        orphans = (await session.scalars(
            select(Runbook).where(
                Runbook.tenant_id == tenant, Runbook.folder == WIZARD_FOLDER,
                Runbook.created_by == "wizard-seed", Runbook.name.notin_(live_names),
            )
        )).all()
        for r in orphans:
            await session.delete(r)
            changed += 1
        if orphans:
            logger.info("wizard seed: pruned %d orphaned wizard(s)", len(orphans))
    if changed:
        await session.commit()
    return changed


def _dir_key(entry: dict) -> str:
    """config_directives.json is keyed by config-file basename — derive it from
    the debian config_path (e.g. /etc/ssh/sshd_config → sshd_config)."""
    fams = entry.get("families", {})
    fam = fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})
    path = fam.get("config_path", "")
    return Path(path).name if path else ""


logger = logging.getLogger(__name__)


async def wizard_reseed_loop(session_factory, settings: Settings, stop_event: asyncio.Event,
                             interval: float = 900.0) -> None:
    """Periodically re-seed wizard runbooks so packages whose template the batch
    just generated become installable roles without a bossman restart.
    Idempotent hash-upsert; best-effort."""
    while not stop_event.is_set():
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
            return  # stop requested
        except asyncio.TimeoutError:
            pass
        try:
            async with session_factory() as session:
                n = await seed_wizard_runbooks(session, settings)
                # Keep the desired-state artifact library in lockstep with the
                # generated install runbooks. Local import avoids a module
                # cycle at import time.
                from bossman.services.role_catalog import seed_catalog_artifacts

                n += await seed_catalog_artifacts(session, settings)
                if n:
                    logger.info("wizard reseed: %d runbook(s) added/updated", n)
        except Exception:  # noqa: BLE001 — never let reseed crash the loop
            logger.warning("wizard reseed failed", exc_info=True)
