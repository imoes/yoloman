# ===== Starlark check module for oracle_crs_res =====
# Reads oracle_crs_res agent section via: crsctl query crs active_resource -f
# Parses pipe-separated NAME|TYPE|STATE|TARGET lines for each resource

# Default levels from Checkmk check default parameters
DEFAULT_LEVELS = {"number_of_nodes_not_in_target_state": (1, 2)}

def _parse_oracle_crs_res(stdout):
    """Parse oracle_crs_res agent output (pipe-separated entries for each resource).
    Returns a dict: {resource_name: {node: {"state": ..., "target": ...}, ...}, ...}"""
    lines = stdout.strip().splitlines() if stdout.strip() else []
    resources = {}
    current_res = None
    for line in lines:
        parts = line.split("|")
        if len(parts) < 2:
            continue
        key = parts[0].strip()
        value = parts[1].strip()
        if key == "NAME":
            current_res = value
            resources[current_res] = {}
        elif key in ["TYPE", "STATE", "TARGET"] and current_res != None:
            # Skip TYPE (not needed for check), parse STATE/TARGET
            if key == "STATE":
                # STATE format: "ONLINE on hostname" or "OFFLINE" etc.
                parts_state = value.split(" ", 1)
                state = parts_state[0] if len(parts_state) > 0 else value
                node = parts_state[1].strip() if len(parts_state) > 1 else ""
                # Normalize node name: "on hostname" -> "hostname"
                if node.startswith("on "):
                    node = node[3:]
                # Ensure node key exists
                if node not in resources[current_res]:
                    resources[current_res][node] = {"state": "", "target": ""}
                resources[current_res][node]["state"] = state
            elif key == "TARGET":
                # TARGET is global per resource, not node-specific; store under empty node key
                if "" not in resources[current_res]:
                    resources[current_res][""] = {"state": "", "target": ""}
                resources[current_res][""]["target"] = value
    return resources

def _check_levels(value, levels):
    """Emulate Checkmk's check_levels_v1 for upper levels.
    Returns (state, summary)."""
    warn, crit = levels
    if value >= crit:
        return "CRIT", ">= %d (threshold critical at %d)" % (crit, crit)
    elif value >= warn:
        return "WARN", ">= %d (threshold warning at %d)" % (warn, warn)
    return "OK", "< %d" % warn

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["crsctl", "query", "crs", "active_resource", "-f"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to query CRS resources",
                    "data": {"discovery": []}}
        resources = _parse_oracle_crs_res(res.stdout)
        discovery = []
        for item in sorted(resources.keys()):
            if item:
                discovery.append({"item": item, "params": {"number_of_nodes_not_in_target_state": DEFAULT_LEVELS["number_of_nodes_not_in_target_state"]},
                                  "metrics": ["oracle_number_of_nodes_not_in_target_state"]})
        return {"changed": False, "msg": "discovered %d resources" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather data
    res = ctx.run(["crsctl", "query", "crs", "active_resource", "-f"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query CRS resources",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    resources = _parse_oracle_crs_res(res.stdout)
    if item not in resources:
        # Special cases from original check
        if item == "ora.cssd":
            return {"changed": False, "msg": "Clusterware not running",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        elif item == "ora.crsd":
            return {"changed": False, "msg": "Cluster resource service daemon not running",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        else:
            return {"changed": False, "msg": "No resource details found for %s, Maybe cssd/crsd is not running" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nodes_info = resources.get(item)
    if nodes_info == None:
        return {"changed": False, "msg": "No resource details found for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Count nodes not in target state
    number_of_nodes_not_in_target_state = 0
    summary_parts = []

    # Collect node data: prefer explicit node names; fall back to "" if present
    nodes_to_process = []
    for node in nodes_info:
        if node == "":
            continue  # Skip global target; process explicit nodes first
        nodes_to_process.append(node)
    if "" in nodes_info:
        # Global entry: treat as single-node fallback if no explicit nodes
        if not nodes_to_process:
            nodes_to_process.append("")
        else:
            # Prefer explicit nodes; global "" is a fallback and may be ignored if nodes exist
            # Checkmk source processes all nodes; mimic by processing "" only if no explicit nodes exist
            pass

    for nodename in nodes_to_process:
        entry = nodes_info[nodename]
        resstate = entry.get("state", "")
        restarget = entry.get("target", "")

        if nodename == "csslocal":
            infotext = "local: "
        elif nodename:
            infotext = "on %s: " % nodename
        else:
            infotext = ""
        infotext += resstate.lower()

        if resstate != restarget:
            number_of_nodes_not_in_target_state += 1
            infotext += ", target state %s" % restarget.lower()

        summary_parts.append(infotext)

    summary = "; ".join(summary_parts) if summary_parts else "(no nodes)"

    # Apply levels
    levels = params.get("number_of_nodes_not_in_target_state", DEFAULT_LEVELS["number_of_nodes_not_in_target_state"])
    state_str, detail = _check_levels(number_of_nodes_not_in_target_state, levels)
    state = "CRIT" if state_str == "CRIT" else ("WARN" if state_str == "WARN" else "OK")

    return {
        "changed": False,
        "msg": "%s; %s" % (summary, detail),
        "data": {
            "state": state,
            "metrics": {"oracle_number_of_nodes_not_in_target_state": number_of_nodes_not_in_target_state},
            "details": detail,
        },
    }