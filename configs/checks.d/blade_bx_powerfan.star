# Top-level constants (module scope)
BLADE_BX_STATUS = {
    "1": "unknown",
    "2": "disabled",
    "3": "ok",
    "4": "fail",
    "5": "prefailure-predicted",
    "6": "redundant-fan-failed",
    "7": "not-manageable",
    "8": "not-present",
    "9": "not-available",
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.7244.1.1.1.3.3.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Parse snmpwalk output: ".1.3.6.1.4.1.7244.1.1.1.3.3.1.1.X = STRING: value"
        section = []
        for line in res.stdout.splitlines():
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            if value_part.startswith("STRING: "):
                val = value_part[8:].strip().strip('"')
                section.append(val)
        
        # Group into 6-tuples: status, descr, rpm, max_speed, speed, ctrlstate
        items = []
        for i in range(0, len(section), 6):
            if i + 6 > len(section):
                break
            status, descr, rpm, max_speed, speed, ctrlstate = section[i:i+6]
            if status != "8":
                items.append({
                    "item": descr,
                    "params": {
                        "levels_lower": [20.0, 10.0],
                        "levels": [80.0, 90.0]
                    },
                    "metrics": ["perc", "rpm"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.7244.1.1.1.3.3.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpwalk output
    section = []
    for line in res.stdout.splitlines():
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if value_part.startswith("STRING: "):
            val = value_part[8:].strip().strip('"')
            section.append(val)
    
    # Find the item
    found = False
    for i in range(0, len(section), 6):
        if i + 6 > len(section):
            continue
        status, descr, rpm, max_speed, speed, ctrlstate = section[i:i+6]
        if descr != item:
            continue
        found = True
        
        # Check if rpm and max_speed are numeric before calculating
        if not rpm.isdigit() or not max_speed.isdigit():
            return {
                "changed": False,
                "msg": "invalid speed values for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        # Calculate percentage
        speed_perc = float(rpm) * 100 / float(max_speed)
        
        # Check ctrlstate first (2 = normal operation)
        if ctrlstate != "2":
            return {
                "changed": False,
                "msg": "Fan not present or poweroff",
                "data": {
                    "state": "CRIT",
                    "metrics": {"perc": speed_perc, "rpm": float(rpm)},
                    "details": ""
                }
            }
        
        # Check status
        if status != "3":
            status_text = BLADE_BX_STATUS.get(status, "unknown")
            return {
                "changed": False,
                "msg": "Status: " + status_text,
                "data": {
                    "state": "CRIT",
                    "metrics": {"perc": speed_perc, "rpm": float(rpm)},
                    "details": ""
                }
            }
        
        # Apply thresholds (levels_lower and levels)
        levels_lower = params.get("levels_lower", [20.0, 10.0])
        levels_upper = params.get("levels", [80.0, 90.0])
        
        state = "OK"
        
        # Upper levels: WARN if >= warn, CRIT if >= crit
        if len(levels_upper) >= 2:
            if speed_perc >= levels_upper[1]:
                state = "CRIT"
            elif speed_perc >= levels_upper[0]:
                state = "WARN"
        
        # Lower levels: WARN if <= warn, CRIT if <= crit
        if state == "OK" and len(levels_lower) >= 2:
            if speed_perc <= levels_lower[1]:
                state = "CRIT"
            elif speed_perc <= levels_lower[0]:
                state = "WARN"
        
        return {
            "changed": False,
            "msg": "Speed at %s RPM" % rpm,
            "data": {
                "state": state,
                "metrics": {"perc": speed_perc, "rpm": float(rpm)},
                "details": ""
            }
        }
    
    # Item not found
    if not found:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
