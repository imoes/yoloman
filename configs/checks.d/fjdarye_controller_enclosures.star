def _status_to_result(status):
    if status == "1":
        return ("OK", "Normal")
    if status == "2":
        return ("CRIT", "Alarm")
    if status == "3":
        return ("WARN", "Warning")
    if status == "4":
        return ("CRIT", "Invalid")
    if status == "5":
        return ("CRIT", "Maintenance")
    if status == "6":
        return ("CRIT", "Undefined")
    return ("UNKNOWN", "Unknown")

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",
    ".1.3.6.1.4.1.211.1.21.1.150",
    ".1.3.6.1.4.1.211.1.21.1.153",
]

FJDARYE_CONTROLLER_ENCLOSURES = {
    ".1.3.6.1.4.1.211.1.21.1.60":  ".2.6.2.1",
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.10.2.1",
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.10.2.1",
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.10.2.1",
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.10.2.1",
}


def _probe_sysoid(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return None
    return res.stdout.strip()


def _walk_enclosure(ctx, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return []
    rows = []
    for line in res.stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        sp = s.find(" ")
        if sp < 0:
            continue
        full_oid = s[:sp]
        value = s[sp + 1:]
        idx = full_oid[len(column_oid) + 1:]
        rows.append((idx, value))
    return rows


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sysoid = _probe_sysoid(ctx, host, community)
        if sysoid == None:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        if sysoid not in FJDARYE_SUPPORTED_DEVICES:
            return {"changed": False, "msg": "not a supported FJDARY-E device", "data": {"discovery": []}}

        ce_oid = FJDARYE_CONTROLLER_ENCLOSURES.get(sysoid)
        if ce_oid == None:
            return {"changed": False, "msg": "no enclosure OID for device", "data": {"discovery": []}}

        index_col = sysoid + ce_oid + ".1"
        status_col = sysoid + ce_oid + ".3"

        indexes = _walk_enclosure(ctx, host, community, index_col)
        statuses = _walk_enclosure(ctx, host, community, status_col)

        status_map = {}
        for idx, val in statuses:
            status_map[idx] = val

        discovery = []
        for idx, _ in indexes:
            st = status_map.get(idx, "4")
            if st != "4":
                discovery.append({"item": idx, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d enclosures" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    sysoid = _probe_sysoid(ctx, host, community)
    if sysoid == None:
        return {
            "changed": False,
            "msg": "no SNMP response for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if sysoid not in FJDARYE_SUPPORTED_DEVICES:
        return {
            "changed": False,
            "msg": "host is not a supported FJDARY-E device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    ce_oid = FJDARYE_CONTROLLER_ENCLOSURES.get(sysoid)
    if ce_oid == None:
        return {
            "changed": False,
            "msg": "no enclosure OID configured for device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_oid = sysoid + ce_oid + ".3." + item
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, status_oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return {
            "changed": False,
            "msg": "enclosure %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = res.stdout.strip()
    state, summary = _status_to_result(status)
    return {
        "changed": False,
        "msg": "Controller Enclosure %s: %s" % (item, summary),
        "data": {"state": state, "metrics": {}, "details": ""},
    }