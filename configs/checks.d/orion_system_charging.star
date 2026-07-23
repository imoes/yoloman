# Mapping of charge state codes to (state_int, state_readable)
CHARGE_STATE_MAP = {
    "1": (0, "float charging"),
    "2": (0, "discharge"),
    "3": (0, "equalize"),
    "4": (0, "boost"),
    "5": (0, "battery test"),
    "6": (0, "recharge"),
    "7": (0, "separate charge"),
    "8": (0, "event control charge"),
}

def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # Discovery mode: fetch SNMP data and enumerate charging entities
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "SNMP walk failed or returned no data",
                "data": {"discovery": []}
            }
        
        # Parse first line (only one row expected)
        lines = res.stdout.splitlines()
        if len(lines) < 8:
            return {
                "changed": False,
                "msg": "SNMP data incomplete (expected 8 OIDs)",
                "data": {"discovery": []}
            }
        
        # Extract values (line format: OID = STRING: "value")
        values = []
        for line in lines[:8]:
            parts = line.strip().split(" = ", 1)
            if len(parts) == 2 and parts[1].startswith('STRING: "'):
                val = parts[1][8:-1]  # Remove 'STRING: "' and trailing '"'
                values.append(val)
            else:
                values.append("2147483647")
        
        if len(values) < 8:
            values = values + ["2147483647"] * (8 - len(values))
        
        charge_state = values[4]
        
        # Build section-like data
        map_charge_states = CHARGE_STATE_MAP
        state_tuple = map_charge_states.get(charge_state, (3, "unknown[" + charge_state + "]"))
        
        # Only Battery entity is exposed in charging section
        charging_entity = "Battery"
        
        # Return discovery list
        return {
            "changed": False,
            "msg": "discovered 1 charging item",
            "data": {"discovery": [
                {"item": charging_entity, "params": {}, "metrics": []}
            ]}
        }
    
    # Check mode: verify charging state of requested item
    item = params.get("item", "")
    if item == "":
        # For backward compatibility, default to Battery if item is empty
        item = "Battery"
    
    # Fetch SNMP data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed or returned no data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to retrieve SNMP data"
            }
        }
    
    # Parse first line (only one row expected)
    lines = res.stdout.splitlines()
    if len(lines) < 8:
        return {
            "changed": False,
            "msg": "SNMP data incomplete (expected 8 OIDs)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Expected 8 SNMP values"
            }
        }
    
    # Extract values
    values = []
    for line in lines[:8]:
        parts = line.strip().split(" = ", 1)
        if len(parts) == 2 and parts[1].startswith('STRING: "'):
            val = parts[1][8:-1]
            values.append(val)
        else:
            values.append("2147483647")
    
    if len(values) < 8:
        values = values + ["2147483647"] * (8 - len(values))
    
    charge_state = values[4]
    state_tuple = CHARGE_STATE_MAP.get(charge_state, (3, "unknown[" + charge_state + "]"))
    
    # Map Checkmk State ints: 0->OK, 1->WARN, 2->CRIT, 3->UNKNOWN
    state_int, state_readable = state_tuple
    if state_int == 0:
        state_name = "OK"
    elif state_int == 1:
        state_name = "WARN"
    elif state_int == 2:
        state_name = "CRIT"
    else:
        state_name = "UNKNOWN"
    
    # Build message
    msg = "Status: " + state_readable
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }