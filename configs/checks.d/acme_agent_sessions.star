def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.2.1.2.2.1"], mutates=False)
        discovery = []
        for line in res.stdout.splitlines():
            if ".22" not in line:
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            # Extract index from OID: .1.3.6.1.4.1.9148.3.2.1.2.2.1.<index>.22
            parts_oid = oid.split(".")
            if len(parts_oid) < 10:
                continue
            index = parts_oid[-2]
            item = index
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d agent sessions" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    map_states = {
        "0": (0, "disabled"),
        "1": (2, "out of service"),
        "2": (0, "standby"),
        "3": (0, "in service"),
        "4": (1, "contraints violation"),
        "5": (1, "in service timed out"),
        "6": (1, "oos provisioned response"),
    }

    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost",
                   ".1.3.6.1.4.1.9148.3.2.1.2.2.1.%s.22" % item], mutates=False)
    if res.rc != 0 or "No Such Object" in res.stdout or "No Such Instance" in res.stdout:
        return {"changed": False, "msg": "no agent session found for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    line = res.stdout.strip()
    if "=" in line:
        value_str = line.split("=")[-1].strip()
        state_str = value_str.split(":")[-1].strip() if ":" in value_str else value_str
    else:
        return {"changed": False, "msg": "cannot parse snmpget output: " + res.stdout,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_int = state_str if state_str.isdigit() else "-1"
    dev_state, dev_state_readable = map_states.get(state_str, (1, "unknown"))
    state_name = "CRIT" if dev_state == 2 else ("WARN" if dev_state == 1 else "OK")
    return {"changed": False, "msg": "Status: %s" % dev_state_readable,
            "data": {"state": state_name, "metrics": {}, "details": ""}}
