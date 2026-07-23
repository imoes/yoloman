# ===== Starlark check: fortigate_node_memory =====

# SNMP OID constants
OID_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
OID_FORTIGATE_STANDALONE = ".1.3.6.1.4.1.12356.101.13.1.1.0"
OID_MEMORY_SECTION_BASE = ".1.3.6.1.4.1.12356.101.13.2.1.1"

# Threshold defaults
DEFAULT_LEVELS = (70.0, 80.0)

def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # Discovery mode: fetch SNMP data and enumerate items
        # First, detect FortiGate and non-standalone mode
        res_detect = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                              "-On", params.get("host", "localhost"), OID_SYS_OBJECT_ID],
                             mutates=False)
        sys_object_id = ""
        for line in res_detect.stdout.splitlines():
            # Format: <OID> = OBJECTIDENTIFIER: <value>
            parts = line.split(" = ", 1)
            if len(parts) == 2 and parts[0].strip() == OID_SYS_OBJECT_ID:
                sys_object_id = parts[1].strip()
                break
        
        # Check if it's a FortiGate
        if not sys_object_id.startswith(".1.3.6.1.4.1.12356.101.1"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Check standalone mode
        res_standalone = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                                  "-On", params.get("host", "localhost"), OID_FORTIGATE_STANDALONE],
                                 mutates=False)
        standalone_value = ""
        for line in res_standalone.stdout.splitlines():
            parts = line.split(" = ", 1)
            if len(parts) == 2 and parts[0].strip() == OID_FORTIGATE_STANDALONE:
                # Extract value: "INTEGER: 1" or similar
                val_part = parts[1].strip()
                if val_part.startswith("INTEGER:"):
                    standalone_value = val_part.split(":", 1)[1].strip()
                break
        
        # Exclude standalone mode (value "1")
        if standalone_value == "1":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Fetch memory section: OIDs are .1.3.6.1.4.1.12356.101.13.2.1.1.11.<OIDEnd> and .1.3.6.1.4.1.12356.101.13.2.1.1.4.<OIDEnd>
        # We need both host name and memory value for each OIDEnd.
        # We'll walk both OIDs separately and correlate by OIDEnd.
        res_memory_11 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"),
                                 OID_MEMORY_SECTION_BASE + ".11"],
                                mutates=False)
        res_memory_4 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                                "-On", params.get("host", "localhost"),
                                OID_MEMORY_SECTION_BASE + ".4"],
                               mutates=False)
        
        # Parse host names (OID .11)
        host_map = {}  # OIDEnd -> host name
        for line in res_memory_11.stdout.splitlines():
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            # Extract OIDEnd: e.g. ".1.3.6.1.4.1.12356.101.13.2.1.1.11.5" -> "5"
            if not oid_full.startswith(OID_MEMORY_SECTION_BASE + ".11."):
                continue
            oid_end = oid_full[len(OID_MEMORY_SECTION_BASE + ".11."):]
            val_part = parts[1].strip()
            if val_part.startswith("STRING:"):
                host_name = val_part.split(":", 1)[1].strip().strip('"')
            elif val_part.startswith("INTEGER:"):
                host_name = val_part.split(":", 1)[1].strip()
            else:
                host_name = val_part
            host_map[oid_end] = host_name
        
        # Parse memory percentages (OID .4)
        memory_map = {}  # OIDEnd -> memory percent
        for line in res_memory_4.stdout.splitlines():
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            if not oid_full.startswith(OID_MEMORY_SECTION_BASE + ".4."):
                continue
            oid_end = oid_full[len(OID_MEMORY_SECTION_BASE + ".4."):]
            val_part = parts[1].strip()
            if val_part.startswith("INTEGER:"):
                # Guard: ensure value is numeric before converting
                mem_val_str = val_part.split(":", 1)[1].strip()
                # Check if it's a valid number string
                mem_val = 0.0
                if mem_val_str.replace(".", "").replace("-", "").isdigit():
                    mem_val = float(mem_val_str)
            else:
                # Try direct conversion
                mem_val_str = val_part
                mem_val = 0.0
                if mem_val_str.replace(".", "").replace("-", "").isdigit():
                    mem_val = float(mem_val_str)
            memory_map[oid_end] = mem_val
        
        # Build items: correlate by OIDEnd
        discovered_items = []
        for oid_end in host_map:
            if oid_end in memory_map:
                item_name = host_map[oid_end]
                if item_name == "":
                    item_name = "Node " + oid_end
                discovered_items.append({
                    "item": item_name,
                    "params": {"levels": DEFAULT_LEVELS},
                    "metrics": ["mem_used_percent"]
                })
        
        return {"changed": False, "msg": "discovered %d items" % len(discovered_items),
                "data": {"discovery": discovered_items}}
    
    # Check mode: specific item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch both data pieces
    res_memory_11 = ctx.run(["snmpwalk", "-v2c", "-c", community,
                             "-On", host, OID_MEMORY_SECTION_BASE + ".11"],
                            mutates=False)
    res_memory_4 = ctx.run(["snmpwalk", "-v2c", "-c", community,
                            "-On", host, OID_MEMORY_SECTION_BASE + ".4"],
                           mutates=False)
    
    # Build host map and memory map as in discovery
    host_map = {}
    for line in res_memory_11.stdout.splitlines():
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        if not oid_full.startswith(OID_MEMORY_SECTION_BASE + ".11."):
            continue
        oid_end = oid_full[len(OID_MEMORY_SECTION_BASE + ".11."):]
        val_part = parts[1].strip()
        if val_part.startswith("STRING:"):
            host_name = val_part.split(":", 1)[1].strip().strip('"')
        elif val_part.startswith("INTEGER:"):
            host_name = val_part.split(":", 1)[1].strip()
        else:
            host_name = val_part
        host_map[oid_end] = host_name
    
    memory_map = {}
    for line in res_memory_4.stdout.splitlines():
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        if not oid_full.startswith(OID_MEMORY_SECTION_BASE + ".4."):
            continue
        oid_end = oid_full[len(OID_MEMORY_SECTION_BASE + ".4."):]
        val_part = parts[1].strip()
        if val_part.startswith("INTEGER:"):
            # Guard: ensure value is numeric before converting
            mem_val_str = val_part.split(":", 1)[1].strip()
            mem_val = 0.0
            if mem_val_str.replace(".", "").replace("-", "").isdigit():
                mem_val = float(mem_val_str)
        else:
            mem_val_str = val_part
            mem_val = 0.0
            if mem_val_str.replace(".", "").replace("-", "").isdigit():
                mem_val = float(mem_val_str)
        memory_map[oid_end] = mem_val
    
    # Find the item's memory value
    memory = None
    for oid_end in host_map:
        if host_map[oid_end] == item or (item == "" and len(host_map) == 1):
            if oid_end in memory_map:
                memory = memory_map[oid_end]
                break
        # Also handle the case where item is numeric (Node 0, etc.)
        if item.startswith("Node ") and oid_end == item[5:]:
            if oid_end in memory_map:
                memory = memory_map[oid_end]
                break
    
    if memory == None:
        return {"changed": False, "msg": "item not found: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply thresholds
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = levels[0] if len(levels) >= 1 else DEFAULT_LEVELS[0]
    crit = levels[1] if len(levels) >= 2 else DEFAULT_LEVELS[1]
    
    # Upper levels: WARN if >= warn, CRIT if >= crit
    state = "CRIT" if memory >= crit else ("WARN" if memory >= warn else "OK")
    
    return {"changed": False,
            "msg": "Usage %f%%" % memory,
            "data": {"state": state, "metrics": {"mem_used_percent": memory}, "details": ""}}
