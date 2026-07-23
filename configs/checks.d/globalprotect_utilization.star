# Module-level constants (metric labels and boundaries)
UTILIZATION_METRIC = "channel_utilization"
ACTIVE_TUNNELS_METRIC = "active_sessions"

def main(ctx, params):
    # SNMP section detection and fetch (single-service check, no items)
    # Detect: startswith(sysDescr, "Palo Alto") and exists OIDs .1.3.6.1.4.1.25461.2.1.2.5.1.*
    sysdesc = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
                      mutates=False)
    if sysdesc.rc != 0 or not sysdesc.stdout:
        return {"changed": False, "msg": "could not read sysDescr",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysdesc_str = sysdesc.stdout.strip().split(" = ", 1)[-1] if " = " in sysdesc.stdout else ""
    if not sysdesc_str.startswith("Palo Alto"):
        # Not applicable - return empty discovery or UNKNOWN state
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "not a Palo Alto device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Check existence of base OID branch by attempting snmpwalk of first OID
    util_check = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"),
                          ".1.3.6.1.4.1.25461.2.1.2.5.1"],
                         mutates=False)
    if util_check.rc != 0 or not util_check.stdout:
        return {"changed": False, "msg": "globalprotect_utilization data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the three OIDs: 1=utilization, 2=max_tunnels, 3=active_tunnels
    util_pct = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.25461.2.1.2.5.1.1"],
                       mutates=False)
    max_tunn = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.25461.2.1.2.5.1.2"],
                       mutates=False)
    active_tun = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"),
                          ".1.3.6.1.4.1.25461.2.1.2.5.1.3"],
                         mutates=False)

    if util_pct.rc != 0 or max_tunn.rc != 0 or active_tun.rc != 0:
        return {"changed": False, "msg": "failed to fetch globalprotect_utilization OIDs",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def extract_value(out):
        if " = " in out:
            val = out.strip().split(" = ", 1)[-1]
            if val.startswith("INTEGER: "):
                val = val.replace("INTEGER: ", "")
            if val.isdigit() or (val.lstrip("-").isdigit() and val.lstrip("-") != ""):
                return int(val)
        return None

    utilization = extract_value(util_pct.stdout)
    max_tunnels = extract_value(max_tunn.stdout)
    active_tunnels = extract_value(active_tun.stdout)

    # Validate parsed values
    if utilization == None or max_tunnels == None or active_tunnels == None:
        return {"changed": False, "msg": "malformed globalprotect_utilization data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["channel_utilization", "active_sessions"]}
                ]}}

    # Normal check mode: evaluate levels (checkmk uses predictive or fixed upper levels)
    # Default thresholds are not provided (params empty), so use no levels unless specified.
    levels_util = params.get("utilization")
    levels_active = params.get("active_tunnels")

    # Accumulator dict for state (Starlark has no nonlocal)
    state_acc = {"value": "OK"}

    # Helper: evaluate levels and update state_acc
    def eval_levels(value, levels, label):
        # Support predictive (dict) and fixed (int/float) formats
        warn = None
        crit = None

        if type(levels) == "dict":
            # For simplicity, assume fixed tuple under 'levels' key if present
            warn = levels.get("levels")[0] if levels.get("levels") else None
            crit = levels.get("levels")[1] if levels.get("levels") else None
        else:
            # Fixed number: upper bound only
            warn = levels
            crit = levels

        # Evaluate: WARN if value >= warn, CRIT if value >= crit
        if crit != None and value >= crit:
            state_acc["value"] = "CRIT"
        elif warn != None and value >= warn and state_acc["value"] == "OK":
            state_acc["value"] = "WARN"
        return "%s: %d" % (label, value)

    # Utilization (0-100)
    util_msg = eval_levels(utilization, levels_util, "Utilization")

    # Active tunnels (0..max_tunnels)
    active_msg = eval_levels(active_tunnels, levels_active, "Active sessions")

    # Always report max sessions in summary
    summary = "%s, Max sessions: %d" % (active_msg if active_msg else "Active sessions: %d" % active_tunnels, max_tunnels)
    if util_msg:
        summary = util_msg + ", " + summary

    # Map Checkmk states to our strings
    state = state_acc["value"]
    if state == "OK":
        summary = "Utilization: %d%%, Active sessions: %d, Max sessions: %d" % (utilization, active_tunnels, max_tunnels)
        state = "OK"

    # Build metrics dict (perfdata)
    metrics = {"channel_utilization": utilization, "active_sessions": active_tunnels}

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}
