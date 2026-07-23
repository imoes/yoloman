def main(ctx, params):
    # Discovery mode: yield one service if agent data is present
    if params.get("_discover"):
        # Run the agent command to check if data is available
        res = ctx.run(["mongodb_mem"], mutates=False)
        # Check if there's any output (non-empty stdout)
        if res.stdout.strip():
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                        "process_resident_size",
                        "process_virtual_size",
                        "process_mapped_size"
                    ]}]}}
        else:
            return {"changed": False, "msg": "no data found",
                    "data": {"discovery": []}}

    # Check mode: process the actual MongoDB memory data
    # The agent section data should come from the standard agent output
    # We simulate parsing by running the same command and parsing manually
    res = ctx.run(["mongodb_mem"], mutates=False)
    if not res.stdout.strip():
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the section: convert lines like "resident 856" to dict
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split(None, 1)  # split into at most 2 parts
        if len(parts) == 2:
            key = parts[0]
            value_str = parts[1]
            # Guard instead of try/except: check if value_str is a valid integer string
            value = int(value_str) if value_str.lstrip("-").isdigit() else value_str
            section[key] = value

    # Collect results and metrics
    details_parts = []
    metrics = {}
    state = "OK"
    state_priority = {"OK": 0, "WARN": 1, "CRIT": 2}

    # Check resident, virtual, mapped sizes
    for key in ("resident", "virtual", "mapped"):
        if section.get(key) != None and type(section.get(key)) == "int":
            # Convert from MB to bytes: MB = 1024*1024 bytes
            value_bytes = section[key] * 1048576
            metric_name = "process_%s_size" % key
            metrics[metric_name] = value_bytes

            # Get levels (Checkmk defaults are None)
            warn = params.get("%s_levels" % key, (None, None))
            crit = params.get("%s_levels" % key, (None, None))

            # Apply simple level checks (mimicking check_levels)
            warn_upper = None
            crit_upper = None
            if type(warn) == "tuple" and len(warn) == 2:
                warn_upper = warn[0]
                if type(crit) == "tuple" and len(crit) == 2:
                    crit_upper = crit[0]

            # Determine state based on levels
            new_state = "OK"
            if crit_upper != None and value_bytes >= crit_upper:
                new_state = "CRIT"
            elif warn_upper != None and value_bytes >= warn_upper:
                new_state = "WARN"

            # Update overall state (worst takes precedence)
            if state_priority[new_state] > state_priority[state]:
                state = new_state

            # Add to details
            if key == "resident":
                label = "Resident usage"
            elif key == "virtual":
                label = "Virtual usage"
            else:
                label = "Mapped usage"
            details_parts.append("%s: %s" % (label, "%d MB" % section[key]))

    # Check for potential memory leak (virtual/mapped ratio)
    if section.get("mapped") != None and type(section.get("mapped")) == "int" and section["mapped"] > 0:
        virt_mapped_factor = float(section["virtual"]) / float(section["mapped"])
        if virt_mapped_factor >= 3:
            new_state = "WARN"
            if state_priority[new_state] > state_priority[state]:
                state = new_state
            details_parts.append("Virtual size is %f times the mapped size (possible memory leak)" % virt_mapped_factor)

    # Build final message
    if details_parts:
        msg = ", ".join(details_parts)
    else:
        msg = "No memory data available"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
