# Starlark check module: checkmk.ra32e_sensors_power
# Read-only check for power state per digital sensor

# SNMP OIDs for ra32e sensors
_BASE_OID_INTERNAL = ".1.3.6.1.4.1.20916.1.8.1.1"
_BASE_OID_DIGITAL = ".1.3.6.1.4.1.20916.1.8.1.2"

def _parse_ra32e_section(ctx, params):
    """Fetch and parse ra32e_sensors SNMP data (internal + digital sensors)."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch internal section: temperature, humidity, heat index (oids: 1, 2, 4.2)
    res_internal = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        _BASE_OID_INTERNAL + ".1", _BASE_OID_INTERNAL + ".2", _BASE_OID_INTERNAL + ".4.2"
    ], mutates=False)
    
    # Parse internal section (first three OIDs: temp, humidity, heat_index)
    internal_lines = res_internal.stdout.splitlines()
    internal = None
    if len(internal_lines) >= 3:
        temp_str = internal_lines[0].strip().split()[-1].strip('"')
        hum_str = internal_lines[1].strip().split()[-1].strip('"')
        heat_str = internal_lines[2].strip().split()[-1].strip('"')
        
        if temp_str != "" and hum_str != "" and heat_str != "":
            # Validate string formats before conversion
            temp_valid = temp_str.replace('.', '').replace('-', '').isdigit()
            hum_valid = hum_str.replace('.', '').replace('-', '').isdigit()
            heat_valid = heat_str.replace('.', '').replace('-', '').isdigit()
            
            if temp_valid and hum_valid and heat_valid:
                internal = {
                    "temperature": float(temp_str) / 100.0,
                    "humidity": float(hum_str) / 100.0,
                    "heat_index": float(heat_str) / 100.0,
                }

    # Fetch all digital sensor data for sensors 1-8 (each has 5 OIDs: temp, temp_F, status, etc.)
    digital_sections = []
    for i in range(1, 9):
        base = _BASE_OID_DIGITAL + "." + str(i)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base + ".1", base + ".2", base + ".3", base + ".4", base + ".5"
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        section = None
        if len(lines) >= 3:
            temp_str = lines[0].strip().split()[-1].strip('"')
            power_str = lines[2].strip().split()[-1].strip('"')
            
            # Only create section if we have temp and power data (temp/active_power type)
            if temp_str != "" and power_str != "":
                # Parse temperature
                temp_valid = temp_str.replace('.', '').replace('-', '').isdigit()
                if temp_valid:
                    temp = float(temp_str) / 100.0
                    power = power_str == "1"
                    section = {"temperature": temp, "power": power}
        digital_sections.append(section)
    
    return {"internal": internal, "digital": digital_sections}

def _index_to_sensor(index):
    return "Sensor " + str(index + 1)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        parsed = _parse_ra32e_section(ctx, params)
        discovery = []
        if parsed.get("digital") != None:
            for i, section in enumerate(parsed["digital"]):
                if section != None and section.get("power") != None:
                    discovery.append({
                        "item": _index_to_sensor(i),
                        "params": {},
                        "metrics": ["device_state"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d power sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    index = None
    if item.startswith("Sensor "):
        suffix = item[7:]
        if suffix.isdigit():
            index = int(suffix) - 1
    
    if index == None:
        return {
            "changed": False,
            "msg": "item not recognized: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parsed = _parse_ra32e_section(ctx, params)
    if parsed.get("digital") == None or index >= len(parsed["digital"]):
        return {
            "changed": False,
            "msg": "sensor index out of range: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    section = parsed["digital"][index]
    if section == None or section.get("power") == None:
        return {
            "changed": False,
            "msg": "power sensor data unavailable: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    power = section["power"]
    state = "OK" if power else "CRIT"
    msg = "power detected" if power else "no power detected"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"device_state": 0 if power else 1},
            "details": ""
        }
    }