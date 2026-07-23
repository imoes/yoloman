# ===== Starlark module: checkpoint_ha_problems =====
# Check: checkpoint_ha_problems
# Description: HA Problem %s
# Parameters: {}
# Source: SNMP section checkpoint_ha_problems (.1.3.6.1.4.1.2620.1.5.13.1)

def main(ctx, params):
    # discovery mode: enumerate HA problem items
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2620.1.5.13.1.2"
        ], mutates=False)
        
        # We'll gather name (oid .2), dev_status (.3), description (.6)
        # Parse name -> item mapping first
        name_map = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            # Extract OID number
            oid_num = oid_full.strip().rsplit(".", 1)[-1]
            # Extract value (strip type prefix like "STRING:" or "INTEGER:")
            value = value_part.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            name_map[oid_num] = value
        
        # Now fetch dev_status
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2620.1.5.13.1.3"
        ], mutates=False)
        
        status_map = {}
        for line in res2.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            oid_num = oid_full.strip().rsplit(".", 1)[-1]
            value = value_part.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            status_map[oid_num] = value
        
        # Now fetch description
        res3 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2620.1.5.13.1.6"
        ], mutates=False)
        
        desc_map = {}
        for line in res3.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            oid_num = oid_full.strip().rsplit(".", 1)[-1]
            value = value_part.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            desc_map[oid_num] = value
        
        # Build discovery list: use name as item, include all items with name present
        out = []
        for oid_num in name_map:
            name = name_map.get(oid_num, "")
            dev_status = status_map.get(oid_num, "")
            description = desc_map.get(oid_num, "")
            if name != "":
                # Suggested params: none (no configurable thresholds)
                out.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d HA problems" % len(out),
            "data": {"discovery": out}
        }
    
    # check mode: examine one item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.1.5.13.1.2"
    ], mutates=False)
    
    # Build lookup: oid_num -> (name, status, description)
    data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        oid_num = oid_full.strip().rsplit(".", 1)[-1]
        name = value_part.strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1]
        data[oid_num] = {"name": name, "status": "", "description": ""}
    
    # Get status data
    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.1.5.13.1.3"
    ], mutates=False)
    
    for line in res2.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        oid_num = oid_full.strip().rsplit(".", 1)[-1]
        status = value_part.strip()
        if status.startswith('"') and status.endswith('"'):
            status = status[1:-1]
        if oid_num in data:
            data[oid_num]["status"] = status
    
    # Get description data
    res3 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.1.5.13.1.6"
    ], mutates=False)
    
    for line in res3.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        oid_num = oid_full.strip().rsplit(".", 1)[-1]
        description = value_part.strip()
        if description.startswith('"') and description.endswith('"'):
            description = description[1:-1]
        if oid_num in data:
            data[oid_num]["description"] = description
    
    # Find matching item
    for oid_num in data:
        entry = data[oid_num]
        if entry["name"] == item:
            status = entry["status"]
            description = entry["description"]
            if status == "OK":
                return {
                    "changed": False,
                    "msg": "OK",
                    "data": {
                        "state": "OK",
                        "metrics": {},
                        "details": ""
                    }
                }
            else:
                summary = "%s - %s" % (status, description) if description else status
                return {
                    "changed": False,
                    "msg": summary,
                    "data": {
                        "state": "CRIT",
                        "metrics": {},
                        "details": ""
                    }
                }
    
    # Item not found
    return {
        "changed": False,
        "msg": "HA problem not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
