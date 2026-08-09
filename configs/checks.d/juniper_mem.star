# juniper_mem.star — translated Checkmk juniper_mem check (read-only)

# SNMP base OID and column OIDs for the juniper_mem section.
_OID_BASE = ".1.3.6.1.4.1.2636.3.1.13.1"
_OID_DESCR = _OID_BASE + ".5.9"
_OID_BUFFER = _OID_BASE + ".11.9"
_JUNIPER_SYSID_PREFIX = ".1.3.6.1.4.1.2636.1.1.1"

def _is_juniper(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if not val:
        return False
    return _is_oid_prefix(val, _JUNIPER_SYSID_PREFIX)

def _is_oid_prefix(oid, prefix):
    if not oid:
        return False
    p = oid.split(".")
    x = prefix.split(".")
    if len(p) < len(x):
        return False
    for i in range(len(x)):
        if p[i] != x[i]:
            return False
    return True

def _walk_descr(ctx, host, community):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _OID_DESCR],
        mutates=False,
    )
    out = {}
    if res.rc != 0:
        return out
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(_OID_DESCR) + 1:]
        if val.startswith('"') and val.endswith('"') and len(val) >= 2:
            val = val[1:-1]
        out[idx] = val
    return out

def _to_float(raw):
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = raw[1:-1]
    if raw.isdigit():
        return float(raw)
    neg = raw.startswith("-")
    body = raw[1:] if neg else raw
    if body.isdigit():
        return -float(body) if neg else float(body)
    if raw.find(".") != -1:
        sign = raw[0]
        rest = raw[1:] if sign in "+-" else raw
        if rest.replace(".", "", 1).isdigit():
            return float(raw)
    return None

def _get_buffer(ctx, host, community, idx):
    oid = _OID_BUFFER + "." + idx
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return _to_float(res.stdout)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_juniper(ctx, host, community):
            return {
                "changed": False,
                "msg": "host is not a Juniper device",
                "data": {"discovery": []},
            }
        descr_map = _walk_descr(ctx, host, community)
        out = []
        for idx in sorted(descr_map.keys(), key=lambda x: _idx_sort_key(x)):
            item = descr_map[idx]
            out.append({
                "item": item,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["mem_used_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d memory items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    levels = params.get("levels", (warn, crit))
    if type(levels) == "tuple" and len(levels) >= 2:
        lw = levels[0]
        lc = levels[1]
    else:
        lw = warn
        lc = crit
    lw = float(lw)
    lc = float(lc)

    descr_map = _walk_descr(ctx, host, community)
    found_idx = None
    for idx in descr_map:
        if descr_map[idx] == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "no such memory item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pct = _get_buffer(ctx, host, community, found_idx)
    if pct == None:
        return {
            "changed": False,
            "msg": "could not read memory value for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    if pct >= lc:
        state = "CRIT"
    elif pct >= lw:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Memory %s: %f%% used" % (item, pct),
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": pct},
            "details": "Routing Engine buffer utilization: %f%% (warn %f%%, crit %f%%)" % (pct, lw, lc),
        },
    }

def _idx_sort_key(idx):
    parts = []
    for seg in idx.split("."):
        if seg.isdigit():
            parts.append((0, int(seg)))
        else:
            parts.append((1, seg))
    return str(parts)