def _snmp_get_oid(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysoid_val = _snmp_get_oid(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    if sysoid_val == None:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no genua device found",
                "data": {"discovery": [], "host_labels": {}},
            }
        return {
            "changed": False,
            "msg": "no genua device found at " + host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP sysDescr not reachable or does not belong to a genua product",
            },
        }

    is_genua = False
    for marker in ["genuscreen", "genubox", "genucrypt"]:
        if sysoid_val.find(marker) >= 0:
            is_genua = True
            break

    if not is_genua:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "host is not a genua device",
                "data": {"discovery": [], "host_labels": {}},
            }
        return {
            "changed": False,
            "msg": "host at " + host + " is not a genua device",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP sysDescr does not match genuscreen/genubox/genucrypt",
            },
        }

    base_3137 = ".1.3.6.1.4.1.3137.2.1.2.1"
    base_3717 = ".1.3.6.1.4.1.3717.2.1.2.1"
    col_map = {"1": "ifIndex", "2": "ifName", "3": "ifType", "4": "ifLinkState", "7": "ifCarpState"}

    if params.get("_discover"):
        found_one = False
        for base in [base_3137, base_3717]:
            rows = _walk_carp_table(ctx, host, community, base, col_map)
            if rows:
                found_one = True
                break
        if not found_one:
            return {
                "changed": False,
                "msg": "no genua carp state table found",
                "data": {"discovery": [], "host_labels": {}},
            }

        numifs = 0
        for row in rows:
            carp = row.get("7", "")
            if carp in ["0", "1", "2"]:
                numifs += 1

        if numifs > 1:
            discovery = [
                {"item": "", "params": {}, "metrics": ["carp_init", "carp_backup", "carp_master"]}
            ]
        else:
            discovery = []

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    rows = []
    for base in [base_3137, base_3717]:
        r = _walk_carp_table(ctx, host, community, base, col_map)
        if r:
            rows = r
            break

    if not rows:
        return {
            "changed": False,
            "msg": "no genua carp state table found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    carp_info = []
    for row in rows:
        if row.get("3", "") == "6":
            carp_info.append(row)

    state = 0
    carp_states = {0: 0, 1: 0, 2: 0}
    for elem in carp_info:
        s = elem.get("7", "")
        if s in ["0", "1", "2"]:
            carp_states[int(s)] += 1
            if carp_info[0].get("7", "") != s:
                state = 2

    names = {"0": "init", "1": "backup", "2": "master"}
    output = "Number of carp IFs in states "
    for i in ["0", "1", "2"]:
        output += names.get(i, i)
        output += ":" + str(carp_states[int(i)]) + " "

    metrics = {}
    metrics["carp_init"] = carp_states[0]
    metrics["carp_backup"] = carp_states[1]
    metrics["carp_master"] = carp_states[2]

    if state == 0:
        st = "OK"
    elif state == 1:
        st = "WARN"
    else:
        st = "CRIT"

    return {
        "changed": False,
        "msg": output,
        "data": {"state": st, "metrics": metrics, "details": ""},
    }


def _walk_carp_table(ctx, host, community, base, col_map):
    cols = ["1", "2", "3", "4", "7"]
    by_index = {}
    for col in cols:
        col_oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if res.rc != 0 or res.stdout.strip() == "":
            return []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            row_oid = parts[0]
            value = parts[1].strip()
            idx = row_oid[len(col_oid) + 1:]
            if idx == "":
                idx = row_oid[len(col_oid):]
                if idx.startswith("."):
                    idx = idx[1:]
            entry = by_index.get(idx)
            if entry == None:
                entry = {}
                by_index[idx] = entry
            entry[col_map[col]] = value
    return list(by_index.values())