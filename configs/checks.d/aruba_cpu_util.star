OID_DESC = ".1.3.6.1.4.1.14823.2.2.1.1.1.9.1.2"
OID_UTIL = ".1.3.6.1.4.1.14823.2.2.1.1.1.9.1.3"

def _snmp_val(raw):
    pos = raw.find(": ")
    val = raw[pos + 2:].strip() if pos >= 0 else raw.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _snmp_idx(oid):
    dot = oid.rfind(".")
    return oid[dot + 1:] if dot >= 0 else oid

def _walk_map(ctx, host, community, base_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid],
        mutates=False,
    )
    result = {}
    if res.rc != 0:
        return result
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        eq = line.find(" = ")
        if eq < 0:
            continue
        oid = line[:eq].strip()
        val = _snmp_val(line[eq + 3:])
        result[_snmp_idx(oid)] = val
    return result

def _to_float(s):
    neg = s.startswith("-")
    core = s[1:] if neg else s
    dot = core.find(".")
    if dot >= 0:
        ip = core[:dot]
        fp = core[dot + 1:]
        ok = (ip == "" or ip.isdigit()) and (fp == "" or fp.isdigit())
    else:
        ok = core != "" and core.isdigit()
    if not ok:
        return None
    return float(s)

def _collect_items(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    descs = _walk_map(ctx, host, community, OID_DESC)
    utils = _walk_map(ctx, host, community, OID_UTIL)
    items = {}
    for idx, desc in descs.items():
        if idx in utils:
            v = _to_float(utils[idx])
            if v != None:
                items[desc] = v
    return items

def main(ctx, params):
    if params.get("_discover"):
        items = _collect_items(ctx, params)
        out = [
            {
                "item": it,
                "params": {"levels": [80.0, 90.0]},
                "metrics": ["util"],
            }
            for it in sorted(items.keys())
        ]
        return {
            "changed": False,
            "msg": "discovered %d CPU items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    items = _collect_items(ctx, params)

    if item not in items:
        return {
            "changed": False,
            "msg": "item not found in SNMP data: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    util = items[item]
    levels = params.get("levels", [80.0, 90.0])
    warn = float(levels[0])
    crit = float(levels[1])

    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")

    return {
        "changed": False,
        "msg": "CPU utilization %s: %f%%" % (item, util),
        "data": {
            "state": state,
            "metrics": {"util": util},
            "details": "",
        },
    }