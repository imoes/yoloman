"""Per-directive schema for a config file — so `ConfigResource.schema()` tells the
truth and the GENERIC resource node renders a real form (docs/resource-protocol.md).

Before this, a config file described itself as three fields
(`path`, `format`, `values:object`), so the generic node rendered the whole file as
one JSON blob — worse than the bespoke Settings editor, which shows one typed row
per directive with enum dropdowns. A config file does not have "a values field";
it has N settings. Saying so is what lets the generic node replace the special
case instead of sitting next to it.

Two correctness rules, both learned from the real data:

1. **Never invert a flat key by splitting on ".".** Codecs return nested maps for
   ini/yaml/toml/json (`{"server": {"use-ipv4": "yes"}}`), so a flat form needs
   dotted labels — but real directive names contain dots and spaces themselves
   (`"wifi.scan rand mac address"`, `"802-1x.auth-timeout"`). `flatten()` therefore
   returns an INDEX carrying each key's exact original segments, and `inflate()`
   looks keys up there. Splitting would corrupt the file.

2. **Types come from the observed value, never from the catalog.** The agent's
   codec renders values with Go's `%v`: posting JSON `true` for a file whose token
   is `yes` writes literally `true`, and `0177` sent as a number becomes `177`/`127`.
   So a catalog `type: bool` on a string value becomes a STRING field with an enum
   of the file's own tokens (yes/no, on/off, …) — a dropdown, not a coercion.

The directive catalog (`configs/config_directives.json`, mined by
scripts/mine_directive_values.py) only ENRICHES: description, allowed values,
documented default.
"""
from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any

# Boolean token families, in the spelling config files actually use. A catalog
# `type: bool` on a string value picks the family containing the observed token,
# so the dropdown offers the file's own vocabulary (mirrors valueOptions() in the
# bespoke editor).
_BOOL_FAMILIES: tuple[tuple[str, str], ...] = (
    ("yes", "no"),
    ("true", "false"),
    ("on", "off"),
    ("enabled", "disabled"),
    ("1", "0"),
)

# ---------------------------------------------------------------- catalog ----

_catalog_cache: dict[tuple[str, float], dict[str, Any]] = {}


def load_catalog(settings: Any) -> dict[str, dict[str, Any]]:
    """The mined directive catalog, cached on (path, mtime) so a request doesn't
    re-parse a 109-file JSON. `{}` when unset/missing/corrupt — the catalog is
    pure enrichment, never a hard dependency."""
    path_str = getattr(settings, "config_directives_path", None) if settings is not None else None
    if not path_str:
        return {}
    path = Path(path_str)
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return {}
    key = (str(path), mtime)
    hit = _catalog_cache.get(key)
    if hit is not None:
        return hit
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    _catalog_cache.clear()          # only ever keep the current mtime
    _catalog_cache[key] = data
    return data


def catalog_for_path(path: str, catalog: Mapping[str, Any]) -> dict[str, Any]:
    """Directives for one config file. The catalog is keyed inconsistently — 96
    basename keys plus 13 full-path keys, which overlap: NetworkManager.conf has 3
    directives under its full path and 101 under its basename. So MERGE the lookup
    chain, letting the more specific key win."""
    if not catalog:
        return {}
    p = (path or "").rstrip()
    base = p.rsplit("/", 1)[-1]
    parent = p.rsplit("/", 1)[0] if "/" in p else ""
    # least → most specific, so later updates override
    candidates = [
        base,
        f"{base}/",
        parent.rsplit("/", 1)[-1] if parent else "",
        f"{parent}/" if parent else "",
        parent,
        p,
    ]
    merged: dict[str, Any] = {}
    for cand in candidates:
        if not cand:
            continue
        entry = catalog.get(cand)
        if isinstance(entry, dict):
            inner = entry.get("directives") if isinstance(entry.get("directives"), dict) else entry
            if isinstance(inner, dict):
                merged.update({k: v for k, v in inner.items() if isinstance(v, dict)})
    return merged


def directive_for(flat_key: str, segments: list[str], directives: Mapping[str, Any]) -> dict[str, Any] | None:
    """Find a directive spec for a field: exact flat key (dotted catalogs, e.g.
    nested yaml) → last path segment (ini catalogs name directives bare: `Storage`,
    not `Journal.Storage`) → case-insensitive last segment."""
    if not directives:
        return None
    for probe in (flat_key, segments[-1] if segments else ""):
        if probe and isinstance(directives.get(probe), dict):
            return directives[probe]
    last = (segments[-1] if segments else flat_key).lower()
    for name, spec in directives.items():
        if name.lower() == last and isinstance(spec, dict):
            return spec
    return None


# --------------------------------------------------------- flatten/inflate ----

def _is_scalar(v: Any) -> bool:
    return isinstance(v, (str, int, float, bool)) or v is None


def _scalar_list(v: Any) -> bool:
    return isinstance(v, list) and all(_is_scalar(e) for e in v)


