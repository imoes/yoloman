ROUTE_TYPE_MAPPING = {
    "DefaultRoute": "default route",
    "PBR": "policy based routing",
    "": "not defined",
}

ROUTE_STATE_MAPPING = {
    "UP": {"state": "OK", "summary": "Route is up"},
    "DOWN": {"state": "CRIT", "summary": "Route is down"},
    "UNDEF": {"state": "UNKNOWN", "summary": "Route is undefined"},
}

# OIDs for stormshield_route table at .1.3.6.1.4.1.11256.1.14.1.1
# column OID 1  -> route name (index / item)
# column OID 2  -> route type
# column OID 4  -> router name
# column OID 5  -> gateway name
# column OID 7  -> gateway type
# column OID 9  -> route state
ROUTE_BASE = ".1.3.6.1.4.1.11256.1.14.1.1"
ROUTE_COL_OID = ROUTE_BASE + ".1"
ROUTE_COLS = ["2", "4", "5", "7", "9"]


def _walk_snmp(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    return res

def _get_snmp(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    return res

def _detect_stormshield(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sys_oid_res = _get_snmp(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid_res.rc != 0:
        return False
    sys_oid = sys_oid_res.stdout.strip()
    if not sys_oid:
        return False
    is_stormshield = (
        sys_oid.startswith(".1.3.6.1.4.1.11256.1")
        or sys_oid == ".1.3.6.1.4.1.11256.2.0"
        or sys_oid.startswith(".1.3.6.1.4.1.8072")
    )
    if not is_stormshield:
        return False
    info_res = _get_snmp(ctx, host, community, ".1.3.6.1.4.1.11256.1.0.1.0")
    if info_res.rc != 0:
        return False
    return len(info_res.stdout.strip()) > 0


def _fetch_route_section(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    rows = {}  # index -> {col_oid_suffix: value}
    # Walk each column
    col_oids = ["1"] + ROUTE_COLS
    for col in col_oids:
        res = _walk_snmp(ctx, host, community, ROUTE_BASE + "." + col)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            full_oid, value = sp[0], sp[1]
            # index is the suffix after column base OID
            idx = full_oid[len(ROUTE_BASE) + 1:]
            rows.setdefault(idx, {})[col] = value.strip()
    section = []
    for idx in sorted(rows.keys()):
        c = rows[idx]
        name = c.get("1", "")
        typ = c.get("2", "")
        router_name = c.get("4", "")
        gateway_name = c.get("5", "")
        gateway_type = c.get("7", "")
        state = c.get("9", "")
        section.append([name, typ, router_name, gateway_name, gateway_type, state])
    return section


def main(ctx, params):
    if params.get("_discover"):
        if not _detect_stormshield(ctx, params):
            return {
                "changed": False,
                "msg": "no stormshield device found",
                "data": {"discovery": []},
            }
        section = _fetch_route_section(ctx, params)
        discovery = []
        for line in section:
            if len(line) >= 6 and line[5] == "UP":
                discovery.append({
                    "item": line[0],
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d gateways" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _detect_stormshield(ctx, params):
        return {
            "changed": False,
            "msg": "no stormshield device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _fetch_route_section(ctx, params)
    target = None
    for line in section:
        if len(line) >= 6 and line[0] == item:
            target = line
            break
    if target == None:
        return {
            "changed": False,
            "msg": "no such route: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    _name, typ, name, gateway_name, gateway_type, state = target
    st = ROUTE_STATE_MAPPING.get(state)
    if st == None:
        st = {"state": "UNKNOWN", "summary": "Route state unknown"}
    rtype = ROUTE_TYPE_MAPPING.get(typ, "not defined")
    infotext = "Type: %s, Router name: %s, Gateway name: %s, Gateway type: %s" % (
        rtype, name, gateway_name, gateway_type)
    summary = st["summary"]
    if st["state"] == "OK":
        summary = summary + " - " + infotext
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": st["state"], "metrics": {}, "details": infotext},
    }