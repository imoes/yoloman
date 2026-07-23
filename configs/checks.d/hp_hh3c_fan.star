def main(ctx, params):
    # Discovery mode: enumerate fan items
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.25506.8.35.9.1.1.1.2"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            # Format: .1.3.6.1.4.1.25506.8.35.9.1.1.1.2.<fan_id> = INTEGER: <status>
            parts = line.strip().split(" = INTEGER: ")
            if len(parts) != 2:
                continue
            oid_with_suffix = parts[0]
            fan_id = oid_with_suffix.rsplit(".", 1)[-1]
            status_str = parts[1]
            if status_str.isdigit():
                status = int(status_str)
                # Only include fans that are not unsupported or not installed
                if status not in (4, 3):  # UNSUPPORTED=4, NOT_INSTALLED=3
                    items.append({
                        "item": fan_id,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: verify a specific fan
    item = params.get("item", "")
    
    # Get sysDescr and sysObjectID for device detection verification
    sysdesc_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"
    ], mutates=False)
    
    sysobj_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    
    # Verify device matches HP/H3C detection criteria
    sysdesc = sysdesc_res.stdout.strip()
    sysobj = sysobj_res.stdout.strip()
    
    # Check if device is H3C or HPE (checkmk uses startswith for OID, contains for desc)
    is_h3c = "H3C" in sysdesc or "HPE" in sysdesc
    is_hh3c = sysobj.startswith(".1.3.6.1.4.1.25506")
    
    if not (is_h3c and is_hh3c):
        return {
            "changed": False,
            "msg": "device not a supported H3C/HPE device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get fan status
    fan_oid = ".1.3.6.1.4.1.25506.8.35.9.1.1.1.2." + item
    fan_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), fan_oid
    ], mutates=False)
    
    fan_line = fan_res.stdout.strip()
    
    # Parse fan status from SNMP output
    # Format: .1.3.6.1.4.1.25506.8.35.9.1.1.1.2.<id> = INTEGER: <status>
    parts = fan_line.split(" = INTEGER: ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "could not parse fan status for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status_str = parts[1].strip()
    if not status_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid fan status for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    status = int(status_str)
    
    # Status mapping: 1=ACTIVE, 2=DEACTIVE, 3=NOT_INSTALLED, 4=UNSUPPORTED
    if status == 2:
        return {
            "changed": False,
            "msg": "Fan %s Status: deactive" % item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    elif status == 1:
        return {
            "changed": False,
            "msg": "Fan %s Status: active" % item,
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    else:
        # status in (3, 4)
        summary = "Fan %s Status: not installed" % item if status == 3 else "Fan %s Status: unsupported" % item
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }