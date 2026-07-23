def main(ctx, params):
    # Discovery mode: yield one service with empty item and no perfdata
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.2.1.1.1.0",
                       ".1.3.6.1.2.1.1.2.0", ".1.3.6.1.2.1.1.4.0", ".1.3.6.1.2.1.1.5.0",
                       ".1.3.6.1.2.1.1.6.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # If no sysDescr, skip discovery (same as detect=HAS_SYSDESC)
        if ".1.3.6.1.2.1.1.1.0" not in res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.2.1.1.1.0",
                   ".1.3.6.1.2.1.1.2.0", ".1.3.6.1.2.1.1.4.0", ".1.3.6.1.2.1.1.5.0",
                   ".1.3.6.1.2.1.1.6.0"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    # Map OID index to value
    data = {}
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) == 2:
            oid_part = parts[0].strip()
            val_part = parts[1].strip().replace('"', '').replace('STRING:', '')
            if oid_part == ".1.3.6.1.2.1.1.1.0":
                data["description"] = val_part.replace("\\n", " ").replace("\\r", "")
            elif oid_part == ".1.3.6.1.2.1.1.2.0":
                data["object_id"] = val_part.split()[-1] if val_part.split() else ""
            elif oid_part == ".1.3.6.1.2.1.1.4.0":
                data["contact"] = val_part
            elif oid_part == ".1.3.6.1.2.1.1.5.0":
                data["name"] = val_part
            elif oid_part == ".1.3.6.1.2.1.1.6.0":
                data["location"] = val_part
    
    # Ensure required fields
    description = data.get("description", "")
    object_id = data.get("object_id", "")
    contact = data.get("contact", "")
    name = data.get("name", "")
    location = data.get("location", "")
    
    # Build summary in Checkmk style: "desc, name, location, contact"
    summary = description + ", " + name + ", " + location + ", " + contact
    
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
