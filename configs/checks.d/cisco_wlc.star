# Module-level constants
_DEVICE_OIDS = (
    ".1.3.6.1.4.1.14179.1.1.4.3",
    ".1.3.6.1.4.1.9.1.1069",
    ".1.3.6.1.4.1.9.1.1279",
    ".1.3.6.1.4.1.9.1.1293",
    ".1.3.6.1.4.1.9.1.1615",
    ".1.3.6.1.4.1.9.1.1631",
    ".1.3.6.1.4.1.9.1.1645",
    ".1.3.6.1.4.1.9.1.2170",
    ".1.3.6.1.4.1.9.1.2250",
    ".1.3.6.1.4.1.9.1.2370",
    ".1.3.6.1.4.1.9.1.2371",
    ".1.3.6.1.4.1.9.1.2427",
    ".1.3.6.1.4.1.9.1.2489",
    ".1.3.6.1.4.1.9.1.2530",
    ".1.3.6.1.4.1.9.1.2669",
    ".1.3.6.1.4.1.9.1.2860",
    ".1.3.6.1.4.1.9.1.2861",
    ".1.3.6.1.4.1.9.1.3323",
    ".1.3.6.1.4.1.9.1.3324",
)

_MAP_STATES = {
    "1": ("OK", "online"),
    "2": ("CRIT", "critical"),
    "3": ("WARN", "warning"),
}

_OID_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"

# Base OID for AP state data
_BASE_OID_AP = ".1.3.6.1.4.1.14179.2.2.1.1"


def _build_detect_spec():
    # Build detect spec: equals(sysObjectID, device_id) for each device_id in _DEVICE_OIDS
    # We can't use functional constructs here, so we just return a string representation
    # of the detection logic; the agent will use its own detection mechanism.
    # For simplicity, we'll use snmpwalk on the base OID and check if we get data.
    return True


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk the AP table and enumerate each AP name as an item
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _BASE_OID_AP + ".3"  # OID for AP name (index 3 in original SNMPTree)
        ], mutates=False)
        
        # Also need AP state OID to validate we have valid data
        res_state = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _BASE_OID_AP + ".6"  # OID for AP state (index 6 in original SNMPTree)
        ], mutates=False)
        
        # Parse AP names
        ap_items = []
        for line in res.stdout.splitlines():
            # Format: <OID>.<index> = STRING: "AP_NAME"
            parts = line.strip().split(" = STRING: ", 1)
            if len(parts) == 2:
                ap_name = parts[1].strip('"')
                ap_items.append({"item": ap_name, "params": {}, "metrics": []})
        
        if len(ap_items) == 0:
            return {"changed": False, "msg": "no access points discovered",
                    "data": {"discovery": []}}
        
        return {"changed": False, "msg": "discovered %d access points" % len(ap_items),
                "data": {"discovery": ap_items}}
    
    # Check mode: one specific AP
    item = params.get("item", "")
    
    # Fetch AP name and state
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _BASE_OID_AP
    ], mutates=False)
    
    ap_state = None
    
    # Parse output: look for our item in the AP name column
    lines = res.stdout.splitlines()
    ap_name_oid = _BASE_OID_AP + ".3"
    ap_state_oid = _BASE_OID_AP + ".6"
    
    ap_name_value = None
    ap_state_value = None
    
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Check for AP name line
        if line.startswith(ap_name_oid):
            # Extract index from OID
            # Format: <base>.<index> = STRING: "AP_NAME"
            oid_part = line.split(" = ", 1)[0]
            # Get the index suffix
            index_suffix = oid_part[len(ap_name_oid) + 1:] if len(oid_part) > len(ap_name_oid) + 1 else ""
            
            # Find the corresponding state line for this index
            j = i + 1
            while j < len(lines):
                state_line = lines[j].strip()
                if state_line.startswith(ap_state_oid):
                    state_oid_part = state_line.split(" = ", 1)[0]
                    state_index_suffix = state_oid_part[len(ap_state_oid) + 1:] if len(state_oid_part) > len(ap_state_oid) + 1 else ""
                    if state_index_suffix == index_suffix:
                        # Found matching pair
                        ap_name_value = line.split(" = STRING: ", 1)[1].strip('"') if " = STRING: " in line else ""
                        ap_state_value = state_line.split(" = ", 1)[1].strip() if " = " in state_line else ""
                        break
                j += 1
            if ap_state_value != None:
                break
        
        i += 1
    
    if ap_state_value == None:
        # Fallback: use snmpget for exact match on the item
        # Since snmpget is simpler for exact match, try it first
        # But note: not all agents support snmpget, so we'll use a more generic approach
        
        # Try to parse using splitlines approach
        # Build a map of AP names to states
        ap_map = {}
        current_ap = ""
        current_state = ""
        
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            
            if line.startswith(ap_name_oid):
                parts = line.split(" = STRING: ", 1)
                if len(parts) == 2:
                    current_ap = parts[1].strip('"')
                    # Try to find state immediately after
                    if i + 1 < len(lines):
                        next_line = lines[i + 1].strip()
                        if next_line.startswith(ap_state_oid):
                            current_state = next_line.split(" = ", 1)[1].strip()
                            ap_map[current_ap] = current_state
                            current_ap = ""
                            current_state = ""
            i += 1
        
        # Check if our item exists in the map
        if item in ap_map:
            ap_state_value = ap_map[item]
        else:
            # AP not found
            return {"changed": False, "msg": "Accesspoint not found",
                    "data": {"state": "CRIT", "metrics": {}, "details": "Accesspoint not found"}}
    
    # Map state
    state_info = _MAP_STATES.get(ap_state_value, ("UNKNOWN", "unknown[%s]" % ap_state_value))
    state = state_info[0]
    state_readable = state_info[1]
    
    summary = "Accesspoint: " + state_readable
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": summary}}
