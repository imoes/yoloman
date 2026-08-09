def _v2_state(s):
    return _STATE_MAP.get(s, _STATE_MAP.get("default", 1))


_STATE_MAP = {
    "ONLINE": 0,
    "RUNNING": 0,
    "OK": 0,
    "OFFLINE": 1,
    "EXITED": 1,
    "PARTIAL": 1,
    "FAULTED": 2,
    "UNKNOWN": 3,
    "default": 1,
}

_FROZEN_MAP = {
    "tfrozen": 1,
    "frozen": 2,
}

def _boil_down_states(states):
    if len(states) == 0:
        return "default"
    if len(states) == 1:
        return states[0]
    for dominant in ("FAULTED", "UNKNOWN", "ONLINE", "RUNNING"):
        for s in states:
            if s == dominant:
                return dominant
    return "default"

def _worst_state(state_ints):
    worst = 0
    for s in state_ints:
        if s > worst:
            worst = s
    if worst == 3:
        return 3
    return worst

def _parse_veritas_vcs(lines):
    parsed = {}
    section = None
    attr_idx = 0
    value_idx = 0
    cluster_name = None
    for line in lines:
        parts = line.split("\t")
        if len(parts) == 0:
            continue
        if parts[0] == "#":
            continue
        if parts[0] == "ClusState":
            section = parsed.setdefault("cluster", {})
            attr = parts[0]
            value = parts[1]
        elif parts[0] == "ClusterName":
            cluster_name = parts[1]
            section.setdefault(cluster_name, []).append((attr, value, None))
        elif parts[0].startswith("#"):
            section = parsed.setdefault(parts[0][1:].lower(), {})
            attr_idx = 0
            value_idx = 0
            for i in range(len(parts)):
                if parts[i] == "Attribute":
                    attr_idx = i
                if parts[i] == "Value":
                    value_idx = i
        elif len(parts) > 2:
            item_name = parts[0]
            attr = parts[attr_idx]
            value = parts[value_idx].replace("|", "")
            if "UNKNOWN" in value:
                value = "UNKNOWN"
            section.setdefault(item_name, []).append((attr, value, cluster_name))
    return parsed

def main(ctx, params):
    if not ctx.file_exists("/sbin/hab"):
        probe = ctx.run(["vcs", "version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "Veritas VCS not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if probe.rc != 0 and probe.rc != 1:
            return {"changed": False, "msg": "cannot determine VCS status",
                    "data": {"discovery": [], "host_labels": {}}}

    res = ctx.run(["vcs", "cluster", "status", "-v"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read VCS status",
                "data": {"discovery": [], "host_labels": {}}}

    parsed = _parse_veritas_vcs(res.stdout.splitlines())
    if len(parsed) == 0:
        return {"changed": False, "msg": "no VCS data",
                "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        system_sub = parsed.get("system", {})
        out = []
        for item_name in system_sub:
            out.append({"item": item_name, "params": {},
                        "metrics": []})
        host_labels = {}
        cluster_sub = parsed.get("cluster", {})
        for cname in cluster_sub:
            host_labels["cmk/vcs_cluster"] = cname
            break
        if len(host_labels) == 0:
            host_labels = {}
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": host_labels}}

    item = params.get("item", "")
    system_sub = parsed.get("system", {})
    item_tuples = system_sub.get(item, [])
    if len(item_tuples) == 0:
        return {"changed": False,
                "msg": "no such VCS system: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    frozen_states = []
    summaries = []
    for vcs in item_tuples:
        attr = vcs[0]
        value = vcs[1]
        if attr.endswith("Frozen") and value != "0":
            sname = attr.lower()
            fs = _FROZEN_MAP.get(sname, 1)
            frozen_states.append(fs)
            txt = attr.lower()
            if txt == "tfrozen":
                summaries.append("temporarily frozen")
            else:
                summaries.append("frozen")

    state_values = []
    for vcs in item_tuples:
        if vcs[0].endswith("State"):
            state_values.append(vcs[1])

    node_state_text = _boil_down_states(state_values) if len(state_values) > 0 else None
    state_ints = list(frozen_states)
    if node_state_text != None:
        state_ints.append(_v2_state(node_state_text))
    cluster_state = _worst_state(state_ints) if len(state_ints) > 0 else 0

    summary_parts = []
    summary_parts.extend(summaries)
    if node_state_text != None:
        summary_parts.append(node_state_text.lower())

    cluster_name = None
    for vcs in item_tuples:
        if vcs[2] != None:
            cluster_name = vcs[2]
            break

    if cluster_state == 0 and len(summary_parts) == 0:
        summary_text = "All nodes OK"
    else:
        summary_text = ", ".join(summary_parts)

    if cluster_state == 0:
        state_str = "OK"
    elif cluster_state == 1:
        state_str = "WARN"
    elif cluster_state == 2:
        state_str = "WARN"
    elif cluster_state == 3:
        state_str = "UNKNOWN"
    else:
        state_str = "UNKNOWN"

    details = summary_text
    if cluster_name != None:
        details = details + "\ncluster: %s" % cluster_name

    return {"changed": False,
            "msg": summary_text,
            "data": {"state": state_str, "metrics": {}, "details": details}}