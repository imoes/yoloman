def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.476.1.42.3.8.20.1"
        
        # Fetch the required OIDs: .5, .10, .15, .45, .50
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".5", base_oid + ".10", base_oid + ".15", base_oid + ".45", base_oid + ".50"
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse SNMP output: lines look like "OID = STRING: value"
        # Group by instance (the suffix after base_oid + ".X")
        pdu_data = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract suffix: base_oid + ".X.Y" -> Y
            if not oid_part.startswith(base_oid + "."):
                continue
            suffix = oid_part[len(base_oid) + 1:]
            # Find last dot to get index (e.g., "5.0" -> "0")
            last_dot = suffix.rfind(".")
            if last_dot == -1:
                continue
            instance = suffix[last_dot + 1:]
            # Extract OID leaf (e.g., "5" from "5.0")
            oid_leaf = suffix[:last_dot]
            
            # Map OID leaf to index: 5->0, 10->1, 15->2, 45->3, 50->4
            oid_to_index = {"5": 0, "10": 1, "15": 2, "45": 3, "50": 4}
            idx = oid_to_index.get(oid_leaf)
            if idx == None:
                continue
            
            # Strip quotes if present (SNMP strings come as "STRING: ..." or "STRING: \"value\"")
            # Checkmk typically returns raw strings like "STRING: TEST-123-HOST"
            value = value_part
            if value_part.startswith("STRING: "):
                value = value_part[8:]
            # Remove surrounding quotes if any
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            
            if instance not in pdu_data:
                pdu_data[instance] = [""] * 5
            pdu_data[instance][idx] = value
        
        discovery = []
        for instance in sorted(pdu_data.keys()):
            pdu = pdu_data[instance]
            # We need at least sys_label (index 2) to use as item
            sys_label = pdu[2]
            if sys_label == None or sys_label == "":
                continue
            discovery.append({
                "item": sys_label,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d PDU(s)" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.476.1.42.3.8.20.1"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".5", base_oid + ".10", base_oid + ".15", base_oid + ".45", base_oid + ".50"
    ], mutates=False)
    
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    pdu_data = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if not oid_part.startswith(base_oid + "."):
            continue
        suffix = oid_part[len(base_oid) + 1:]
        last_dot = suffix.rfind(".")
        if last_dot == -1:
            continue
        instance = suffix[last_dot + 1:]
        oid_leaf = suffix[:last_dot]
        
        oid_to_index = {"5": 0, "10": 1, "15": 2, "45": 3, "50": 4}
        idx = oid_to_index.get(oid_leaf)
        if idx == None:
            continue
        
        value = value_part
        if value_part.startswith("STRING: "):
            value = value_part[8:]
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        
        if instance not in pdu_data:
            pdu_data[instance] = [""] * 5
        pdu_data[instance][idx] = value
    
    for instance in pdu_data:
        pdu = pdu_data[instance]
        sys_label = pdu[2]
        if sys_label == item:
            entry_id = pdu[0]
            label = pdu[1]
            serial = pdu[3]
            num_rcs = pdu[4]
            
            # Build summary in Checkmk style
            summary = "Entry-ID: %s, Label: %s (%s), S/N: %s, Num. RCs: %s" % (
                entry_id if entry_id != "" else "N/A",
                label if label != "" else "N/A",
                sys_label if sys_label != "" else "N/A",
                serial if serial != "" else "N/A",
                num_rcs if num_rcs != "" else "N/A"
            )
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": ""
                }
            }
    
    return {
        "changed": False,
        "msg": "Device can not be found in SNMP output.",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }