# Translated Checkmk check: liebert_pump
# READ-ONLY Starlark module for the yolo-man agent.
# Monitors Liebert pump run-hours (and optional threshold) via SNMP.

# --- module-level constants ---

OID_BASE = ".1.3.6.1.4.1.476.1.42.3.9.20.1"

OID_NAME = OID_BASE + ".10.1.2.1.5298"
OID_VALUE = OID_BASE + ".20.1.2.1.5298"
OID_UNIT = OID_BASE + ".30.1.2.1.5298"
OID_NAME_TH = OID_BASE + ".10.1.2.1.5299"
OID_VALUE_TH = OID_BASE + ".20.1.2.1.5299"
OID_UNIT_TH = OID_BASE + ".30.1.2.1.5299"

LIEBERT_SYSOID_PREFIX = ".1.3.6.1.4.1.476.1.42"

DEFAULT_HOST = "localhost"
DEFAULT_COMMUNITY = "public"
DEFAULT_VERSION = "2c"


def _snmpget(ctx, host, community, version, oid):
    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmpwalk(ctx, host, community, version, oid):
    res = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        out.append({"oid": line[:sp], "value": line[sp + 1:]})
    return out


def _index_after(oid, base):
    prefix = base + "."
    if oid.startswith(prefix):
        return oid[len(prefix):]
    return ""


def _walk_by_index(ctx, host, community, version, oid):
    rows = _snmpwalk(ctx, host, community, version, oid)
    result = {}
    for r in rows:
        idx = _index_after(r["oid"], oid)
        result[idx] = r["value"]
    return result


def _is_liebert(ctx, host, community, version):
    sys_oid = _snmpget(ctx, host, community, version, ".1.3.6.1.2.1.1.2.0")
    if not sys_oid:
        return False
    return sys_oid.startswith(LIEBERT_SYSOID_PREFIX)


def _collect_pump_rows(ctx, host, community, version):
    name_rows = _snmpwalk(ctx, host, community, version, OID_NAME)

    value_by_idx = _walk_by_index(ctx, host, community, version, OID_VALUE)
    unit_by_idx = _walk_by_index(ctx, host, community, version, OID_UNIT)
    th_value_by_idx = _walk_by_index(ctx, host, community, version, OID_VALUE_TH)
    th_unit_by_idx = _walk_by_index(ctx, host, community, version, OID_UNIT_TH)

    rows = []
    for r in name_rows:
        idx = _index_after(r["oid"], OID_NAME)
        rows.append({
            "index": idx,
            "name": r["value"],
            "value": value_by_idx.get(idx, ""),
            "unit": unit_by_idx.get(idx, ""),
            "th_value": th_value_by_idx.get(idx, ""),
            "th_unit": th_unit_by_idx.get(idx, ""),
        })
    return rows


def _strip_quotes(s):
    if s == None:
        return ""
    clean = s
    if len(clean) >= 2 and clean[0] == "'" and clean[-1] == "'":
        return clean[1:-1]
    if len(clean) >= 2 and clean[0] == '"' and clean[-1] == '"':
        return clean[1:-1]
    return clean


def _to_float(s):
    if s == None or s == "":
        return None
    clean = _strip_quotes(s)
    # Guard: only attempt float conversion when it looks numeric.
    # Starlark float() fails on non-numeric; use a safe probe.
    neg = clean.startswith("-")
    body = clean[1:] if neg else clean
    if body == "":
        return None
    # Accept digits with at most one '.'.
    parts = body.split(".")
    ok = True
    if len(parts) == 1:
        ok = parts[0].isdigit() and len(parts[0]) > 0
    elif len(parts) == 2:
        ok = (parts[0].isdigit() or parts[0] == "") and (parts[1].isdigit() or parts[1] == "") and len(parts[0] + parts[1]) > 0
    else:
        ok = False
    if not ok:
        return None
    return float(clean)


def main(ctx, params):
    host = params.get("host", DEFAULT_HOST)
    community = params.get("community", DEFAULT_COMMUNITY)
    version = params.get("version", DEFAULT_VERSION)

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        if not _is_liebert(ctx, host, community, version):
            return {"changed": False, "msg": "not a Liebert device", "data": {"discovery": []}}

        rows = _collect_pump_rows(ctx, host, community, version)
        discovery = []
        for r in rows:
            name = r["name"]
            if name == None or name == "":
                continue
            if "threshold" in name.lower():
                continue
            discovery.append({
                "item": name,
                "params": {"warn": 0, "crit": 0},
                "metrics": ["pump_hours"],
            })
        return {
            "changed": False,
            "msg": "discovered %d pump items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")

    if not _is_liebert(ctx, host, community, version):
        return {
            "changed": False,
            "msg": "not a Liebert device (sysOID detection failed)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _collect_pump_rows(ctx, host, community, version)
    row = None
    for r in rows:
        if r["name"] == item and not ("threshold" in r["name"].lower()):
            row = r
            break

    if row == None:
        return {
            "changed": False,
            "msg": "item not found: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = _to_float(row["value"])
    if value == None:
        return {
            "changed": False,
            "msg": "no numeric value for item: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    unit = row["unit"] if row["unit"] != None else ""

    threshold = None
    for r in rows:
        if r["name"] == None:
            continue
        if "Threshold" in r["name"] and r["name"].replace(" Threshold", "") == item:
            t = _to_float(r["th_value"])
            if t != None:
                threshold = t
                break

    warn = params.get("warn")
    crit = params.get("crit")

    if threshold != None:
        warn_level = threshold
        crit_level = threshold
    else:
        warn_level = warn if warn != None else 0
        crit_level = crit if crit != None else 0

    if crit_level != None and crit_level != 0 and value >= crit_level:
        state = "CRIT"
    elif warn_level != None and warn_level != 0 and value >= warn_level:
        state = "WARN"
    else:
        state = "OK"

    rendered = "%f %s" % (value, unit)

    return {
        "changed": False,
        "msg": rendered,
        "data": {
            "state": state,
            "metrics": {"pump_hours": value},
            "details": "",
        },
    }