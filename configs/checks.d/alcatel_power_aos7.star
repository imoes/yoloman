# ===== Starlark check: alcatel_power_aos7 =====
# Translation of Checkmk check: checkmk.alcatel_power_aos7
# Read-only SNMP check for Alcatel-Lucent AOS7 power supplies

def main(ctx, params):
    # Mappings defined at module top level (Starlark requirement)
    alcatel_power_aos7_operability_to_status_mapping = {
        "1": "up",
        "2": "down",
        "3": "testing",
        "4": "unknown",
        "5": "secondary",
        "6": "not present",
        "7": "unpowered",
        "8": "master",
        "9": "idle",
        "10": "power save",
    }

    alcatel_power_aos7_no_power_supply = "no power supply"
    
    alcatel_power_aos7_power_type_mapping = {
        "0": alcatel_power_aos7_no_power_supply,
        "1": "AC",
        "2": "DC",
    }
    
    base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".2",  # operabilityStatus
            base_oid + ".35", # powerSupplyType
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []},
            }
        
        # Parse snmpwalk output: lines like ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.1.2 = INTEGER: 1"
        # We need to correlate items by their index (end of OID)
        power_entries = {}
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            
            oid_full = parts[0]
            value = parts[1]
            
            # Extract index (last numeric part of OID)
            oid_end = oid_full.rsplit(".", 1)
            if len(oid_end) != 2:
                continue
            
            # Extract value integer
            val_parts = value.split(": ")
            if len(val_parts) < 2:
                continue
            value_str = val_parts[1].strip()
            if not value_str.isdigit():
                continue
            
            index = oid_end[1]
            value_int = value_str
            
            # Store value by index
            if index not in power_entries:
                power_entries[index] = {}
            
            # Determine which OID this is by checking OID length/structure
            # base_oid.2 = operabilityStatus, base_oid.35 = powerSupplyType
            if oid_full.endswith(".2"):
                power_entries[index]["operability"] = value_int
            elif oid_full.endswith(".35"):
                power_entries[index]["type"] = value_int
        
        # Build discovery list
        discovered = []
        for idx, entry in sorted(power_entries.items()):
            # Map values to readable strings
            status_readable = alcatel_power_aos7_operability_to_status_mapping.get(
                entry.get("operability", "4"), "unknown"
            )
            power_type = alcatel_power_aos7_power_type_mapping.get(
                entry.get("type", "0"), alcatel_power_aos7_no_power_supply
            )
            
            # Only discover if it's a real power supply and not "not present"
            if (power_type != alcatel_power_aos7_no_power_supply and
                status_readable != "not present"):
                # Item name is just the index (e.g., "1")
                item = str(idx)
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": [],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovered),
            "data": {"discovery": discovered},
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    
    # Fetch both required OIDs in one walk for the specific item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        base_oid + ".2." + item,  # operabilityStatus
        base_oid + ".35." + item, # powerSupplyType
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for item " + item + ": " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Parse snmpget output: lines like ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.1.2 = INTEGER: 1"
    values = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        
        oid_full = parts[0]
        value = parts[1]
        
        # Extract value
        val_parts = value.split(": ")
        if len(val_parts) < 2:
            continue
        value_str = val_parts[1].strip()
        if not value_str.isdigit():
            continue
        
        # Determine OID type from suffix
        if oid_full.endswith(".2"):
            values["operability"] = value_str
        elif oid_full.endswith(".35"):
            values["type"] = value_str
    
    # Check if we got values for both OIDs
    if "operability" not in values or "type" not in values:
        return {
            "changed": False,
            "msg": "missing data for power supply " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Map values
    status_readable = alcatel_power_aos7_operability_to_status_mapping.get(
        values["operability"], "unknown"
    )
    power_type = alcatel_power_aos7_power_type_mapping.get(
        values["type"], alcatel_power_aos7_no_power_supply
    )
    
    # Determine state (CRIT if not "up", OK otherwise)
    state = "OK" if status_readable == "up" else "CRIT"
    
    # Build message in Checkmk style
    msg = "[%s] Status: %s" % (power_type, status_readable)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
