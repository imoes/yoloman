def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Probe for Supermicro hardware via sysObjectID and product name
    sys_obj_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    sys_oid = ""
    if sys_obj_res.rc == 0:
        sys_oid = sys_obj_res.stdout.strip()

    sys_descr_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    sys_descr = ""
    if sys_descr_res.rc == 0:
        sys_descr = sys_descr_res.stdout.strip()

    # DECTECT_SUPERMICRO: sysObjectID is Supermicro OR (linux-based AND smart OID exists)
    is_supermicro_sys = sys_oid == ".1.3.6.1.4.1.10876.2"
    is_linux = sys_descr != "" and sys_descr.find("Linux") != -1
    smart_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10876.100.1.4.1.1.1"],
        mutates=False,
    )
    smart_exists = smart_oid_res.rc == 0 and smart_oid_res.stdout.strip() != ""

    if not is_supermicro_sys and not (is_linux and smart_exists):
        return {
            "changed": False,
            "msg": "Supermicro hardware not detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        # Walk the SMART table: base .1.3.6.1.4.1.10876.100.1.4.1
        # columns: 1=serial, 2=name, 4=status
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.10876.100.1.4.1.1"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 smart devices", "data": {"discovery": []}}

        names = {}
        serials = {}
        statuses = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            # oid like .1.3.6.1.4.1.10876.100.1.4.1.1.<col>.<idx>
            parts = oid.split(".")
            if len(parts) < 2:
                continue
            col = parts[-2]
            idx = parts[-1]
            if col == "2":
                names[idx] = val
            elif col == "1":
                serials[idx] = val
            elif col == "4":
                statuses[idx] = val

        discovery = []
        for idx, name in names.items():
            serial = serials.get(idx, "")
            status = statuses.get(idx, "0")
            fmt = name.replace(r"\\\\.\\", "")
            discovery.append({
                "item": fmt,
                "params": {"serial": serial, "status": status},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d smart devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    # Fetch serial, name, status for the matching item by walking the table
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.10876.100.1.4.1.1"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "no SMART data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    names = {}
    serials = {}
    statuses = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        parts = oid.split(".")
        if len(parts) < 2:
            continue
        col = parts[-2]
        idx = parts[-1]
        if col == "2":
            names[idx] = val
        elif col == "1":
            serials[idx] = val
        elif col == "4":
            statuses[idx] = val

    found_idx = None
    for idx, name in names.items():
        fmt = name.replace(r"\\\\.\\", "")
        if fmt == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "no such SMART device: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    serial = serials.get(found_idx, "")
    status = statuses.get(found_idx, "0")
    label_map = {"0": "Healthy", "1": "Warning", "2": "Critical", "3": "Unknown"}
    state_map = {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN"}
    state = state_map.get(status, "UNKNOWN")
    label = label_map.get(status, "Unknown")
    summary = "(S/N %s) %s" % (serial, label)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }