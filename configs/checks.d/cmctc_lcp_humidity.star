# Sensor type mapping from Checkmk plugin
SENSOR_TYPE_MAP = {
    "4": ("access", "4"),
    "12": ("humidity", "12"),
    "13": ("user", "13"),
    "14": ("user", "14"),
    "23": ("flow", "23"),
    "30": ("current", "30"),
    "31": ("status", "31"),
    "32": ("position", "32"),
    "40": ("blower", "40"),
    "41": ("blower", "41"),
    "42": ("blower", "42"),
    "43": ("blower", "43"),
    "44": ("blower", "44"),
    "45": ("blower", "45"),
    "46": ("blower", "46"),
    "47": ("blower", "47"),
    "48": ("temp", "48"),
    "49": ("temp", "49"),
    "50": ("temp", "50"),
    "51": ("temp", "51"),
    "52": ("temp", "52"),
    "53": ("temp", "53"),
    "54": ("temp", "54"),
    "55": ("temp", "55"),
    "56": ("temp", "56"),
    "57": ("temp", "57"),
    "58": ("temp", "58"),
    "59": ("temp", "59"),
    "60": ("flow", "60"),
    "61": ("blowergrade", "61"),
    "62": ("regulator", "62"),
}

UNIT_MAP = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " °C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}

SENSOR_STATE_MAP = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # SNMP walk for the 4 trees: .1.3.6.1.4.1.2606.4.2.{3,4,5,6}
        results = []
        for tree in ["3", "4", "5", "6"]:
            base_oid = ".1.3.6.1.4.1.2606.4.2." + tree
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"),
                          base_oid + ".5.2.1"], mutates=False)
            
            # Parse each line: OID = TYPE: value
            lines = res.stdout.splitlines() if res.stdout else []
            # Group by index (first 7 OIDs per entry)
            i = 0
            while i < len(lines):
                if i + 7 >= len(lines):
                    break
                    
                # Extract values from 7 consecutive lines
                values = []
                for j in range(7):
                    line = lines[i + j]
                    # Parse "oid = type: value"
                    eq_idx = line.find("=")
                    if eq_idx == -1:
                        break
                    val = line[eq_idx+1:].strip()
                    # Extract the value part after type:
                    colon_idx = val.find(":")
                    if colon_idx != -1:
                        val = val[colon_idx+1:].strip()
                    values.append(val)
                
                if len(values) == 7:
                    # index, typeid, status, reading, high, low, warn
                    index = values[0]
                    typeid = values[1]
                    status = values[2]
                    reading = values[3]
                    high = values[4]
                    low = values[5]
                    warn = values[6]
                    
                    # Look up sensor type
                    sensor_info = SENSOR_TYPE_MAP.get(typeid)
                    if sensor_info:
                        sensor_type, type_id = sensor_info
                        # Build item name
                        if sensor_type == "humidity":
                            item = tree + "." + index
                            results.append({
                                "item": item,
                                "params": {},
                                "metrics": ["humidity"]
                            })
                
                i += 7
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(results),
            "data": {"discovery": results}
        }
    
    # Check mode for a specific humidity item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse tree.index from item
    dot_pos = item.find(".")
    if dot_pos == -1:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    tree = item[:dot_pos]
    index = item[dot_pos+1:]
    
    # Perform SNMP walk for this specific sensor
    base_oid = ".1.3.6.1.4.1.2606.4.2." + tree + ".5.2.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"),
                  base_oid], mutates=False)
    
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output to find the specific sensor entry
    lines = res.stdout.splitlines()
    i = 0
    sensor_found = False
    status = "4"  # Default to OK
    reading = 0.0
    high = 0.0
    low = 0.0
    warn = 0.0
    description = ""
    
    while i < len(lines):
        # Expect 7 consecutive lines per entry
        if i + 6 >= len(lines):
            break
        
        # Parse index
        line0 = lines[i]
        eq_idx = line0.find("=")
        if eq_idx == -1:
            i += 1
            continue
        val = line0[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        idx_val = val
        
        if idx_val != index:
            i += 7
            continue
        
        # Parse typeid
        line1 = lines[i+1]
        eq_idx = line1.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line1[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        typeid = val
        
        # Check if this is a humidity sensor
        if typeid != "12":
            i += 7
            continue
        
        # Parse status
        line2 = lines[i+2]
        eq_idx = line2.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line2[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        status = val
        
        # Parse reading
        line3 = lines[i+3]
        eq_idx = line3.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line3[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            reading = int(val)
        else:
            reading = 0.0
        
        # Parse high
        line4 = lines[i+4]
        eq_idx = line4.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line4[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            high = int(val)
        else:
            high = 0.0
        
        # Parse low
        line5 = lines[i+5]
        eq_idx = line5.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line5[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            low = int(val)
        else:
            low = 0.0
        
        # Parse warn
        line6 = lines[i+6]
        eq_idx = line6.find("=")
        if eq_idx == -1:
            i += 7
            continue
        val = line6[eq_idx+1:].strip()
        colon_idx = val.find(":")
        if colon_idx != -1:
            val = val[colon_idx+1:].strip()
        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            warn = int(val)
        else:
            warn = 0.0
        
        # Try to get description from next entry's last field (description is 7th field)
        # For simplicity, we'll use an empty description if not found
        description = ""
        
        sensor_found = True
        break
    
    if not sensor_found:
        return {
            "changed": False,
            "msg": "humidity sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds from params (none defined, use defaults from sensor)
    # For humidity, there are no default thresholds in the plugin
    
    # Determine state based on sensor status
    status_int = int(status)
    base_state, base_text = SENSOR_STATE_MAP.get(status, (3, "unknown"))
    
    # Build info text
    infotext = ""
    if description:
        infotext = infotext + "[" + description + "] "
    
    # Determine if we need to check levels
    extra_state = 0
    extra_info = ""
    
    # Check device levels (from sensor)
    if low != 0.0 or high != 0.0:
        if reading <= low or reading >= high:
            extra_state = 2
            extra_info = " (device lower/upper crit at " + str(int(low)) + "/" + str(int(high)) + UNIT_MAP["humidity"] + ")"
    
    # Combine states
    final_state = base_state
    if extra_state > final_state:
        final_state = extra_state
    
    state_str = "UNKNOWN"
    if final_state == 0:
        state_str = "OK"
    elif final_state == 1:
        state_str = "WARN"
    elif final_state == 2:
        state_str = "CRIT"
    
    summary = infotext + str(int(reading)) + UNIT_MAP["humidity"]
    if extra_info:
        summary = summary + ", " + extra_info
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {"humidity": int(reading)},
            "details": ""
        }
    }
