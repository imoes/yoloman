# Constants for state mapping (Checkmk defaults)
DEFAULT_MAP_STATES = {
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

DEFAULT_MAP_FROZEN = {
    "tfrozen": 1,
    "frozen": 2,
}

# Helper: boil down states with dominance rules
def _boil_down_states(states):
    if len(states) == 0:
        return "default"
    for dominant in ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]:
        if dominant in states:
            return dominant
    return "default"

# Helper: parse agent output
def _parse_vcs_output(output):
    parsed = {}
    cluster_name = None
    section = None
    section_name = None
    attr_idx = None
    value_idx = None

    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "" or stripped == "#":
            continue
        parts = stripped.split()
        if len(parts) == 0:
            continue

        if parts[0] == "ClusState":
            section_name = "cluster"
            section = parsed.setdefault(section_name, {})
            attr = parts[0]
            value = parts[1]
            continue

        elif parts[0] == "ClusterName":
            cluster_name = parts[1]
            if section_name == "cluster":
                section.setdefault(cluster_name, []).append({"attr": "ClusState", "value": value, "cluster": None})
            continue

        elif parts[0].startswith("#"):
            section_name = parts[0][1:].lower()
            section = parsed.setdefault(section_name, {})
            # Find indices from header line (parts is tokenized, assume fixed format)
            # Header is like "#Resource        Attribute      System       Value"
            attr_idx = None
            value_idx = None
            for i, p in enumerate(parts):
                if p == "Attribute":
                    attr_idx = i
                if p == "Value":
                    value_idx = i
            continue

        elif len(parts) > 2 and attr_idx != None and value_idx != None:
            item_name = parts[0]
            attr = parts[attr_idx]
            value = parts[value_idx].replace("|", "")
            if value.find("UNKNOWN") != -1:
                value = "UNKNOWN"
            section.setdefault(item_name, []).append({"attr": attr, "value": value, "cluster": cluster_name})
        # else ignore malformed lines

    return parsed or None

# Helper: find cluster name from list of VCS entries (last non-None)
def _cluster_name(entries):
    name = None
    for e in entries:
        if e.get("cluster") != None:
            name = e["cluster"]
    return name

# Helper: yield frozen state results
def _frozen_state_results(entries, map_frozen):
    res = []
    for e in entries:
        if e.get("attr", "").endswith("Frozen") and e.get("value", "0") != "0":
            attr_lower = e["attr"].lower()
            if attr_lower in map_frozen:
                state = map_frozen[attr_lower]
                summary = e["attr"].replace("t", "temporarily ") if "T" in e["attr"] else e["attr"]
                res.append({"state": state, "summary": summary})
    return res

# Helper: check one item
def _check_one_item(item, params, subsection):
    entries = subsection.get(item)
    if entries == None:
        return {
            "state": "UNKNOWN",
            "msg": "item not found",
            "details": "",
            "metrics": {}
        }

    # Frozen state checks
    frozen_results = _frozen_state_results(entries, params.get("map_frozen", DEFAULT_MAP_FROZEN))
    frozen_states = [r["state"] for r in frozen_results]
    state_texts = [r["summary"] for r in frozen_results]

    # State extraction and boiling down
    states = []
    for e in entries:
        if e.get("attr", "").endswith("State"):
            states.append(e["value"])

    boil_down = _boil_down_states(states)
    map_states = params.get("map_states", DEFAULT_MAP_STATES)
    state_val = map_states.get(boil_down, map_states.get("default", 1))

    # Final state (worst among frozen + boil-down)
    all_states = frozen_states[:]
    if boil_down != "default":
        # map boil_down state to numeric
        s_val = map_states.get(boil_down, map_states.get("default", 1))
        all_states.append(s_val)

    final_state = max(all_states) if len(all_states) > 0 else 0
    # Map numeric to Checkmk string
    state_map_num_to_str = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_str = state_map_num_to_str.get(final_state, "UNKNOWN")

    # Build summary
    summaries = []
    for r in frozen_results:
        summaries.append(r["summary"])
    if len(states) > 0:
        summaries.extend([s.lower() for s in states])
    cluster_name = _cluster_name(entries)
    if cluster_name != None:
        summaries.append("cluster: %s" % cluster_name)

    msg = ", ".join(summaries) if len(summaries) > 0 else "no data"

    return {
        "state": state_str,
        "msg": msg,
        "details": "",
        "metrics": {}
    }

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/tmp/agent_output/veritas_vcs"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read agent data", "data": {"discovery": []}}
        parsed = _parse_vcs_output(res.stdout)
        if parsed == None:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        # Discover items for each subsection (resource, system, group, cluster)
        items = []
        for subsection_name in ["resource", "system", "group", "cluster"]:
            subsection = parsed.get(subsection_name, {})
            for item in subsection.keys():
                # Only resources are required by the task
                if subsection_name == "resource":
                    items.append({
                        "item": item,
                        "params": {"map_states": DEFAULT_MAP_STATES, "map_frozen": DEFAULT_MAP_FROZEN},
                        "metrics": []
                    })
        return {"changed": False, "msg": "discovered %d resources" % len(items), "data": {"discovery": items}}

    # Check mode (non-discovery)
    item = params.get("item", "")
    res = ctx.run(["cat", "/tmp/agent_output/veritas_vcs"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read agent data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_vcs_output(res.stdout)
    if parsed == None:
        return {"changed": False, "msg": "no data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    subsection = parsed.get("resource", {})
    result = _check_one_item(item, params, subsection)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"]
        }
    }
