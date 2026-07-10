def main(ctx, params):
    # Read agent data (JSON from 3par_remotecopy section)
    res = ctx.run(["cmk", "-d", ctx.facts()["hostname"], "--agents", "hpe_3par", "3par_remotecopy"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        fail("No data received from 3par_remotecopy agent section")
    
    data = json.decode(res.stdout)
    
    mode = int(data.get("mode", 1))
    status_raw = str(data.get("status", 6))
    status_readable = {
        "1": "NORMAL",
        "2": "STARTUP",
        "3": "SHUTDOWN",
        "4": "ENABLE",
        "5": "DISABLE",
        "6": "INVALID",
        "7": "NODEDUP",
        "8": "UPGRADE",
    }.get(status_raw, "UNKNOWN")

    # Discovery mode: yield one service if mode > 1
    if params.get("_discover"):
        if mode > 1:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []},
        }

    # Check mode: single-service check (item is always "")
    # Determine state from mode
    mode_state = {
        1: "UNKNOWN",  # NONE
        2: "OK",       # STARTED
        3: "CRIT",     # STOPPED
    }.get(mode, "UNKNOWN")

    # Status mapping: Checkmk defaults are "1":0, "2":1, "3":1, "4":0, "5":2, "6":2, "7":1, "8":0
    # Convert to State enum: OK=0, WARN=1, CRIT=2, UNKNOWN=3
    status_levels = {
        "1": 0,  # NORMAL
        "2": 1,  # STARTUP
        "3": 1,  # SHUTDOWN
        "4": 0,  # ENABLE
        "5": 2,  # DISABLE
        "6": 2,  # INVALID
        "7": 1,  # NODEDUP
        "8": 0,  # UPGRADE
    }
    status_code = int(status_levels.get(status_raw, 2))  # Default CRIT if unknown
    status_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = status_map.get(status_code, "CRIT")

    # Build summary message
    msg = "Mode: %s, Status: %s" % ({"1": "NONE", "2": "STARTED", "3": "STOPPED"}.get(str(mode), "UNKNOWN"), status_readable)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
