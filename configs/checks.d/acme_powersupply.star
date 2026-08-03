def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysOID.rc != 0 or not sysOID.stdout:
            return {"changed": False, "msg": "not an ACME device",
                    "data": {"discovery": []}}
        if not sysOID.stdout.startswith(".1.3.6.1.4.1.9148"):
            return {"changed": False, "msg": "not an ACME device",
                    "data": {"discovery": []}}
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.9148.3.3.1.5.1.1"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no power supply data",
                    "data": {"discovery": []}}
        col3 = {}
        col4 = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            suffix = oid[len(".1.3.6.1.4.1.9148.3.3.1.5.1.1") + 1:]
            parts = suffix.split(".")
            if len(parts) != 2:
                continue
            col = parts[0]
            idx = parts[1]
            if col == "3":
                col3[idx] = val
            elif col == "4":
                col4[idx] = val
        out = []
        for idx in col3:
            if idx in col4 and col4[idx] != "7":
                out.append({"item": col3[idx], "params": {},
                            "metrics": [], "service_labels": {"acme/envmon_index": idx}})
        return {"changed": False,
                "msg": "discovered %d power supplies" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.9148.3.3.1.5.1.1"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no power supply data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    col3 = {}
    col4 = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        suffix = oid[len(".1.3.6.1.4.1.9148.3.3.1.5.1.1") + 1:]
        parts = suffix.split(".")
        if len(parts) != 2:
            continue
        col = parts[0]
        idx = parts[1]
        if col == "3":
            col3[idx] = val
        elif col == "4":
            col4[idx] = val
    found_idx = None
    for idx in col3:
        if col3[idx] == item:
            found_idx = idx
            break
    if found_idx == None or found_idx not in col4:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = col4[found_idx]
    readable = _STATE_MAP.get(state, "unknown")
    dev_state = _STATE_MAP_STATUS.get(state, "UNKNOWN")
    if state == "7":
        dev_state = "CRIT"
        readable = "not present"
    return {"changed": False,
            "msg": "Status: " + readable,
            "data": {"state": dev_state, "metrics": {},
                     "details": "Power supply: %s" % item}}

_STATE_MAP = {
    "1": "initial",
    "2": "normal",
    "3": "minor",
    "4": "major",
    "5": "critical",
    "6": "shutdown",
    "7": "not present",
    "8": "not functioning",
    "9": "unknown",
}

_STATE_MAP_STATUS = {
    "1": "OK",
    "2": "OK",
    "3": "WARN",
    "4": "WARN",
    "5": "CRIT",
    "6": "CRIT",
    "7": "CRIT",
    "8": "CRIT",
    "9": "CRIT",
}