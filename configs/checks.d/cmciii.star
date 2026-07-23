# ===== Starlark check module for cmk.cmciii (state monitor) =====
# This check monitors the state of Rittal CMCIII devices via SNMP.
# It reproduces the Checkmk check plugin logic as a read-only Starlark module.

# OID base constants (from Checkmk source)
BASE_OID_DEVICE_TABLE = ".1.3.6.1.4.1.2606.7.4.1.2.1"
BASE_OID_VAR_TABLE = ".1.3.6.1.4.1.2606.7.4.2.2.1"

# MAP_STATES mapping (state ID -> (State, description))
# Using Starlark-compatible strings for states: "OK", "WARN", "CRIT", "UNKNOWN"
MAP_STATES = {
    "1": ("UNKNOWN", "not available"),
    "2": ("OK", "OK"),
    "3": ("WARN", "detect"),
    "4": ("CRIT", "lost"),
    "5": ("WARN", "changed"),
    "6": ("CRIT", "error"),
}

def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        # Fetch device table via SNMP
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            BASE_OID_DEVICE_TABLE
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP device table query failed",
                "data": {"discovery": []}
            }
        
        # Parse device table lines: "OID = STRING: name", "OID = STRING: alias", "OID = INTEGER: status"
        # The SNMP section fetches 4 OIDs per device: endoid (index), name, alias, status
        # We need to group them as 4-tuples per device
        devices = {}
        states = {}
        num = 0
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            # Expect 4 lines per device (OIDEnd, name, alias, status)
            if i + 3 >= len(lines):
                break
            
            # Extract value from "OID = TYPE: value" format
            line1 = lines[i].strip()
            line2 = lines[i+1].strip()
            line3 = lines[i+2].strip()
            line4 = lines[i+3].strip()
            
            # Get endoid (index)
            endoid = ""
            if "=" in line1:
                endoid = line1.split("=")[0].strip()
            
            # Get name
            name = ""
            if "=" in line2:
                parts = line2.split("=")
                val = "=".join(parts[1:]).strip()
                if val.startswith("STRING:"):
                    name = val[7:].strip().strip('"')
            
            # Get alias
            alias = ""
            if "=" in line3:
                parts = line3.split("=")
                val = "=".join(parts[1:]).strip()
                if val.startswith("STRING:"):
                    alias = val[7:].strip().strip('"')
            
            # Get status
            status = ""
            if "=" in line4:
                parts = line4.split("=")
                val = "=".join(parts[1:]).strip()
                if val.startswith("INTEGER:"):
                    status = val[8:].strip()
            
            # Skip if we don't have all required fields
            if not endoid or not status:
                i += 4
                continue
            
            num += 1
            # Build dev_name (alias with spaces replaced by underscores, fallback to name-index)
            dev_name = alias.replace(" ", "_")
            if not dev_name:
                dev_name = name + "-" + str(num)
            
            # Handle duplicate dev_name by appending endoid
            if dev_name in states and states[dev_name]["_location_"] != endoid:
                dev_name += " %s" % endoid
            
            devices[endoid] = dev_name
            states[dev_name] = {"status": status, "_location_": endoid}
            
            i += 4
        
        # Build discovery list
        discovery_items = []
        for id_, entry in states.items():
            if params.get("use_sensor_description", False):
                item = "%s %s" % (entry["_location_"], id_)
            else:
                item = id_
            discovery_items.append({
                "item": item,
                "params": {"_item_key": id_},
                "metrics": ["state"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    entry_key = params.get("_item_key", item)
    
    # Fetch device table via SNMP (read-only)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        BASE_OID_DEVICE_TABLE
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse device table to find the specific device entry
    # We need to locate the device with matching item/key
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        if i + 3 >= len(lines):
            break
        
        line1 = lines[i].strip()
        line2 = lines[i+1].strip()
        line3 = lines[i+2].strip()
        line4 = lines[i+3].strip()
        
        # Extract values
        endoid = ""
        if "=" in line1:
            endoid = line1.split("=")[0].strip()
        
        name = ""
        if "=" in line2:
            parts = line2.split("=")
            val = "=".join(parts[1:]).strip()
            if val.startswith("STRING:"):
                name = val[7:].strip().strip('"')
        
        alias = ""
        if "=" in line3:
            parts = line3.split("=")
            val = "=".join(parts[1:]).strip()
            if val.startswith("STRING:"):
                alias = val[7:].strip().strip('"')
        
        status = ""
        if "=" in line4:
            parts = line4.split("=")
            val = "=".join(parts[1:]).strip()
            if val.startswith("INTEGER:"):
                status = val[8:].strip()
        
        # Build dev_name (same logic as discovery)
        dev_name = alias.replace(" ", "_")
        if not dev_name:
            dev_name = name + "-" + str(i//4 + 1)
        
        if dev_name in states and states[dev_name]["_location_"] != endoid:
            dev_name += " %s" % endoid
        
        # Check if this is the target device
        if dev_name == entry_key:
            # Found the device - get state mapping
            status_val = status if status in MAP_STATES else "1"
            state, state_readable = MAP_STATES.get(status_val, ("UNKNOWN", "not available"))
            
            return {
                "changed": False,
                "msg": "Status: %s" % state_readable,
                "data": {
                    "state": state,
                    "metrics": {"state": 1.0 if state == "OK" else (0.0 if state == "CRIT" else 0.5)},
                    "details": ""
                }
            }
        
        i += 4
    
    # Device not found
    return {
        "changed": False,
        "msg": "device not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
