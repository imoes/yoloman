def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe for SNMP availability (rc==127 => not installed)
        have = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                        "1.3.6.1.2.1.31.1.1.1.1.1"], mutates=False)
        if have.rc == 127 or (have.rc != 0 and not have.stdout):
            return {"changed": False, "msg": "snmp not available",
                    "data": {"discovery": []}}

        # Walk ifName (.1.3.6.1.2.1.31.1.1.1.1) to get interface indexes
        names_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                             "1.3.6.1.2.1.31.1.1.1.1"], mutates=False)
        if names_res.rc != 0 or not names_res.stdout:
            return {"changed": False, "msg": "no interfaces discovered",
                    "data": {"discovery": []}}

        items = []
        for line in names_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            name = parts[1]
            idx = oid[len("1.3.6.1.2.1.31.1.1.1.1") + 1:]
            if idx == "" or idx == "0":
                continue
            items.append({"item": name, "params": {"warn": 90, "crit": 95},
                          "metrics": ["if_in_octets", "if_out_octets"]})

        return {"changed": False,
                "msg": "discovered %d interfaces" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Find the interface index by walking ifName
    names_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                         "1.3.6.1.2.1.31.1.1.1.1"], mutates=False)
    if names_res.rc != 0 or not names_res.stdout:
        return {"changed": False, "msg": "no interfaces found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = None
    for line in names_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2 or parts[1] != item:
            continue
        idx = parts[0][len("1.3.6.1.2.1.31.1.1.1.1") + 1:]
        if idx == "" or idx == "0":
            continue
        break

    if not idx:
        return {"changed": False, "msg": "interface not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read counters: ifHCInOctets (.1), ifHCOutOctets (.10)
    in_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                      "1.3.6.1.2.1.31.1.1.1.6." + idx], mutates=False)
    out_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                       "1.3.6.1.2.1.31.1.1.1.10." + idx], mutates=False)

    if in_res.rc != 0 or out_res.rc != 0:
        return {"changed": False, "msg": "failed to read counters for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    in_oct = int(in_res.stdout) if in_res.stdout.isdigit() else 0
    out_oct = int(out_res.stdout) if out_res.stdout.isdigit() else 0

    warn = params.get("warn", 90)
    crit = params.get("crit", 95)
    util = in_oct  # simplified metric
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")

    return {"changed": False,
            "msg": "Interface %s: in=%d out=%d" % (item, in_oct, out_oct),
            "data": {"state": state,
                     "metrics": {"if_in_octets": in_oct, "if_out_octets": out_oct},
                     "details": ""}}