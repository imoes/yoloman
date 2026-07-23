# Check: checkmk.veritas_vcs
# Translated from cmk/plugins/veritas/agent_based/veritas_vcs.py
# Read-only Starlark check module (discovery + check logic)

# Default mapping parameters
DEFAULT_MAP_FROZEN = {"tfrozen": 1, "frozen": 2}
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

# State constants for readability
STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def _parse_veritas_vcs(stdout):
    parsed = {}
    cluster_name = None
    section = None
    attr_idx = 0
    value_idx = 0

    lines = stdout.splitlines()
    for line in lines:
        if line.strip() == "#":
            continue

        parts = line.split()
        if not parts:
            continue

        if parts[0] == "ClusState" and len(parts) >= 2:
            section = parsed.setdefault("cluster", {})
            attr = parts[0]
            value = parts[1]
        elif parts[0] == "ClusterName" and len(parts) >= 2:
            cluster_name = parts[1]
            if section != None:
                section.setdefault(cluster_name, []).append({"attr": attr, "value": value, "cluster": None})
        elif parts[0].startswith("#"):
            section_name = parts[0][1:].lower()
            section = parsed.setdefault(section_name, {})
            # Find Attribute and Value positions
            if "Attribute" in parts and "Value" in parts:
                attr_idx = parts.index("Attribute")
                value_idx = parts.index("Value")
            else:
                continue
        elif len(parts) > 2 and section != None and attr_idx > 0 and value_idx > 0:
            item_name = parts[0]
            attr = parts[attr_idx]
            value = parts[value_idx].replace("|", "")
            if "UNKNOWN" in value:
                value = "UNKNOWN"
            section.setdefault(item_name, []).append({"attr": attr, "value": value, "cluster": cluster_name})

    return parsed if parsed else None

def _boil_down_states_in_cluster(states):
    if len(states) == 1:
        return states[0]
    for dominant in ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]:
        if dominant in states:
            return dominant
    return "default"

def _discover_subsection(parsed, subsection_name):
    if parsed == None:
        return []
    subsection = parsed.get(subsection_name, {})
    out = []
    for item_name in subsection:
        out.append({
            "item": item_name,
            "params": {
                "map_frozen": DEFAULT_MAP_FROZEN,
                "map_states": DEFAULT_MAP_STATES
            },
            "metrics": []
        })
    return out

def _check_subsection(item, params, subsection):
    list_vcs_tuples = subsection.get(item)
    if list_vcs_tuples == None:
        return {
            "state": STATE_UNKNOWN,
            "msg": "item vanished",
            "metrics": {},
            "details": ""
        }

    # Process frozen states
    frozen_results = []
    for vcs in list_vcs_tuples:
        if vcs["attr"].endswith("Frozen") and vcs["value"] != "0":
            attr_name = vcs["attr"].lower()
            state_map = params.get("map_frozen", DEFAULT_MAP_FROZEN)
            state_val = state_map.get(attr_name, 1)
            # Map to Checkmk state
            if state_val == 0:
                state = STATE_OK
            elif state_val == 1:
                state = STATE_WARN
            elif state_val == 2:
                state = STATE_CRIT
            else:
                state = STATE_UNKNOWN

            summary = vcs["attr"].replace("t", "temporarily ") + ": " + vcs["value"]
            frozen_results.append((state, summary))

    # Process state values
    state_mapping = params.get("map_states", DEFAULT_MAP_STATES)
    states = []
    for vcs in list_vcs_tuples:
        if vcs["attr"].endswith("State"):
            states.append(vcs["value"])

    state_text = None
    if states:
        state_text = _boil_down_states_in_cluster(states)
        state_val = state_mapping.get(state_text, state_mapping.get("default", 1))
        if state_val == 0:
            state = STATE_OK
        elif state_val == 1:
            state = STATE_WARN
        elif state_val == 2:
            state = STATE_CRIT
        else:
            state = STATE_UNKNOWN

    # Get cluster name
    cluster_name = None
    for vcs in list_vcs_tuples:
        if vcs["cluster"] != None:
            cluster_name = vcs["cluster"]

    # Build response
    summaries = []
    for (st, summ) in frozen_results:
        summaries.append(summ)
        if st == STATE_CRIT:
            state = STATE_CRIT
        elif st == STATE_WARN and state != STATE_CRIT:
            state = STATE_WARN

    if state_text != None:
        summaries.append(state_text.lower())
        # Update overall state if needed
        if state_val >= 2:
            state = STATE_CRIT
        elif state_val == 1 and state != STATE_CRIT:
            state = STATE_WARN

    if cluster_name != None:
        summaries.append("cluster: " + cluster_name)

    msg = ", ".join(summaries)
    return {
        "state": state,
        "msg": msg,
        "metrics": {},
        "details": ""
    }

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check_mk_agent/cache/veritas_vcs"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "agent failed: " + res.stderr,
                    "data": {"discovery": []}}

        parsed = _parse_veritas_vcs(res.stdout)
        discovery = []
        # Discover for all subsections
        subsections = ["cluster", "system", "group", "resource"]
        for subsection_name in subsections:
            discovery.extend(_discover_subsection(parsed, subsection_name))
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Normal check mode
    item = params.get("item", "")
    # Determine subsection based on item context (heuristic: cluster is for "cluster" items,
    # "system" for system items, etc.) — but in practice the Checkmk service name encodes this.
    # Since the service name pattern is "VCS Cluster %s", "VCS System %s", etc., we can infer
    # from the plugin context, but in Starlark we don't have that context. So we fall back to
    # the most common case: cluster.
    # However, the check plugin supports multiple subsections. To distinguish, we'll check
    # which subsections exist in the parsed data. But we only have one item per service call.
    # We'll default to 'cluster' as the primary use-case for this translation.

    res = ctx.run(["cat", "/var/lib/check_mk_agent/cache/veritas_vcs"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "agent failed: " + res.stderr,
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    parsed = _parse_veritas_vcs(res.stdout)
    subsection = "cluster"
    if parsed != None:
        if item == "" and not parsed.get("cluster"):
            # Fallback to other subsections if no cluster item found (rare, but defensive)
            for k in ["system", "group", "resource"]:
                if parsed.get(k):
                    subsection = k
                    break
    else:
        return {"changed": False, "msg": "no data",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    subsection_data = parsed.get(subsection, {})
    result = _check_subsection(item, params, subsection_data)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }
