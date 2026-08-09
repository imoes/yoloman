def main(ctx, params):
    if params.get("_discover"):
        sysid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                        mutates=False)
        if sysid.rc != 0:
            return {"changed": False, "msg": "no snmp response", "data": {"discovery": []}}
        sysid_val = sysid.stdout.strip()
        if not sysid_val.startswith(".1.3.6.1.4.1.6486.800"):
            return {"changed": False, "msg": "not an Alcatel device", "data": {"discovery": []}}

        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1"],
                           mutates=False)
        if walk_res.rc != 0:
            return {"changed": False, "msg": "no power supply data", "data": {"discovery": []}}

        column_base = ".1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1"
        status_map = {
            "1": "up", "2": "down", "3": "testing", "4": "unknown",
            "5": "secondary", "6": "not present", "7": "unpowered", "9": "master",
        }
        type_map = {"0": "no power supply", "1": "AC", "2": "DC"}

        entries = {}
        for line in walk_res.stdout.splitlines():
            sp = line.split(None, 1)
            if len(sp) < 2:
                continue
            oid, val = sp[0], sp[1]
            idx = oid[len(column_base) + 1:]
            if idx == "" or idx.startswith("."):
                continue
            if idx not in entries:
                entries[idx] = {"status": None, "ptype": None}
            if oid.endswith(".2"):
                entries[idx]["status"] = val.strip()
            elif oid.endswith(".36"):
                entries[idx]["ptype"] = val.strip()

        discovery = []
        for idx in entries:
            e = entries[idx]
            if e["status"] == None or e["ptype"] == None:
                continue
            oper = status_map.get(e["status"], "unknown[%s]" % e["status"])
            ptype = type_map.get(e["ptype"], "no power supply")
            if ptype == "no power supply" or oper == "not present":
                continue
            discovery.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    column_base = ".1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1"
    comm = params.get("community", "public")
    host = params.get("host", "localhost")

    status_res = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host,
                          column_base + "." + item + ".2"], mutates=False)
    type_res = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host,
                        column_base + "." + item + ".36"], mutates=False)

    if status_res.rc != 0 or type_res.rc != 0:
        return {"changed": False, "msg": "item not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_map = {
        "1": "up", "2": "down", "3": "testing", "4": "unknown",
        "5": "secondary", "6": "not present", "7": "unpowered", "9": "master",
    }
    type_map = {"0": "no power supply", "1": "AC", "2": "DC"}

    oper = status_map.get(status_res.stdout.strip(), "unknown[%s]" % status_res.stdout.strip())
    ptype = type_map.get(type_res.stdout.strip(), "no power supply")

    state = "OK" if oper == "up" else "CRIT"
    return {"changed": False,
            "msg": "[%s] Operational status: %s" % (ptype, oper),
            "data": {"state": state, "metrics": {}, "details": ""}}