"""A schema field's default — including an object whose default lives in its `properties`.

One function for every caller that needs "the value this field has when the operator sets nothing": the wizard seed
(the role's default parameters), the package e2e (the defaults it renders with), the template invariants. Three
private copies had drifted: none derived an object's default from its properties, so fastnetmon's `main` (ban_time,
graphite_* …) and munin-node's `main` reached the template as nothing and `{{ main.ban_time }}` failed to render —
in the e2e pod AND through the wizard on a real host.
"""

from __future__ import annotations

from typing import Any


def default_of(spec: Any) -> Any:
    """The field's own `default`; for an object without one, a dict of its properties' defaults (recursively);
    None when there is nothing to say."""
    if not isinstance(spec, dict):
        return None
    if spec.get("default") is not None:
        return spec["default"]
    props = spec.get("properties")
    if spec.get("type") == "object" and isinstance(props, dict):
        derived = {k: d for k, d in ((k, default_of(v)) for k, v in props.items()) if d is not None}
        return derived or None
    return None


def schema_defaults(schema: dict) -> dict:
    """{field: default} for every field that has one (null defaults are left out — see template_invariants)."""
    return {k: d for k, d in ((k, default_of(v)) for k, v in (schema or {}).items()) if d is not None}


# No leading zero: "0644" is a file mode, and as a number it would render as 644.
_NUMERIC = __import__("re").compile(r"^-?(0|[1-9]\d*)(\.\d+)?$")


def _as_number(v: Any, integer: bool) -> Any:
    if isinstance(v, str) and _NUMERIC.match(v.strip()):
        s = v.strip()
        return int(s) if integer or "." not in s else float(s)
    return v


def normalize_types(schema: dict) -> int:
    """Make a field's default and enum values agree with its declared type, IN PLACE; returns how many fields moved.

    A number/integer field whose values are numeric strings ("2", enum ["0".."4"]) gets numbers; one whose values
    include a word ("auto") is not a number field at all and becomes a string field. The model writes values as
    text; the wizard validates against the type — measured 2026-10-10: 352 fields in 77 templates, and the
    mtpolicyd role refused at preview with "role parameter 'log_level' must be number". Nested properties too."""
    moved = 0
    for spec in (schema or {}).values():
        if not isinstance(spec, dict):
            continue
        if isinstance(spec.get("properties"), dict):
            moved += normalize_types(spec["properties"])
        if spec.get("type") in ("object", "list", "array") and spec.get("default") is not None:
            moved += _fix_container_default(spec)
            if spec.get("type") not in ("number", "integer", "bool", "boolean"):
                continue
        retyped = False
        if spec.get("type") in ("bool", "boolean"):
            # A bool field whose values are the config's own tokens ("1"/"0", "yes"/"no") is not a bool field: the
            # template writes the value literally, so turning "1" into true would write "True" into the file
            # (stubby: round_robin_upstreams: 1). It becomes a number field (0/1) or a string field instead.
            values = ([spec["default"]] if "default" in spec else []) + list(spec.get("enum") or [])
            scalars = [v for v in values if v is not None and not isinstance(v, (bool, dict, list))]
            if not scalars:
                continue
            spec["type"] = "number" if all(_NUMERIC.match(str(v).strip()) for v in scalars) else "string"
            retyped = True
            if spec["type"] == "string":
                if isinstance(spec.get("default"), (int, float)) and not isinstance(spec.get("default"), bool):
                    spec["default"] = str(spec["default"])
                if spec.get("enum"):
                    spec["enum"] = list(dict.fromkeys(v if isinstance(v, str) else str(v).lower()
                                                      if isinstance(v, bool) else str(v) for v in spec["enum"]))
                moved += 1
                continue
        if spec.get("type") not in ("number", "integer"):
            continue
        values = ([spec["default"]] if "default" in spec else []) + list(spec.get("enum") or [])
        texts = [v for v in values if isinstance(v, str)]
        if not texts:
            moved += int(retyped)
            continue
        if all(_NUMERIC.match(v.strip()) for v in texts):
            integer = spec["type"] == "integer"
            if "default" in spec:
                spec["default"] = _as_number(spec["default"], integer)
            if spec.get("enum"):
                spec["enum"] = list(dict.fromkeys(_as_number(v, integer) for v in spec["enum"]))
        else:
            spec["type"] = "string"
            if "default" in spec and spec["default"] is not None and not isinstance(spec["default"], str):
                spec["default"] = str(spec["default"])
            if spec.get("enum"):
                spec["enum"] = list(dict.fromkeys(str(v) for v in spec["enum"]))
            for bound in ("minimum", "maximum"):
                spec.pop(bound, None)
        moved += 1
    return moved


def _fix_container_default(spec: dict) -> int:
    """An object/list field whose default is not an object/list (measured: 102 fields — munin-node's `tls` object
    defaulted to "disabled", so the wizard sent None and the agent failed on `tls.enabled`). A JSON string is parsed;
    [] ↔ {} swap to the declared kind; with sub-fields the bad default goes (the derived one applies); otherwise
    the TYPE was wrong and follows the value. Returns 1 when it changed something."""
    want = dict if spec["type"] == "object" else list
    d = spec["default"]
    if isinstance(d, want):
        return 0
    if isinstance(d, str) and d.strip()[:1] in "{[":
        try:
            parsed = __import__("json").loads(d)
        except ValueError:
            parsed = None
        if isinstance(parsed, want):
            spec["default"] = parsed
            return 1
    if want is dict and d == []:
        spec["default"] = {}
        return 1
    if want is list and d == {}:
        spec["default"] = []
        return 1
    if spec.get("properties") or spec.get("items"):
        spec.pop("default")
        return 1
    spec["type"] = ("bool" if isinstance(d, bool) else "number" if isinstance(d, (int, float)) else "string")
    return 1
