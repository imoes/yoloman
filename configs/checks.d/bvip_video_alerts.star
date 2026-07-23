# Module-level constants
OID_BASE = ".1.3.6.1.4.1.3967.1"
OID_SYSDESCR = ".1.3.6.1.2.1.1.1.0"
DETECT_PATTERNS = ["flexidome", "vip-x", "dinion", "autodome"]

def _walk_alerts(ctx, community):
    section = {}
    items = {}
    
    # Walk item names from base + ".1.1.3.1"
    res_items = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", "localhost", OID_BASE + ".1.1.3.1"], mutates=False)
    if res_items.rc == 0 and res_items.stdout:
        for line in res_items.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract value - handle both "STRING: value" and direct quoted formats
            if value_part.startswith("STRING:"):
                value = value_part[7:].strip().strip('"')
            else:
                value = value_part.strip('"')
            
            # Get index from OID
            if oid_part.startswith(OID_BASE + ".1.1.3.1."):
                index = oid_part[len(OID_BASE + ".1.1.3.1."):]
                # Take only first part if there are subindices
                if "." in index:
                    index = index.split(".")[0]
                # Skip if not numeric index
                if index.isdigit():
                    items[index] = value.replace("\x00", "")
    
    # Walk alert states from base + ".3.1.1"
    res_states = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", "localhost", OID_BASE + ".3.1.1"], mutates=False)
    if res_states.rc == 0 and res_states.stdout:
        for line in res_states.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract value
            if value_part.startswith("STRING:"):
                value = value_part[7:].strip().strip('"')
            else:
                value = value_part.strip('"')
            
            # Get index from OID
            if oid_part.startswith(OID_BASE + ".3.1.1."):
                index = oid_part[len(OID_BASE + ".3.1.1."):]
                if "." in index:
                    index = index.split(".")[0]
                if index.isdigit() and index in items:
                    item_name = items[index]
                    section[item_name] = value.replace("\x00", "")
    
    return section

def main(ctx, params):
    # Detect if device is a BVIP device
    community = params.get("community", "public")
    
    # Get system description for detection
    res_sysdescr = ctx.run(["snmpget", "-v2c", "-c", community, "-On", "localhost", OID_SYSDESCR], mutates=False)
    if res_sysdescr.rc != 0 or not res_sysdescr.stdout:
        # No sysdescr available, device not detected as BVIP
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    
    # Extract system description value
    sysdescr_line = res_sysdescr.stdout.strip()
    parts = sysdescr_line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    sysdescr = parts[1].strip()
    
    # Check if any detection pattern is present
    detected = False
    for pattern in DETECT_PATTERNS:
        if pattern in sysdescr.lower():
            detected = True
            break
    
    if not detected:
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    
    if params.get("_discover"):
        # Discovery mode: get all items
        section = _walk_alerts(ctx, community)
        items = []
        for item in section:
            items.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d video alert(s)" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    section = _walk_alerts(ctx, community)
    alerts = section.get(item)
    
    if alerts == None:
        return {
            "changed": False,
            "msg": "no such video alert: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    if alerts != "0":
        return {
            "changed": False,
            "msg": "Device on Alarm State",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }
    else:
        return {
            "changed": False,
            "msg": "No alarms",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
