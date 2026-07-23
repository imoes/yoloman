def main(ctx, params):
    # Read raw agent data (same format as Checkmk's veritas_vcs section)
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/veritas_vcs"], mutates=False)
    if not res.stdout.strip():
        res = ctx.run(["cat", "/var/lib/mk-agent-client/local/veritas_vcs"], mutates=False)
        if not res.stdout.strip():
            res = ctx.run(["cat", "/var/lib/check-mk-agent/agent-local/veritas_vcs"], mutates=False)
            if not res.stdout.strip():
                res = ctx.run(["/opt/VRTSvcs/bin/hagrp", "-dump"], mutates=False)

    # If still no data, report UNKNOWN for discovery and check modes
    if not res.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 service groups",
                    "data": {"discovery": []}}
        item = params.get("item", "")
        return {"changed": False, "msg": "no veritas_vcs data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse raw data into structured format matching Checkmk's parse_veritas_vcs
    parsed = {"group": {}}
    cluster_name = None
    section = None
    attr_idx = 0
    value_idx = 0

    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped == "#":
            continue

        parts = stripped.split()
        if not parts:
            continue

        # Handle ClusState and ClusterName lines
        if parts[0] == "ClusState" and len(parts) >= 2:
            section = parsed.setdefault("cluster", {})
            attr = parts[0]
            value = parts[1]
            continue
        elif parts[0] == "ClusterName" and len(parts) >= 2:
            cluster_name = parts[1]
            if "cluster" not in parsed:
                parsed["cluster"] = {}
            cluster_sec = parsed["cluster"]
            if cluster_name not in cluster_sec:
                cluster_sec[cluster_name] = []
            cluster_sec[cluster_name].append({"attr": attr, "value": value, "cluster": None})
            section = None
            continue

        # Handle section headers
        if parts[0].startswith("#"):
            section_name = parts[0][1:].lower()
            if section_name == "group":
                section = parsed.setdefault("group", {})
            elif section_name == "system":
                section = parsed.setdefault("system", {})
            elif section_name == "resource":
                section = parsed.setdefault("resource", {})
            else:
                section = None
                continue

            # Find Attribute and Value indices
            found_attr = False
            found_value = False
            for idx in range(len(parts)):
                if parts[idx] == "Attribute":
                    attr_idx = idx
                    found_attr = True
                if parts[idx] == "Value":
                    value_idx = idx
                    found_value = True
            if not found_attr or not found_value:
                section = None
                continue
            continue

        # Skip empty sections or malformed lines
        if section == None:
            continue
        if len(parts) < max(attr_idx, value_idx) + 1:
            continue

        item_name = parts[0]
        attr = parts[attr_idx]
        value = parts[value_idx].replace("|", "")
        if "UNKNOWN" in value:
            value = "UNKNOWN"

        if item_name not in section:
            section[item_name] = []
        section[item_name].append({"attr": attr, "value": value, "cluster": cluster_name})

    # DISCOVERY MODE: discover service groups (group section)
    if params.get("_discover"):
        group_section = parsed.get("group", {})
        discovery_items = []
        for item_name in group_section:
            discovery_items.append({
                "item": item_name,
                "params": {
                    "map_frozen": {"tfrozen": 1, "frozen": 2},
                    "map_states": {
                        "ONLINE": 0, "RUNNING": 0, "OK": 0,
                        "OFFLINE": 1, "EXITED": 1, "PARTIAL": 1,
                        "FAULTED": 2, "UNKNOWN": 3, "default": 1
                    }
                },
                "metrics": ["state"]
            })
        return {"changed": False, "msg": "discovered %d service groups" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    # CHECK MODE: check one service group
    item = params.get("item", "")
    group_section = parsed.get("group", {})
    list_vcs_tuples = group_section.get(item)
    
    # Handle missing item (vanished)
    if list_vcs_tuples == None:
        return {"changed": False, "msg": "service group '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract frozen state attributes and compute frozen state
    map_frozen = params.get("map_frozen", {"tfrozen": 1, "frozen": 2})
    frozen_states = [v["attr"].lower() for v in list_vcs_tuples
                     if v["attr"].endswith("Frozen") and v["value"] != "0"]
    
    frozen_results = []
    for s in frozen_states:
        state = map_frozen.get(s, 3)  # UNKNOWN if not found
        text = s.replace("t", "temporarily ")
        frozen_results.append((state, text))
    
    # Extract state attributes and boil down
    map_states = params.get("map_states", {
        "ONLINE": 0, "RUNNING": 0, "OK": 0,
        "OFFLINE": 1, "EXITED": 1, "PARTIAL": 1,
        "FAULTED": 2, "UNKNOWN": 3, "default": 1
    })
    states = [v["value"] for v in list_vcs_tuples if v["attr"].endswith("State")]
    
    # Boil down states (same logic as Checkmk)
    state_text = ""
    if len(states) == 1:
        state_text = states[0]
    else:
        for dominant in ("FAULTED", "UNKNOWN", "ONLINE", "RUNNING"):
            if dominant in states:
                state_text = dominant
                break
        if not state_text:
            state_text = "default"
    
    # Determine state level
    state_level = map_states.get(state_text, map_states.get("default", 1))
    
    # Map to Checkmk states
    if state_level == 0:
        final_state = "OK"
    elif state_level == 1:
        final_state = "WARN"
    elif state_level == 2:
        final_state = "CRIT"
    else:
        final_state = "UNKNOWN"
    
    # Build summary message
    state_summaries = [s.lower() for s in states]
    frozen_summaries = [text for _, text in frozen_results]
    summary_parts = state_summaries + frozen_summaries
    summary = ", ".join(summary_parts) if summary_parts else "no state information"
    
    # Get cluster name
    cluster_name_out = ""
    for v in reversed(list_vcs_tuples):
        if v.get("cluster"):
            cluster_name_out = v["cluster"]
            break
    
    # Prepare output
    details = ""
    if cluster_name_out:
        details = "cluster: %s" % cluster_name_out
        if summary:
            summary = summary + " | " + details
    
    metrics = {"state": 0 if final_state == "OK" else (1 if final_state == "WARN" else (2 if final_state == "CRIT" else 3))}
    
    return {"changed": False, "msg": "%s: %s" % (item, summary),
            "data": {"state": final_state, "metrics": metrics, "details": details}}