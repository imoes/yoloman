def main(ctx, params):
    # Constants
    OID_BASE = ".1.3.6.1.2.1.33.1.3.3.1"
    DEFAULT_WARN = 45.0
    DEFAULT_CRIT = 40.0

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_BASE
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (SNMP error)",
                "data": {"discovery": []}
            }
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract OID end (e.g., ".1.3.6.1.2.1.33.1.3.3.1.1" -> "1")
            oid_suffix = oid_part.rsplit(".", 1)
            if len(oid_suffix) != 2:
                continue
            item = oid_suffix[1]
            # Parse frequency value (string -> integer -> float)
            value_str = value_part.split(": ", 1)[-1].strip()
            freq = int(value_str) / 10.0 if value_str.isdigit() else None
            if freq != None and freq > 0:
                items.append({
                    "item": item,
                    "params": {"levels_lower": [DEFAULT_WARN, DEFAULT_CRIT]},
                    "metrics": ["in_freq"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn = params.get("levels_lower", [DEFAULT_WARN, DEFAULT_CRIT])
    if type(warn) == "list":
        warn = tuple(warn)
    warn_val = warn[0]
    crit_val = warn[1]

    # Build full OID for this item
    full_oid = OID_BASE + "." + item
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, full_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error getting data for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: "OID = STRING: value"
    output = res.stdout.strip()
    if not output:
        return {
            "changed": False,
            "msg": "no data for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parts = output.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[1].strip()
    # Handle type prefix (INTEGER: or STRING:)
    if value_str.find(":") >= 0:
        value_str = value_str.split(":", 1)[1].strip()
    
    freq = int(value_str) / 10.0 if value_str.isdigit() else None
    if freq == None:
        return {
            "changed": False,
            "msg": "cannot parse frequency value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state
    state = "OK"
    if freq < crit_val:
        state = "CRIT"
    elif freq < warn_val:
        state = "WARN"
    
    # Build message
    infotext = "%f Hz" % freq
    if state != "OK":
        infotext += " (warn/crit below %f Hz/%f Hz)" % (warn_val, crit_val)
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {"in_freq": freq},
            "details": ""
        }
    }