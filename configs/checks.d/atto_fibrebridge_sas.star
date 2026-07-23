# Module-level maps (constant) - reproduce Checkmk state mappings
_operstate_map = {
    -1: "unknown",
    1: "online",
    2: "offline",
    3: "degraded",
}

_adminstate_map = {
    -1: "unknown",
    1: "disabled",
    2: "enabled",
}

_operstate_severity = {
    "unknown": "UNKNOWN",
    "online": "OK",
    "degraded": "WARN",
    "offline": "CRIT",
}


def main(ctx, params):
    if params.get("_discover"):
        # Discover mode: fetch SAS port data via SNMP and enumerate enabled ports
        base_oid = ".1.3.6.1.4.1.4547.2.3.3.3.1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        
        # If no output, nothing to discover
        if not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 SAS ports",
                "data": {"discovery": []}
            }
        
        # Parse SNMP walk output: OID = TYPE: value
        lines = res.stdout.splitlines()
        
        # Collect all port data by parsing SNMP walk output
        ports = {}  # index -> {name, admin_state, oper_state, phy1, phy2, phy3, phy4}
        for line in lines:
            if not line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            value = parts[1].strip()
            
            # Extract value after type
            if ":" in value:
                value = value.split(": ", 1)[-1].strip().strip('"')
            
            # Skip if not our OID
            if not oid_full.startswith(base_oid + "."):
                continue
            
            # Extract index and field suffix
            rest = oid_full[len(base_oid) + 1:]
            if "." not in rest:
                continue
            
            # Find the field number after the base
            parts_rest = rest.split(".")
            if len(parts_rest) < 1:
                continue
            
            # Parse index - guard against non-digit
            idx_str = parts_rest[0]
            idx = int(idx_str) if idx_str.isdigit() else 0
            
            # Determine which field we have based on remaining suffix
            if len(parts_rest) == 1:
                # This is field 2 (port name)
                field = "2"
            else:
                # Get the next part which indicates the field
                field = parts_rest[1] if len(parts_rest) > 1 else ""
            
            if field == "2":
                ports.setdefault(idx, {})["name"] = value
            elif field == "3":
                oper_val = int(value) if value.isdigit() else -1
                ports.setdefault(idx, {})["oper_state"] = _operstate_map.get(oper_val, "unknown")
            elif field == "4":
                ports.setdefault(idx, {})["phy1"] = value
            elif field == "5":
                ports.setdefault(idx, {})["phy2"] = value
            elif field == "6":
                ports.setdefault(idx, {})["phy3"] = value
            elif field == "7":
                ports.setdefault(idx, {})["phy4"] = value
            elif field == "8":
                admin_val = int(value) if value.isdigit() else -1
                ports.setdefault(idx, {})["admin_state"] = _adminstate_map.get(admin_val, "unknown")
        
        # Build discovery list for ports with admin_state == "enabled"
        discovery_list = []
        for idx, port in ports.items():
            name = port.get("name", "")
            admin = port.get("admin_state", "unknown")
            if admin == "enabled":
                discovery_list.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d SAS ports" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode: verify one SAS port
    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.4547.2.3.3.3.1"
    
    # Fetch data via snmpwalk
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)
    
    # If no output, item not found
    if not res.stdout:
        return {
            "changed": False,
            "msg": "port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP walk output
    lines = res.stdout.splitlines()
    ports = {}  # index -> {name, oper_state, admin_state, phy1, phy2, phy3, phy4}
    
    for line in lines:
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        value = parts[1].strip()
        
        # Extract value after type
        if ":" in value:
            value = value.split(": ", 1)[-1].strip().strip('"')
        
        # Skip if not our OID
        if not oid_full.startswith(base_oid + "."):
            continue
        
        # Extract index and field
        rest = oid_full[len(base_oid) + 1:]
        if "." not in rest:
            continue
        
        parts_rest = rest.split(".")
        if len(parts_rest) < 1:
            continue
        
        # Parse index - guard against non-digit
        idx_str = parts_rest[0]
        idx = int(idx_str) if idx_str.isdigit() else 0
        
        # Determine field
        if len(parts_rest) == 1:
            field = "2"
        else:
            field = parts_rest[1] if len(parts_rest) > 1 else ""
        
        # Build port entry
        if field == "2":
            ports.setdefault(idx, {})["name"] = value
        elif field == "3":
            oper_val = int(value) if value.isdigit() else -1
            ports.setdefault(idx, {})["oper_state"] = _operstate_map.get(oper_val, "unknown")
        elif field == "4":
            ports.setdefault(idx, {})["phy1"] = value
        elif field == "5":
            ports.setdefault(idx, {})["phy2"] = value
        elif field == "6":
            ports.setdefault(idx, {})["phy3"] = value
        elif field == "7":
            ports.setdefault(idx, {})["phy4"] = value
        elif field == "8":
            admin_val = int(value) if value.isdigit() else -1
            ports.setdefault(idx, {})["admin_state"] = _adminstate_map.get(admin_val, "unknown")
    
    # Find the requested item
    port_data = None
    for idx, port in ports.items():
        if port.get("name", "") == item:
            port_data = port
            break
    
    # If item not found or disabled, return UNKNOWN
    if port_data == None or port_data.get("admin_state") != "enabled":
        return {
            "changed": False,
            "msg": "port not found or admin_state != enabled: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get port info
    oper_state = port_data.get("oper_state", "unknown")
    state = _operstate_severity.get(oper_state, "UNKNOWN")
    
    # Build summary msg
    msg_parts = ["Operational state: " + oper_state]
    for i in range(1, 5):
        phy_key = "phy" + str(i)
        phy_val = port_data.get(phy_key, "unknown")
        # Clean value if it's an integer code
        if phy_val.isdigit():
            phy_val = _operstate_map.get(int(phy_val), "unknown")
        msg_parts.append("PHY%d operational state: %s" % (i, phy_val))
    
    msg = "; ".join(msg_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
