# Module-level constants
FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: fetch controller enclosures via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Base OIDs per device type (from FJDARYE_CONTROLLER_ENCLOSURES)
        device_oids = [
            (".1.3.6.1.4.1.211.1.21.1.60", ".2.6.2.1"),    # fjdarye60
            (".1.3.6.1.4.1.211.1.21.1.100", ".2.10.2.1"),  # fjdarye100
            (".1.3.6.1.4.1.211.1.21.1.101", ".2.10.2.1"),  # fjdarye101
            (".1.3.6.1.4.1.211.1.21.1.150", ".2.10.2.1"),  # fjdarye500
            (".1.3.6.1.4.1.211.1.21.1.153", ".2.10.2.1"),  # fjdarye600
        ]
        
        discovered = []
        for device_oid, controller_enclosure_oid in device_oids:
            base_oid = device_oid + controller_enclosure_oid
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, base_oid + ".1",  # fetch index
                base_oid + ".3"        # fetch status
            ], mutates=False)
            
            if res.rc != 0:
                continue
                
            # Parse snmpwalk output: lines like "OID.1 = INTEGER: index" and "OID.3 = INTEGER: status"
            lines = res.stdout.splitlines()
            index_map = {}
            status_map = {}
            
            for line in lines:
                if not line.strip():
                    continue
                # Split into OID and value part
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                # Extract value after colon and type prefix
                if ":" in value_part:
                    value = value_part.split(":", 1)[1].strip()
                else:
                    value = value_part
                
                # Determine if this is an index (.1) or status (.3) line
                if oid_part.endswith(".1"):
                    # Extract item index from OID (e.g., ...index.1 -> index)
                    oid_suffix = oid_part.rsplit(".", 1)[0]
                    item_index = oid_suffix.rsplit(".", 1)[-1] if "." in oid_suffix else oid_suffix
                    index_map[item_index] = value
                elif oid_part.endswith(".3"):
                    oid_suffix = oid_part.rsplit(".", 1)[0]
                    item_index = oid_suffix.rsplit(".", 1)[-1] if "." in oid_suffix else oid_suffix
                    status_map[item_index] = value
            
            # Combine index and status to produce discovered items
            for item_index in index_map:
                if item_index in status_map and status_map[item_index] != "4":
                    # status != "Invalid" (4) for inventory
                    discovered.append({
                        "item": item_index,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d controller enclosures" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: examine a specific item
    item = params.get("item", "")
    
    # Reconstruct the same SNMP fetch logic for discovery
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    device_oids = [
        (".1.3.6.1.4.1.211.1.21.1.60", ".2.6.2.1"),
        (".1.3.6.1.4.1.211.1.21.1.100", ".2.10.2.1"),
        (".1.3.6.1.4.1.211.1.21.1.101", ".2.10.2.1"),
        (".1.3.6.1.4.1.211.1.21.1.150", ".2.10.2.1"),
        (".1.3.6.1.4.1.211.1.21.1.153", ".2.10.2.1"),
    ]
    
    # Gather all data across devices to find the requested item
    section = {}
    for device_oid, controller_enclosure_oid in device_oids:
        base_oid = device_oid + controller_enclosure_oid
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".1", base_oid + ".3"
        ], mutates=False)
        
        if res.rc != 0:
            continue
        
        lines = res.stdout.splitlines()
        index_map = {}
        status_map = {}
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            value = value_part.split(":", 1)[1].strip() if ":" in value_part else value_part
            
            if oid_part.endswith(".1"):
                oid_suffix = oid_part.rsplit(".", 1)[0]
                item_index = oid_suffix.rsplit(".", 1)[-1] if "." in oid_suffix else oid_suffix
                index_map[item_index] = value
            elif oid_part.endswith(".3"):
                oid_suffix = oid_part.rsplit(".", 1)[0]
                item_index = oid_suffix.rsplit(".", 1)[-1] if "." in oid_suffix else oid_suffix
                status_map[item_index] = value
        
        # Combine into section
        for item_index in index_map:
            if item_index in status_map:
                section[item_index] = status_map[item_index]
    
    # Check the specific item
    if item not in section:
        return {
            "changed": False,
            "msg": "item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status = section[item]
    state_summary = FJDARYE_ITEM_STATUS.get(status, ("UNKNOWN", "Unknown"))
    state, summary = state_summary
    
    return {
        "changed": False,
        "msg": "Controller Enclosure %s: %s" % (item, summary),
        "data": {"state": state, "metrics": {}, "details": ""}
    }
