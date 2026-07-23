# Checkmk check: primekey_data
# Read-only Starlark translation of SNMP-based status check for PrimeKey components

def main(ctx, params):
    # SNMP base OID for PrimeKey data
    base_oid = ".1.3.6.1.4.1.22408.1.1.2"
    
    # Map item names to SNMP OIDs (as per Checkmk source)
    item_oids = {
        "VMs": ".1.3.6.1.4.1.22408.1.1.2.1.2.118.109.1",
        "RAID": ".1.3.6.1.4.1.22408.1.1.2.1.5.114.97.105.100.49.1",
        "EJBCA": ".1.3.6.1.4.1.22408.1.1.2.1.8.104.101.97.108.116.104.50.1",
        "Signserver": ".1.3.6.1.4.1.22408.1.1.2.1.8.104.101.97.108.116.104.115.50.1",
        "HSM": ".1.3.6.1.4.1.22408.1.1.2.2.4.104.115.109.51.1",
    }
    
    # Check if we are in discovery mode
    if params.get("_discover"):
        # Gather all items by walking each OID individually (snmpget for each)
        items = []
        for item_name in item_oids.keys():
            oid = item_oids[item_name]
            res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), 
                          "-On", params.get("host", "localhost"), oid], mutates=False)
            # Parse snmpget output: "OID = TYPE: value"
            if res.rc == 0 and res.stdout.strip() != "":
                # Check if value is present (not empty)
                parts = res.stdout.strip().split(": ", 1)
                if len(parts) == 2:
                    # Status is 0 (OK) or 1 (NOT_OK)
                    status_str = parts[1].strip()
                    if status_str.isdigit():
                        items.append({
                            "item": item_name,
                            "params": {},
                            "metrics": []
                        })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: inspect specific item
    item = params.get("item", "")
    if item == "" or item not in item_oids:
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch status for the specific item
    oid = item_oids[item]
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), oid], mutates=False)
    
    # Parse result
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "no data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = res.stdout.strip().split(": ", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid data format for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status_str = parts[1].strip()
    if not status_str.isdigit():
        return {"changed": False, "msg": "invalid status value for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status_val = int(status_str)
    
    # Determine state: 0=OK, 1=NOT_OK (mapped to CRIT)
    state = "OK" if status_val == 0 else "CRIT"
    notice = "Status is ok" if status_val == 0 else "Status is not ok"
    
    return {"changed": False, "msg": notice,
            "data": {"state": state, "metrics": {}, "details": ""}}