def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.3224.4.1.1.1.4"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed for juniper_screenos_vpn",
                "data": {"discovery": []}
            }
        # Also fetch the corresponding status OID to build item->status map
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.3224.4.1.1.1.23"
        ], mutates=False)
        if res_status.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed for juniper_screenos_vpn status",
                "data": {"discovery": []}
            }
        
        # Parse both walks and build map: item = OID leaf (index), value = status
        status_map = {}
        # Process status walk first (OID .1.3.6.1.4.1.3224.4.1.1.1.23)
        for line in res_status.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract the leaf (last numeric part of OID)
            if oid_part.startswith(".1.3.6.1.4.1.3224.4.1.1.1.23."):
                index = oid_part.rsplit(".", 1)[-1]
                # Value is typically "INTEGER: 0" or "INTEGER: 1"
                if value_part.startswith("INTEGER: "):
                    status = value_part.split(": ", 1)[1].strip()
                    status_map[index] = status
        
        # Build discovery list from status_map (item = vpn_id)
        discovery_items = []
        for vpn_id in sorted(status_map.keys()):
            # Default thresholds aren't used here, but include empty dict for params
            discovery_items.append({
                "item": vpn_id,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d VPNs" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Fetch status for the specific item (OID .1.3.6.1.4.1.3224.4.1.1.1.23.<item>)
    # We need to construct the full OID for the item's leaf
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3224.4.1.1.1.23." + item
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "unable to retrieve VPN status for item %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse single-line output: "OID = INTEGER: <value>"
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unable to parse VPN status for item %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    value_part = parts[1].strip()
    if not value_part.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "unexpected response format for VPN item %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    status = value_part.split(": ", 1)[1].strip()
    if status == "1":
        summary = "VPN Status %s is active" % item
        state = "OK"
    elif status == "0":
        summary = "VPN Status %s inactive" % item
        state = "CRIT"
    else:
        summary = "Unknown vpn status %s" % status
        state = "WARN"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }