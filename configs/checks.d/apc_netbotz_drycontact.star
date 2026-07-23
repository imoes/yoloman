# ===== Starlark check module: apc_netbotz_drycontact =====

# State text mapping
STATE_TEXT = {
    "1": "Closed high mem",
    "2": "Open low mem",
    "3": "Disabled",
    "4": "Not applicable",
}

# Severity mapping (SNMP value -> Checkmk State)
SEVERITY_MAP = {
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "UNKNOWN",
}

def _get_state_text(state):
    return "%s [%s]" % (STATE_TEXT.get(state, "unknown"), state)

def _get_state_tuple(state, normal, severity):
    current_state = _get_state_text(state)
    if state == normal:
        return ("Normal state (%s)" % current_state, "OK")
    # State is not normal. Error with given severity
    severity_state = SEVERITY_MAP.get(severity, "UNKNOWN")
    return ("State: %s but expected %s" % (current_state, _get_state_text(normal)), severity_state)

def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.318.1.1.10.4.3"
        
        # Fetch all needed OIDs in one walk
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Build dicts for each OID sub-tree by index
        input_name = {}
        input_location = {}
        current_state = {}
        normal_state = {}
        severity = {}
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Format: OID = TYPE: VALUE
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract index from end of OID
            if oid_part.startswith(base_oid + "."):
                sub_oid = oid_part[len(base_oid)+1:]
                # Split by dots to get the path parts
                path_parts = sub_oid.split(".")
                if len(path_parts) >= 2:
                    idx = path_parts[-1]
                    # Determine the OID type (2.1.3, 2.1.4, 2.1.5, 4.1.7, 4.1.8)
                    if sub_oid.startswith("2.1.3."):
                        input_name[idx] = value_part.strip('"')
                    elif sub_oid.startswith("2.1.4."):
                        input_location[idx] = value_part.strip('"')
                    elif sub_oid.startswith("2.1.5."):
                        current_state[idx] = value_part
                    elif sub_oid.startswith("4.1.7."):
                        normal_state[idx] = value_part
                    elif sub_oid.startswith("4.1.8."):
                        severity[idx] = value_part
        
        # Build items from indices present in all needed dicts
        items = []
        for idx in input_name:
            if idx in current_state and idx in normal_state and idx in severity:
                name = input_name.get(idx, "")
                location = input_location.get(idx, "")
                state = current_state.get(idx, "")
                normal = normal_state.get(idx, "")
                sev = severity.get(idx, "")
                
                # Compute state tuple
                state_readable, state_enum = _get_state_tuple(state, normal, sev)
                loc_info = ""
                if location:
                    loc_info = "[%s] " % location
                
                items.append({
                    "item": name + " " + idx,
                    "params": {},
                    "metrics": [],
                })
        
        return {"changed": False, "msg": "discovered %d dry contacts" % len(items),
                "data": {"discovery": items}}
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    if item == "":
        fail("item is required")
    
    # Extract index from item (format: "name index")
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        fail("invalid item format: " + item)
    idx = parts[1]
    
    # Re-run snmpwalk to get current state (same as discovery)
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.318.1.1.10.4.3"
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    
    # Parse output
    input_location = {}
    current_state = {}
    normal_state = {}
    severity = {}
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid_part.startswith(base_oid + "."):
            sub_oid = oid_part[len(base_oid)+1:]
            path_parts = sub_oid.split(".")
            if len(path_parts) >= 2:
                item_idx = path_parts[-1]
                if item_idx == idx:
                    if sub_oid.startswith("2.1.4."):
                        input_location[idx] = value_part.strip('"')
                    elif sub_oid.startswith("2.1.5."):
                        current_state[idx] = value_part
                    elif sub_oid.startswith("4.1.7."):
                        normal_state[idx] = value_part
                    elif sub_oid.startswith("4.1.8."):
                        severity[idx] = value_part
    
    # Check if item exists
    if not current_state.get(idx) or not normal_state.get(idx) or not severity.get(idx):
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Compute state
    state = current_state.get(idx, "")
    normal = normal_state.get(idx, "")
    sev = severity.get(idx, "")
    state_readable, state_enum = _get_state_tuple(state, normal, sev)
    
    location = input_location.get(idx, "")
    loc_info = ""
    if location:
        loc_info = "[%s] " % location
    
    return {"changed": False, "msg": loc_info + state_readable,
            "data": {"state": state_enum, "metrics": {}, "details": ""}}
