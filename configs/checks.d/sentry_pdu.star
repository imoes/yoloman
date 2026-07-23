DETECT_OID    = ".1.3.6.1.2.1.1.2.0"
OID_V3_SYSOID = ".1.3.6.1.4.1.1718.3"
OID_V4_SYSOID = ".1.3.6.1.4.1.1718.4"

OID_V3_NAME  = ".1.3.6.1.4.1.1718.3.2.2.1.3"
OID_V3_STATE = ".1.3.6.1.4.1.1718.3.2.2.1.5"
OID_V3_POWER = ".1.3.6.1.4.1.1718.3.2.2.1.12"

OID_V4_NAME  = ".1.3.6.1.4.1.1718.4.1.3.2.1.3"
OID_V4_STATE = ".1.3.6.1.4.1.1718.4.1.3.3.1.2"
OID_V4_POWER = ".1.3.6.1.4.1.1718.4.1.3.3.1.3"

STATES_V3 = {
    0: "off",
    1: "on",
    2: "off wait",
    3: "on wait",
    4: "off error",
    5: "on error",
    6: "no comm",
}

STATES_V4 = {
    0:  ("OK",   "normal"),
    1:  ("CRIT", "disabled"),
    2:  ("CRIT", "purged"),
    5:  ("WARN", "reading"),
    6:  ("WARN", "settle"),
    7:  ("CRIT", "not found"),
    8:  ("CRIT", "lost"),
    9:  ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}

def _snmp_val(raw):
    if ": " in raw:
        return raw.split(": ", 1)[1].strip().strip('"')
    return raw.strip()

def _walk_col(ctx, host, community, col_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, col_oid],
        mutates=False, ok_codes=[0, 1],
    )
    result = {}
    prefix = col_oid + "."
    for line in res.stdout.splitlines():
        if " = " not in line:
            continue
        parts = line.split(" = ", 1)
        oid = parts[0].strip()
        if oid.startswith(prefix):
            result[oid[len(prefix):]] = _snmp_val(parts[1])
    return result

def _detect_version(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, DETECT_OID],
        mutates=False, ok_codes=[0, 1, 2],
    )
    for line in res.stdout.splitlines():
        if "OID: " in line:
            sysoid = line.split("OID: ", 1)[1].strip()
            if sysoid == OID_V3_SYSOID:
                return "v3"
            if sysoid == OID_V4_SYSOID:
                return "v4"
    return None

def _fetch_plugs(ctx, host, community, version):
    if version == "v3":
        n_oid, s_oid, p_oid = OID_V3_NAME, OID_V3_STATE, OID_V3_POWER
    else:
        n_oid, s_oid, p_oid = OID_V4_NAME, OID_V4_STATE, OID_V4_POWER
    names  = _walk_col(ctx, host, community, n_oid)
    states = _walk_col(ctx, host, community, s_oid)
    powers = _walk_col(ctx, host, community, p_oid)
    plugs = {}
    for idx, name in names.items():
        s = states.get(idx, "")
        p = powers.get(idx, "")
        plugs[name] = {
            "state": int(s) if s.isdigit() else -1,
            "power": int(p) if p.isdigit() else None,
        }
    return plugs

def main(ctx, params):
    host      = params.get("host", "localhost")
    community = params.get("community", "public")
    version   = params.get("version", None)

    if version == None:
        version = _detect_version(ctx, host, community)

    if params.get("_discover"):
        if version == None:
            return {"changed": False, "msg": "no Sentry PDU detected",
                    "data": {"discovery": []}}
        plugs = _fetch_plugs(ctx, host, community, version)
        items = [
            {"item": name, "params": {}, "metrics": ["power"]}
            for name in sorted(plugs.keys())
        ]
        return {"changed": False, "msg": "discovered %d plugs" % len(items),
                "data": {"discovery": items}}

    item           = params.get("item", "")
    required_state = params.get("required_state", None)

    if version == None:
        return {"changed": False, "msg": "no Sentry PDU detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    plugs = _fetch_plugs(ctx, host, community, version)
    if item not in plugs:
        return {"changed": False, "msg": "plug not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    pdu       = plugs[item]
    state_int = pdu["state"]
    power     = pdu["power"]

    metrics = {}
    if power != None and power > 0:
        metrics["power"] = power

    if version == "v3":
        readable = STATES_V3.get(state_int, "unknown")
        if required_state != None and readable != required_state:
            mon_state = "CRIT"
        elif readable == "unknown":
            mon_state = "UNKNOWN"
        else:
            mon_state = "OK"
        msg = "Status: " + readable
    else:
        if state_int in STATES_V4:
            tup       = STATES_V4[state_int]
            mon_state = tup[0]
            readable  = tup[1]
        else:
            mon_state = "UNKNOWN"
            readable  = str(state_int)
        msg = "Status: " + readable

    if power != None and power > 0:
        msg = msg + (", Power: %d Watt" % power)

    return {"changed": False, "msg": msg,
            "data": {"state": mon_state, "metrics": metrics, "details": ""}}