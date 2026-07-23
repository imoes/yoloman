# ===== Starlark check module: hitachi_hus_dku =====
# Translated from Checkmk check: cmk.plugins.hitachi.hitachi_hus_dku
# Reads HUS DKU (Disk Unit) chassis status via SNMP


def main(ctx, params):
    # Constants
    BASE_OID_DKU = ".1.3.6.1.4.1.116.5.11.4.1.1.7.1"
    LABELS = ["Power Supply", "Fan", "Environment", "Drive"]
    STATE_MAP = {
        "0": ("UNKNOWN", "unknown"),
        "1": ("OK", "no error"),
        "2": ("CRIT", "acute"),
        "3": ("CRIT", "serious"),
        "4": ("WARN", "moderate"),
        "5": ("WARN", "service"),
    }
    
    # Discovery mode
    if params.get("_discover"):
        # Fetch all DKU status entries via snmpwalk
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID_DKU],
            mutates=False
        )
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse the output: find OID ends and extract status values
        entries = {}  # item -> list of (oid_index, status_value)
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract OID index (last number after the base OID)
            if not oid_part.startswith(BASE_OID_DKU + "."):
                continue
            suffix = oid_part[len(BASE_OID_DKU) + 1:]
            idx = 0
            if suffix.isdigit():
                idx = int(suffix)
            else:
                continue
            
            # Extract status value (expecting "INTEGER: <value>" or similar)
            status = ""
            if value_part.startswith("INTEGER: "):
                status = value_part[9:].strip()
            elif value_part.startswith("Gauge32: "):
                status = value_part[9:].strip()
            else:
                # Try to get the last part after ': '
                colon_idx = value_part.find(": ")
                if colon_idx != -1:
                    status = value_part[colon_idx+2:].strip()
                else:
                    status = value_part
            
            # Group by item: first OID index is the item identifier (1 or 2 typically)
            # For DKU, the first OID index (1 or 2) represents different DKU units
            item_key = str(idx)
            if item_key not in entries:
                entries[item_key] = []
            entries[item_key].append((idx, status))
        
        # Build discovery list
        discovery = []
        for item in sorted(entries.keys()):
            statuses = entries[item]
            # Sort by OID index to ensure consistent ordering
            statuses.sort(key=lambda x: x[0])
            
            # We'll use item as the DKU unit number (e.g., "1", "2")
            # Extract the status values for each label (first 4 values)
            status_values = []
            for _, status in statuses[:4]:
                if status in STATE_MAP:
                    status_values.append(status)
                else:
                    status_values.append("0")  # Default unknown
            
            # Only include if we have exactly 4 status values (one per label)
            if len(status_values) == 4:
                # Create suggested params (no thresholds, just item)
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d DKU chassis" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    # Check mode
    item = params.get("item", "1")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch all DKU data for this item's unit
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID_DKU],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output and collect statuses for this item
    statuses = {}  # oid_index -> status_value
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract OID index
        if not oid_part.startswith(BASE_OID_DKU + "."):
            continue
        suffix = oid_part[len(BASE_OID_DKU) + 1:]
        idx = 0
        if suffix.isdigit():
            idx = int(suffix)
        else:
            continue
        
        # Extract status value
        status = ""
        if value_part.startswith("INTEGER: "):
            status = value_part[9:].strip()
        elif value_part.startswith("Gauge32: "):
            status = value_part[9:].strip()
        else:
            colon_idx = value_part.find(": ")
            if colon_idx != -1:
                status = value_part[colon_idx+2:].strip()
            else:
                status = value_part
        
        statuses[str(idx)] = status
    
    # Assume item "1" covers indices 1-5 (typical for DKU)
    if item == "1":
        item_indices = [1, 2, 3, 4, 5]
    else:
        # For other items, try to find matching indices
        idx_val = 0
        if item.isdigit():
            idx_val = int(item)
        item_indices = [idx_val]
    
    # Collect statuses for these indices
    status_values = []
    for idx in item_indices:
        status_key = str(idx)
        if status_key in statuses:
            status_values.append(statuses[status_key])
        else:
            status_values.append("0")
    
    # Trim to 4 values (labels only has 4 entries)
    status_values = status_values[:4]
    
    if len(status_values) == 0:
        return {
            "changed": False,
            "msg": "no data for DKU chassis " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine worst state and collect details
    state = "OK"
    details_lines = []
    
    for i, s in enumerate(status_values):
        label = LABELS[i] if i < len(LABELS) else "Unknown"
        state_str = "UNKNOWN"
        desc = "unknown"
        if s in STATE_MAP:
            state_str, desc = STATE_MAP[s]
        
        # Update worst state: CRIT > WARN > UNKNOWN > OK
        if state_str == "CRIT":
            state = "CRIT"
        elif state_str == "WARN" and state != "CRIT":
            state = "WARN"
        elif state_str == "UNKNOWN" and state not in ["CRIT", "WARN"]:
            state = "UNKNOWN"
        
        details_lines.append(label + ": " + desc)
    
    # Build details string
    details = "; ".join(details_lines)
    
    # Build summary (Checkmk style: first line of details)
    summary = details_lines[0] if details_lines else "no data"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }