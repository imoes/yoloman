# Module: veritas_vcs_system.star
# Check: checkmk.veritas_vcs_system
# Service name: VCS System %s

# Default parameters (same as CHECK_DEFAULT_PARAMETERS in source)
DEFAULT_PARAMS = {
    "map_frozen": {
        "tfrozen": 1,
        "frozen": 2,
    },
    "map_states": {
        "ONLINE": 0,
        "RUNNING": 0,
        "OK": 0,
        "OFFLINE": 1,
        "EXITED": 1,
        "PARTIAL": 1,
        "FAULTED": 2,
        "UNKNOWN": 3,
        "default": 1,
    },
}

# State mapping helper
def _state_to_num(state_val, map_states):
    if state_val == None:
        return map_states.get("default")
    return map_states.get(state_val.upper(), map_states.get("default"))

def _boil_down_states(states):
    if len(states) == 0:
        return ""
    # Dominant order: FAULTED, UNKNOWN, ONLINE, RUNNING
    for s in ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]:
        if s in states:
            return s
    return states[0]

def _parse_agent_output(stdout):
    parsed = {}
    cluster_name = ""
    section_name = ""
    attr_idx = -1
    value_idx = -1

    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped == "#":
            continue

        parts = stripped.split()
        if len(parts) == 0:
            continue

        if parts[0] == "ClusState":
            section_name = "cluster"
            attr = "ClusState"
            value = parts[1] if len(parts) > 1 else ""
            if "cluster" not in parsed:
                parsed["cluster"] = {}
            if cluster_name != "":
                parsed["cluster"].setdefault(cluster_name, []).append({"attr": attr, "value": value, "cluster": ""})
            continue

        if parts[0] == "ClusterName":
            cluster_name = parts[1] if len(parts) > 1 else ""
            continue

        if len(parts) > 0 and parts[0].startswith("#"):
            section_name = parts[0][1:].lower()
            attr_idx = -1
            value_idx = -1
            if section_name not in parsed:
                parsed[section_name] = {}
            # find Attribute and Value positions
            for i in range(len(parts)):
                p = parts[i]
                if p == "Attribute":
                    attr_idx = i
                if p == "Value":
                    value_idx = i
            continue

        if len(parts) > 2 and attr_idx != -1 and value_idx != -1:
            item_name = parts[0]
            attr = parts[attr_idx]
            value = parts[value_idx].replace("|", "")
            if "UNKNOWN" in value:
                value = "UNKNOWN"
            if section_name not in parsed:
                parsed[section_name] = {}
            parsed[section_name].setdefault(item_name, []).append({"attr": attr, "value": value, "cluster": cluster_name})

    return parsed or None

def _check_system_item(item, params, subsection):
    list_vcs = subsection.get(item)
    if list_vcs == None:
        return {"state": "UNKNOWN", "msg": "item not found", "details": ""}

    frozen_state_map = params.get("map_frozen", DEFAULT_PARAMS["map_frozen"])
    state_map = params.get("map_states", DEFAULT_PARAMS["map_states"])

    # Check frozen states
    frozen_results = []
    for v in list_vcs:
        attr_val = v.get("attr", "")
        if attr_val.lower().endswith("frozen") and v.get("value", "") != "0":
            # tfrozen or frozen
            if attr_val.lower() == "tfrozen":
                state_key = "tfrozen"
            else:
                state_key = "frozen"
            num = frozen_state_map.get(state_key, 1)
            # Map numeric to Checkmk state
            if num == 0:
                state_str = "OK"
            elif num == 1:
                state_str = "WARN"
            elif num == 2:
                state_str = "CRIT"
            else:
                state_str = "UNKNOWN"
            attr_name = v.get("attr", "")
            summary = attr_name.replace("t", "temporarily ")
            frozen_results.append({
                "state": state_str,
                "summary": summary
            })

    # Check State values
    state_values = [v.get("value") for v in list_vcs if v.get("attr", "").endswith("State")]
    state_text = _boil_down_states(state_values)
    state_num = _state_to_num(state_text, state_map)
    # Map numeric to Checkmk state
    if state_num == 0:
        state_str = "OK"
    elif state_num == 1:
        state_str = "WARN"
    elif state_num == 2:
        state_str = "CRIT"
    else:
        state_str = "UNKNOWN"

    # Cluster name
    cluster_names = [v.get("cluster") for v in list_vcs if v.get("cluster") != None]
    cluster_name = ""
    if len(cluster_names) > 0:
        cluster_name = cluster_names[len(cluster_names) - 1]

    # Build message
    summaries = []
    if len(frozen_results) > 0:
        for r in frozen_results:
            summaries.append(r["summary"])
    if len(state_values) > 0:
        joined = ""
        for s in state_values:
            if joined != "":
                joined = joined + ", "
            joined = joined + s.lower()
        summaries.append(joined)
    if cluster_name != "":
        summaries.append("cluster: " + cluster_name)

    msg = ""
    if len(summaries) > 0:
        for i in range(len(summaries)):
            if i > 0:
                msg = msg + "; "
            msg = msg + summaries[i]
    else:
        msg = "no state data"
    if state_str == "UNKNOWN" and len(summaries) == 0:
        msg = "item not found or no state data"

    return {"state": state_str, "msg": msg, "details": ""}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check_mk_agent/local/veritas_vcs"], mutates=False)
        # In case agent is in standard output format (not local), fallback to raw agent section
        if res.rc != 0:
            res = ctx.run(["cat", "/usr/lib/check_mk_agent/local/veritas_vcs"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "veritas_vcs agent not available", "data": {"discovery": []}}

        parsed = _parse_agent_output(res.stdout)
        if parsed == None:
            return {"changed": False, "msg": "could not parse veritas_vcs data", "data": {"discovery": []}}

        system_items = parsed.get("system", {})
        out = []
        for item_name in system_items:
            out.append({"item": item_name, "params": {"map_frozen": DEFAULT_PARAMS["map_frozen"], "map_states": DEFAULT_PARAMS["map_states"]},
                        "metrics": []})
        return {"changed": False, "msg": "discovered %d systems" % len(out), "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["cat", "/var/lib/check_mk_agent/local/veritas_vcs"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["cat", "/usr/lib/check_mk_agent/local/veritas_vcs"], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "veritas_vcs agent not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_agent_output(res.stdout)
    if parsed == None:
        return {"changed": False, "msg": "could not parse veritas_vcs data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    subsection = parsed.get("system", {})
    result = _check_system_item(item, params, subsection)

    return {"changed": False, "msg": result["msg"], "data": {"state": result["state"], "metrics": {}, "details": result["details"]}}
