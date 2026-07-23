# Top-level constants for SNMP OIDs and MIB subtrees
SEH_PORTS_DETECT_OID = ".1.3.6.1.2.1.1.2.0"
SEH_PORTS_DETECT_VALUE = ".1.3.6.1.4.1.1229.1.1"

# SNMP trees from original source
SEH_TREE_V1_BASE = ".1.3.6.1.4.1.1229.2.50.2.1"
SEH_TREE_V1_OIDS = ["10", "26", "27"]  # utnPortTag, utnPortUsbOwn, utnPortSlot

SEH_TREE_V2_BASE = ".1.3.6.1.4.1.1229.5"
SEH_TREE_V2_OIDS = ["10.2.1.10", "20.2.1.7", "20.2.1.8"]  # utnPortTag, utnDevOwn, utnDevPort

def _parse_seh_ports_v1(output):
    parsed = {}
    lines = output.splitlines()
    for line in lines:
        parts = line.strip().split("|")
        if len(parts) >= 4:
            oid_end, tag, status, port_number = parts[0], parts[1], parts[2], parts[3]
            oid_index = oid_end.split(".")[0]
            if tag != "":
                parsed.setdefault(oid_index, {}).update({"tag": tag})
            if port_number != "0":
                parsed.setdefault(port_number, {}).update({"status": status})
    return parsed

def _parse_seh_ports_v2(output):
    parsed = {}
    lines = output.splitlines()
    for line in lines:
        parts = line.strip().split("|")
        if len(parts) >= 4:
            oid_end, tag, status, port_number = parts[0], parts[1], parts[2], parts[3]
            oid_index = oid_end.split(".")[0]
            if tag != "":
                parsed.setdefault(oid_index, {}).update({"tag": tag})
            if port_number != "0":
                parsed.setdefault(port_number, {}).update({"status": status})
    return parsed

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Detect if SEH device (via SNMP sysObjectID)
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On", 
                       params.get("host", "localhost"), SEH_PORTS_DETECT_OID], 
                       mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (device not detected)",
                    "data": {"discovery": []}}
        
        # Check detection OID value
        if res.stdout.find(SEH_PORTS_DETECT_VALUE) == -1:
            return {"changed": False, "msg": "discovered 0 items (device not detected)",
                    "data": {"discovery": []}}
        
        # Try v1 tree first, fallback to v2
        section = {}
        
        # Try v1
        v1_oids = ["%s.%s" % (SEH_TREE_V1_BASE, oid) for oid in SEH_TREE_V1_OIDS]
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost")] + v1_oids, mutates=False)
        if res1.rc == 0 and res1.stdout != "":
            section = _parse_seh_ports_v1(res1.stdout)
        
        # If v1 failed, try v2
        if section == {}:
            v2_oids = ["%s.%s" % (SEH_TREE_V2_BASE, oid) for oid in SEH_TREE_V2_OIDS]
            res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                            params.get("host", "localhost")] + v2_oids, mutates=False)
            if res2.rc == 0 and res2.stdout != "":
                section = _parse_seh_ports_v2(res2.stdout)
        
        # Build discovery result
        items = []
        for key, port in section.items():
            items.append({
                "item": key,
                "params": {"status_at_discovery": port.get("status")},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    # Get community and host (required params for SNMP checks)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Re-run discovery to get section data
    section = {}
    
    # Detect if SEH device
    res_detect = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, SEH_PORTS_DETECT_OID], 
                         mutates=False)
    if res_detect.rc != 0 or res_detect.stdout.find(SEH_PORTS_DETECT_VALUE) == -1:
        return {
            "changed": False,
            "msg": "Status: Device not detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Try v1 tree first
    v1_oids = ["%s.%s" % (SEH_TREE_V1_BASE, oid) for oid in SEH_TREE_V1_OIDS]
    res_v1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + v1_oids, 
                     mutates=False)
    if res_v1.rc == 0 and res_v1.stdout != "":
        section = _parse_seh_ports_v1(res_v1.stdout)
    
    # Fallback to v2
    if section == {}:
        v2_oids = ["%s.%s" % (SEH_TREE_V2_BASE, oid) for oid in SEH_TREE_V2_OIDS]
        res_v2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + v2_oids, 
                         mutates=False)
        if res_v2.rc == 0 and res_v2.stdout != "":
            section = _parse_seh_ports_v2(res_v2.stdout)
    
    # Get item data
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "Port %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Build message and state
    msg_parts = []
    for key in ("tag", "status"):
        if key in data:
            msg_parts.append("%s: %s" % (key.title(), data[key]))
    
    # Check for status change
    status_at_discovery = params.get("status_at_discovery")
    current_status = data.get("status")
    if status_at_discovery != current_status:
        msg_parts.append("Status during discovery: %s" % (status_at_discovery if status_at_discovery != None else "unknown"))
    
    # Determine state
    state = "OK"
    if status_at_discovery != current_status:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }