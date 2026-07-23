# hp_psu starlark check module for yolo-man agent
# Read-only: only gathers data, never mutates the system

# PSU status mapping: status code -> (state_str, summary)
_PSU_STATE_MAP = {
    "1": ("CRIT", "Not present"),
    "2": ("CRIT", "Not plugged"),
    "3": ("OK", "Powered"),
    "4": ("WARN", "Failed"),
    "5": ("CRIT", "Permanent Failure"),
    "6": ("UNKNOWN", "Max"),
    "8": ("CRIT", "Unplugged"),
    "9": ("CRIT", "Aux not powered"),
}

def main(ctx, params):
    # Discovery mode: enumerate all power supply items
    if params.get("_discover"):
        # Fetch: base OID .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1 with OIDEnd(), "2", "4"
        # Map to item name (OIDEnd), status (oid 2), temp (oid 4)
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
        ], mutates=False)
        
        items = []
        # Parse snmpwalk output lines: "<oid>.<end> = STRING: <status>" and "<oid>.<end> = INTEGER: <temp>"
        # We need to correlate status and temp per item index (the OID end value)
        # Strategy: scan for both status and temp per OID end segment
        # snmpwalk line format: OID = TYPE: VALUE
        lines = res.stdout.splitlines()
        status_map = {}
        temp_map = {}
        
        # Walk all lines; look for status (STRING) and temp (INTEGER) entries
        for line in lines:
            if not line:
                continue
            # Split on " = " to separate OID from value part
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract base OID and end segment
            base = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
            if not oid_part.startswith(base + "."):
                continue
            end = oid_part[len(base)+1:]
            # Parse value: TYPE: VALUE
            if ": " in value_part:
                type_val = value_part.split(": ", 1)
                if len(type_val) == 2:
                    val_type, val = type_val
                    val = val.strip()
                    # Status is STRING (type 2), temp is INTEGER (type 3)
                    if val_type == "STRING" or val_type == "octet string":
                        status_map[end] = val
                    elif val_type == "INTEGER":
                        temp_map[end] = val
        
        # Now build list of items by iterating over common ends
        # Use ends present in status_map (required), and include temp if present
        for item in sorted(status_map.keys()):
            state_str = status_map[item]
            temp_str = temp_map.get(item, "")
            # Only add item if status is defined
            if state_str != "":
                metrics = ["temp"] if temp_str != "" else []
                # Suggest default temperature levels
                params_suggested = {"levels": [70.0, 80.0]}
                items.append({
                    "item": item,
                    "params": params_suggested,
                    "metrics": metrics
                })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: check one item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item provided",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch status and temp for this item using snmpget for speed
    # Query status: .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.<item>.2
    # Query temp:   .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.<item>.4
    status_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1." + item + ".2"
    temp_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1." + item + ".4"
    
    # Run both snmpget in one call for efficiency (snmpget can handle multiple OIDs)
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        status_oid,
        temp_oid
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "no data for PSU " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse status first (first line)
    status_line = lines[0]
    status_val = ""
    if " = " in status_line:
        _, value_part = status_line.split(" = ", 1)
        if ": " in value_part:
            type_val = value_part.split(": ", 1)
            if len(type_val) == 2:
                val_type, val = type_val
                status_val = val.strip()
    
    # Parse temp (second line if present)
    temp_val = 0.0
    if len(lines) >= 2:
        temp_line = lines[1]
        if " = " in temp_line:
            _, value_part = temp_line.split(" = ", 1)
            if ": " in value_part:
                type_val = value_part.split(": ", 1)
                if len(type_val) == 2 and type_val[0] == "INTEGER":
                    val_str = type_val[1].strip()
                    if val_str.isdigit():
                        temp_val = float(val_str)
    
    # Determine state and message from status
    status_entry = _PSU_STATE_MAP.get(status_val)
    if status_entry == None:
        return {
            "changed": False,
            "msg": "Unknown status code for PSU " + item + ": " + status_val,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state, summary = status_entry
    
    # Special case: status "8" and temp 0 -> "No temperature data available"
    if status_val == "8" and temp_val == 0:
        return {
            "changed": False,
            "msg": "No temperature data available for PSU " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Temperature check: get levels from params
    warn_temp = 70.0
    crit_temp = 80.0
    levels = params.get("levels", [warn_temp, crit_temp])
    if type(levels) == "list" and len(levels) >= 2:
        warn_temp = float(levels[0])
        crit_temp = float(levels[1])
    
    # Apply temperature levels (upper thresholds)
    if temp_val >= crit_temp:
        state = "CRIT"
        summary = "Temperature %f°C (critical threshold exceeded)" % temp_val
    elif temp_val >= warn_temp:
        state = "WARN"
        summary = "Temperature %f°C (warning threshold exceeded)" % temp_val
    
    # Build final message and metrics
    msg = summary
    metrics = {"temp": temp_val} if temp_val != 0 else {}
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }