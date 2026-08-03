def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.2334.2.1.5"
        cols = ["12", "14", "22", "24"]
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        sys = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys.rc != 0 or sys.stdout == "":
            return {"changed": False, "msg": "packeteer not present", "data": {"discovery": []}}

        out = []
        for i, col in enumerate(cols):
            oid = base + "." + col
            res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
            if res.rc == 0 and res.stdout != "":
                val = res.stdout.strip()
                if val == "1" or val == "2":
                    out.append({"item": str(i), "params": {"warn": 1, "crit": 2},
                                "metrics": []})
        return {"changed": False, "msg": "discovered %d fans" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.2334.2.1.5"
    cols = ["12", "14", "22", "24"]
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if item == "" or not item.isdigit() or int(item) >= len(cols):
        return {"changed": False, "msg": "invalid item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oid = base + "." + cols[int(item)]
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = res.stdout.strip()
    if val == "1":
        return {"changed": False, "msg": "OK", "data": {"state": "OK", "metrics": {}, "details": ""}}
    if val == "2":
        return {"changed": False, "msg": "Not OK", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if val == "3":
        return {"changed": False, "msg": "Not present", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "unknown status %s" % val,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}