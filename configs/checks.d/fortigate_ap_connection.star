# Constants for state mapping (Checkmk default)
_CONN_STATE_TO_READABLE = {
    "0": ("offLine", "The WTP is not connected."),
    "1": ("onLine", "The WTP is connected."),
    "2": ("downloadingImage", "The WTP is downloading software image from the AC on joining."),
    "3": ("connectedImage", "The AC is pushing software image to the connected WTP."),
    "4": ("standby", "The WTP is standby on the AC."),
    "other": ("other", "The WTP connection state is unknown."),
}

# Default state mapping (OK=0, WARN=1, CRIT=2, UNKNOWN=3)
_DEFAULT_CONN_STATE_TO_MON_STATE = {
    "other": 3,
    "offLine": 1,
    "onLine": 0,
    "downloadingImage": 0,
    "connectedImage": 0,
    "standby": 0,
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Get WTP names (OID: .1.3.6.1.4.1.12356.101.14.4.3.1.3)
        res_wtp = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.12356.101.14.4.3.1.3"
        ], mutates=False)
        
        # Get connection states and station counts (OIDs: .1.3.6.1.4.1.12356.101.14.4.4.1.7 and .17)
        res_conn = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.12356.101.14.4.4.1.7"
        ], mutates=False)
        res_clients = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.12356.101.14.4.4.1.17"
        ], mutates=False)
        
        # Parse WTP names
        wtp_names = []
        for line in res_wtp.stdout.splitlines():
            if "=" in line:
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    wtp_names.append(parts[1].strip().strip('"'))
        
        # Parse connection states
        conn_states = {}
        for line in res_conn.stdout.splitlines():
            if "=" in line:
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    # Extract last part of OID as key
                    oid_part = parts[0].strip()
                    oid_idx = oid_part.rsplit(".", 1)[-1]
                    value = parts[1].strip()
                    if value.isdigit():
                        conn_states[oid_idx] = value
        
        # Parse station counts
        client_counts = {}
        for line in res_clients.stdout.splitlines():
            if "=" in line:
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    oid_part = parts[0].strip()
                    oid_idx = oid_part.rsplit(".", 1)[-1]
                    value = parts[1].strip()
                    if value.isdigit():
                        client_counts[oid_idx] = int(value)
        
        # Build discovery items
        items = []
        for i, name in enumerate(wtp_names):
            if name:
                oid_idx = str(i + 1)  # SNMP index typically 1-based
                status = conn_states.get(oid_idx, "0")
                # Map status code to readable name
                status_name = _CONN_STATE_TO_READABLE.get(status, ("other", ""))[0]
                station_count = client_counts.get(oid_idx, 0)
                
                items.append({
                    "item": name,
                    "params": {"conn_state_to_mon_state": _DEFAULT_CONN_STATE_TO_MON_STATE},
                    "metrics": ["connections"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d access points" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get WTP names and their indices
    res_wtp = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.12356.101.14.4.3.1.3"
    ], mutates=False)
    
    # Get connection states
    res_conn = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.12356.101.14.4.4.1.7"
    ], mutates=False)
    
    # Get station counts
    res_clients = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.12356.101.14.4.4.1.17"
    ], mutates=False)
    
    # Build mapping from item name to status and client count
    wtp_names = []
    wtp_map = {}  # name -> (oid_idx, status, clients)
    
    for line in res_wtp.stdout.splitlines():
        if "=" in line:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                name = parts[1].strip().strip('"')
                if name:
                    wtp_names.append(name)
    
    # Parse connection states and clients
    conn_states = {}
    for line in res_conn.stdout.splitlines():
        if "=" in line:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_part = parts[0].strip()
                oid_idx = oid_part.rsplit(".", 1)[-1]
                value = parts[1].strip()
                if value.isdigit():
                    conn_states[oid_idx] = value
    
    client_counts = {}
    for line in res_clients.stdout.splitlines():
        if "=" in line:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_part = parts[0].strip()
                oid_idx = oid_part.rsplit(".", 1)[-1]
                value = parts[1].strip()
                if value.isdigit():
                    client_counts[oid_idx] = int(value)
    
    # Map by index (position in walk)
    for i, name in enumerate(wtp_names):
        oid_idx = str(i + 1)
        status = conn_states.get(oid_idx, "0")
        station_count = client_counts.get(oid_idx, 0)
        wtp_map[name] = (oid_idx, status, station_count)
    
    # Check if item exists
    if item not in wtp_map:
        return {
            "changed": False,
            "msg": "AP not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    oid_idx, status, station_count = wtp_map[item]
    
    # Get state mapping (default if not provided)
    conn_state_to_mon_state = params.get("conn_state_to_mon_state", _DEFAULT_CONN_STATE_TO_MON_STATE)
    
    # Map status to readable name
    status_name = _CONN_STATE_TO_READABLE.get(status, ("other", ""))[0]
    
    # Determine state
    mon_state = conn_state_to_mon_state.get(status_name, 3)  # default UNKNOWN
    
    # Map to Checkmk states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(mon_state, "UNKNOWN")
    
    # Get description
    description = _CONN_STATE_TO_READABLE.get(status, ("other", ""))[1]
    
    # Build metrics
    metrics = {"connections": station_count}
    
    return {
        "changed": False,
        "msg": "State: " + status_name + ", Clients: " + str(station_count),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": description
        }
    }
