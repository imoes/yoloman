# cisco_temp starlark check module
# Maps the Checkmk cisco_temp check plugin to SNMP OIDs.

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: walk the ciscoTempSensorTable columns via SNMP.
    # base = .1.3.6.1.4.1.9.9.13.1.3.1
    # col 2 = ciscoTempSensorName (STRING)
    # col 6 = ciscoTempSensorState  (INTEGER)
    name_base = ".1.3.6.1.4.1.9.9.13.1.3.1.2"
    state_base = ".1.3.6.1.4.1.9.9.13.1.3.1.6"

    if params.get("_discover"):
        res_n = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, name_base], mutates=False)
        if res_n.rc != 0:
            return {"changed": False, "msg": "no cisco_temp sensors found", "data": {"discovery": [], "details": ""}}
        names = {}
        for line in res_n.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            idx = oid[len(name_base) + 1:]
            names[idx] = line[sp + 1:].strip().strip('"')
        res_s = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_base], mutates=False)
        states_by_idx = {}
        if res_s.rc == 0:
            for line in res_s.stdout.splitlines():
                sp = line.find(" ")
                if sp < 0:
                    continue
                oid = line[:sp]
                idx = oid[len(state_base) + 1:]
                states_by_idx[idx] = line[sp + 1:].strip()
        if len(names) == 0:
            return {"changed": False, "msg": "no cisco_temp sensors found", "data": {"discovery": [], "details": ""}}
        discovery = []
        for idx in names.keys():
            if states_by_idx.get(idx, "5") != "5":
                discovery.append({"item": names[idx], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery, "details": ""}}

    item = params.get("item", "")
    res_n = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, name_base], mutates=False)
    if res_n.rc != 0:
        return {"changed": False, "msg": "no cisco_temp sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    names = {}
    for line in res_n.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        idx = oid[len(name_base) + 1:]
        names[idx] = line[sp + 1:].strip().strip('"')
    states_by_idx = {}
    res_s = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_base], mutates=False)
    if res_s.rc == 0:
        for line in res_s.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            idx = oid[len(state_base) + 1:]
            states_by_idx[idx] = line[sp + 1:].strip()
    found_idx = None
    for idx in names.keys():
        if names[idx] == item:
            found_idx = idx
            break
    if found_idx == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dev_state = states_by_idx.get(found_idx, "5")
    if dev_state == "1":
        msg = "Status: OK"
        st = "OK"
    elif dev_state == "2":
        msg = "Status: warning"
        st = "WARN"
    elif dev_state == "3":
        msg = "Status: critical"
        st = "CRIT"
    elif dev_state == "4":
        msg = "Status: shutdown"
        st = "CRIT"
    elif dev_state == "5":
        msg = "Status: not present"
        st = "UNKNOWN"
    elif dev_state == "6":
        msg = "Status: value out of range"
        st = "UNKNOWN"
    else:
        msg = "Status: unknown[" + dev_state + "]"
        st = "UNKNOWN"
    return {"changed": False, "msg": item + " " + msg,
            "data": {"state": st, "metrics": {}, "details": ""}}