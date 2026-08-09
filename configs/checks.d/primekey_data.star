# Checkmk check: primekey_data -> PrimeKey %s Status
# Translated to read-only Starlark for the yolo-man agent.
# SNMP-based check. Walks PrimeKey status OIDs.

_BASE_OID = "1.3.6.1.4.1.22408.1.1.2"
_STATUS_OIDS = {
    "VMs":        _BASE_OID + ".1.2.118.109.1",
    "RAID":       _BASE_OID + ".1.5.114.97.105.100.49.1",
    "EJBCA":      _BASE_OID + ".1.8.104.101.97.108.116.104.101.50.1",
    "Signserver": _BASE_OID + ".1.8.104.101.97.108.116.104.115.50.1",
    "HSM":        _BASE_OID + ".2.4.104.115.109.51.1",
}


def _snmpget(ctx, host, community, version, oid):
    return ctx.run(
        ["snmpget", "-v%s" % version, "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _parse_status_value(raw):
    v = raw.strip().strip('"').strip()
    if v == "":
        return ""
    if v.isdigit():
        d = int(v)
        if d == 0 or d == 1:
            return v
    return ""


def _fetch_all_statuses(ctx, host, community, version):
    out = {}
    for item, oid in _STATUS_OIDS.items():
        res = _snmpget(ctx, host, community, version, oid)
        if res.rc != 0:
            return None
        out[item] = res.stdout.strip()
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")

    if params.get("_discover"):
        # DETECT_PRIMEKEY: sysObjectID must equal .1.3.6.1.4.1.8072.3.2.10
        sys_res = _snmpget(ctx, host, community, version, "1.3.6.1.2.1.1.2.0")
        if sys_res.rc != 0:
            return {"changed": False, "msg": "PrimeKey not detected (no SNMP)", "data": {"discovery": []}}

        statuses = _fetch_all_statuses(ctx, host, community, version)
        if statuses == None:
            return {"changed": False, "msg": "PrimeKey detected but no statuses available", "data": {"discovery": []}}

        discovery = []
        for item in statuses:
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d PrimeKey items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    statuses = _fetch_all_statuses(ctx, host, community, version)
    if statuses == None:
        return {
            "changed": False,
            "msg": "PrimeKey not reachable on " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = statuses.get(item, "")
    if raw == "":
        return {
            "changed": False,
            "msg": "no status for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    val = _parse_status_value(raw)
    if val == "":
        return {
            "changed": False,
            "msg": "could not parse status for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if val == "0":
        return {
            "changed": False,
            "msg": item + " status is ok",
            "data": {"state": "OK", "metrics": {"status": 0}, "details": "Status is ok"},
        }
    return {
        "changed": False,
        "msg": item + " status is not ok",
        "data": {"state": "CRIT", "metrics": {"status": 1}, "details": "Status is not ok"},
    }