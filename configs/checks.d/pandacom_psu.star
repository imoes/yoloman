def _map_psu_type(type_index):
    map_psu_type = {
        "0": "type not configured",
        "1": "230 V AC 75 W",
        "2": "230 V AC 160 W",
        "3": "48 V DC 75 W",
        "4": "48 V DC 150 W",
        "5": "48 V DC 60 W",
        "6": "230 V AC 60 W",
        "7": "48 V DC 250 W",
        "8": "230 V AC 250 W",
        "9": "48 V DC 1100 W",
        "10": "230 V AC 1100 W",
        "255": "type not available",
        "65025": "48 V DC 60 W",
        "65026": "230 V AC 60 W",
        "65027": "48 V DC 250 W",
        "65028": "230 V AC 250 W",
        "65029": "48 V DC 1100 W",
        "65030": "230 V AC 1100 W",
        "65031": "48 V DC 1100 W 1 UH",
        "65032": "230 V AC 1100 W 1 UH",
        "65033": "230 V AC 1200W 1 UH",
    }
    return map_psu_type.get(type_index, "unknown type")

def _map_psu_state(state_index):
    map_psu_state = {
        "0": ("UNKNOWN", "not installed"),
        "1": ("CRIT", "fail"),
        "2": ("WARN", "temperature warning"),
        "3": ("OK", "pass"),
        "255": ("UNKNOWN", "not available"),
    }
    return map_psu_state.get(state_index, ("UNKNOWN", "unknown state"))

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.3652.3.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output into a dict keyed by OID suffix
        snmp_data = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            value_part = parts[1].strip()
            # Extract last number from OID like .1.3.6.1.4.1.3652.3.2.1.2.0
            oid_tokens = oid_part.rsplit(".", 1)
            if len(oid_tokens) != 2:
                continue
            suffix = oid_tokens[1]
            # Extract value type and content
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip().strip('"')
            else:
                value = value_part
            
            snmp_data[suffix] = value
        
        # Build section as parse_pandacom_psu would
        section = {}
        for psu_nr, type_oid, state_oid in [
            ("1", "6", "3"),
            ("2", "7", "4"),
            ("3", "11", "12"),
        ]:
            type_index = snmp_data.get(type_oid, "0")
            state_index = snmp_data.get(state_oid, "0")
            
            # Skip if state is "0" (not installed) or "255" (not available)
            if state_index in ["0", "255"]:
                continue
            
            section[psu_nr] = {
                "type": _map_psu_type(type_index),
                "state": _map_psu_state(state_index),
            }
        
        # Discover services for each PSU
        discovered = []
        for psu_nr in section:
            discovered.append({
                "item": psu_nr,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.2.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse SNMP output
    snmp_data = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1].strip()
        oid_tokens = oid_part.rsplit(".", 1)
        if len(oid_tokens) != 2:
            continue
        suffix = oid_tokens[1]
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value = value_part
        snmp_data[suffix] = value
    
    # Build section as parse_pandacom_psu would
    section = {}
    for psu_nr, type_oid, state_oid in [
        ("1", "6", "3"),
        ("2", "7", "4"),
        ("3", "11", "12"),
    ]:
        type_index = snmp_data.get(type_oid, "0")
        state_index = snmp_data.get(state_oid, "0")
        
        if state_index in ["0", "255"]:
            continue
        
        section[psu_nr] = {
            "type": _map_psu_type(type_index),
            "state": _map_psu_state(state_index),
        }
    
    # Check the specific item
    if item not in section:
        return {
            "changed": False,
            "msg": "PSU %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state, state_readable = section[item]["state"]
    psu_type = section[item]["type"]
    
    return {
        "changed": False,
        "msg": "[%s] Operational status: %s" % (psu_type, state_readable),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }