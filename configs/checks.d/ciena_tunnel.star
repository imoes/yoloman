def main(ctx, params):
    oper_map = {"1": "enabled", "2": "disabled"}

    def detect_ciena(host, community):
        sysoid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        sysdesc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysoid.rc != 0 or sysdesc.rc != 0:
            return None
        so = sysoid.stdout.strip()
        sd = sysdesc.stdout.strip()
        is_ciena = so.startswith(".1.3.6.1.4.1.1271.1.2.11") or so.startswith(".1.3.6.1.4.1.6141.1.96")
        if not is_ciena:
            return None
        if "5171" in sd:
            return "5171"
        if "5142" in sd:
            return "5142"
        return None

    def walk_snmp(base, community, host):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
            mutates=False,
        )
        rows = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            oid = sp[0]
            val = sp[1]
            if oid.startswith(base + "."):
                idx = oid[len(base) + 1:]
            elif oid == base:
                idx = ""
            else:
                idx = oid[len(base):].lstrip(".")
            rows.append((idx, val))
        return rows

    def get_oper_col(model):
        if model == "5171":
            return "7"
        return "4"

    def get_base(model):
        if model == "5171":
            return ".1.3.6.1.4.1.1271.2.1.18.1.2.2.1"
        return ".1.3.6.1.4.1.1271.2.1.18.1.2.6.1"

    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        model = detect_ciena(host, community)
        if model == None:
            return {"changed": False, "msg": "no Ciena device detected", "data": {"discovery": []}}

        base = get_base(model)
        oper_col = get_oper_col(model)
        name_col = "2"

        name_rows = walk_snmp(base + "." + name_col, community, host)
        if len(name_rows) == 0:
            return {"changed": False, "msg": "no Ciena tunnels discovered", "data": {"discovery": []}}

        discovery = []
        for idx, name_val in name_rows:
            if name_val.strip() == "":
                continue
            oper_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oper_col + "." + idx],
                mutates=False,
            )
            oper_val = oper_res.stdout.strip().strip('"') if oper_res.rc == 0 else ""
            if oper_val == "":
                continue
            state_name = oper_map.get(oper_val)
            if state_name == None:
                continue
            discovery.append({
                "item": name_val.strip('"'),
                "params": {"discovered_oper_state": state_name},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d tunnels" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    discovered_state = params.get("discovered_oper_state", "")

    model = detect_ciena(host, community)
    if model == None:
        return {
            "changed": False,
            "msg": "no Ciena device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base = get_base(model)
    oper_col = get_oper_col(model)
    name_col = "2"

    name_rows = walk_snmp(base + "." + name_col, community, host)
    found_idx = None
    for idx, val in name_rows:
        if val.strip('"') == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "tunnel not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oper_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oper_col + "." + found_idx],
        mutates=False,
    )
    if oper_res.rc != 0:
        return {
            "changed": False,
            "msg": "cannot fetch oper state for tunnel: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oper_val = oper_res.stdout.strip().strip('"')
    current_state = oper_map.get(oper_val)
    if current_state == None:
        return {
            "changed": False,
            "msg": "unknown oper state value: " + oper_val,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if current_state == discovered_state:
        state = "OK"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "Tunnel is %s" % current_state,
        "data": {"state": state, "metrics": {}, "details": ""},
    }