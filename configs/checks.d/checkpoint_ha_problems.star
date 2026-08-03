def main(ctx, params):
    if params.get("_discover"):
        if not _is_checkpoint(ctx, params):
            return {"changed": False, "msg": "no Check Point HA device found",
                    "data": {"discovery": []}}
        section = _fetch_ha_problems(ctx, params)
        if section == None:
            return {"changed": False, "msg": "no Check Point HA device found",
                    "data": {"discovery": []}}
        out = []
        for row in section:
            name = row[0]
            if len(name) == 0:
                continue
            out.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d HA problems" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    section = _fetch_ha_problems(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no Check Point HA data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for row in section:
        name = row[0]
        dev_status = row[1]
        description = row[2]
        if name == item:
            if dev_status == "OK":
                return {"changed": False,
                        "msg": "OK",
                        "data": {"state": "OK", "metrics": {}, "details": ""}}
            return {"changed": False,
                    "msg": "%s - %s" % (dev_status, description),
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "HA problem item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _is_checkpoint(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sysoid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                      ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysoid.rc != 0 or len(sysoid.stdout) == 0:
        return False
    sysoid = sysoid.stdout
    if sysoid.startswith(".1.3.6.1.4.1.2620"):
        return True
    sysdesc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                       ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sysdesc.rc != 0:
        return False
    desc = sysdesc.stdout
    if _matches_fw_role(desc):
        return True
    gaia = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                    ".1.3.6.1.4.1.2620.1.6.5.1.0"], mutates=False)
    if gaia.rc == 0 and gaia.stdout.startswith("Gaia"):
        return True
    return False


def _matches_fw_role(s):
    if s == None or len(s) == 0:
        return False
    if s.startswith("IPSO "):
        return True
    parts = s.split(" ")
    if len(parts) >= 4:
        if parts[0].startswith("Linux") and "cpx" in parts[3]:
            return True
    return False


def _fetch_ha_problems(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                   ".1.3.6.1.4.1.2620.1.5.13.1"], mutates=False)
    if res.rc != 0 or len(res.stdout) == 0:
        return None
    rows = {}
    order = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        col = _oid_col(oid, ".1.3.6.1.4.1.2620.1.5.13.1")
        idx = _oid_index(oid, ".1.3.6.1.4.1.2620.1.5.13.1")
        if idx == None:
            continue
        key = idx
        if not rows.get(key):
            rows[key] = ["", "", ""]
            order.append(key)
        if col == 2:
            rows[key][0] = val
        elif col == 3:
            rows[key][1] = val
        elif col == 6:
            rows[key][2] = val
    result = []
    for key in order:
        row = rows[key]
        if len(row[0]) > 0:
            result.append(row)
    return result


def _oid_col(oid, base):
    suffix = oid[len(base) + 1:]
    dot = suffix.find(".")
    if dot == -1:
        return int(suffix) if suffix.isdigit() else None
    first = suffix[:dot]
    return int(first) if first.isdigit() else None


def _oid_index(oid, base):
    suffix = oid[len(base) + 1:]
    dot = suffix.find(".")
    if dot == -1:
        return None
    return suffix[dot + 1:]