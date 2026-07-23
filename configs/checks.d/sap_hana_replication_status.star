
# SAP HANA replication status code mapping (from Checkmk plugin lib)
def get_replication_state(code_str):
    """Return (state, state_readable, param_key) for a given status code string."""
    code = int(code_str) if code_str.isdigit() else -1
    if code == 0:
        return (0, "Primary", "primary")
    elif code == 1:
        return (1, "Secondary", "secondary")
    elif code == 2:
        return (2, "Initial", "initial")
    elif code == 3:
        return (0, "Inactive", "inactive")
    elif code == 10:
        return (0, "Disabled", "disabled")
    else:
        return (3, "Unknown (%s)" % code_str, "unknown")


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: run HANA CLI command and parse output
        # We use the same command Checkmk would: hdbnsutil -sr_state
        res = ctx.run(["hdbnsutil", "-sr_state"], mutates=False)
        if res.rc != 0:
            # No HANA installation or command not found -> no services
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse HANA output: multi-line blocks per instance
        lines = res.stdout.splitlines()
        section = {}
        current_sid = None
        
        for line in lines:
            stripped = line.strip()
            # Detect SID_INSTANCE lines: "system replication mode: PRIMARY (active)"
            # or lines that start with "host" or "sid"
            # Checkmk parses the output of `hdbnsutil -sr_state` which is formatted like:
            #   system replication mode: PRIMARY (active)
            #   System replication status: 0
            #   ...
            # We extract the sid_instance from the first line of each block
            if stripped.startswith("host") or stripped.startswith("sid"):
                parts = stripped.split(":", 1)
                if len(parts) == 2:
                    key = parts[0].strip().lower()
                    if key == "sid":
                        current_sid = parts[1].strip()
                        section[current_sid] = {}
                    elif key == "host":
                        # Host entry but no SID? Skip
                        current_sid = None
            elif current_sid and stripped:
                # Parse key: value pairs
                idx = stripped.find(":")
                if idx > 0:
                    key = stripped[:idx].strip().lower()
                    value = stripped[idx+1:].strip()
                    if key in ["mode", "system replication status"]:
                        # Normalize key names to match Checkmk's logic
                        if key == "system replication status":
                            key = "systemreplicationstatus"
                        section[current_sid][key] = value
        
        # Build discovery list
        discovery = []
        for sid_instance, data in section.items():
            if not data:
                continue
            status = data.get("systemreplicationstatus", "")
            mode = data.get("mode", "")
            # Replicate Checkmk's discovery condition:
            # yield Service if status != "10" and (mode is "primary" or "sync")
            if status != "10" and (mode.lower() == "primary" or mode.lower() == "sync"):
                discovery.append({
                    "item": sid_instance,
                    "params": {},
                    "metrics": []
                })
        
        return {"changed": False, "msg": "discovered %d instances" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    
    # Gather fresh data
    res = ctx.run(["hdbnsutil", "-sr_state"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to run hdbnsutil -sr_state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Command exit code: %d" % res.rc}}
    
    # Parse output (same parsing as discovery)
    lines = res.stdout.splitlines()
    section = {}
    current_sid = None
    
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("host") or stripped.startswith("sid"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip().lower()
                if key == "sid":
                    current_sid = parts[1].strip()
                    section[current_sid] = {}
        elif current_sid and stripped:
            idx = stripped.find(":")
            if idx > 0:
                key = stripped[:idx].strip().lower()
                value = stripped[idx+1:].strip()
                if key in ["mode", "system replication status"]:
                    if key == "system replication status":
                        key = "systemreplicationstatus"
                    section[current_sid][key] = value
    
    # Look up the item
    data = section.get(item)
    if not data:
        return {"changed": False, "msg": "instance not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Instance %s not present in HANA replication status" % item}}
    
    status_code = data.get("systemreplicationstatus", "")
    if not status_code:
        return {"changed": False, "msg": "no replication status for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Missing system replication status"}}
    
    state_int, state_str, param_key = get_replication_state(status_code)
    
    # Map to Checkmk result states
    # state_int: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    # Map to "OK", "WARN", "CRIT", "UNKNOWN"
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(state_int, "UNKNOWN")
    
    # Checkmk default: no params, so we just use the raw code mapping
    # In real usage, params might override states but defaults are empty
    # (check_default_parameters = {})
    
    return {
        "changed": False,
        "msg": "System replication: %s" % state_str,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }