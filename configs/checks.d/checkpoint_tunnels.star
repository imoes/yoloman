def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.2620.500.9002.1"
    cols = ["2", "3"]

    def _snmpget(oid):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return None
        return res.stdout.strip()

    def _detect():
        sys_oid = _snmpget(".1.3.6.1.2.1.1.2.0")
        sys_desc = _snmpget(".1.3.6.1.2.1.1.1.0")
        fw = _snmpget(".1.3.6.1.4.1.2620.1.1.21.0")
        gaia = _snmpget(".1.3.6.1.4.1.2620.1.6.5.1.0")
        ok1 = (
            (sys_oid != None and sys_oid.startswith(".1.3.6.1.4.1.2620"))
            or (sys_desc != None and " cp" in sys_desc.split(" ", 3)[:4])
            or (sys_desc != None and sys_desc.startswith("IPSO "))
            or (sys_desc != None and sys_desc.startswith("Linux") and "cpx" in sys_desc)
        )
        ok2 = (
            (fw != None and fw.startswith("firewall"))
            or (gaia != None and gaia == "Gaia")
        )
        return ok1 and ok2

    def _walk_col(col):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + col],
            mutates=False,
        )
        rows = []
        if res.rc != 0 or not res.stdout:
            return rows
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(base + "." + col) + 1:]
            if idx == "":
                continue
            rows.append((idx, val))
        return rows

    if params.get("_discover"):
        peer_res = _snmpget(base + "." + "2")
        if peer_res == None and not _walk_col("2"):
            return {"changed": False, "msg": "no checkpoint device", "data": {"discovery": []}}
        rows2 = _walk_col("2")
        rows3 = _walk_col("3")
        by_idx = {}
        for idx, peer in rows2:
            by_idx[idx] = [peer, None]
        for idx, status in rows3:
            if idx in by_idx:
                by_idx[idx][1] = status
            else:
                by_idx[idx] = [None, status]
        discovery = []
        for idx, (peer, status) in by_idx.items():
            if peer == None or peer == "":
                continue
            discovery.append({"item": peer, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d tunnels" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if not _detect():
        return {
            "changed": False,
            "msg": "not a checkpoint device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows2 = _walk_col("2")
    rows3 = _walk_col("3")
    by_idx = {}
    for idx, peer in rows2:
        by_idx[idx] = [peer, None]
    for idx, status in rows3:
        if idx in by_idx:
            by_idx[idx][1] = status
        else:
            by_idx[idx] = [None, status]

    peer_val = None
    status_val = None
    for idx, (peer, status) in by_idx.items():
        if peer == item:
            peer_val = peer
            status_val = status
            break

    if peer_val == None or status_val == None:
        return {
            "changed": False,
            "msg": "no such tunnel: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_name = TUNNEL_STATES.get(status_val)
    if state_name == None:
        return {
            "changed": False,
            "msg": "Unknown tunnel status: " + str(status_val),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = {
        "Active": 0,
        "Destroy": 1,
        "Idle": 0,
        "Phase1": 2,
        "Init": 1,
        "Down": 2,
    }
    level = params.get(state_name, levels.get(state_name, 0))

    if level == 0:
        state = "OK"
    elif level == 1:
        state = "WARN"
    elif level == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": state_name,
        "data": {"state": state, "metrics": {}, "details": ""},
    }

TUNNEL_STATES = {
    "3": "Active",
    "4": "Destroy",
    "129": "Idle",
    "130": "Phase1",
    "131": "Down",
    "132": "Init",
}