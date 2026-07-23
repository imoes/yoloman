def main(ctx, params):
    # Discovery mode: enumerate all FAN items
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.12962.1.2.3.1.2"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Parse snmpwalk output lines like:
        # .1.3.6.1.4.1.12962.1.2.3.1.2.1 = INTEGER: 9200
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            # Extract OID index (e.g., ".1.3.6.1.4.1.12962.1.2.3.1.2.1")
            oid_full = parts[0]
            # Get the last number of the OID as the item name
            oid_parts = oid_full.split(".")
            if len(oid_parts) >= 12:
                item_name = oid_parts[-1]
                items.append({
                    "item": item_name,
                    "params": {"levels_lower": (8400, 8000)},
                    "metrics": ["rpm"]
                })
        return {
            "changed": False,
            "msg": "discovered %d FANs" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one specific FAN item
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Get current RPM for the specific item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.12962.1.2.3.1.2." + item
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "FAN %s not found: snmpget failed" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: .1.3.6.1.4.1.12962.1.2.3.1.2.1 = INTEGER: 9200
    line = res.stdout.strip()
    if " = INTEGER: " not in line:
        return {
            "changed": False,
            "msg": "FAN %s not found: unexpected output" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    rpm_str = line.split(" = INTEGER: ")[-1].strip()
    if not rpm_str.isdigit():
        return {
            "changed": False,
            "msg": "FAN %s not found: invalid RPM value" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    rpm = int(rpm_str)
    
    # Extract threshold parameters with defaults from Checkmk defaults
    levels_lower = params.get("levels_lower", (8400, 8000))
    warn = levels_lower[0]
    crit = levels_lower[1]
    
    # Determine state: lower levels -> WARN if value <= warn, CRIT if value <= crit
    if rpm <= crit:
        state = "CRIT"
    elif rpm <= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "RPM: %d" % rpm,
        "data": {"state": state, "metrics": {"rpm": rpm}, "details": ""}
    }
