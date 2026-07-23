FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

def main(ctx, params):
    # Discovery mode: enumerate all PSUs from SNMP
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.211.1.21.1.60.2.9.2.1"
        
        # Fetch index and status via snmpwalk
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse output lines: "<oid>.<index> = INTEGER: <value>"
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val_part = parts[1].strip()
            # Extract last component as index: .1.3.6.1.4.1.211.1.21.1.60.2.9.2.1.1 => index "1"
            index_str = oid_val.rsplit(".", 1)[-1]
            if val_part.startswith("INTEGER: "):
                status = val_part[len("INTEGER: "):].strip()
            else:
                continue
            
            # Only include items where status != "4" (Invalid)
            if status != "4":
                items.append({
                    "item": index_str,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: examine one PSU
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.211.1.21.1.60.2.9.2.1"
    
    # Use snmpget to fetch specific OID: .1.3.6.1.4.1.211.1.21.1.60.2.9.2.1.<item>.3
    # According to the section spec: base .1.3.6.1.4.1.211.1.21.1.60.2.9.2.1, oids=["1", "3"]
    # So we need OID: <base>.<item>.3 for status
    oid_to_query = base_oid + "." + item + ".3"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid_to_query], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "PSU " + item + " not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse snmpget output: "<oid> = INTEGER: <value>"
    parts = res.stdout.strip().split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "Unexpected SNMP output for PSU " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    val_part = parts[1].strip()
    if not val_part.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "Invalid value format for PSU " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    status = val_part[len("INTEGER: "):].strip()
    
    # Map status to state
    state_summary = FJDARYE_ITEM_STATUS.get(status, ("UNKNOWN", "Unknown"))
    state, summary = state_summary
    
    return {
        "changed": False,
        "msg": "PSU " + item + ": " + summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
