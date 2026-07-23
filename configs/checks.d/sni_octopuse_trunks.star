def main(ctx, params):
    # Constants
    TRUNKPORTS = ("S0 trunk: extern",)
    BASE_OID = ".1.3.6.1.4.1.231.7.2.9.3.8.1"
    
    # Helper to extract value from snmpwalk output line
    def parse_snmp_line(line):
        # Format: ".1.3.6.1.4.1.231.7.2.9.3.8.1.3.1 = STRING: "OpenStage 30""
        # or: ".1.3.6.1.4.1.231.7.2.9.3.8.1.4.11 = INTEGER: 2"
        line = line.strip()
        eq_idx = line.find("=")
        if eq_idx == -1:
            return None, None
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        
        # Extract OID index (last part after last dot)
        oid_parts = oid_part.split(".")
        if len(oid_parts) == 0:
            return None, None
        index = int(oid_parts[-1]) if oid_parts[-1].isdigit() else None
        if index == None:
            return None, None
        
        # Parse value - handle quoted strings or integers
        if value_part.startswith("STRING:"):
            value = value_part[7:].strip().strip('"')
        elif value_part.startswith("INTEGER:"):
            int_str = value_part[8:].strip()
            value = int(int_str) if int_str.lstrip("-").isdigit() else 0
        else:
            value = value_part
        return index, value
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            BASE_OID
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 trunks",
                    "data": {"discovery": []}}
        
        # Parse section into structured data
        data_by_index = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            index, value = parse_snmp_line(line)
            if index == None:
                continue
            
            oid_prefix = BASE_OID + "."
            if not line.startswith(oid_prefix):
                continue
            
            full_oid = line.split("=")[0].strip()
            parts = full_oid.split(".")
            if len(parts) < 11:
                continue
            
            col_str = parts[-2]
            col = int(col_str) if col_str.isdigit() else 0
            
            if index not in data_by_index:
                data_by_index[index] = {}
            data_by_index[index][col] = value
        
        # Build structured section: [portindex, cardindex, porttype, portstate]
        section = []
        for idx, cols in data_by_index.items():
            portindex = cols.get(2)
            cardindex = cols.get(1)
            porttype = cols.get(3)
            portstate = cols.get(4)
            
            # Skip if missing required fields
            if portindex == None or cardindex == None or porttype == None or portstate == None:
                continue
            
            # Only include trunk ports that are in active state
            if porttype in TRUNKPORTS and str(portstate) == "2":
                section.append([portindex, cardindex, porttype, portstate])
        
        # Build discovery result
        items = []
        for entry in section:
            portindex, cardindex, porttype, portstate = entry
            item = str(cardindex) + "/" + str(portindex)
            items.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d trunks" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    
    # Run same snmpwalk for check data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        BASE_OID
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "UNKW - cannot fetch SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse same way as discovery
    data_by_index = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        index, value = parse_snmp_line(line)
        if index == None:
            continue
        
        oid_prefix = BASE_OID + "."
        if not line.startswith(oid_prefix):
            continue
        
        full_oid = line.split("=")[0].strip()
        parts = full_oid.split(".")
        if len(parts) < 11:
            continue
        
        col_str = parts[-2]
        col = int(col_str) if col_str.isdigit() else 0
        
        if index not in data_by_index:
            data_by_index[index] = {}
        data_by_index[index][col] = value
    
    # Build section
    section = []
    for idx, cols in data_by_index.items():
        portindex = cols.get(2)
        cardindex = cols.get(1)
        porttype = cols.get(3)
        portstate = cols.get(4)
        
        if portindex == None or cardindex == None or porttype == None or portstate == None:
            continue
        
        section.append([portindex, cardindex, porttype, portstate])
    
    # Look for matching item
    for entry in section:
        portindex, cardindex, porttype, portstate = entry
        check_item = str(cardindex) + "/" + str(portindex)
        if check_item == item:
            # Check port state: 1 = inactive, 2 = active
            if str(portstate) == "1":
                return {"changed": False, "msg": "Port [%s] is inactive" % porttype,
                        "data": {"state": "CRIT", "metrics": {}, "details": ""}}
            return {"changed": False, "msg": "Port [%s] is active" % porttype,
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    # Item not found
    return {"changed": False, "msg": "UNKW - unknown data received from agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}