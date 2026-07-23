_OPER_STATE_MAP = {
    1: "standalone",
    2: "active",
    3: "passiv",
    4: "stopped",
    5: "stopping",
    6: "becoming active",
    7: "becomming passive",
    8: "fault",
}

# Checkmk default parameters
_DEFAULT_OPER_STATES = {
    "warning": [5, 6, 7],
    "critical": [8, 4],
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.13315.3.1.5.2.1.1"
        ], mutates=False)
        
        # Check if we got any results
        lines = res.stdout.splitlines() if res.stdout else []
        if len(lines) > 0 and lines[0].find(" = ") != -1:
            # HA service exists and is not in standalone mode (state != 1)
            # Extract state value
            first_line = lines[0]
            state_str = first_line[first_line.rfind(" = ") + 3:].strip()
            # Guard against non-digit state_str
            if state_str.isdigit():
                state = int(state_str)
                if state != 1:
                    return {
                        "changed": False,
                        "msg": "discovered 1 item",
                        "data": {"discovery": [
                            {"item": "", "params": {}, "metrics": []}
                        ]}
                    }
        
        # No service to discover (standalone or no data)
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    
    # Check mode
    # Get SNMP data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.13315.3.1.5.2.1.1"
    ], mutates=False)
    
    # Parse state from SNMP output
    lines = res.stdout.splitlines() if res.stdout else []
    if len(lines) == 0 or lines[0].find(" = ") == -1:
        return {
            "changed": False,
            "msg": "HA state data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    first_line = lines[0]
    state_str = first_line[first_line.rfind(" = ") + 3:].strip()
    # Guard: only parse if string contains digits
    if not state_str.isdigit():
        return {
            "changed": False,
            "msg": "HA state data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    oper_state = int(state_str)
    
    # Get operational state thresholds from params, use defaults
    oper_states = params.get("oper_states", _DEFAULT_OPER_STATES)
    warn_list = oper_states.get("warning", _DEFAULT_OPER_STATES["warning"])
    crit_list = oper_states.get("critical", _DEFAULT_OPER_STATES["critical"])
    
    # Determine state
    state = "OK"
    if oper_state in crit_list:
        state = "CRIT"
    elif oper_state in warn_list:
        state = "WARN"
    
    # Get state description
    state_desc = _OPER_STATE_MAP.get(oper_state, "unknown")
    msg = "State is " + state_desc
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
