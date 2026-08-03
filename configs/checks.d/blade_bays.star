# Checkmk check: blade_bays -> Starlark read-only check module
# Source: cmk/plugins/blade/agent_based/blade_bays.py

def _parse_power(s):
    v = s.rstrip("W")
    return int(v) if v.isdigit() else 0

def _map_state(state):
    table = {
        "0": (0, "standby"),
        "1": (0, "on"),
        "2": (1, "not present"),
        "3": (1, "switched off"),
        "255": (2, "not applicable"),
    }
    return table.get(state, (3, "unhandled[%s]" % state))

def _walk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, oid], mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        if line == "":
            continue
        idx = line.find(" ")
        if idx < 0:
            continue
        lines.append((line[:idx], line[idx + 1:]))
    return lines

def _get(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        bases = [
            ".1.3.6.1.4.1.2.3.51.2.2.10.2.1.1",
            ".1.3.6.1.4.1.2.3.51.2.2.10.3.1.1",
        ]
        col_oids = {
            "5": "name",
            "6": "state",
            "2": "type",
            "1": "id",
            "7": "power",
            "8": "power_max",
        }
        by_item = {}
        for base in bases:
            rows = {}
            for col_oid, val in _walk(ctx, community, host, base + ".5"):
                idx = col_oid[len(base + ".5") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["name"] = val
            for col_oid, val in _walk(ctx, community, host, base + ".6"):
                idx = col_oid[len(base + ".6") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["state"] = val
            for col_oid, val in _walk(ctx, community, host, base + ".2"):
                idx = col_oid[len(base + ".2") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["type"] = val
            for col_oid, val in _walk(ctx, community, host, base + ".1"):
                idx = col_oid[len(base + ".1") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["id"] = val
            for col_oid, val in _walk(ctx, community, host, base + ".7"):
                idx = col_oid[len(base + ".7") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["power"] = val
            for col_oid, val in _walk(ctx, community, host, base + ".8"):
                idx = col_oid[len(base + ".8") + 1:]
                rows.setdefault(idx, {})
                rows[idx]["power_max"] = val
            pd = bases.index(base) + 1
            for idx, attrs in rows.items():
                name = attrs.get("name", "")
                if name == "":
                    continue
                itemname = "PD%d %s" % (pd, name)
                if itemname in by_item:
                    itemname = "%s %s" % (itemname, idx)
                st = attrs.get("state", "")
                si, sr = _map_state(st)
                if sr in ["standby", "on"]:
                    ty = attrs.get("type", "").split("(")[0]
                    identifier = attrs.get("id", "")
                    power = _parse_power(attrs.get("power", "0W"))
                    power_max = _parse_power(attrs.get("power_max", "0W"))
                    by_item[itemname] = {
                        "name": name, "state_int": si, "state_readable": sr,
                        "type": ty, "id": identifier, "power": power,
                        "power_max": power_max,
                    }
        discovery = []
        for item, attrs in by_item.items():
            discovery.append({
                "item": item,
                "params": {"warn": 0, "crit": 0},
                "metrics": ["power", "power_max"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    bases = [
        ".1.3.6.1.4.1.2.3.51.2.2.10.2.1.1",
        ".1.3.6.1.4.1.2.3.51.2.2.10.3.1.1",
    ]
    if item == "":
        return {
            "changed": False,
            "msg": "no blade bay item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    name_part = None
    for base in bases:
        rows = {}
        for col_oid, val in _walk(ctx, community, host, base + ".5"):
            idx = col_oid[len(base + ".5") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["name"] = val
        for col_oid, val in _walk(ctx, community, host, base + ".6"):
            idx = col_oid[len(base + ".6") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["state"] = val
        for col_oid, val in _walk(ctx, community, host, base + ".2"):
            idx = col_oid[len(base + ".2") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["type"] = val
        for col_oid, val in _walk(ctx, community, host, base + ".1"):
            idx = col_oid[len(base + ".1") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["id"] = val
        for col_oid, val in _walk(ctx, community, host, base + ".7"):
            idx = col_oid[len(base + ".7") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["power"] = val
        for col_oid, val in _walk(ctx, community, host, base + ".8"):
            idx = col_oid[len(base + ".8") + 1:]
            rows.setdefault(idx, {})
            rows[idx]["power_max"] = val
        pd = bases.index(base) + 1
        for idx, attrs in rows.items():
            name = attrs.get("name", "")
            if name == "":
                continue
            candidate = "PD%d %s" % (pd, name)
            if candidate == item or ("%s %s" % (candidate, idx)) == item:
                st = attrs.get("state", "")
                si, sr = _map_state(st)
                ty = attrs.get("type", "").split("(")[0]
                identifier = attrs.get("id", "")
                power = _parse_power(attrs.get("power", "0W"))
                power_max = _parse_power(attrs.get("power_max", "0W"))
                state_str = ["OK", "WARN", "CRIT", "UNKNOWN"][si] if si < 4 else "UNKNOWN"
                details = "Max. power: %d W\nID: %s" % (power_max, identifier)
                return {
                    "changed": False,
                    "msg": "Status: %s" % sr,
                    "data": {
                        "state": state_str,
                        "metrics": {"power": power, "power_max": power_max},
                        "details": details,
                    },
                }
    return {
        "changed": False,
        "msg": "No data for '%s' in SNMP info" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }