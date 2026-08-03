# liebert_cooling_status — Checkmk check translated to read-only Starlark

DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_PREFIX = ".1.3.6.1.4.1.476.1.42"
BASE_OID = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
NAME_COL_OID = ".10.1.2.1.5302"
VALUE_COL_OID = ".20.1.2.1.5302"
SNMP_TIMEOUT = "2"
SNMP_RETRIES = "1"


def _oid_suffix(oid, full_oid):
    if len(full_oid) > len(oid):
        return full_oid[len(oid) + 1:]
    return ""


def _strip_type_prefix(value):
    idx = 0
    ln = len(value)
    while idx < ln:
        ch = value[idx]
        if ch == ":" or ch == " ":
            idx = idx + 1
            continue
        break
    while idx < ln:
        ch = value[idx]
        if ch == ":" or ch == " ":
            idx = idx + 1
            continue
        break
    out = value[idx:]
    if len(out) >= 2 and out[0] == "\"" and out[len(out) - 1] == "\"":
        return out[1:len(out) - 1]
    return out


def _snmpget(ctx, host, community, oid):
    return ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", SNMP_TIMEOUT,
                    "-r", SNMP_RETRIES, host, oid], mutates=False)


def _snmpwalk(ctx, host, community, oid):
    return ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", SNMP_TIMEOUT,
                    "-r", SNMP_RETRIES, host, oid], mutates=False)


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sysOid = _snmpget(ctx, host, community, DETECT_OID)
        if sysOid.rc != 0:
            return {"changed": False, "msg": "host not reachable or not a Liebert device",
                    "data": {"discovery": []}}
        sysOidVal = _strip_type_prefix(sysOid.stdout).strip()
        if sysOidVal.find(DETECT_PREFIX) != 0:
            return {"changed": False, "msg": "host is not a Liebert device",
                    "data": {"discovery": []}}

        walk = _snmpwalk(ctx, host, community, BASE_OID + NAME_COL_OID)
        if walk.rc != 0 or walk.stdout.strip() == "":
            return {"changed": False, "msg": "no cooling status data available",
                    "data": {"discovery": []}}

        names = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            full_oid = line[:sp]
            raw_val = line[sp + 1:]
            idx = _oid_suffix(BASE_OID + NAME_COL_OID, full_oid)
            if idx == "":
                continue
            val = _strip_type_prefix(raw_val).strip()
            if val == "":
                continue
            names.append((idx, val))

        if len(names) == 0:
            return {"changed": False, "msg": "no cooling status names found",
                    "data": {"discovery": []}}

        discovery = []
        for idx, name in names:
            discovery.append({"item": name, "params": {}, "metrics": ["status"]})

        return {"changed": False,
                "msg": "discovered %d cooling status items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysOid = _snmpget(ctx, host, community, DETECT_OID)
    if sysOid.rc != 0:
        return {"changed": False, "msg": "host not reachable or not a Liebert device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    walk = _snmpwalk(ctx, host, community, BASE_OID + NAME_COL_OID)
    if walk.rc != 0 or walk.stdout.strip() == "":
        return {"changed": False, "msg": "no Liebert cooling status data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_idx = ""
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        raw_val = line[sp + 1:]
        val = _strip_type_prefix(raw_val).strip()
        idx = _oid_suffix(BASE_OID + NAME_COL_OID, full_oid)
        if idx == "" or val == "":
            continue
        if val == item:
            found_idx = idx
            break

    if found_idx == "":
        return {"changed": False,
                "msg": "no cooling status named '%s' found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    valRes = _snmpget(ctx, host, community, BASE_OID + VALUE_COL_OID + "." + found_idx)
    if valRes.rc != 0:
        return {"changed": False,
                "msg": "could not read cooling status value for '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = _strip_type_prefix(valRes.stdout).strip()
    return {"changed": False,
            "msg": "%s" % status,
            "data": {"state": "OK", "metrics": {}, "details": status}}