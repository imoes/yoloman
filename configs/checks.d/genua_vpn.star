# ===== module-level constants =====
GENUA_OIDS = {
    "base": ".1.3.6.1.4.1.3717.2.1.3.1",
    "vpn_id": ".1",
    "hostname": ".2",
    "ip_opposite": ".3",
    "vpn_private": ".4",
    "vpn_remote": ".5",
    "vpn_state": ".6",
}

# ===== helper functions =====
def _snmp_parse_line(line):
    """Parse a single snmpwalk line: '<OID> = <TYPE>: <value>'"""
    # Split on ' = '
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None, None
    oid_part, value_part = parts
    # Split value on ': ' to get type and value
    val_parts = value_part.split(": ", 1)
    if len(val_parts) != 2:
        return None, None
    value = val_parts[1].strip()
    # Strip quotes if present
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    return oid_part.strip(), value

def _get_oid_suffix(oid_base, suffix):
    """Append suffix to base OID"""
    if not oid_base.endswith("."):
        return oid_base + suffix
    return oid_base + suffix[1:] if suffix.startswith(".") else oid_base + suffix

# ===== main function =====
def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            GENUA_OIDS["base"]
        ], mutates=False)
        
        # Parse SNMP output into structured data
        sections = []
        lines = res.stdout.splitlines()
        # Build a map: oid_suffix -> value
        oid_map = {}
        for line in lines:
            if not line.strip():
                continue
            oid_part, value = _snmp_parse_line(line)
            if oid_part == None:
                continue
            # Extract suffix relative to base
            if oid_part.startswith(GENUA_OIDS["base"] + "."):
                suffix = oid_part[len(GENUA_OIDS["base"] + "."):]
                oid_map[suffix] = value
        
        # Group entries by vpn_id (1-based indices)
        # Collect all vpn_ids first
        vpn_ids = []
        for suffix in oid_map:
            if suffix == "1":  # vpn_id
                val = oid_map[suffix]
                if val.isdigit():
                    vpn_ids.append(val)
        
        # Build discovery list
        discovery_items = []
        seen_vpn_ids = set()
        for idx in vpn_ids:
            if idx in seen_vpn_ids:
                continue
            seen_vpn_ids.add(idx)
            # Get all fields for this index
            hostname = oid_map.get("2." + idx, "")
            ip_opposite = oid_map.get("3." + idx, "")
            vpn_private = oid_map.get("4." + idx, "")
            vpn_remote = oid_map.get("5." + idx, "")
            vpn_state = oid_map.get("6." + idx, "")
            
            # Skip if no vpn_id found (should not happen)
            if not idx:
                continue
            
            # Item is vpn_id (string)
            item_name = idx
            # Build suggested params (none needed, but keep structure)
            suggested_params = {}
            
            # Metrics: none, but list placeholder for consistency
            metrics = []
            
            discovery_items.append({
                "item": item_name,
                "params": suggested_params,
                "metrics": metrics
            })
        
        return {
            "changed": False,
            "msg": "discovered %d VPN connections" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        GENUA_OIDS["base"]
    ], mutates=False)
    
    # Parse into structured data
    lines = res.stdout.splitlines()
    oid_map = {}
    for line in lines:
        if not line.strip():
            continue
        oid_part, value = _snmp_parse_line(line)
        if oid_part == None:
            continue
        if oid_part.startswith(GENUA_OIDS["base"] + "."):
            suffix = oid_part[len(GENUA_OIDS["base"] + "."):]
            oid_map[suffix] = value
    
    # Find matching entry by vpn_id
    for idx in oid_map:
        # Check if this is a vpn_id entry
        if idx.isdigit():
            vpn_id = idx
            hostname = oid_map.get("2." + vpn_id, "")
            ip_opposite = oid_map.get("3." + vpn_id, "")
            vpn_private = oid_map.get("4." + vpn_id, "")
            vpn_remote = oid_map.get("5." + vpn_id, "")
            vpn_state = oid_map.get("6." + vpn_id, "")
            
            if vpn_id == item:
                # Build info text
                ip_info = ""
                if ip_opposite:
                    ip_info = " (%s)" % ip_opposite
                
                infotext = "Hostname: %s%s, VPN private: %s, VPN remote: %s" % (
                    hostname, ip_info, vpn_private, vpn_remote
                )
                
                # Determine state: 2 = connected, else = disconnected
                state = "OK" if vpn_state == "2" else "CRIT"
                
                return {
                    "changed": False,
                    "msg": "%s, %s" % ("Connected" if vpn_state == "2" else "Disconnected", infotext),
                    "data": {
                        "state": state,
                        "metrics": {},
                        "details": ""
                    }
                }
    
    # Item not found
    return {
        "changed": False,
        "msg": "VPN item not found: %s" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
