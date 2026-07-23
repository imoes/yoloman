# ===== translated check module: cisco_sma_disk_io_utilization.star =====

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {"upper_levels": ("fixed", (80.0, 90.0))}, "metrics": ["disk_io_utilization"]}
            ]}
        }

    # Check mode
    item = params.get("item", "")
    # Only one service, item must be empty
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # SNMP walk for disk_io_utilization OID .1.3.6.1.4.1.15497.1.1.1.3.0
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = ".1.3.6.1.4.1.15497.1.1.1.3.0"
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpwalk output: "OID = INTEGER: value" or similar
    value = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) == 2 and parts[0].strip() == oid:
            val_str = parts[1].strip()
            # Handle different SNMP types: INTEGER:, GAUGE:, etc.
            if val_str.startswith("INTEGER:"):
                val_str = val_str[8:].strip()
            elif val_str.startswith("GAUGE:"):
                val_str = val_str[6:].strip()
            elif val_str.startswith("Counter:"):
                val_str = val_str[8:].strip()
            # Guard against non-numeric values before attempting conversion
            if val_str != "":
                # Check if string contains only digits, optional decimal point and minus sign
                valid = True
                for c in val_str:
                    if c not in "0123456789.-":
                        valid = False
                        break
                if valid:
                    value = float(val_str)
                    break
    
    if value == None:
        return {
            "changed": False,
            "msg": "disk_io_utilization value not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds
    levels_upper = params.get("upper_levels", ("fixed", (80.0, 90.0)))
    if levels_upper[0] == "fixed":
        warn = levels_upper[1][0]
        crit = levels_upper[1][1]
    else:
        # For now, only handle 'fixed' levels (Checkmk default)
        warn = 80.0
        crit = 90.0
    
    # Determine state
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    msg = "Total Disk IO Utilization: %f%%" % value
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"disk_io_utilization": value},
            "details": ""
        }
    }
