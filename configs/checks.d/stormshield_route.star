BASE_OID = ".1.3.6.1.4.1.11256.1.14.1.1"
_BASE_LEN = len(BASE_OID.split("."))

ROUTE_TYPE_MAP = {
    "DefaultRoute": "default route",
    "PBR": "policy based routing",
    "": "not defined",
}

def _snmp_val(raw):
    idx = raw.find(": ")
    if idx < 0:
        return raw.strip()
    val = raw[idx + 2:].strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _parse_table(stdout):
    rows = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line or " = " not in line:
            continue
        halves = line.split(" = ", 1)
        if len(halves) < 2:
            continue
        parts = halves[0].split(".")
        if len(parts) < _BASE_LEN + 2:
            continue
        col = parts[_BASE_LEN]
        row = parts[_BASE_LEN + 1]
        if row not in rows:
            rows[row] = {}
        rows[row][col] = _snmp_val(halves[1])
    return rows

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
        ok_codes=[0, 1],
    )

    rows = _parse_table(res.stdout)

    if params.get("_discover"):
        discovery = []
        for row_idx in sorted(rows.keys()):
            row = rows[row_idx]
            index = row.get("1", row_idx)
            if row.get("9", "") == "UP":
                discovery.append({
                    "item": index,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d routes" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    for row_idx in rows:
        row = rows[row_idx]
        index = row.get("1", row_idx)
        if index != item:
            continue
        typ = row.get("2", "")
        name = row.get("4", "")
        gw_name = row.get("5", "")
        gw_type = row.get("7", "")
        state = row.get("9", "UNDEF")

        if state == "UP":
            check_state = "OK"
            state_msg = "Route is up"
        elif state == "DOWN":
            check_state = "CRIT"
            state_msg = "Route is down"
        else:
            check_state = "UNKNOWN"
            state_msg = "Route is undefined"

        type_label = ROUTE_TYPE_MAP.get(typ, typ)
        details = "Type: %s, Router name: %s, Gateway name: %s, Gateway type: %s" % (
            type_label, name, gw_name, gw_type,
        )

        return {
            "changed": False,
            "msg": "%s, %s" % (state_msg, details),
            "data": {
                "state": check_state,
                "metrics": {},
                "details": details,
            },
        }

    return {
        "changed": False,
        "msg": "route not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }