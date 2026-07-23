# Module: checkmk.fjdarye_device_enclosures
# Read-only Starlark check module for Fujitsu device enclosures via SNMP

FJDARYE_ITEM_STATUS = {
    "1": {"state": "OK", "summary": "Normal"},
    "2": {"state": "CRIT", "summary": "Alarm"},
    "3": {"state": "WARN", "summary": "Warning"},
    "4": {"state": "CRIT", "summary": "Invalid"},
    "5": {"state": "CRIT", "summary": "Maintenance"},
    "6": {"state": "CRIT", "summary": "Undefined"},
}

FJDARYE_OIDS = {
    "fjdarye60": ".1.3.6.1.4.1.211.1.21.1.60",
    "fjdarye100": ".1.3.6.1.4.1.211.1.21.1.100",
    "fjdarye500": ".1.3.6.1.4.1.211.1.21.1.150",
    "fjdarye600": ".1.3.6.1.4.1.211.1.21.1.153",
}

# Device OID to enclosure OID mapping
DEVICE_TO_ENCLOSURE_OID = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.7.2.1",      # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.14.2.1",    # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.14.2.1",    # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.14.2.1",    # fjdarye600
}


def main(ctx, params):
    # Discovery mode: enumerate device enclosures
    if params.get("_discover"):
        # Get system OID to determine model family
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed: snmpget error",
                    "data": {"discovery": []}}
        
        # Extract OID from snmpget output: ".1.3.6.1.2.1.1.2.0 = OID: .1.3.6.1.4.1.211.1.21.1.60"
        sys_oid_line = res.stdout.strip()
        if sys_oid_line.find(" = OID: ") != -1:
            sys_oid = sys_oid_line.split(" = OID: ")[1].strip()
        else:
            return {"changed": False, "msg": "discovery failed: could not parse system OID",
                    "data": {"discovery": []}}
        
        # Check if we support this device
        if sys_oid not in DEVICE_TO_ENCLOSURE_OID:
            return {"changed": False, "msg": "discovery: unsupported Fujitsu device",
                    "data": {"discovery": []}}
        
        # Walk device enclosure section: base_oid = device_oid + enclosure_oid
        base_oid = sys_oid + DEVICE_TO_ENCLOSURE_OID[sys_oid]
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), base_oid + ".1",
                       base_oid + ".3"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed: snmpwalk error",
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: each line is "OID.index = TYPE: value"
        items = []
        index_map = {}
        status_map = {}
        
        for line in res.stdout.splitlines():
            if line.find("=") == -1:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value = parts
            oid_parts = oid_full.rsplit(".", 1)
            if len(oid_parts) != 2:
                continue
            base, suffix = oid_parts
            idx = base.rsplit(".", 1)[0] if "." in base else ""
            
            # Extract numeric index from OID like ".1.2.3.4.1.1" -> "1"
            if suffix == "1":
                # Index OID -> store index
                idx_num = base.rsplit(".", 1)[1] if "." in base else base
                if idx_num.isdigit():
                    index_map[idx_num] = value.strip()
            elif suffix == "3":
                # Status OID -> store status
                idx_num = base.rsplit(".", 1)[1] if "." in base else base
                if idx_num.isdigit():
                    status_map[idx_num] = value.strip()
        
        # Build items: only include those with non-Invalid status (status != "4")
        for idx_num in index_map:
            status = status_map.get(idx_num, "4")  # Default to Invalid if missing
            if status != "4":
                items.append({
                    "item": index_map[idx_num],
                    "params": {},
                    "metrics": []
                })
        
        return {"changed": False, "msg": "discovered %d enclosures" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: validate one enclosure item
    item = params.get("item", "")
    
    # Get system OID to determine model family
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "check failed: snmpget error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sys_oid_line = res.stdout.strip()
    if sys_oid_line.find(" = OID: ") != -1:
        sys_oid = sys_oid_line.split(" = OID: ")[1].strip()
    else:
        return {"changed": False, "msg": "check failed: could not parse system OID",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if sys_oid not in DEVICE_TO_ENCLOSURE_OID:
        return {"changed": False, "msg": "unsupported Fujitsu device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch index and status for this specific item using snmpget
    base_oid = sys_oid + DEVICE_TO_ENCLOSURE_OID[sys_oid]
    
    # First, find the index for the item name by walking indices
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), base_oid + ".1"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "check failed: snmpwalk error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Build name->index mapping
    name_to_idx = {}
    for line in res.stdout.splitlines():
        if line.find("=") == -1:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value = parts
        # OID ends with .1 -> get parent index
        idx_str = oid_full.rsplit(".", 1)[0].rsplit(".", 1)[1]
        if idx_str.isdigit():
            name_to_idx[value.strip()] = idx_str
    
    if item not in name_to_idx:
        return {"changed": False, "msg": "enclosure not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    idx_num = name_to_idx[item]
    
    # Now get status for this index
    status_oid = base_oid + ".3." + idx_num
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), status_oid],
                  mutates=False)
    
    if res.rc != 0 or res.stdout.strip().find("=") == -1:
        return {"changed": False, "msg": "check failed: could not read status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse status value
    status_line = res.stdout.strip()
    status_value = status_line.split("=")[-1].strip()
    
    # Map status to Checkmk state
    status_info = FJDARYE_ITEM_STATUS.get(status_value, {"state": "UNKNOWN", "summary": "Unknown"})
    
    msg = "%s: %s" % (item, status_info["summary"])
    
    return {"changed": False, "msg": msg,
            "data": {"state": status_info["state"], "metrics": {}, "details": ""}}
