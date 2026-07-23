# Module: juniper_trpz_flash.star
# Read-only check module for flash usage on Juniper TRPZ devices via SNMP

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.14525.4.8.1.1"
        ], mutates=False)

        # Check if we got any output (device exists)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Parse: look for lines ending with .3 and .4
        used_val = None
        total_val = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Format: ".1.3.6.1.4.1.14525.4.8.1.1.3 = STRING: value"
            parts = line.split(" = ", 1)
            if len(parts) < 2:
                continue
            oid_part, value_part = parts
            value_part = value_part.strip()
            # Extract type and value
            type_val = value_part.split(": ", 1)
            if len(type_val) < 2:
                continue
            val_str = type_val[1].strip()
            # Validate that value is numeric (allow decimals)
            clean_val = val_str.replace(".", "")
            if not clean_val.isdigit():
                continue

            if oid_part.endswith(".3"):
                used_val = val_str
            elif oid_part.endswith(".4"):
                total_val = val_str

        # If both values present, this device has flash data
        if used_val != None and total_val != None:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "", "params": {"levels": (90.0, 95.0)},
                         "metrics": ["used"]}
                    ]
                }
            }
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

    # Check mode (one item only, and item is always "" for this single-service check)
    # Get host and community from params if provided, else defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Fetch both values via SNMP walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.14525.4.8.1.1"
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "SNMP walk failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse to get used and total
    used_val = None
    total_val = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        oid_part, value_part = parts
        value_part = value_part.strip()
        type_val = value_part.split(": ", 1)
        if len(type_val) < 2:
            continue
        val_str = type_val[1].strip()
        clean_val = val_str.replace(".", "")
        if not clean_val.isdigit():
            continue

        if oid_part.endswith(".3"):
            used_val = val_str
        elif oid_part.endswith(".4"):
            total_val = val_str

    if used_val == None or total_val == None:
        return {"changed": False, "msg": "SNMP data missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse numbers with guards (no try/except in Starlark)
    used = 0.0
    total = 0.0
    
    # Convert used_val to float
    if used_val.find(".") != -1:
        # Has decimal point
        parts_float = used_val.split(".")
        if len(parts_float) == 2 and parts_float[0].isdigit() and parts_float[1].isdigit():
            used = float(used_val)
        else:
            return {"changed": False, "msg": "Failed to parse used value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    elif used_val.isdigit():
        used = float(used_val)
    else:
        return {"changed": False, "msg": "Failed to parse used value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Convert total_val to float
    if total_val.find(".") != -1:
        # Has decimal point
        parts_float = total_val.split(".")
        if len(parts_float) == 2 and parts_float[0].isdigit() and parts_float[1].isdigit():
            total = float(total_val)
        else:
            return {"changed": False, "msg": "Failed to parse total value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    elif total_val.isdigit():
        total = float(total_val)
    else:
        return {"changed": False, "msg": "Failed to parse total value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if total == 0:
        return {"changed": False, "msg": "Total flash size is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get thresholds: Checkmk default is (90.0, 95.0)
    levels = params.get("levels", (90.0, 95.0))
    warn = levels[0]
    crit = levels[1]

    # Compute percentage used
    perc_used = (used / total) * 100

    # Determine state
    # In Checkmk, crit and warn are percentages for this check (float values)
    state = "CRIT" if perc_used > crit else ("WARN" if perc_used > warn else "OK")

    # Build message (Checkmk style, human-readable)
    # We'll report in MB for readability
    def _to_mb(v):
        return v / (1024.0 * 1024.0)

    msg = "Used: %f MB of %f MB " % (_to_mb(used), _to_mb(total))
    levels_str = "Levels Warn/Crit are (%f%%, %f%%)" % (warn, crit)

    if state == "CRIT":
        msg += levels_str
    elif state == "WARN":
        msg += levels_str

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used": used},
            "details": "",
        },
    }