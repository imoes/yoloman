def _saveint(i):
    # Guard instead of try/except: only convert if all digits or starts with '-' then digits
    if i == "":
        return 0
    if i.startswith("-"):
        if len(i) == 1 or not i[1:].isdigit():
            return 0
        return int(i)
    if not i.isdigit():
        return 0
    return int(i)

def _discover_items(ctx, what):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", "public", "-On",
        "localhost", ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    ], mutates=False)
    
    items = []
    for line in res.stdout.splitlines():
        # Line format: OID = STRING: "value1|value2|value3"
        if "STRING:" not in line:
            continue
        parts = line.strip().split("STRING: \"")
        if len(parts) != 2:
            continue
        values_str = parts[1].rstrip("\"")
        values = values_str.split("|")
        if len(values) < 3:
            continue
        presence, state, name = values[0], values[1], values[2].lstrip()
        
        # Filter for the specified "what" type
        if not name.startswith(what):
            continue
        # Skip if presence is "6" (not present)
        if presence == "6":
            continue
        # Skip if state is 0 (or less) unless it's Power
        state_int = _saveint(state)
        if what != "Power" and state_int <= 0:
            continue
        
        # Extract sensor ID (last part after #)
        sensor_id = name.split("#")[-1]
        items.append(sensor_id)
    
    return items

def main(ctx, params):
    if params.get("_discover"):
        items = _discover_items(ctx, "SLOT")
        out = []
        for item in items:
            out.append({
                "item": item,
                "params": {"levels": (55.0, 60.0)},
                "metrics": ["temperature"]
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        "localhost", ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    ], mutates=False)
    
    # Find the matching sensor value
    value = None
    for line in res.stdout.splitlines():
        if "STRING:" not in line:
            continue
        parts = line.strip().split("STRING: \"")
        if len(parts) != 2:
            continue
        values_str = parts[1].rstrip("\"")
        values = values_str.split("|")
        if len(values) < 3:
            continue
        presence, state, name = values[0], values[1], values[2].lstrip()
        
        # Filter for SLOT and check item match
        if not name.startswith("SLOT"):
            continue
        if presence == "6":
            continue
        
        sensor_id = name.split("#")[-1]
        if sensor_id == item:
            value = _saveint(state)
            break
    
    # Handle missing sensor
    if value == None:
        return {
            "changed": False,
            "msg": "temperature sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Threshold logic
    levels = params.get("levels", (55.0, 60.0))
    warn, crit = float(levels[0]), float(levels[1])
    
    temp = float(value)
    if temp >= crit:
        state = "CRIT"
        summary = "CRIT (at %d°C, threshold %d°C)" % (temp, crit)
    elif temp >= warn:
        state = "WARN"
        summary = "WARN (at %d°C, threshold %d°C)" % (temp, warn)
    else:
        state = "OK"
        summary = "OK (at %d°C)" % temp
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }