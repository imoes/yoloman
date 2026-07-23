def main(ctx, params):
    # Read the agent section data from the host
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/couchbase_nodes_operations"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        res = ctx.run(["cat", "/usr/lib/check-mk-agent/local/couchbase_nodes_operations"], mutates=False)

    # Parse the section: each line is "<value> <node_name>"
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        raw_value, node = parts[0], parts[1]
        # Guard instead of try: check if string can be converted to float
        s = raw_value.lstrip('-')
        if s.replace('.', '', 1).isdigit():
            section[node] = float(raw_value)
        elif raw_value.find('nan') != -1 or raw_value.find('inf') != -1:
            # Skip NaN/Inf as Starlark float() doesn't support them reliably
            continue
        else:
            # Skip non-numeric strings
            continue

    # Compute total (None key in Checkmk's logic)
    total = 0.0
    for v in section.values():
        total = total + v
    section[None] = total

    if params.get("_discover"):
        # Discovery mode: yield one service for "Total Operations" if section has None key
        discovery = []
        if section.get(None) != None:
            discovery.append({"item": "", "params": {}, "metrics": ["op_s"]})
        return {
            "changed": False,
            "msg": "discovered %d item(s)" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: check the total operations value
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "invalid item for this check: only empty item is supported",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = section.get(None)
    if value == None:
        return {
            "changed": False,
            "msg": "no operation data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Apply levels (warn/crit are optional, default to None)
    warn = params.get("ops")
    crit = params.get("ops")
    # If "ops" is a list, use the second element as crit and first as warn (Checkmk convention)
    if type(warn) == "list" and len(warn) == 2:
        warn = float(warn[0])
        crit = float(warn[1])
    elif type(warn) == "float" or type(warn) == "int":
        # Single level - used for both warn and crit in some rulesets
        crit = float(warn)
        warn = None

    # Determine state
    state = "OK"

    if crit != None and value >= float(crit):
        state = "CRIT"
    elif warn != None and value >= float(warn):
        state = "WARN"

    # Build message
    details = "%f/s" % value

    return {
        "changed": False,
        "msg": "Total Operations: " + details,
        "data": {
            "state": state,
            "metrics": {"op_s": value},
            "details": details,
        },
    }