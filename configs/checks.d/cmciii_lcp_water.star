def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        section = []
        for line in res.stdout.splitlines():
            if line.strip():
                # Extract value after '=' and strip spaces
                parts = line.split(" = ")
                if len(parts) == 2:
                    section.append(parts[1].strip())
        
        water_section = _parse_cmciii_lcp_water(section)
        if not water_section:
            return {"changed": False, "msg": "no water unit data", "data": {"discovery": []}}
        
        discovery_items = [
            {"item": "IN", "params": {}, "metrics": ["temperature"]},
            {"item": "OUT", "params": {}, "metrics": ["temperature"]}
        ]
        return {
            "changed": False,
            "msg": "discovered 2 water temperature items",
            "data": {"discovery": discovery_items}
        }
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section = []
    for line in res.stdout.splitlines():
        if line.strip():
            parts = line.split(" = ")
            if len(parts) == 2:
                section.append(parts[1].strip())
    
    water_section = _parse_cmciii_lcp_water(section)
    if not water_section:
        return {
            "changed": False,
            "msg": "no water unit data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse unit status
    unit_status_name = water_section[2] if len(water_section) > 2 else "unknown"
    status_value = _parse_status(unit_status_name)
    
    # Determine lines based on item
    if item == "IN":
        lines = water_section[5:12] if len(water_section) > 12 else []
    else:
        lines = water_section[14:21] if len(water_section) > 20 else []
    
    if not lines:
        return {
            "changed": False,
            "msg": "no data for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse temperatures - guard before parsing
    temperatures = []
    if len(lines) >= 5:
        for i in range(5):
            val = lines[i].split()
            if len(val) > 0 and val[0].replace(".", "").replace("-", "").isdigit():
                temperatures.append(float(val[0]))
            else:
                return {
                    "changed": False,
                    "msg": "unable to parse temperatures",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
    else:
        return {
            "changed": False,
            "msg": "insufficient data lines",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    temp = temperatures[0] if temperatures else 0.0
    limits = temperatures[1:] if len(temperatures) > 1 else [0.0, 0.0, 0.0, 0.0]
    
    # Parse status line
    status_parts = lines[-1].split()
    status_str = status_parts[-1] if len(status_parts) > 0 else "ok"
    sensor_status = _parse_status(status_str)
    
    # Apply thresholds using Checkmk defaults
    warn = params.get("levels", [80.0, 90.0])
    crit = params.get("levels", [90.0, 100.0])
    warn_lower = params.get("levels_lower", [0.0, 10.0])
    crit_lower = params.get("levels_lower", [0.0, 5.0])
    
    # Check temperature against thresholds
    state = "OK"
    if temp >= crit[1]:
        state = "CRIT"
    elif temp >= warn[1]:
        state = "WARN"
    elif temp <= crit_lower[1]:
        state = "CRIT"
    elif temp <= warn_lower[1]:
        state = "WARN"
    
    # Combine with sensor status
    if sensor_status != "OK":
        state = "CRIT" if sensor_status == "CRIT" else ("WARN" if sensor_status == "WARN" else "CRIT")
    
    msg_parts = []
    msg_parts.append("Unit: " + unit_status_name)
    msg_parts.append("Temperature: %f C" % temp)
    msg = "; ".join(msg_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }


def _parse_status(status_name):
    status_lower = status_name.lower()
    if status_lower == "ok":
        return "OK"
    elif status_lower == "warning":
        return "WARN"
    else:
        return "CRIT"


def _parse_cmciii_lcp_water(section):
    units = {}
    unit_lines = None
    for line in section:
        if line.endswith(" Unit"):
            unit_name = line.split(" ")[0]
            unit_lines = []
            units[unit_name] = unit_lines
        elif unit_lines != None:
            unit_lines.append(line)
    
    if "Water" in units:
        return units["Water"]
    
    return []
