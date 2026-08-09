def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.9.9.500.1.3.2.1"
    sys_oid = ".1.3.6.1.2.1.1.2.0"

    # Detect Cisco device via sysObjectID prefix
    sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid], mutates=False)
    if sys_res.rc != 0 and sys_res.rc != 127:
        pass
    if sys_res.rc == 127 or not sys_res.stdout.strip():
        return {"changed": False, "msg": "snmp not available / host unreachable", "data": {"discovery": []} if params.get("_discover") else {"state": "UNKNOWN", "metrics": {}, "details": "no SNMP connectivity"}}
    sys_val = sys_res.stdout.strip()
    if not sys_val.startswith(".1.3.6.1.4.1.9.1.516"):
        return {"changed": False, "msg": "not a Cisco StackPower device", "data": {"discovery": []} if params.get("_discover") else {"state": "UNKNOWN", "metrics": {}, "details": "host is not a Cisco device with StackPower"}}

    # Walk columns: 2 (oper), 5 (link), 7 (port name), indexed by OIDEnd
    def walk_col(col):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + "." + col], mutates=False)
        rows = []
        if res.rc == 0 and res.stdout.strip():
            for line in res.stdout.splitlines():
                sp = line.strip().split(" ", 1)
                if len(sp) < 2:
                    continue
                oid = sp[0]
                val = sp[1].strip()
                idx = oid[len(base_oid) + 1:]
                rows.append((idx, val))
        return rows

    oper_rows = walk_col("2")
    link_rows = walk_col("5")
    name_rows = walk_col("7")

    # Build index -> (oper, link, name)
    by_idx = {}
    for idx, v in oper_rows:
        by_idx[idx] = {"oper": v, "link": "", "name": ""}
    for idx, v in link_rows:
        if idx in by_idx:
            by_idx[idx]["link"] = v
        else:
            by_idx[idx] = {"oper": "", "link": v, "name": ""}
    for idx, v in name_rows:
        if idx in by_idx:
            by_idx[idx]["name"] = v
        else:
            by_idx[idx] = {"oper": "", "link": "", "name": v}

    # The index format is like "1001.0" -> we need split(".")[0] as in the check
    entries = []
    for idx, data in sorted(by_idx.items()):
        if not data["name"]:
            continue
        if data["oper"] != "1":
            continue
        part = idx.split(".")[0]
        item = "%s %s" % (part, data["name"])
        entries.append((item, data))

    if params.get("_discover"):
        discovery = []
        for item, data in entries:
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    map_oper_status = {
        "1": "OK",
        "2": "CRIT",
    }
    map_status = {
        "1": "OK",
        "2": "CRIT",
    }

    found = None
    for it, data in entries:
        if it == item:
            found = data
            break

    if found == None:
        return {"changed": False, "msg": "no such StackPower interface: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "interface %s not found on device" % item}}

    oper = found["oper"]
    link = found["link"]

    oper_state = map_oper_status.get(oper, "UNKNOWN")
    if oper_state == "OK":
        oper_msg = "Port enabled"
    elif oper_state == "CRIT":
        oper_msg = "Port disabled"
    else:
        oper_msg = "Port oper status unknown"

    link_state = map_status.get(link, "UNKNOWN")
    if link_state == "OK":
        link_msg = "Status: connected and operational"
    elif link_state == "CRIT":
        link_msg = "Status: forced down or not connected"
    else:
        link_msg = "Status unknown"

    if oper_state == "CRIT" or link_state == "CRIT":
        state = "CRIT"
    elif oper_state == "UNKNOWN" or link_state == "UNKNOWN":
        state = "UNKNOWN"
    else:
        state = "OK"

    msg = oper_msg + "; " + link_msg
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": msg + " (item: %s)" % item}}