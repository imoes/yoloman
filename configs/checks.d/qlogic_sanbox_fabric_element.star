# Status mapping for Fabric Element states
FE_STATUS = {
    "1": ("OK", "is online"),
    "2": ("CRIT", "is offline"),
    "3": ("WARN", "is testing"),
    "4": ("CRIT", "is faulty"),
}

def main(ctx, params):
    # Discovery mode: enumerate all Fabric Elements
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.75.1.1.4.1.4"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        items = []
        for line in res.stdout.splitlines():
            # Format: .1.3.6.1.2.1.75.1.1.4.1.4.<oid-end> = INTEGER: <status>
            if "INTEGER:" not in line:
                continue
            # Extract OID end (item name) and status value
            parts = line.strip().split(" = INTEGER: ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            status = parts[1].strip()
            items.append({
                "item": oid_end,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d Fabric Elements" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: examine one Fabric Element
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.2.1.75.1.1.4.1.4"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    fe_status = None
    for line in res.stdout.splitlines():
        if "INTEGER:" not in line:
            continue
        parts = line.strip().split(" = INTEGER: ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        if oid_end == item:
            fe_status = parts[1].strip()
            break
    
    if fe_status == None:
        return {
            "changed": False,
            "msg": "No Fabric Element %s found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status_info = FE_STATUS.get(fe_status, ("UNKNOWN", "is in unidentified status"))
    state = status_info[0]
    description = status_info[1]
    
    return {
        "changed": False,
        "msg": "Fabric Element %s %s" % (item, description),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }