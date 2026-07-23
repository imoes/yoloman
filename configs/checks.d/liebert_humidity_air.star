# module: liebert_humidity_air.star
# Translate check: checkmk.liebert_humidity_air

LIEBERT_HUMIDITY_AIR_DEFAULT_PARAMETERS = {
    "levels": (50.0, 55.0),
    "levels_lower": (10.0, 15.0),
}

def _item_from_key(key):
    return key.replace(" Humidity", "")

def _get_oid_index(oid):
    idx = oid.rsplit(".", 1)
    return idx[-1] if len(idx) > 1 else ""

def _parse_snmp_value(line):
    if " = " in line:
        return line.split(" = ", 1)[-1].strip().strip('"')
    return ""

def main(ctx, params):
    # Parameters
    warn_upper = params.get("levels", LIEBERT_HUMIDITY_AIR_DEFAULT_PARAMETERS["levels"])
    warn_upper_val = 50.0
    crit_upper_val = 55.0
    if isinstance(warn_upper, list) and len(warn_upper) >= 2:
        warn_upper_val = warn_upper[0]
        crit_upper_val = warn_upper[1]
    
    warn_lower = params.get("levels_lower", LIEBERT_HUMIDITY_AIR_DEFAULT_PARAMETERS["levels_lower"])
    warn_lower_val = 10.0
    crit_lower_val = 15.0
    if isinstance(warn_lower, list) and len(warn_lower) >= 2:
        warn_lower_val = warn_lower[0]
        crit_lower_val = warn_lower[1]
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode
    if params.get("_discover"):
        # Get humidity labels
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2"
        ], mutates=False)
        
        discovered_items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            label = _parse_snmp_value(parts[1])
            
            if label and "Humidity" in label:
                idx = _get_oid_index(oid_part)
                value_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1." + idx
                unit_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1." + idx
                
                # Get value
                vres = ctx.run([
                    "snmpget", "-v2c", "-c", community, "-On", host, value_oid
                ], mutates=False)
                value_str = ""
                for vline in vres.stdout.splitlines():
                    if vline.strip():
                        value_str = _parse_snmp_value(vline)
                        break
                
                # Determine item
                item = _item_from_key(label)
                if "Unavailable" not in value_str:
                    discovered_items.append({
                        "item": item,
                        "params": {
                            "levels": [warn_upper_val, crit_upper_val],
                            "levels_lower": [warn_lower_val, crit_lower_val]
                        },
                        "metrics": ["humidity"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d humidities" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }
    
    # Check mode: get one item
    item = params.get("item", "")
    
    # Get system section (Unit Operating State) for standby detection
    sys_oid = ".1.3.6.1.4.1.476.1.42.3.9.10.1.2.1.1"
    sres = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, sys_oid
    ], mutates=False)
    device_state = "Unknown"
    for line in sres.stdout.splitlines():
        if line.strip():
            device_state = _parse_snmp_value(line)
            break
    
    # Get humidity data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2"
    ], mutates=False)
    
    # Build a mapping from item labels to values
    found = False
    value = ""
    unit = "%"
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        label = _parse_snmp_value(parts[1])
        
        if label and "Humidity" in label:
            idx = _get_oid_index(oid_part)
            value_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1." + idx
            unit_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1." + idx
            
            # Get value
            vres = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On", host, value_oid
            ], mutates=False)
            value_str = ""
            for vline in vres.stdout.splitlines():
                if vline.strip():
                    value_str = _parse_snmp_value(vline)
                    break
            
            # Get unit
            ures = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On", host, unit_oid
            ], mutates=False)
            unit_str = "%"
            for uline in ures.stdout.splitlines():
                if uline.strip():
                    unit_str = _parse_snmp_value(uline)
                    break
            
            if _item_from_key(label) == item:
                found = True
                value = value_str
                unit = unit_str
                break
    
    # Handle not found
    if not found:
        return {
            "changed": False,
            "msg": "humidity item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check standby condition
    if "Unavailable" in value and device_state.lower() == "standby":
        return {
            "changed": False,
            "msg": "Unit is in standby (unavailable)",
            "data": {"state": "OK", "metrics": {"humidity": 0.0}, "details": ""}
        }
    
    # Parse numeric value (guarded instead of try/except)
    num_value = 0.0
    if value and value.replace(".", "", 1).replace("-", "", 1).isdigit():
        num_value = float(value)
    else:
        return {
            "changed": False,
            "msg": "invalid humidity value: " + value,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state
    state = "OK"
    if num_value >= crit_upper_val:
        state = "CRIT"
    elif num_value >= warn_upper_val:
        state = "WARN"
    elif num_value <= crit_lower_val:
        state = "CRIT"
    elif num_value <= warn_lower_val:
        state = "WARN"
    
    # Format message
    msg = "%f %s" % (num_value, unit)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"humidity": num_value}, "details": ""}
    }