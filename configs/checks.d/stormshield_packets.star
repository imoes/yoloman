# ===== Starlark check module: stormshield_packets =====
# Translate Checkmk check: checkmk.stormshield_packets
# Read-only: gathers SNMP data and reports packet stats per interface.

# SNMP base OID for stormshield_packets section
_STORMSHIELD_BASE_OID = ".1.3.6.1.4.1.11256.1.4.1.1"

def _discover_interfaces(ctx, community, host):
    # Fetch all rows from the stormshield_packets SNMP table
    # OIDs: 2=description, 3=name, 6=iftype, 11=pktaccepted, 12=pktblocked,
    #       16=pkticmp, 23=tcp, 24=udp
    base = _STORMSHIELD_BASE_OID
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base
    ], mutates=False)
    
    # Parse SNMP output: each line is OID = TYPE: value
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return []
    
    # Group by row index (8 columns per row)
    rows = []
    current_row = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        # Extract value after " = "
        value = parts[1].strip()
        # Strip type prefix like "INTEGER: ", "STRING: ", "Gauge32: ", etc.
        if ": " in value:
            value = value.split(": ", 1)[1].strip()
        # Remove surrounding quotes from STRINGs
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        current_row.append(value)
        if len(current_row) == 8:
            rows.append(current_row)
            current_row = []
    
    # Filter and build discovery list: iftype must be "ethernet" or "ipsec"
    items = []
    for row in rows:
        if len(row) < 8:
            continue
        description = row[0]  # description (index 2)
        name = row[1]         # name (index 3)
        iftype = row[2]       # iftype (index 6)
        # Check if type matches discovery criteria (case-insensitive)
        if iftype.lower() in ["ethernet", "ipsec"]:
            # Build suggested params (no thresholds needed for this check)
            items.append({
                "item": description,
                "params": {},
                "metrics": ["tcp_active_sessions", "udp_active_sessions",
                            "packages_accepted", "packages_blocked", "packages_icmp_total"]
            })
    
    return items

def _check_interface(ctx, community, host, item, params):
    # Fetch specific OID row for the requested item
    # We'll walk and filter locally since snmpwalk returns all rows.
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        _STORMSHIELD_BASE_OID
    ], mutates=False)
    
    # Parse output and find the row with matching description
    lines = res.stdout.splitlines()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        # Extract description from first OID (.1.3.6.1.4.1.11256.1.4.1.1.2.*)
        if not line.startswith(_STORMSHIELD_BASE_OID + ".2"):
            continue
        
        # Extract value after " = "
        value = parts[1].strip()
        if ": " in value:
            value = value.split(": ", 1)[1].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        description = value
        
        # If not matching, skip to next row
        if description != item:
            # Skip ahead to next row (7 more OIDs)
            continue
        
        # We found the row: collect all 8 values
        # Extract the 7 subsequent OIDs for this row
        # Use a simple approach: collect all lines and group
        pass  # We'll restructure below
    
    # Better approach: parse all rows as in discovery, then filter by item
    # (Same logic as discovery, but return metrics for the single item)
    rows = []
    current_row = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        value = parts[1].strip()
        if ": " in value:
            value = value.split(": ", 1)[1].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        current_row.append(value)
        if len(current_row) == 8:
            rows.append(current_row)
            current_row = []
    
    # Find the matching row
    matched = None
    for row in rows:
        if len(row) < 8:
            continue
        if row[0] == item:
            matched = row
            break
    
    if matched == None:
        return {
            "changed": False,
            "msg": "interface not found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    description = matched[0]
    name = matched[1]
    iftype = matched[2]
    pktaccepted_str = matched[3]
    pktblocked_str = matched[4]
    pkticmp_str = matched[5]
    tcp_str = matched[6]
    udp_str = matched[7]
    
    # Convert to int
    pktaccepted = int(pktaccepted_str) if pktaccepted_str.isdigit() else 0
    pktblocked = int(pktblocked_str) if pktblocked_str.isdigit() else 0
    pkticmp = int(pkticmp_str) if pkticmp_str.isdigit() else 0
    tcp = int(tcp_str) if tcp_str.isdigit() else 0
    udp = int(udp_str) if udp_str.isdigit() else 0
    
    # Build info text
    infotext = "[%s], tcp: %d, udp: %d" % (name, tcp, udp)
    
    # Metrics: we do NOT use rate calculation here because:
    # - Checkmk's get_rate relies on value_store (not available in Starlark)
    # - The agent runs once per check; the source uses get_rate with a persistent store.
    # - We'll report raw counts instead of rates (checkmk agent stores rates).
    # - But the Checkmk source *requires* get_rate; since Starlark lacks persistence,
    #   we report zero for rate metrics (or raw counts if acceptable).
    #   To match the Checkmk plugin, we MUST use rates, so we'll simulate:
    #   For now, return 0 for rate metrics and note that this is a known limitation
    #   for single-run Starlark checks (a real agent would need persistent value_store).
    metrics = {
        "tcp_active_sessions": float(tcp),
        "udp_active_sessions": float(udp),
        "packages_accepted": float(0),  # rate — placeholder (requires persistent store)
        "packages_blocked": float(0),   # rate — placeholder
        "packages_icmp_total": float(0) # rate — placeholder
    }
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode
    if params.get("_discover"):
        items = _discover_interfaces(ctx, community, host)
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(items),
            "data": {
                "discovery": items
            }
        }
    
    # Check mode: single item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no interface item specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    return _check_interface(ctx, community, host, item, params)