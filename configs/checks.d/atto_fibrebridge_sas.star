def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        sys_oid = res.stdout.strip()
        if res.rc == 127 or res.rc != 0 or not sys_oid.startswith(".1.3.6.1.4.1.4547"):
            return {"changed": False, "msg": "not an Atto Fibrebridge", "data": {"discovery": []}}
        walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.4547.2.3.3.3.1"], mutates=False)
        discovery = []
        indices = {}
        for line in walk.stdout.splitlines():
            oid_val = line.split(" ", 1)
            if len(oid_val) < 2:
                continue
            oid = oid_val[0]
            rest = oid[len(".1.3.6.1.4.1.4547.2.3.3.3.1"):]
            parts = rest.split(".")
            if len(parts) < 2:
                continue
            col = parts[1]
            idx = parts[2]
            indices[idx] = True
        for idx in indices:
            base = ".1.3.6.1.4.1.4547.2.3.3.3.1"
            cols = {}
            ok = True
            for col_idx, col_name in enumerate(["2", "3", "4", "5", "6", "7", "8"]):
                g = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + "." + col_name + "." + idx], mutates=False)
                if g.rc != 0:
                    ok = False
                    break
                cols[col_idx] = g.stdout.strip()
            if not ok:
                continue
            sas_adminstates = {-1: "unknown", 1: "disabled", 2: "enabled"}
            admin_val = cols[6]
            if not admin_val.lstrip("-").isdigit():
                continue
            admin_int = int(admin_val)
            if sas_adminstates.get(admin_int, "unknown") != "enabled":
                continue
            discovery.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.4547.2.3.3.3.1"
    cols = {}
    for col_idx, col_name in enumerate(["2", "3", "4", "5", "6", "7", "8"]):
        g = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + "." + col_name + "." + item], mutates=False)
        if g.rc != 0:
            return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        cols[col_idx] = g.stdout.strip()

    phy_operstates = {-1: "unknown", 1: "online", 2: "offline"}
    sas_operstates = {-1: "unknown", 1: "online", 2: "offline", 3: "degraded"}
    sas_adminstates = {-1: "unknown", 1: "disabled", 2: "enabled"}
    operstate_severities = {"unknown": "UNKNOWN", "online": "OK", "degraded": "WARN", "offline": "CRIT"}

    oper_val = cols[1]
    admin_val = cols[6]
    if not oper_val.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid oper state value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not admin_val.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid admin state value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oper_state = sas_operstates.get(int(oper_val), "unknown")
    state = operstate_severities.get(oper_state, "UNKNOWN")
    msg = "Operational state: " + oper_state

    details = []
    for phy_index in range(1, 5):
        phy_raw = cols[phy_index + 1]
        phy_val_int = int(phy_raw) if phy_raw.lstrip("-").isdigit() else -1
        phy_val = phy_operstates.get(phy_val_int, "unknown")
        details.append("PHY%d operational state: %s" % (phy_index, phy_val))

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": ", ".join(details)}}