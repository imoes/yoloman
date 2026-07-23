def main(ctx, params):
    # Discovery mode: enumerate installed power supplies
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2272.1.4.8.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        
        # Parse snmpwalk output: ".OID.index = TYPE: value"
        entries = []
        lines = res.stdout.splitlines()
        ps_ids = []  # collect all power supply IDs
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_with_index = parts[0].strip()
            value_str = parts[1].strip()
            
            # Extract index from OID like .1.3.6.1.4.1.2272.1.4.8.1.1.1
            # We expect two OIDs per index: 1 -> name, 2 -> status
            # Split on dots and get last part as index
            idx_str = oid_with_index.rsplit(".", 1)[-1]
            idx = int(idx_str) if idx_str.isdigit() else None
            if idx == None:
                continue
            
            ps_ids.append(idx)
        
        # Now fetch values by index: OID 1 = name, OID 2 = status
        # Re-run snmpget for each index's status (OID 2)
        installed = []
        for idx in sorted(set(ps_ids)):
            status_oid = ".1.3.6.1.4.1.2272.1.4.8.1.1.2." + str(idx)
            res_get = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), status_oid
            ], mutates=False)
            if res_get.rc != 0:
                continue
            
            # Parse snmpget output: ".OID = TYPE: value"
            line = res_get.stdout.strip()
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            value_str = parts[1].strip()
            # Remove type prefix (e.g., "INTEGER: ", "Gauge32: ")
            if value_str.find(":") >= 0:
                value_str = value_str.split(":", 1)[1].strip()
            
            # Status: 2 = empty (not installed), others are installed
            status_code = int(value_str) if value_str.isdigit() else 0
            if status_code != 2:
                # Get name from OID 1
                name_oid = ".1.3.6.1.4.1.2272.1.4.8.1.1.1." + str(idx)
                res_name = ctx.run([
                    "snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-On", params.get("host", "localhost"), name_oid
                ], mutates=False)
                name = "PS " + str(idx)
                if res_name.rc == 0:
                    nline = res_name.stdout.strip()
                    nparts = nline.split(" = ")
                    if len(nparts) == 2:
                        nval = nparts[1].strip()
                        if nval.find(":") >= 0:
                            nval = nval.split(":", 1)[1].strip()
                        if nval != "":
                            name = nval
                
                installed.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(installed),
            "data": {"discovery": installed}
        }
    
    # Check mode: examine one power supply
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no power supply item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # We need to find this item's index. Since discovery used name,
    # we scan all ps entries again to find the matching index.
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2272.1.4.8.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: build a mapping from name -> index and status_oid -> value
    name_oid_base = ".1.3.6.1.4.1.2272.1.4.8.1.1.1"
    status_oid_base = ".1.3.6.1.4.1.2272.1.4.8.1.1.2"
    ps_status_map = {}  # name -> (index, status_code)
    lines = res.stdout.splitlines()
    current_index = None
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_with_index = parts[0].strip()
        value_str = parts[1].strip()
        # Extract index from OID
        idx_str = oid_with_index.rsplit(".", 1)[-1]
        idx = int(idx_str) if idx_str.isdigit() else None
        if idx == None:
            continue
        
        # Determine if this is a name or status OID
        base = oid_with_index.rsplit(".", 1)[0]
        if base == name_oid_base:
            # Name OID
            value_str = value_str.strip()
            if value_str.find(":") >= 0:
                value_str = value_str.split(":", 1)[1].strip()
            current_index = idx
            ps_status_map[value_str] = (idx, None)
        elif base == status_oid_base:
            # Status OID
            value_str = value_str.strip()
            if value_str.find(":") >= 0:
                value_str = value_str.split(":", 1)[1].strip()
            status_code = int(value_str) if value_str.isdigit() else 0
            if current_index != None:
                # Update existing entry
                names = []
                for k in ps_status_map:
                    if ps_status_map[k][0] == current_index:
                        names.append(k)
                for name in names:
                    ps_status_map[name] = (current_index, status_code)
    
    # Search for matching item
    found_status = None
    for name, (idx, status_code) in ps_status_map.items():
        if name == item:
            found_status = status_code
            break
    
    if found_status == None:
        return {
            "changed": False,
            "msg": "power supply not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Map status code to state
    status_codes = {
        1: ("UNKNOWN", "Status cannot be determined", "unknown"),
        2: ("WARN", "Power supply not installed", "empty"),
        3: ("OK", "Present and supplying power", "up"),
        4: ("CRIT", "Failure indicated", "down")
    }
    
    state_name = ""
    description = ""
    status_name = ""
    if found_status in status_codes:
        state_name, description, status_name = status_codes[found_status]
    else:
        return {
            "changed": False,
            "msg": "unknown status code %d" % found_status,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # State mapping: OK=0, WARN=1, CRIT=2, UNKNOWN=3
    state_map = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    state = state_map.get(state_name, 3)
    
    return {
        "changed": False,
        "msg": description + " (" + status_name + ")",
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }