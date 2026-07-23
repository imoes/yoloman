_FAN_ID_TO_NAME = {
    "1": "CPU 1",
    "2": "CPU 2",
    "3": "Chassis 1",
    "4": "Chassis 2",
    "5": "Chassis 3",
    "6": "Chassis 4",
    "7": "Chassis 5",
    "8": "Chassis 6",
    "9": "Chassis 7",
    "10": "Chassis 8",
    "11": "Tray 1 Fan 1",
    "12": "Tray 1 Fan 2",
    "13": "Tray 1 Fan 3",
    "14": "Tray 1 Fan 4",
    "15": "Tray 2 Fan 1",
    "16": "Tray 2 Fan 2",
    "17": "Tray 2 Fan 3",
    "18": "Tray 2 Fan 4",
    "19": "Tray 3 Fan 1",
    "20": "Tray 3 Fan 2",
    "21": "Tray 3 Fan 3",
    "22": "Tray 3 Fan 4",
    "23": "Hard Disk Tray Fan 1",
    "24": "Hard Disk Tray Fan 2",
    "25": "1a",
    "26": "1b",
    "27": "2a",
    "28": "2b",
    "29": "3a",
    "30": "3b",
    "31": "4a",
    "32": "4b",
    "33": "1",
    "34": "2",
    "35": "3",
}

_FAN_STATE_TO_TXT = {
    "1": "reached lower non-recoverable limit",
    "2": "reached lower critical limit",
    "3": "reached lower non-critical limit",
    "4": "operating normally",
    "5": "reached upper non-critical limit",
    "6": "reached upper critical limit",
    "7": "reached upper non-recoverable limit",
    "8": "failure",
    "9": "no reading",
    "10": "Invalid",
}

_FAN_STATE_TO_MON_STATE = {
    "1": "CRIT",
    "2": "CRIT",
    "3": "WARN",
    "4": "OK",
    "5": "WARN",
    "6": "CRIT",
    "7": "CRIT",
    "8": "CRIT",
    "9": "CRIT",
    "10": "WARN",
}


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.14685.3.1.97.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            # OID ends with index (e.g., ".1.3.6.1.4.1.14685.3.1.97.1.1")
            oid_tail = parts[0].rsplit(".", 1)[-1]
            # Parse value part: "TYPE: VALUE"
            value_part = " ".join(parts[2:])
            if ":" not in value_part:
                continue
            # Skip parsing type, get value
            value = value_part.split(":", 1)[1].strip()
            # We'll get all three columns by doing multiple passes
            # For now store index and value for later reconstruction
            # This approach is inefficient; better to parse all at once
            pass  # Will restructure below
        
        # Re-parse properly: snmpwalk yields lines like:
        # .1.3.6.1.4.1.14685.3.1.97.1.1.1 = INTEGER: 1
        # .1.3.6.1.4.1.14685.3.1.97.1.1.2 = INTEGER: 2
        # .1.3.6.1.4.1.14685.3.1.97.1.1.3 = Gauge32: 0
        # ...etc
        # We need to group by row (same index)
        
        # Collect all rows by index
        fans_by_index = {}
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split OID and value part
            if " = " not in line:
                continue
            oid_part, value_part = line.split(" = ", 1)
            # Get base OID and index
            if not oid_part.startswith(".1.3.6.1.4.1.14685.3.1.97.1."):
                continue
            # Extract index (after base)
            idx_str = oid_part[33:]  # len(".1.3.6.1.4.1.14685.3.1.97.1.") == 33
            if "." not in idx_str:
                continue
            fan_index = idx_str.split(".", 1)[0]
            # Get column number from tail
            col_tail = idx_str.split(".", 1)[1]
            if col_tail == "1":
                col = "id"
            elif col_tail == "2":
                col = "speed"
            elif col_tail == "4":
                col = "state"
            else:
                continue
            
            # Parse value
            if ":" not in value_part:
                continue
            value = value_part.split(":", 1)[1].strip()
            # Convert id/speed/state to integers if possible
            if col != "speed" and value.isdigit():
                value = int(value)
            if col == "speed" and value.isdigit():
                value = int(value)
            
            if fan_index not in fans_by_index:
                fans_by_index[fan_index] = {}
            fans_by_index[fan_index][col] = value
        
        # Build items
        discovery_list = []
        for fan_index, data in fans_by_index.items():
            if "id" not in data:
                continue
            fan_id = str(data["id"])
            fan_name = _FAN_ID_TO_NAME.get(fan_id, "Fan %s" % fan_id)
            speed = data.get("speed", "0")
            state = data.get("state", "")
            state_txt = _FAN_STATE_TO_TXT.get(str(state), "unknown") if state else "unknown"
            
            # Suggested params empty (no thresholds defined in original)
            params_dict = {}
            metrics = ["speed"]
            
            discovery_list.append({
                "item": fan_name,
                "params": params_dict,
                "metrics": metrics
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.14685.3.1.97.1"
    ], mutates=False)
    
    # Parse rows
    fans_by_index = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if " = " not in line:
            continue
        oid_part, value_part = line.split(" = ", 1)
        if not oid_part.startswith(".1.3.6.1.4.1.14685.3.1.97.1."):
            continue
        idx_str = oid_part[33:]
        if "." not in idx_str:
            continue
        fan_index = idx_str.split(".", 1)[0]
        col_tail = idx_str.split(".", 1)[1]
        if col_tail == "1":
            col = "id"
        elif col_tail == "2":
            col = "speed"
        elif col_tail == "4":
            col = "state"
        else:
            continue
        if ":" not in value_part:
            continue
        value = value_part.split(":", 1)[1].strip()
        if col != "speed" and value.isdigit():
            value = int(value)
        if col == "speed" and value.isdigit():
            value = int(value)
        if fan_index not in fans_by_index:
            fans_by_index[fan_index] = {}
        fans_by_index[fan_index][col] = value
    
    # Find matching fan by name
    state = None
    speed = "0"
    state_txt = "unknown"
    found = False
    
    for fan_index, data in fans_by_index.items():
        if "id" not in data:
            continue
        fan_id = str(data["id"])
        fan_name = _FAN_ID_TO_NAME.get(fan_id, "Fan %s" % fan_id)
        if fan_name == item:
            found = True
            speed = str(data.get("speed", "0"))
            st = str(data.get("state", ""))
            state = _FAN_STATE_TO_MON_STATE.get(st, "CRIT") if st else "CRIT"
            state_txt = _FAN_STATE_TO_TXT.get(st, "unknown") if st else "unknown"
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    return {
        "changed": False,
        "msg": "%s, %s rpm" % (state_txt, speed),
        "data": {
            "state": state,
            "metrics": {"speed": int(speed) if speed.isdigit() else 0},
            "details": ""
        }
    }