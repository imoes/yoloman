SCLI_PATHS = [
    "/opt/emc/scaleio/sds/bin/scli",
    "/opt/emc/scaleio/mdm/bin/scli",
    "/usr/local/bin/scli",
    "/usr/bin/scli",
]

SECTION_CANONICAL = {
    "cluster": "Cluster",
    "master mdm": "Master MDM",
    "slave mdms": "Slave MDMs",
    "tie-breakers": "Tie-Breakers",
    "standby mdms": "Standby MDMs",
}

STATUS_MAP = {
    "Normal": 0,
    "Degraded": 1,
    "Error": 2,
    "Disconnected": 2,
    "Not synchronized": 1,
}

def _find_scli(ctx, override):
    if override != "scli":
        return override
    for p in SCLI_PATHS:
        if ctx.file_exists(p):
            return p
    res = ctx.run(["which", "scli"], mutates=False, ok_codes=[0, 1])
    if res.rc == 0 and res.stdout.strip():
        return res.stdout.strip()
    return None

def _add_kv(data, tokens, state):
    for entry in tokens:
        parts = entry.split(": ")
        if len(parts) > 1:
            k = parts[0].strip()
            v = ": ".join(parts[1:]).strip()
            state["k"] = k
            data[k] = v
        else:
            last_k = state.get("k", "")
            if last_k != "":
                existing = data.get(last_k)
                if existing != None:
                    if type(existing) == "list":
                        data[last_k] = existing + [entry.strip().replace(" ", "")]
                    else:
                        data[last_k] = [existing, entry.strip().replace(" ", "")]

def _parse(raw):
    parsed = {}
    cur_id = ""
    cur_node = ""
    kv_state = {"k": ""}
    for raw_line in raw.splitlines():
        tokens = raw_line.split(",")
        if not tokens:
            continue
        first = tokens[0]
        if not first.strip():
            continue
        lookup_key = first.strip().lower().rstrip(":")
        canonical = SECTION_CANONICAL.get(lookup_key)
        if canonical != None:
            cur_id = canonical
            cur_node = ""
            kv_state["k"] = ""
            if cur_id not in parsed:
                parsed[cur_id] = {}
            continue
        if cur_id == "":
            continue
        if cur_id == "Cluster":
            _add_kv(parsed[cur_id], tokens, kv_state)
        elif "name" in first.lower():
            np = first.split(": ")
            if len(np) >= 2:
                cur_node = np[1].strip()
                nd = {}
                if len(tokens) > 1:
                    ip = tokens[1].strip().split(": ")
                    if len(ip) >= 2:
                        nd[ip[0].strip()] = ": ".join(ip[1:]).strip()
                if len(tokens) > 2:
                    nd["Role"] = tokens[2].strip()
                parsed[cur_id][cur_node] = nd
                kv_state["k"] = ""
        elif cur_node != "":
            nd = parsed[cur_id].get(cur_node)
            if nd != None:
                _add_kv(nd, tokens, kv_state)
    return parsed

def _build_cmd(scli, mdm_ip):
    if mdm_ip != "":
        return [scli, "--mdm_ip", mdm_ip, "--query_cluster", "--approve_certificate"]
    return [scli, "--query_cluster", "--approve_certificate"]

def main(ctx, params):
    scli = _find_scli(ctx, params.get("scli_path", "scli"))
    mdm_ip = params.get("mdm_ip", "")

    if params.get("_discover"):
        if scli == None:
            return {"changed": False, "msg": "scli not found", "data": {"discovery": []}}
        res = ctx.run(_build_cmd(scli, mdm_ip), mutates=False, ok_codes=[0])
        if not res.stdout.strip():
            return {"changed": False, "msg": "no data from scli", "data": {"discovery": []}}
        parsed = _parse(res.stdout)
        if parsed.get("Cluster") != None:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["active_nodes", "replica_count"]},
                ]},
            }
        return {"changed": False, "msg": "no cluster found", "data": {"discovery": []}}

    # Check mode
    if scli == None:
        return {
            "changed": False,
            "msg": "scli not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    res = ctx.run(_build_cmd(scli, mdm_ip), mutates=False, ok_codes=[0])
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no output from scli",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _parse(res.stdout)
    cluster = parsed.get("Cluster")
    if cluster == None:
        return {
            "changed": False,
            "msg": "Cluster section not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    overall = 0
    summaries = []

    status = cluster.get("State", "Unknown")
    cs = STATUS_MAP.get(status, 2)
    if cs > overall:
        overall = cs
    mode = cluster.get("Mode", "unknown")
    summaries.append("Mode: %s, State: %s" % (mode, status))

    active_str = cluster.get("Active", "0/0")
    replicas_str = cluster.get("Replicas", "0/0")
    ap = active_str.split("/")
    rp = replicas_str.split("/")

    ar_state = 0
    if len(ap) == 2 and ap[0] != ap[1]:
        ar_state = 2
    if len(rp) == 2 and rp[0] != rp[1]:
        if ar_state < 2:
            ar_state = 2
    if ar_state > overall:
        overall = ar_state
    summaries.append("Active: %s, Replicas: %s" % (active_str, replicas_str))

    active_val = int(ap[0]) if (len(ap) > 0 and ap[0].strip().isdigit()) else 0
    replica_val = int(rp[0]) if (len(rp) > 0 and rp[0].strip().isdigit()) else 0
    metrics = {"active_nodes": active_val, "replica_count": replica_val}

    for role in ["Master MDM", "Slave MDMs", "Tie-Breakers", "Standby MDMs"]:
        role_data = parsed.get(role, {})
        rs = 0
        nodes = sorted(role_data.keys())
        for node in nodes:
            ni = role_data[node]
            ns_str = ni.get("Status", "Normal") if type(ni) == "dict" else "Normal"
            ns = STATUS_MAP.get(ns_str, 0)
            if ns > rs:
                rs = ns
        if nodes:
            infotext = "%s: %s" % (role, ", ".join(nodes))
        elif role != "Standby MDMs":
            rs = 2
            infotext = "%s not found in agent output" % role
        else:
            infotext = "%s: no" % role
        if rs > overall:
            overall = rs
        summaries.append(infotext)

    state_names = ["OK", "WARN", "CRIT"]
    final_state = state_names[overall] if overall < 3 else "CRIT"

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {"state": final_state, "metrics": metrics, "details": ""},
    }