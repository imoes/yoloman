# Module-level constants
TUNNEL_STATES = {
    "3": "Active",
    "4": "Destroy",
    "129": "Idle",
    "130": "Phase1",
    "131": "Down",
    "132": "Init",
}

# Default state mappings from Checkmk plugin
DEFAULT_STATE_MAP = {
    "Active": 0,
    "Destroy": 1,
    "Idle": 0,
    "Phase1": 2,
    "Down": 2,
    "Init": 1,
}

# State code mapping (OK=0, WARN=1, CRIT=2, UNKNOWN=3)
STATE_CODE_MAP = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
    3: "UNKNOWN",
}

def main(ctx, params):
    # Discovery mode: enumerate all tunnel peers
    if params.get("_discover") == True:
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2620.500.9002.1.2"  # OID index 2 = tunnel peer
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "SNMP error or no output",
                "data": {"discovery": []}
            }
        
        items = []
        for line in res.stdout.splitlines():
            # Format: .1.3.6.1.4.1.2620.500.9002.1.2.<idx> = STRING: "<peer_ip>"
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            value = parts[1].strip()
            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            if value:
                items.append({
                    "item": value,
                    "params": DEFAULT_STATE_MAP.copy(),
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d tunnels" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: examine one tunnel item
    item = params.get("item", "")
    
    # Fetch both peer (index 2) and status (index 3) OIDs
    res_peer = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.500.9002.1.2"
    ], mutates=False)
    
    res_status = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.500.9002.1.3"
    ], mutates=False)
    
    if res_peer.rc != 0 or not res_peer.stdout or res_status.rc != 0 or not res_status.stdout:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query failed"
            }
        }
    
    # Parse peer names
    peer_map = {}
    for line in res_peer.stdout.splitlines():
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        value = parts[1].strip()
        # Extract index from OID tail
        oid_part = parts[0].strip()
        idx = oid_part.rsplit(".", 1)[-1]
        # Remove quotes if present
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        peer_map[idx] = value
    
    # Parse status values
    status_map = {}
    for line in res_status.stdout.splitlines():
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        value = parts[1].strip()
        # Extract index from OID tail
        oid_part = parts[0].strip()
        idx = oid_part.rsplit(".", 1)[-1]
        if idx.isdigit():
            status_map[idx] = value
    
    # Match the requested item
    found = False
    for idx, peer in peer_map.items():
        if peer == item:
            found = True
            status_str = status_map.get(idx, "")
            state_name = TUNNEL_STATES.get(status_str)
            
            if state_name == None:
                return {
                    "changed": False,
                    "msg": "Unknown tunnel status: %s" % status_str,
                    "data": {
                        "state": "UNKNOWN",
                        "metrics": {},
                        "details": "Unknown tunnel status"
                    }
                }
            
            # Determine state based on params or defaults
            state_code = params.get(state_name, DEFAULT_STATE_MAP.get(state_name, 0))
            actual_state = STATE_CODE_MAP.get(state_code, "UNKNOWN")
            
            return {
                "changed": False,
                "msg": state_name,
                "data": {
                    "state": actual_state,
                    "metrics": {},
                    "details": "Tunnel status: " + state_name
                }
            }
    
    # Item not found
    if not found:
        return {
            "changed": False,
            "msg": "Tunnel not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Tunnel not found"
            }
        }
