# Checkmk check: liebert_chilled_water
# Translated to a read-only Starlark check module for the yolo-man agent.

LIEBERT_BASE_OID = ".1.3.6.1.4.1.476.1.42"
CHILLED_WATER_BASE = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
NAME_COL_OID = CHILLED_WATER_BASE + ".10.1.2.100"
EVENT_COL_OID = CHILLED_WATER_BASE + ".20.1.2.100"


def _snmpget_rows(ctx, base_oid, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0 and res.rc != 1:
        return rows
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts[0], parts[1]
        if value.endswith('"') and value.startswith('"'):
            value = value[1:-1]
        rows.append((oid, value))
    return rows


def _index_from_oid(oid, col_oid):
    prefix = col_oid + "."
    if oid.startswith(prefix):
        return oid[len(prefix):]
    return None


def _dedupe_name(name, used):
    counter = 2
    new_name = name
    while new_name in used:
        new_name = "%s %d" % (name, counter)
        counter += 1
    used.add(new_name)
    return new_name


def _detect_liebert(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", "-On", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    return sys_oid.startswith(LIEBERT_BASE_OID)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        if not _detect_liebert(ctx, params):
            return {"changed": False, "msg": "not a Liebert device", "data": {"discovery": []}}
        names = _snmpget_rows(ctx, NAME_COL_OID, community, host)
        used = set()
        discovery = []
        for oid, value in names:
            if not value:
                continue
            idx = _index_from_oid(oid, NAME_COL_OID)
            if idx == None:
                continue
            name = _dedupe_name(value, used)
            discovery.append({
                "item": name,
                "params": {"warn": 0, "crit": 0},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    if not _detect_liebert(ctx, params):
        return {
            "changed": False,
            "msg": "not a Liebert device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    names = _snmpget_rows(ctx, NAME_COL_OID, community, host)
    events = _snmpget_rows(ctx, EVENT_COL_OID, community, host)

    name_map = {}
    used = set()
    for oid, value in names:
        if not value:
            continue
        idx = _index_from_oid(oid, NAME_COL_OID)
        if idx == None:
            continue
        name = _dedupe_name(value, used)
        name_map[idx] = name

    event_map = {}
    for oid, value in events:
        idx = _index_from_oid(oid, EVENT_COL_OID)
        if idx == None:
            continue
        if value.endswith('"') and value.startswith('"'):
            value = value[1:-1]
        event_map[idx] = value

    target_idx = None
    for idx, name in name_map.items():
        if name == item:
            target_idx = idx
            break
    if target_idx == None:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = event_map.get(target_idx, "")
    if value == "":
        return {
            "changed": False,
            "msg": "no event data for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if value.lower() == "inactive event":
        return {
            "changed": False,
            "msg": "Normal",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }
    else:
        return {
            "changed": False,
            "msg": value,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }