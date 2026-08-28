"""Unified per-path field spec — the `describe()` of a config file as ONE
endpoint, so the UI stops juggling two catalogs (raw config-directives vs
config-templates) and two field-spec shapes.

For a given config path it answers a single question — "what typed fields does
this file have, and how is it written?" — resolving the two irreducible write
paths (see docs/config-model-consolidation.md):

  codec != none  ->  write:"codec"     fields from codec ⊕ directive catalog
  codec == none  ->  write:"template"  fields from the template's schema.json (+ .j2)

Read-only: it composes the offline-generated catalogs (config_codecs.json,
config_directives.json, config_templates/). Host-independent — the authoring
view (OU/group policy). Per-host observed merging stays in ConfigResource.schema.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.config_templates import _load_template
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services import config_schema
from bossman.services.capabilities import family_of
from bossman.services.template_index import build_template_index

router = APIRouter()


def _load_json(path_str: str | Path) -> dict:
    try:
        data = json.loads(Path(path_str).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


#: ONE SPELLING PER TYPE, translated here beside values->enum. The generated template schemas use
#: JSON-Schema words (`boolean`, `integer`, `array`) while the renderer and the directive catalog use this
#: project's (`bool`, `int`, `list`) — measured, 427 fields say `boolean` and 62 say `integer`, and the form
#: renderer knows neither, so every one of them renders as a TEXT BOX where a checkbox or a number field
#: belongs. A union like `bool|string` resolves to the permissive side: a text box accepts everything a
#: checkbox would, the reverse is not true.
_TYPE_SPELLINGS = {
    "boolean": "bool", "integer": "int", "array": "list", "number": "number",
    "bool|string": "string", "string|bool": "string", "flat_map": "object",
    None: "string", "": "string",
}


def _spell_types(fields: dict) -> dict:
    """Apply the one spelling per type to a TEMPLATE schema's fields.

    The template branch returns the schema's properties as they are — they already have the FieldDef shape —
    so the only thing needing translation is the type word, and it needs it here too: the 427 `boolean` fields
    live in template schemas, not in the directive catalog.
    """
    for spec in fields.values():
        if isinstance(spec, dict) and spec.get("type") in _TYPE_SPELLINGS:
            spec["type"] = _TYPE_SPELLINGS[spec["type"]]
    return fields


def _field_from_directive(spec: dict) -> dict:
    """Directive spec {type, values?, default?, min?, max?, description?} ->
    unified FieldDef {type, enum?, default?, description?, min?, max?}."""
    values = spec.get("values") or spec.get("enum")
    out: dict[str, Any] = {"type": "enum" if isinstance(values, list) and values
                           else _TYPE_SPELLINGS.get(spec.get("type"), spec.get("type", "string"))}
    if isinstance(values, list) and values:
        out["enum"] = [str(v) for v in values]
        # value -> what it MEANS, for a set whose values are opaque on their own. A `log_level` of 0..3 is a
        # menu of nothing without them: the numbers are what gets written to the file, and the words live in
        # the description, where a dropdown cannot show them.
        # BOTH SPELLINGS, translated HERE. The directive catalog calls the set `values` and its labels
        # `value_labels`; a template schema calls them `enum` and `enum_labels`. This normaliser already
        # translates values->enum and int->number, so the label key belongs in the same one place rather
        # than as a second name the two catalogs have to agree on.
        labels = spec.get("value_labels") or spec.get("enum_labels")
        if isinstance(labels, dict) and labels:
            out["enum_labels"] = {str(k): str(v) for k, v in labels.items()}
        # AN OPEN SET: the values are suggestions, not the whole legal range, because the field's own
        # description introduces them with "e.g." or "common values". 497 fields measured. The editor renders
        # an input with a datalist rather than a select, so the suggestions stay and a value the catalog never
        # learned can still be typed — a closed menu there would remove local0-local7 from a syslog facility.
        if spec.get("enum_open"):
            out["enum_open"] = True
    if spec.get("default") not in (None, ""):
        out["default"] = spec["default"]
    if isinstance(spec.get("description"), str) and spec["description"]:
        out["description"] = spec["description"]
    for k in ("min", "max"):
        if isinstance(spec.get(k), int):
            out[k] = spec[k]
    return out


def _provenance(record: dict, probe: dict | None = None) -> dict:
    """WHERE THIS ANSWER COMES FROM — every state needs a reachable cause (docs/logik-audit.md).

    The registry has just learned to distinguish measured answers from asked ones: `source: "probe"` means the
    codec was decided by round-tripping the file the package really ships, `"extension"` that the file name
    settles it, `"embedded-import"` that it was carried over from the agent's own registry, and NO source at
    all that a model was once shown a package description. Of 11573 records, 7098 are measured and 4216 are
    not — and the UI has been presenting all of them identically.

    That matters because the write path acts on this: an unverified `keyvalue` claim means the editor offers a
    per-key merge on a grammar nobody ever checked. Saying so is cheap; leaving it unsaid is how a catalog
    lies quietly.
    """
    source = record.get("source") or "unverified"
    measured = source in ("probe", "extension")
    note = record.get("notes") or ("" if measured else
                                   "this grammar has never been checked against a real file")
    # NOT-MEASURED HAS TWO SHAPES and they call for different work. "Nobody has looked yet" is a task; "the
    # file was probed and could not decide" is a dead end for this method. Measured: all 81 unmeasured claims
    # whose real file exists in the corpus came back no-evidence — the shipped /etc/security/limits.conf,
    # /etc/sysctl.conf and 79 others contain nothing but comments, so the bytes cannot say whether the
    # grammar fits. Naming that stops the same probe being run again forever, and points at the right tool:
    # the COMMENTED settings are the evidence for such a file.
    if not measured and isinstance(probe, dict) and probe.get("verdict") == "no-evidence":
        note = ("probed against the file the package ships: it contains no active setting ({} lines), so the "
                "bytes cannot confirm or refute this grammar".format(probe.get("active_lines", 0)))
    return {
        "source": source,
        "measured": measured,
        "confidence": record.get("confidence") or "unknown",
        "note": note,
        # The probe's own answer, when there is one — so a screen can distinguish "not yet tried" from
        # "tried, and the file had nothing to say".
        "probe": probe if isinstance(probe, dict) else None,
    }


def _fields_the_template_places(schema: dict, body: str) -> tuple[dict, list[str]]:
    """Split a template's schema into the fields its body can actually write, and the rest.

    The test is presence of the field NAME as a word anywhere in the template — deliberately generous, so a
    field used inside a conditional, a loop or a filter expression still counts. What it catches is the field
    that occurs nowhere at all, which no rendering path can reach.

    Not the same question as the gate's. template_configures asks "does this template configure ANYTHING"
    and one placed field is enough for a yes — a documented limit, with a test named after it. This asks it
    per field, which is what a form needs.
    """
    if not isinstance(schema, dict):
        return {}, []
    placed, missing = {}, []
    for name, spec in schema.items():
        if isinstance(name, str) and name and not re.search(r"\b" + re.escape(name) + r"\b", body or ""):
            missing.append(name)
        else:
            placed[name] = spec
    return placed, sorted(missing)


def _template_for_path(path: str, settings: Settings, family: str = "") -> str | None:
    """Resolve a freeform file to the template that renders THAT file — through the index, not by name.

    THIS USED TO BE A SECOND RESOLVER, and it gave the wrong answer the moment a second distribution appeared.
    It matched on the basename (minus .conf/.cfg) and then on a codec `packages` name, so:

      /etc/named.conf            -> the DEBIAN bind9 template, whose meta.json says it renders
                                    /etc/bind/named.conf. Rendering that over EL's named.conf writes another
                                    distribution's file.
      /etc/httpd/conf/httpd.conf -> nothing at all, although apache2-redhat renders exactly it — because no
                                    template directory happens to be called "httpd.conf".

    The path->template index exists precisely to answer this by TARGET PATH (each template's meta.json
    target_path), which is why 2786 templates were unreachable while it was a name guess. Two resolvers for one
    question is one name for two things, and the second one was the wrong answer.
    """
    # Same three inputs the index endpoint passes (config_templates.py:89) — there is no separate catalog
    # setting; the catalog sits beside the templates directory.
    index = build_template_index(
        Path(settings.config_templates_dir).parent / "package_catalog.json",
        settings.config_codecs_path,
        settings.config_templates_dir,
        family,
        settings.config_path_verdicts_path,
    )
    entry = (index.get("paths") or {}).get(path)
    return entry.get("template") if isinstance(entry, dict) else None


@router.get("/api/v1/config-fields")
async def config_fields(
    path: str,
    family: str = "",
    agent_id: UUID | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """One field spec for `path`: {path, write, format?, separator?, template?,
    fields:{key:FieldDef}, available}."""
    # THE SERVER DERIVES THE FAMILY, not the caller. `agent_id` says "for this host" and family_of(facts)
    # answers what family that is — the same function the package wizard and the capability matcher use. A
    # caller could pass `family` directly (the OU/authoring view has no host), but reimplementing the
    # os_release sniffing in TypeScript would put one rule in two languages, which is how the two halves of
    # this system started disagreeing about codecs in the first place.
    if agent_id is not None and not family:
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            family = family_of(agent.facts or {})

    codecs = _load_json(settings.config_codecs_path)
    codec = codecs.get(path) or {}
    # A PER-FAMILY MEASUREMENT WINS, because the two distributions ship different bytes for the same path.
    # Measured: of 1605 paths present in both corpora, 33 disagree — /etc/logrotate.conf and
    # /etc/lighttpd/lighttpd.conf are flat on Debian and nested on EL, /etc/dnsmasq.conf the other way round.
    # One record per path is then wrong for one family, so the registry keeps both under `by_family` and the
    # top level holds the conservative answer for a caller that does not know which host it is asking about.
    # This one does: `family` comes from the host's own facts a few lines above.
    branch = (codec.get("by_family") or {}).get(family) if family else None
    if isinstance(branch, dict) and branch.get("codec"):
        codec = {**codec, **branch}
    codec_kind = codec.get("codec")
    # The file's OWN statement about itself, carried on every branch below. It is not a write state and not
    # a refusal: /etc/munin/munin.conf is perfectly parsable and perfectly editable, and munin still says
    # "Please don't edit this example config file. Create and edit /etc/munin/munin-conf.d/…". An editor
    # that stays silent about that lets an operator apply a value which the next generator run drops, and
    # the returning drift then has no visible cause.
    generated = _load_json(settings.config_generated_path).get(path)
    advisory = {"machine_written": generated} if isinstance(generated, dict) else {}
    # DOES THE FILE EXIST AT ALL. The codec registry answers how a file is written and says nothing about
    # whether there is one: 2248 of its entries have a path that is exactly their package's own name, and
    # extracting the real .deb finds /etc/bind is a directory (the file is /etc/named.conf), /etc/aide is a
    # directory, /etc/ttygif nothing at all. Carried on EVERY branch, because a measured grammar for a
    # nonexistent path is still a measured grammar — and still an editor over nothing.
    seen = _load_json(settings.config_path_verdicts_path).get(path)
    # THE FAMILY'S OWN MEASUREMENT WINS, as it does for the codec above and in the template index: of 83 paths
    # measured on both distributions 20 disagree, so the conservative top level is wrong for one of them. This
    # request knows its family (from the host's facts), so it must not settle for the host-independent answer.
    if isinstance(seen, dict):
        own = (seen.get("by_family") or {}).get(family) if family else None
        if isinstance(own, dict) and own.get("verdict"):
            # `family` must be overwritten, not inherited: the branch carries no family of its own, and the
            # top level's is the aggregate's ("redhat" for a path only EL ships). Leaving it would report
            # Debian's verdict under EL's label — an answer inconsistent with itself. The differential against
            # the agent caught exactly that on /etc/radvd.conf and /etc/kbd.
            seen = {**seen, **own, "family": family, "measured_here": True}
    # A verdict that one of the two guards disarms is not reported as a warning at all: the file exists, and
    # "the package ships nothing here" is then an expected, meaningless fact. /etc/hostname belongs to no
    # package on any distribution; /etc/named.conf is Debian-absent and EL-present.
    owner = _load_json(Path(settings.config_path_verdicts_path).parent
                       / "config_unowned_paths.json").get(path)
    # The corpus guard yields to a direct measurement — it was only ever a proxy for "we do not know this
    # host's distribution", and `measured_here` says we do.
    # A verdict measured in a package that does not ship this path is about the wrong subject: it answers
    # "does distrobox contain /etc/os-release" (no) while the file belongs to base-files and is on every host.
    wrong_subject = (isinstance(seen, dict) and isinstance(seen.get("shipped_by"), list)
                     and seen["shipped_by"] and seen.get("package") not in seen["shipped_by"])
    disarmed = wrong_subject or (isinstance(seen, dict) and seen.get("exists_elsewhere")
                and not seen.get("measured_here")) or (
        isinstance(owner, dict) and not owner.get("container_artifact"))
    if isinstance(seen, dict) and seen.get("verdict") != "file" and not disarmed:
        # An `absent` path that a maintainer script names is created at install time and is a real file on a
        # real host — legitimately missing from the archive, so it is reported without the warning.
        installed_later = seen.get("verdict") == "absent" and seen.get("postinst_mentions")
        advisory["path_verdict"] = {
            "verdict": seen.get("verdict"), "package": seen.get("package"),
            "family": seen.get("family"), "created_at_install": bool(installed_later),
            "reason": ("this path was measured in package {} on {} as {}"
                       .format(seen.get("package"), seen.get("family") or "debian", seen.get("verdict"))
                       + ("; a maintainer script creates it at install time"
                          if installed_later else
                          " — no file is shipped there, so there is nothing to edit")),
        }

    if codec_kind and codec_kind != "none":
        directives = config_schema.load_catalog(settings)
        dirs = config_schema.catalog_for_path(path, directives)
        fields = {k: _field_from_directive(v) for k, v in dirs.items() if isinstance(v, dict)}
        return {
            "path": path, "write": "codec",
            "format": codec_kind, "separator": codec.get("separator", ""),
            "provenance": _provenance(codec, _load_json(settings.codec_probe_verdicts_path).get(path)),
            "fields": fields, "available": True, **advisory,
        }

    # Freeform (codec == none, or unknown): the whole-file template is the spec.
    tdir = Path(settings.config_templates_dir)
    # `family` (debian|redhat|…) lets a host ask for the template that renders ITS file: /etc/caddy/Caddyfile
    # exists on both with different content. Omitted, the answer is the host-independent authoring view.
    tpl = _template_for_path(path, settings, family)
    if tpl:
        t = _load_template(tdir / tpl) or {}
        meta = _load_json(tdir / tpl / "meta.json")
        schema = t.get("schema") or {}
        placed, withheld = _fields_the_template_places(schema, t.get("template", ""))
        # The same gap from the other side: variables the BODY needs that no field declares, so the operator
        # cannot supply them and the render writes them empty. Measured with jinja2's parser and recorded by
        # scripts/find_unsettable_variables.py — 182 templates, 523 variables. The 24 whose body needs more
        # than their form offers are refused by the gate and never reach this branch; the rest say how many.
        unsettable = _load_json(Path(settings.config_templates_dir).parent / "template_unsettable.json") \
            or _load_json(Path(settings.config_templates_dir).parent / "configs" / "template_unsettable.json")
        needs = unsettable.get(tpl) if isinstance(unsettable, dict) else None
        # WHAT THE RENDERER CANNOT EXECUTE, named before Apply rather than after. Jinja passes Python objects
        # through, so a generated template may call `x.items()`, `x.get('k')` or `x.append(v)`; gonja — the
        # engine that writes the file — implements none of them. Only five templates fail on it today because
        # the calls sit in branches the SAMPLE never enters, which is exactly why the render ratchet cannot
        # see it: measured, 125 of the templates still offered carry such a call. Whenever a host's real
        # values take that branch, the whole-file write fails.
        gaps = _load_json(Path(settings.config_templates_dir).parent / "template_renderer_gaps.json") \
            or _load_json(Path(settings.config_templates_dir).parent / "configs"
                          / "template_renderer_gaps.json")
        calls = gaps.get(tpl) if isinstance(gaps, dict) else None
        return {
            "path": path, "write": "template",
            "template": t.get("template", ""),
            # The NAME and the SAMPLE ride along so the template editor can resolve everything through this
            # one endpoint. It used to fetch GET /config-templates/<name> itself and read the raw schema,
            # which meant the withholding below had no effect where it matters — and would have put the same
            # rule in TypeScript to fix it. One rule, one place.
            "template_name": tpl,
            "sample": t.get("sample") or {},
            # A template's provenance is its own: witness "deb"/"rpm" means the target path was read out of
            # the package, "derived" that it was inferred from a name.
            "provenance": {"source": meta.get("source") or "unknown",
                           "measured": meta.get("witness") in ("deb", "rpm"),
                           "confidence": "high" if meta.get("witness") in ("deb", "rpm") else "unknown",
                           "note": "renders {} (witness: {})".format(
                               meta.get("target_path") or path, meta.get("witness") or "none")},
            "fields": _spell_types(placed), "available": True,
            # NOTHING VANISHES SILENTLY. A whole-file render can only honour a value it actually places, and
            # measured across the library 2561 of 54026 offered fields (341 templates) appear NOWHERE in
            # their template body — acme.sh offers 69 and places 5. Those were rendered as inputs, filled in
            # by an operator, and dropped by the write with nothing said. They are withheld now, and the
            # count is reported rather than the fields quietly disappearing from the form.
            "withheld": {"count": len(withheld), "fields": withheld,
                         "reason": "the template never places these fields, so a value set here could not "
                                   "reach the file"} if withheld else None,
            "renderer_gaps": {"calls": calls,
                              "reason": "this template calls a Python method the renderer does not "
                                        "implement; a value that reaches that line will fail the write"}
            if isinstance(calls, list) and calls else None,
            "unsettable": {"count": len(needs), "variables": needs,
                           "reason": "the template reads these values and no field offers them, so they "
                                     "render empty"} if isinstance(needs, list) and needs else None,
            **advisory,
        }
    # NO WAY TO EDIT BY FIELD — and the two reasons are different, so they get different names instead of
    # both being called a codec write with zero fields.
    #
    # `"codec" if codec_kind else "unknown"` used to answer write="codec", format="none", fields={} for a file
    # whose record says "no grammar fits": the string "none" is truthy. So the record said one thing and the
    # API said the opposite about the same file — and with the RedHat corpus measured, thousands of files now
    # carry exactly that record, /etc/httpd/conf/httpd.conf among them.
    #
    #   freeform  MEASURED: no codec fits this file, and no template exists for it yet. It is editable as raw
    #             text, and generating a template is the work that would make it editable by field.
    #   unknown   nothing has ever been recorded about this path. Not the same claim at all.
    return {
        "path": path,
        "write": "freeform" if codec_kind == "none" else "unknown",
        "reason": ("no codec fits this file (measured) and no template renders it yet — raw text only"
                   if codec_kind == "none" else
                   "this path has no codec record and no template — nothing is known about it yet"),
        "format": None, "separator": "",
        "fields": {}, "available": False, **advisory,
    }


@router.get("/api/v1/config-generated")
async def config_generated(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """{path: {line, quote, marker}} — every config file whose own header says it is machine-written.

    A MAP rather than a per-path question, because the callers render whole lists of files: the host
    Configuration tab shows every discovered config file at once, and asking /config-fields 40 times to
    annotate them would trade one small read for forty. 84 files across the measured corpus, a few kB.

    The quote is passed through verbatim and no verdict is attached. "DO NOT EDIT THIS FILE" and "Please
    don't edit this EXAMPLE config file. Create and edit /etc/munin/munin-conf.d/…" call for very different
    actions, and the file is the one that knows which — see scripts/find_generated_files.py for how the
    sentence is proven to be about the file itself rather than about its reports, its keys or one block.
    """
    data = _load_json(settings.config_generated_path)
    return {"files": data if isinstance(data, dict) else {}, "count": len(data or {})}
