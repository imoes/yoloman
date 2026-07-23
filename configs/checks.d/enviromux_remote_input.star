# Module-level constants
INPUT_STATUS_MAPPING = {
    "normal": "OK",
    "prealert": "CRIT",
    "alert": "CRIT",
    "acknowledged": "WARN",
    "dismissed": "WARN",
    "disconnected": "CRIT",
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Run snmpwalk to get all remote input entries
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.12.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1",  # remoteInputIndex
            base_oid + ".3",  # remoteInputDescription
            base_oid + ".7",  # remoteInputValue
            base_oid + ".8",  # remoteInputStatus
            base_oid + ".9",  # remoteInputNormalValue
        ], mutates=False)
        
        # Parse SNMP output
        lines = res.stdout.splitlines()
        
        # Organize by index: group lines by OID prefix to collect all fields for each entry
        entries = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # OID format: .1.3.6.1.4.1.3699.1.1.11.1.12.1.1.<oid>.<index>
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid, value = parts
            oid = oid.strip()
            value = value.strip()
            
            # Extract field type and index from OID
            # base_oid is .1.3.6.1.4.1.3699.1.1.11.1.12.1.1
            # full OID: base_oid.<field_oid>.<index>
            suffix = oid[len(base_oid)+1:]  # after base_oid + dot
            if "." not in suffix:
                continue
            field_oid, index = suffix.rsplit(".", 1)
            if index.isdigit():
                idx = int(index)
            else:
                continue
            
            # Map field_oid to field name
            field_map = {"1": "index", "3": "desc", "7": "value", "8": "status", "9": "normal_value"}
            field = field_map.get(field_oid)
            if not field:
                continue
            
            # Initialize entry dict for this index if needed
            if idx not in entries:
                entries[idx] = {}
            
            # Clean value: strip type prefix (e.g., "INTEGER: ", "STRING: ")
            value = value.strip()
            if value.startswith("STRING: "):
                value = value[8:].strip().strip('"')
            elif value.startswith("INTEGER: "):
                value = value[9:].strip()
            
            entries[idx][field] = value
        
        # Build discovery result
        discovery_items = []
        for idx, entry in sorted(entries.items()):
            # Required fields: desc and status
            desc = entry.get("desc", "")
            status = entry.get("status", "")
            if not desc or not status.isdigit():
                continue
            
            # Skip notconnected status items
            status_int = int(status)
            if status_int == 0:
                continue
            
            item = desc + " " + str(idx)
            discovery_items.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d remote inputs" % len(discovery_items),
            "data": {"discovery": discovery_items},
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.12.1.1"
    # Get the index from item (last space-separated token)
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse description and index
    # Guard before risky int conversion
    index_str = parts[1]
    if not index_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    index = int(index_str)
    
    # Fetch all required fields for the specific item using snmpget
    # Build full OIDs for each field for this index
    oid_list = [base_oid + ".3." + str(index), base_oid + ".7." + str(index),
                base_oid + ".8." + str(index), base_oid + ".9." + str(index)]
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host
    ] + oid_list, mutates=False)
    
    # Parse output: each line is "OID = TYPE: value"
    raw_data = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid, value = parts
        oid = oid.strip()
        value = value.strip()
        
        # Extract field number from OID (last component)
        suffix = oid[len(base_oid)+1:]
        if "." not in suffix:
            continue
        field_oid = suffix.rsplit(".", 1)[0]
        
        # Map field OID to field name
        field_map = {"3": "desc", "7": "value", "8": "status", "9": "normal_value"}
        field = field_map.get(field_oid)
        if not field:
            continue
        
        # Clean value: strip type prefix
        value = value.strip()
        if value.startswith("STRING: "):
            value = value[8:].strip().strip('"')
        elif value.startswith("INTEGER: "):
            value = value[9:].strip()
        
        raw_data[field] = value
    
    # Verify required fields exist
    if "status" not in raw_data or "value" not in raw_data or "normal_value" not in raw_data:
        return {
            "changed": False,
            "msg": "no such remote input: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Extract values
    value = raw_data.get("value", "")
    status = raw_data.get("status", "")
    normal_value = raw_data.get("normal_value", "")
    desc = raw_data.get("desc", "")
    
    # Determine state and messages
    status_int = -1
    if status.isdigit():
        status_int = int(status)
    
    if status_int not in [0, 1, 2, 3, 4, 5, 6]:
        return {
            "changed": False,
            "msg": "unknown status: " + str(status),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Build message parts
    msg_parts = ["Input value: " + str(value) + ", Normal value: " + str(normal_value)]
    
    # Check if value differs from normal
    if value != normal_value:
        msg_parts.append("Input value different from normal")
    
    # Get state from status
    status_name = "unknown"
    if status_int == 0:
        status_name = "notconnected"
    elif status_int == 1:
        status_name = "normal"
    elif status_int == 2:
        status_name = "prealert"
    elif status_int == 3:
        status_name = "alert"
    elif status_int == 4:
        status_name = "acknowledged"
    elif status_int == 5:
        status_name = "dismissed"
    elif status_int == 6:
        status_name = "disconnected"
    
    state = INPUT_STATUS_MAPPING.get(status_int, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": "Status: " + status_name,
        },
    }
