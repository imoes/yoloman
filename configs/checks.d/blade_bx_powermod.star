# ===== check plugin: blade_bx_powermod.star =====
# Translation of Checkmk's blade_bx_powermod check to Starlark

# Map status codes to (state_readable, state) tuples
POWER_STATUS = {
    "1": ("unknown", "UNKNOWN"),
    "2": ("ok", "OK"),
    "3": ("not-present", "CRIT"),
    "4": ("error", "CRIT"),
    "5": ("critical", "CRIT"),
    "6": ("off", "CRIT"),
    "7": ("dummy", "CRIT"),
    "8": ("fanmodule", "OK"),
}

def main(ctx, params):
    # Discovery mode: enumerate power modules
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        # Fetch the SNMP table: base OID .1.3.6.1.4.1.7244.1.1.1.3.2.4.1 with OIDs 1,2,4
        base_oid = ".1.3.6.1.4.1.7244.1.1.1.3.2.4.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []},
            }
        
        # Parse SNMP output: each line format is "OID.index = TYPE: value"
        # We expect three OIDs per index: .1 (index), .2 (status), .4 (product_name)
        # Build a map: index -> (status, product_name)
        entries = {}
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            # Expect three consecutive lines for same index (index, status, product_name)
            # Skip empty lines
            if not lines[i].strip():
                i += 1
                continue
            
            # Parse the first OID line (index)
            parts1 = lines[i].strip().split(" = ")
            if len(parts1) < 2:
                i += 1
                continue
            oid1 = parts1[0].strip()
            # Extract base and index from OID like .1.3.6.1.4.1.7244.1.1.1.3.2.4.1.1.1
            if not oid1.startswith(base_oid + "."):
                i += 1
                continue
            suffix1 = oid1[len(base_oid)+1:]
            # Extract the index part (e.g., "1" from ".1.1")
            dot_pos = suffix1.find(".")
            if dot_pos == -1:
                index = suffix1
            else:
                index = suffix1[:dot_pos]
            
            val1 = parts1[1].strip()
            # Skip non-numeric index or invalid value
            if not index.isdigit():
                i += 1
                continue
            
            # Parse the status line (.2)
            if i + 1 >= len(lines) or not lines[i + 1].strip():
                i += 1
                continue
            parts2 = lines[i + 1].strip().split(" = ")
            if len(parts2) < 2:
                i += 1
                continue
            oid2 = parts2[0].strip()
            if not oid2.startswith(base_oid + "." + index + ".2"):
                i += 1
                continue
            status = parts2[1].strip()
            # Strip type prefix (e.g., "INTEGER: " or "Gauge32: ")
            if ":" in status:
                status = status.split(":", 1)[1].strip()
            
            # Parse the product_name line (.4)
            if i + 2 >= len(lines) or not lines[i + 2].strip():
                i += 1
                continue
            parts3 = lines[i + 2].strip().split(" = ")
            if len(parts3) < 2:
                i += 1
                continue
            oid3 = parts3[0].strip()
            if not oid3.startswith(base_oid + "." + index + ".4"):
                i += 1
                continue
            product_name = parts3[1].strip()
            # Strip type prefix (e.g., "STRING: ")
            if ":" in product_name:
                product_name = product_name.split(":", 1)[1].strip()
                # Remove surrounding quotes if present
                if product_name.startswith('"') and product_name.endswith('"'):
                    product_name = product_name[1:-1]
            
            # Store entry
            entries[index] = (status, product_name)
            
            i += 3
        
        # Build discovery list: one item per entry
        discovery_items = []
        for index, (status, product_name) in entries.items():
            # Suggested params: empty dict (no thresholds in original)
            discovery_items.append({
                "item": index,
                "params": {},
                "metrics": [],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d power modules" % len(discovery_items),
            "data": {"discovery": discovery_items},
        }
    
    # Check mode: examine one power module
    item = params.get("item", "")
    
    # Get SNMP data (same as discovery)
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    base_oid = ".1.3.6.1.4.1.7244.1.1.1.3.2.4.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse SNMP output (same as discovery)
    entries = {}
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        if not lines[i].strip():
            i += 1
            continue
        parts1 = lines[i].strip().split(" = ")
        if len(parts1) < 2:
            i += 1
            continue
        oid1 = parts1[0].strip()
        if not oid1.startswith(base_oid + "."):
            i += 1
            continue
        suffix1 = oid1[len(base_oid)+1:]
        dot_pos = suffix1.find(".")
        if dot_pos == -1:
            index = suffix1
        else:
            index = suffix1[:dot_pos]
        
        val1 = parts1[1].strip()
        if not index.isdigit():
            i += 1
            continue
        
        # Parse the status line (.2)
        if i + 1 >= len(lines) or not lines[i + 1].strip():
            i += 1
            continue
        parts2 = lines[i + 1].strip().split(" = ")
        if len(parts2) < 2:
            i += 1
            continue
        oid2 = parts2[0].strip()
        if not oid2.startswith(base_oid + "." + index + ".2"):
            i += 1
            continue
        status = parts2[1].strip()
        if ":" in status:
            status = status.split(":", 1)[1].strip()
        
        # Parse the product_name line (.4)
        if i + 2 >= len(lines) or not lines[i + 2].strip():
            i += 1
            continue
        parts3 = lines[i + 2].strip().split(" = ")
        if len(parts3) < 2:
            i += 1
            continue
        oid3 = parts3[0].strip()
        if not oid3.startswith(base_oid + "." + index + ".4"):
            i += 1
            continue
        product_name = parts3[1].strip()
        if ":" in product_name:
            product_name = product_name.split(":", 1)[1].strip()
            if product_name.startswith('"') and product_name.endswith('"'):
                product_name = product_name[1:-1]
        
        entries[index] = (status, product_name)
        i += 3
    
    # Look for the requested item
    if item not in entries:
        return {
            "changed": False,
            "msg": "power module %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    status, product_name = entries[item]
    
    # Look up state
    state_readable, state = POWER_STATUS.get(status, ("unknown", "UNKNOWN"))
    
    msg = "[%s] Status: %s" % (product_name, state_readable)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
