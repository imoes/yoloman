# Translation of Checkmk check: fjdarye_device_enclosures
# Monitors Fujitsu storage systems supporting FJDARY-E60/E100/E500/E600 MIBs
# via SNMP for device enclosure status.

FJDARYE_DEVICE_ENCLOSURES = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.7.2.1",
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.14.2.1",
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.14.2.1",
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.14.2.1",
}

FJDARYE_STATUS_MAP = {
    "1": {"state": "OK", "summary": "Normal"},
    "2": {"state": "CRIT", "summary": "Alarm"},
    "3": {"state": "WARN", "summary": "Warning"},
    "4": {"state": "CRIT", "summary": "Invalid"},
    "5": {"state": "CRIT", "summary": "Maintenance"},
    "6": {"state": "CRIT", "summary": "Undefined"},
}

SYSOID_OID = ".1.3.6.1.2.1.1.2.0"


def _detect_sysoid(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_OID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    oid = res.stdout.strip()
    # oid may be quoted for string types; strip surrounding quotes
    return oid.strip('"')


def _get_base_oid(ctx, host, community):
    sysoid = _detect_sysoid(ctx, host, community)
    if sysoid == None:
        return None
    return FJDARYE_DEVICE_ENCLOSURES.get(sysoid)


def _walk_column(ctx, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        rows.append({"oid": parts[0].strip(), "value": parts[1].strip()})
    return rows


def _get_status(ctx, host, community, base_oid, index):
    status_oid = base_oid + ".3." + index
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, status_oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip().strip('"')


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        base_oid = _get_base_oid(ctx, host, community)
        if base_oid == None:
            return {"changed": False, "msg": "not a Fujitsu FJDARY device", "data": {"discovery": []}}

        index_column_oid = base_oid + ".1"
        rows = _walk_column(ctx, host, community, index_column_oid)
        if len(rows) == 0:
            return {"changed": False, "msg": "no enclosures found", "data": {"discovery": []}}

        discovery = []
        seen = set()
        for row in rows:
            # index is the oid suffix after the column base
            idx = row["oid"][len(index_column_oid) + 1:]
            if idx in seen:
                continue
            seen.add(idx)
            status = _get_status(ctx, host, community, base_oid, idx)
            # skip '4' (Invalid) per discover_fjdarye_item
            if status == "4":
                continue
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d enclosures" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = _get_base_oid(ctx, host, community)
    if base_oid == None:
        return {
            "changed": False,
            "msg": "not a Fujitsu FJDARY device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "host does not match any supported FJDARY sysObjectID"},
        }

    status = _get_status(ctx, host, community, base_oid, item)
    if status == None:
        return {
            "changed": False,
            "msg": "no such enclosure: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "enclosure index " + item + " not found"},
        }

    entry = FJDARYE_STATUS_MAP.get(status)
    if entry == None:
        return {
            "changed": False,
            "msg": "unknown status code: " + str(status),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "unknown status value " + str(status)},
        }

    return {
        "changed": False,
        "msg": entry["summary"],
        "data": {"state": entry["state"], "metrics": {"status": int(status)}, "details": ""},
    }