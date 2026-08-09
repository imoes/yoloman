def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.6574.3.1.1"

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "synology not detected via sysDescr",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no Synology device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         host, base + ".2"],
        mutates=False,
    )
    if res.rc != 0 or len(res.stdout.strip()) == 0:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no synology raids discovered",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no Synology RAID found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    states = {
        1: ("OK", "OK"),
        2: ("repairing", "WARN"),
        3: ("migrating", "WARN"),
        4: ("expanding", "WARN"),
        5: ("deleting", "WARN"),
        6: ("creating", "WARN"),
        7: ("RAID syncing", "OK"),
        8: ("RAID parity checking", "OK"),
        9: ("RAID assembling", "WARN"),
        10: ("cancelling", "WARN"),
        11: ("degraded", "CRIT"),
        12: ("crashed", "CRIT"),
        13: ("scrubbing", "OK"),
        14: ("RAID deploying", "OK"),
        15: ("RAID undeploying", "OK"),
        16: ("RAID mounting cache", "OK"),
        17: ("RAID unmounting cache", "OK"),
        18: ("RAID continue expanding", "WARN"),
        19: ("RAID converting", "OK"),
        20: ("RAID migrating", "OK"),
        21: ("RAID status unknown", "UNKNOWN"),
    }

    if params.get("_discover"):
        discovery = []
        rows = _parse_snmp_table(res.stdout)
        for index, name in rows:
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["raid_status"],
            })
        return {
            "changed": False,
            "msg": "discovered %d raid entries" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    name_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, base + ".2." + item],
        mutates=False,
    )

    status_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, base + ".3." + item],
        mutates=False,
    )

    if name_res.rc != 0 or status_res.rc != 0:
        return {
            "changed": False,
            "msg": "no such raid: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_str = name_res.stdout.strip()
    if status_str.startswith('"') and status_str.endswith('"'):
        status_str = status_str[1:-1]

    try_status = status_res.stdout.strip()
    if not try_status.isdigit():
        return {
            "changed": False,
            "msg": "invalid raid status value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = int(try_status)
    info = states.get(status, ("RAID status unknown", "UNKNOWN"))
    summary = info[0]
    state = info[1]

    return {
        "changed": False,
        "msg": "Raid %s - Status: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": {"raid_status": status},
            "details": "Raid %s status code: %d" % (item, status),
        },
    }


def _parse_snmp_table(walk_output):
    rows = []
    for line in walk_output.splitlines():
        line = line.strip()
        if len(line) == 0:
            continue
        space_idx = line.find(" ")
        if space_idx == -1:
            continue
        oid_part = line[:space_idx]
        value_part = line[space_idx + 1:]
        parts = oid_part.split(".")
        if len(parts) < 2:
            continue
        index = parts[-1]
        val = value_part.strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        rows.append((index, val))
    return rows