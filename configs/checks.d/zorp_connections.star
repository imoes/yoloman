def main(ctx, params):
    # Discovery mode: always yield one service for this check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": ("fixed", 15, 20)},
                        "metrics": ["connections"]
                    }
                ]
            }
        }

    # Check mode: run zorpctl command
    res = ctx.run(["zorpctl", "szig", "-r", "zorp.stats.active_connections"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve Zorp connections data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse output: section = {"<instance>": <count>, ...}
    lines = res.stdout.splitlines()
    section = {}
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("Instance ") and line.endswith(":"):
            instance_name = line[9:-1]  # strip "Instance " prefix and ":" suffix
            if i + 1 < len(lines):
                state_line = lines[i + 1].strip()
                if state_line.startswith("zorp.stats.active_connections:"):
                    value_part = state_line.split(":", 1)[1].strip()
                    count = 0
                    if value_part != "None" and value_part.isdigit():
                        count = int(value_part)
                    section[instance_name] = count
        i += 1

    # Extract parameters
    levels = params.get("levels", ("fixed", 15, 20))
    warn = 15
    crit = 20
    if type(levels) == "list":
        if len(levels) >= 3 and levels[0] == "fixed":
            warn = levels[1]
            crit = levels[2]
    elif type(levels) == "tuple":
        if len(levels) >= 3 and levels[0] == "fixed":
            warn = levels[1]
            crit = levels[2]

    # Compute total connections (sum is not available in Starlark — compute manually)
    total = 0
    for k in section:
        total = total + section[k]

    # Determine state
    state = "OK"
    if total >= crit:
        state = "CRIT"
    elif total >= warn:
        state = "WARN"

    # Build message
    details_parts = []
    for name in sorted(section):
        count = section[name]
        details_parts.append("%s: %d" % (name, count))
    details = "; ".join(details_parts) if details_parts else ""

    # Return result
    return {
        "changed": False,
        "msg": "Total connections: %d" % total,
        "data": {
            "state": state,
            "metrics": {"connections": total},
            "details": details
        }
    }