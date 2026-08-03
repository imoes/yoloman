def main(ctx, params):
    # Non-breaking space (U+00A0) as used throughout the Checkmk source
    NBSP = "\u00a0"

    if params.get("_discover"):
        sysOID = ".1.3.6.1.2.1.1.2.0"
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", "-On", params.get("host", "localhost"), sysOID],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no SNMP response from host",
                    "data": {"discovery": []}}
        sysOIDVal = res.stdout.strip()
        supported = [
            ".1.3.6.1.4.1.211.1.21.1.60",
            ".1.3.6.1.4.1.211.1.21.1.100",
            ".1.3.6.1.4.1.211.1.21.1.101",
        ]
        if sysOIDVal not in supported:
            return {"changed": False, "msg": "not a supported FJDARY-E device",
                    "data": {"discovery": []}}

        baseOID = sysOIDVal + ".3.4.2.1"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), baseOID],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RLUN table data",
                    "data": {"discovery": []}}

        discovery = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            index = oid[len(baseOID) + 1:]
            if len(val) < 4:
                continue
            if val[3] == NBSP:
                discovery.append({"item": index, "params": {},
                                  "metrics": []})

        return {"changed": False, "msg": "discovered %d RLUNs" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    sysOID = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-On", params.get("host", "localhost"), sysOID],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no SNMP response from host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysOIDVal = res.stdout.strip()
    supported = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.100",
        ".1.3.6.1.4.1.211.1.21.1.101",
    ]
    if sysOIDVal not in supported:
        return {"changed": False, "msg": "not a supported FJDARY-E device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    baseOID = sysOIDVal + ".3.4.2.1"
    resGet = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-On", params.get("host", "localhost"),
         baseOID + "." + item + ".1", baseOID + "." + item + ".2"],
        mutates=False,
    )
    if resGet.rc != 0:
        return {"changed": False, "msg": "no RLUN data for index " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = resGet.stdout.splitlines()
    rawVal = ""
    for ln in lines:
        parts = ln.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        if oid.endswith(".2"):
            rawVal = val

    if len(rawVal) < 4:
        return {"changed": False, "msg": "RLUN data too short for index " + item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if rawVal[3] != NBSP:
        return {"changed": False, "msg": "RLUN %s is not present" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    mapping = {
        "\x08": {"state": "WARN", "summary": "RLUN is rebuilding"},
        "\x07": {"state": "WARN", "summary": "RLUN copyback in progress"},
        "A": {"state": "WARN", "summary": "RLUN spare is in use"},
        "B": {"state": "OK", "summary": "RLUN is in RAID0 state"},
        "\x00": {"state": "OK", "summary": "RLUN is in normal state"},
    }
    stateChar = rawVal[2]
    entry = mapping.get(stateChar, {"state": "CRIT", "summary": "RLUN in unknown state"})

    return {"changed": False, "msg": "RLUN %s: %s" % (item, entry["summary"]),
            "data": {"state": entry["state"], "metrics": {}, "details": ""}}