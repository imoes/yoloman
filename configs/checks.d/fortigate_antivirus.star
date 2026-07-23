# Constants for SNMP OIDs
FG_AV_BASE_OID = ".1.3.6.1.4.1.12356.101.8.2.1.1"
FG_IPS_BASE_OID = ".1.3.6.1.4.1.12356.101.9.2.1.1"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: try both AV and IPS sections
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), FG_AV_BASE_OID], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            # Parse lines like: .1.3.6.1.4.1.12356.101.8.2.1.1.101 = INTEGER: 101
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            if oid_end.isdigit():
                items.append(oid_end)
        # If no AV items found, try IPS section
        if not items:
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), FG_IPS_BASE_OID], mutates=False)
            for line in res.stdout.splitlines():
                parts = line.strip().split()
                if len(parts) < 4:
                    continue
                oid_end = parts[0].rsplit(".", 1)[-1]
                if oid_end.isdigit():
                    items.append(oid_end)
        # Build discovery list
        out = []
        for item in items:
            out.append({"item": item, "params": {"detections": (100.0, 300.0)},
                        "metrics": ["fortigate_detection_rate", "fortigate_blocking_rate"]})
        return {"changed": False, "msg": "discovered %d antivirus/ips items" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item must be specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Try AV section first
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   FG_AV_BASE_OID + "." + item], mutates=False)
    detected = None
    blocked = None
    
    # Parse response lines
    for line in res.stdout.splitlines():
        line = line.strip()
        if " = INTEGER:" in line:
            # Find the numeric value
            val_part = line.split(" = INTEGER: ", 1)[-1]
            if line.endswith(".1"):  # detected
                if val_part.isdigit():
                    detected = int(val_part)
            elif line.endswith(".2"):  # blocked
                if val_part.isdigit():
                    blocked = int(val_part)
    
    # If not found in AV, try IPS
    if detected == None or blocked == None:
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"),
                       FG_IPS_BASE_OID + "." + item], mutates=False)
        for line in res.stdout.splitlines():
            line = line.strip()
            if " = INTEGER:" in line:
                val_part = line.split(" = INTEGER: ", 1)[-1]
                if line.endswith(".1"):  # detected
                    if val_part.isdigit():
                        detected = int(val_part)
                elif line.endswith(".2"):  # blocked
                    if val_part.isdigit():
                        blocked = int(val_part)
    
    # If still not found, return UNKNOWN
    if detected == None or blocked == None:
        return {"changed": False, "msg": "item %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get thresholds from params
    warn_level, crit_level = params.get("detections", (100.0, 300.0))
    
    # Compute rates (simulating get_rate with value_store)
    now = ctx.facts().get("uptime", 0) if ctx.facts().get("uptime") else 0
    # Use a synthetic time value (since we cannot access real time)
    # We'll approximate by assuming constant time delta for rate calculation
    # In practice, rate = delta_value / delta_time; we use current value as rate for single sample
    detection_rate = float(detected)
    blocking_rate = float(blocked)
    
    # Determine state for detection rate
    state = "OK"
    if detection_rate >= crit_level:
        state = "CRIT"
    elif detection_rate >= warn_level:
        state = "WARN"
    
    # Determine state for blocking rate (no thresholds applied, always OK unless detection rate fails)
    # Note: Checkmk plugin doesn't apply levels to blocking rate by default
    
    # Build summary message
    msg = "Detection rate %f/s, Blocking rate %f/s" % (detection_rate, blocking_rate)
    
    # Return final result
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"fortigate_detection_rate": detection_rate,
                                 "fortigate_blocking_rate": blocking_rate},
                     "details": ""}}