def flatten(values: Mapping[str, Any] | None) -> tuple[dict[str, Any], dict[str, list[str]]]:
    """Nested codec values → (flat dotted map, index of exact segments).

    The index is the whole point: `index["Journal.Storage"] == ["Journal", "Storage"]`,
    recorded verbatim, so the inverse never has to split a string that may itself
    contain dots. Complex structures (lists of objects) and None are skipped — the
    agent's config module defaults to `manage: merge`, so an omitted key is left
    untouched, never deleted."""
    flat: dict[str, Any] = {}
    index: dict[str, list[str]] = {}

    def walk(node: Mapping[str, Any], prefix: list[str]) -> None:
        for key, val in node.items():
            segs = [*prefix, str(key)]
            if isinstance(val, Mapping):
                walk(val, segs)          # empty dict → contributes no field
                continue
            if not (_is_scalar(val) or _scalar_list(val)) or val is None:
                continue                  # list-of-objects etc. stay out of the form
            label = ".".join(segs)
            if label in index and index[label] != segs:
                # genuine collision, e.g. {"a": {"b.c": 1}, "a.b": {"c": 2}} — keep
                # both, each with its exact path.
                n = 2
                while f"{label} #{n}" in index:
                    n += 1
                label = f"{label} #{n}"
            flat[label] = val
            index[label] = segs

    if isinstance(values, Mapping):
        walk(values, [])
    return flat, index


def inflate(flat: Mapping[str, Any] | None, index: Mapping[str, list[str]] | None,
            observed: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Flat form values → the nested map the codec expects, using `index` for exact
    key paths. Fallbacks for a key the index doesn't know (a NEW directive):
    (a) an already-nested dict whose key exists at the observed top level passes
    through unchanged (back-compat for API/MCP callers sending nested values);
    (b) the longest observed top-level section prefix (`"Journal.NewKey"` →
    ["Journal", "NewKey"]); (c) the whole string as one top-level key — correct for
    keyvalue files, whose names may contain anything."""
    out: dict[str, Any] = {}
    idx = index or {}
    obs = observed or {}
    sections = [k for k, v in obs.items() if isinstance(v, Mapping)]

    for key, val in (flat or {}).items():
        segs = idx.get(key)
        if segs is None:
            if isinstance(val, Mapping) and key in obs:
                out[key] = val               # (a) already nested — leave as-is
                continue
            match = max((s for s in sections if key.startswith(f"{s}.")), key=len, default=None)
            segs = [match, key[len(match) + 1:]] if match else [key]   # (b) / (c)
        node = out
        for seg in segs[:-1]:
            nxt = node.get(seg)
            if not isinstance(nxt, dict):
                nxt = {}
                node[seg] = nxt
            node = nxt
        node[segs[-1]] = val
    return out


def flat_changed(before: Mapping[str, Any] | None,
                 after: Mapping[str, Any] | None) -> dict[str, list[Any]]:
    """Per-directive diff. The agent reports changes per resource, so for an ini
    file `changed` would otherwise be one section blob → {} vs {}; flattening both
    sides yields `Journal.Storage: auto → persistent`."""
    fb, _ = flatten(before)
    fa, _ = flatten(after)
    out: dict[str, list[Any]] = {}
    for key in sorted(set(fb) | set(fa)):
        old, new = fb.get(key), fa.get(key)
        if old != new:
            out[key] = [old, new]
    return out


# ------------------------------------------------------------ derive schema ----

def _lexical_type(value: Any) -> str:
    """The type of what is ACTUALLY in the file. bool before int — Python's bool is
    an int subclass."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "list"
    return "string"


def _bool_family(token: str) -> list[str] | None:
    low = token.strip().lower()
    for family in _BOOL_FAMILIES:
        if low in family:
            return list(family)
    return None


def derive_schema(values: Mapping[str, Any] | None,
                  directives: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """One typed field per directive present in the file, enriched by the catalog.

    `default` is always the observed value, so param-form prefills the real state
    (and, since every field then has a default, opens as one uniform list). Each
    spec also carries `key_path` — the exact segments — so a client can be precise
    without holding the index."""
    flat, index = flatten(values)
    directives = directives or {}
    schema: dict[str, Any] = {}

    for key, val in flat.items():
        segs = index[key]
        spec: dict[str, Any] = {"type": _lexical_type(val), "default": val, "key_path": segs}
        cat = directive_for(key, segs, directives)
        if cat:
            desc = cat.get("description")
            if isinstance(desc, str) and desc:
                spec["description"] = desc
            enum = cat.get("values") or cat.get("enum")
            if isinstance(enum, list) and enum:
                opts = [str(e) for e in enum]
                cur = "" if val is None else str(val)
                # the file may hold a value the catalog didn't document — never hide it
                if cur and cur not in opts:
                    opts = [cur, *opts]
                spec["enum"] = opts
            elif cat.get("type") == "bool" and isinstance(val, str):
                # deliberately NOT type=bool: the file's token (yes/on/…) must survive
                fam = _bool_family(val)
                if fam:
                    spec["enum"] = fam
            cat_default = cat.get("default")
            if cat_default is not None:
                spec["catalog_default"] = cat_default
        schema[key] = spec
    return schema
