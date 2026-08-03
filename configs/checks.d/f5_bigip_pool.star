def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect real F5 BIG-IP first.
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host,
         ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid_res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"discovery": []}}
    sysid = ""
    if sysid_res.rc == 0:
        parts = sysid_res.stdout.strip().split()
        if len(parts) >= 1:
            sysid = parts[0]
    if not sysid or "3375.2" not in sysid:
        if params.get("_discover"):
            return {"changed": False, "msg": "no F5 BIG-IP detected",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no F5 BIG-IP detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    pool_tree_base = ".1.3.6.1.4.1.3375.2.2.5.1.2.1"
    member_tree_base = ".1.3.6.1.4.1.3375.2.2.5.3.2.1"

    def walk_col(base, col):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqv", host,
             base + "." + col], mutates=False)
        if res.rc != 0 or not res.stdout:
            return []
        lines = res.stdout.strip().splitlines()
        out = []
        for ln in lines:
            out.append(ln.strip())
        return out

    def walk_col_oqn(base, col):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqv", host,
             base + "." + col], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {}
        d = {}
        for ln in res.stdout.strip().splitlines():
            sp = ln.strip().split(" ", 1)
            if len(sp) != 2:
                continue
            oid, val = sp
            idx = oid[len(base + "." + col) + 1:]
            d[idx] = val
        return d

    def discover():
        names = walk_col(pool_tree_base, "1")
        active = walk_col(pool_tree_base, "8")
        defined = walk_col(pool_tree_base, "23")
        pools = []
        for i in range(len(names)):
            nm = names[i] if i < len(names) else ""
            am = active[i] if i < len(active) else "0"
            dm = defined[i] if i < len(defined) else "0"
            pools.append({"name": nm, "active": am, "defined": dm})
        out = []
        for p in pools:
            pools_lower = params.get("levels_lower", [2, 1])
            if type(pools_lower) == "tuple":
                pools_lower = list(pools_lower)
            warn_n = pools_lower[0] if len(pools_lower) > 0 else 2
            crit_n = pools_lower[1] if len(pools_lower) > 1 else 1
            out.append({
                "item": p["name"],
                "params": {"levels_lower": [warn_n, crit_n]},
                "metrics": ["members_up"],
            })
        return out

    if params.get("_discover"):
        out = discover()
        return {"changed": False,
                "msg": "discovered %d pools" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")

    names = walk_col(pool_tree_base, "1")
    active = walk_col(pool_tree_base, "8")
    defined = walk_col(pool_tree_base, "23")
    pools = []
    for i in range(len(names)):
        nm = names[i] if i < len(names) else ""
        am = active[i] if i < len(active) else "0"
        dm = defined[i] if i < len(defined) else "0"
        pools.append({"name": nm, "active": am, "defined": dm})

    pool = None
    for p in pools:
        if p["name"] == item:
            pool = p
            break

    if pool == None:
        return {"changed": False,
                "msg": "pool not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    active_members = 0
    if pool["active"].isdigit():
        active_members = int(pool["active"])
    defined_members = 0
    if pool["defined"].isdigit():
        defined_members = int(pool["defined"])

    members = []
    if active_members < defined_members:
        names_m = walk_col(member_tree_base, "1")
        ports = walk_col(member_tree_base, "4")
        mstates = walk_col(member_tree_base, "10")
        mstatus = walk_col(member_tree_base, "11")
        sstatus = walk_col(member_tree_base, "13")
        nodes = walk_col(member_tree_base, "19")
        idx_map = walk_col_oqn(member_tree_base, "1")
        for idx in idx_map:
            m_pool = idx_map[idx]
            port = ports[i] if False else ""
    # Re-collect member info by walking each column and indexing by index
    m_names = walk_col_oqn(member_tree_base, "1")
    m_ports = walk_col_oqn(member_tree_base, "4")
    m_mstates = walk_col_oqn(member_tree_base, "10")
    m_mstatus = walk_col_oqn(member_tree_base, "11")
    m_sstatus = walk_col_oqn(member_tree_base, "13")
    m_nodes = walk_col_oqn(member_tree_base, "19")

    members_info = []
    for idx in m_names:
        if m_names[idx] != item:
            continue
        members_info.append({
            "port": m_ports.get(idx, ""),
            "monitor_state": m_mstates.get(idx, "0"),
            "monitor_status": m_mstatus.get(idx, "0"),
            "session_status": m_sstatus.get(idx, "0"),
            "node_name": m_nodes.get(idx, ""),
        })

    levels = params.get("levels_lower", [2, 1])
    if type(levels) == "tuple":
        levels = list(levels)
    warn_n = levels[0] if len(levels) > 0 else 2
    crit_n = levels[1] if len(levels) > 1 else 1

    msg = "Members up: %d" % active_members
    if active_members >= defined_members:
        state = "OK"
    else:
        if active_members <= crit_n:
            state = "CRIT"
        elif active_members <= warn_n:
            state = "WARN"
        else:
            state = "OK"

    down_list = ""
    if active_members < defined_members:
        up_states = ("4", "28")
        disabled_states = ("2", "3", "4", "5")
        down = []
        for m in members_info:
            if (str(m["monitor_state"]) not in up_states or
                    str(m["monitor_status"]) not in up_states or
                    str(m["session_status"]) in disabled_states):
                nm = m["node_name"]
                if nm != "" and nm.startswith("/"):
                    parts = nm.split("/")
                    if len(parts) > 2:
                        host_v = parts[2]
                    else:
                        host_v = nm
                else:
                    host_v = nm
                down.append(host_v + ":" + m["port"])
        down_list = ", ".join(down)

    details = ""
    if down_list:
        details = "down/disabled nodes: " + down_list

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"members_up": active_members},
            "details": details,
        },
    }