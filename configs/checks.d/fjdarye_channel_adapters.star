# ===== Checkmk fjdarye_channel_adapters translated to Starlark =====
# SNMP OIDs mapping for supported devices
FJDARYE_DEVICE_OIDS = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.2.2.1",  # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.3.2.1", # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.3.2.1", # fjdarye101
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.3.2.1", # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.3.2.1", # fjdarye600
}

# Status mapping: status code -> (state, summary)
FJDARYE_STATUS_MAP = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

def main(ctx, params):
    # Discovery mode: enumerate all channel adapters
    if params.get("_discover"):
        discovery_items = []
        for device_oid, channel_adapter_oid in FJDARYE_DEVICE_OIDS.items():
            base_oid = device_oid + channel_adapter_oid
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                base_oid + ".1",  # Index
                base_oid + ".3"   # Status
            ], mutates=False)
            
            # Parse snmpwalk output: OID = TYPE: value lines
            lines = res.stdout.splitlines()
            indices = {}
            statuses = {}
            
            for line in lines:
                # Format: .oid.index = STRING: value or INTEGER: value
                if "=" not in line:
                    continue
                oid_part, value_part = line.split("=", 1)
                oid = oid_part.strip()
                value = value_part.strip()
                
                # Extract base OID (without .1 or .3 suffix)
                if oid.endswith(".1"):
                    item_idx = oid[:-2]
                    # Extract index value
                    idx_val = value.split(":")[-1].strip() if ":" in value else value
                    indices[item_idx] = idx_val
                elif oid.endswith(".3"):
                    item_idx = oid[:-2]
                    # Extract status value
                    status_val = value.split(":")[-1].strip() if ":" in value else value
                    statuses[item_idx] = status_val
            
            # Build list of (item_index, status) pairs
            for item_idx in sorted(indices.keys()):
                if item_idx in statuses:
                    item_index = indices[item_idx]
                    status = statuses[item_idx]
                    discovery_items.append({
                        "item": item_index,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d channel adapters" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: examine one item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        item + ".1",  # Index
        item + ".3"   # Status
    ], mutates=False)
    
    # Parse the response
    lines = res.stdout.splitlines()
    index_val = ""
    status_val = ""
    
    for line in lines:
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid = oid_part.strip()
        value = value_part.strip()
        
        if oid == item + ".1":
            index_val = value.split(":")[-1].strip() if ":" in value else value
        elif oid == item + ".3":
            status_val = value.split(":")[-1].strip() if ":" in value else value
    
    # Determine state and summary based on status
    if status_val == "":
        return {
            "changed": False,
            "msg": "channel adapter %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_summary = FJDARYE_STATUS_MAP.get(status_val, ("UNKNOWN", "Unknown"))
    state, summary = state_summary
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
