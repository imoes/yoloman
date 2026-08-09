def _parse_status_map():
    return {
        "Normal": 0,
        "Degraded": 1,
        "Error": 2,
        "Disconnected": 2,
        "Not synchronized": 1,
    }

def _add_key_values(data_dict, tokens):
    name = ""
    for token in tokens:
        if len(token) > 1:
            name = token[0].strip()
            data_dict[name] = token[1].strip()
        else:
            cur = data_dict.get(name)
            if type(cur) != "list":
                data_dict[name] = [cur]
            data_dict[name].append(token[0].replace(" ", ""))

def _parse_section(text):
    parsed = {}
    id_ = ""
    node = ""
    data = {}
    lines = text.split("\n")
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        tokens = line.split(":")
        first = tokens[0].strip()
        if len(tokens) >= 2:
            parts = line.split(": ", 1)
            first_key = parts[0].strip()
        else:
            parts = [first, ""]
            first_key = first
        lowered = first_key.lower()
        if lowered == "cluster:":
            id_ = "Cluster"
            data = parsed.setdefault(id_, {})
            rest = parts[1].split(", ") if len(parts) > 1 else []
            for kv in rest:
                kv_parts = kv.split(": ", 1)
                if len(kv_parts) == 2:
                    data[kv_parts[0].strip()] = kv_parts[1].strip()
            continue
        if lowered == "master mdm:":
            id_ = "Master MDM"
            data = parsed.setdefault(id_, {})
            continue
        if lowered == "slave mdms:":
            id_ = "Slave MDMs"
            data = parsed.setdefault(id_, {})
            continue
        if lowered == "tie-breakers:":
            id_ = "Tie-Breakers"
            data = parsed.setdefault(id_, {})
            continue
        if lowered == "standby mdms:":
            id_ = "Standby MDMs"
            data = parsed.setdefault(id_, {})
            continue
        if id_ not in parsed:
            continue
        if id_ == "Cluster":
            _add_key_values(data, [p.strip() for p in line.split(": ")])
        elif lowered == "name":
            node = parts[1].strip()
            if len(tokens) >= 2:
                data[node] = {}
            continue
        if node in data:
            _add_key_values(data[node], [p.strip() for p in line.split(": ")])
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["scli", "--version"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "ScaleIO not found on this host",
                    "data": {"discovery": []}}
        out = ctx.run(["scli", "--query_cluster"], mutates=False)
        if out.rc != 0:
            return {"changed": False, "msg": "ScaleIO cluster not found",
                    "data": {"discovery": []}}
        section = _parse_section(out.stdout)
        if not section.get("Cluster"):
            return {"changed": False, "msg": "No ScaleIO cluster found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
    section_text = ctx.run(["scli", "--query_cluster"], mutates=False).stdout
    section = _parse_section(section_text)
    translate = _parse_status_map()
    results = []
    cluster = section.get("Cluster")
    if cluster:
        status = cluster.get("State", "Unknown")
        active = cluster.get("Active", "").split("/")
        replicas = cluster.get("Replicas", "").split("/")
        st = translate.get(status, 3)
        summary = "Mode: %s, State: %s" % (cluster.get("Mode", ""), status)
        results.append({"state": "OK" if st == 0 else ("WARN" if st == 1 else "CRIT"),
                        "summary": summary, "metrics": {}, "details": ""})
        if len(active) == 2 and len(replicas) == 2:
            a_ok = active[0] == active[1]
            r_ok = replicas[0] == replicas[1]
            a_state = "OK" if (a_ok and r_ok) else "CRIT"
            a_summary = "Active: %s, Replicas: %s" % ("/".join(active), "/".join(replicas))
            results.append({"state": a_state, "summary": a_summary, "metrics": {}, "details": ""})
    for role in ["Master MDM", "Slave MDMs", "Tie-Breakers", "Standby MDMs"]:
        role_data = section.get(role, {})
        nodes = sorted(role_data.keys())
        role_state = 0
        for node in nodes:
            node_status = role_data[node].get("Status", "Normal")
            st = translate.get(node_status, 0)
            if st > role_state:
                role_state = st
        if nodes:
            infotext = "%s: %s" % (role, ", ".join(nodes))
        elif role != "Standby MDMs":
            role_state = 2
            infotext = "%s not found in agent output" % role
        else:
            infotext = "%s: no" % role
        state_str = "OK" if role_state == 0 else ("WARN" if role_state == 1 else "CRIT")
        results.append({"state": state_str, "summary": infotext, "metrics": {}, "details": ""})
    overall = "OK"
    for r in results:
        if r["state"] == "CRIT":
            overall = "CRIT"
        elif r["state"] == "WARN" and overall != "CRIT":
            overall = "WARN"
    msgs = [r["summary"] for r in results]
    return {"changed": False, "msg": "; ".join(msgs),
            "data": {"state": overall, "metrics": {}, "details": ""}}