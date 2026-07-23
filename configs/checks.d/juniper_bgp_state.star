# Juniper BGP State Check - read-only Starlark translation
# SNMP OIDs for juniper_bgp_state section
BGP_BASE_OID = ".1.3.6.1.4.1.2636.5.1.1.2.1.1.1"
BGP_STATE_OID = "2"      # bgpPeerState
BGP_OPER_STATE_OID = "3" # bgpPeerAdminStatus
BGP_PEER_ADDR_OID = "11" # bgpPeerRemoteAs or address (OctetString)

# State mappings
BGP_STATE_MAP = {
    "0": "undefined",
    "1": "idle",
    "2": "connect",
    "3": "active",
    "4": "opensent",
    "5": "openconfirm",
    "6": "established",
}

BGP_OPER_STATE_MAP = {
    "0": "undefined",
    "1": "halted",
    "2": "running",
}

# State to Checkmk State mapping
STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def _parse_hex_bytes(addr_bytes):
    """Parse hex string to list of integer bytes."""
    nums = []
    if addr_bytes == None:
        return nums
    hex_str = addr_bytes.strip()
    if not hex_str:
        return nums
    # Process two hex chars at a time
    i = 0
    while i < len(hex_str):
        if i + 1 < len(hex_str):
            pair = hex_str[i:i+2]
            v1 = 0
            v2 = 0
            if pair[0] >= '0' and pair[0] <= '9':
                v1 = int(pair[0])
            elif pair[0] >= 'a' and pair[0] <= 'f':
                v1 = ord(pair[0]) - ord('a') + 10
            elif pair[0] >= 'A' and pair[0] <= 'F':
                v1 = ord(pair[0]) - ord('A') + 10
            if pair[1] >= '0' and pair[1] <= '9':
                v2 = int(pair[1])
            elif pair[1] >= 'a' and pair[1] <= 'f':
                v2 = ord(pair[1]) - ord('a') + 10
            elif pair[1] >= 'A' and pair[1] <= 'F':
                v2 = ord(pair[1]) - ord('A') + 10
            nums.append(v1 * 16 + v2)
        i = i + 1
    return nums

def _format_ipv4(nums):
    """Format IPv4 address from 4 bytes."""
    if len(nums) != 4:
        return None
    return "%d.%d.%d.%d" % (nums[0], nums[1], nums[2], nums[3])

def _format_ipv6(nums):
    """Format IPv6 address from 16 bytes."""
    if len(nums) != 16:
        return None
    groups = []
    for i in range(0, 16, 2):
        group = "%x%x" % (nums[i], nums[i+1])
        groups.append(group)
    return ":".join(groups)

def _clean_address(addr_bytes):
    """Convert hex string to cleaned IP address representation."""
    if addr_bytes == None:
        return ""
    nums = _parse_hex_bytes(addr_bytes)
    
    # Check for IPv4 (4 bytes)
    if len(nums) == 4:
        return _format_ipv4(nums)
    
    # Check for IPv6 (16 bytes)
    if len(nums) == 16:
        return _format_ipv6(nums)
    
    # Fallback: format as space-separated hex bytes
    parts = []
    for n in nums:
        parts.append("%X" % n)
    return " ".join(parts)

def _get_bgp_peers(ctx, params):
    """Fetch BGP peer data via SNMP."""
    # Use snmpwalk to get the section data
    base_oid = BGP_BASE_OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", 
                   params.get("host", "localhost"), base_oid], mutates=False)
    if res.rc != 0:
        return None
    
    peers = {}
    # Parse the output lines: each line is "oid.index = TYPE: value"
    lines = res.stdout.splitlines()
    
    # Build mapping from index to values
    state_data = {}    # index -> state
    oper_data = {}     # index -> operational state
    addr_data = {}     # index -> address bytes
    
    i = 0
    while i < len(lines):
        line = lines[i]
        i = i + 1
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        
        # Extract base OID and index
        if not oid_part.startswith(base_oid + "."):
            continue
        suffix = oid_part[len(base_oid) + 1:]
        if "." not in suffix:
            continue
        index_part, oid_suffix = suffix.split(".", 1)
        index_part = index_part.strip()
        oid_suffix = oid_suffix.strip()
        
        # Extract value (remove type prefix if present, e.g., "STRING:" or "INTEGER:")
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value = value_part.strip()
        
        # Categorize by OID suffix
        if oid_suffix == BGP_STATE_OID:
            state_data[index_part] = value
        elif oid_suffix == BGP_OPER_STATE_OID:
            oper_data[index_part] = value
        elif oid_suffix == BGP_PEER_ADDR_OID:
            addr_data[index_part] = value
    
    # Combine data per index
    all_indices = set(state_data.keys()) | set(oper_data.keys()) | set(addr_data.keys())
    idx_list = []
    for idx in all_indices:
        idx_list.append(idx)
    
    i = 0
    while i < len(idx_list):
        idx = idx_list[i]
        i = i + 1
        state = state_data.get(idx, "")
        oper_state = oper_data.get(idx, "")
        addr_bytes = addr_data.get(idx, "")
        
        # Create item from address bytes
        item = _clean_address(addr_bytes) if addr_bytes else idx
        
        # Map states
        state_txt = BGP_STATE_MAP.get(state.strip(), "undefined")
        oper_txt = BGP_OPER_STATE_MAP.get(oper_state.strip(), "undefined")
        
        peers[item] = {
            "state": state_txt,
            "operational_state": oper_txt,
        }
    
    return peers

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        peers = _get_bgp_peers(ctx, params)
        if peers == None:
            return {
                "changed": False,
                "msg": "no BGP data available (SNMP error)",
                "data": {"discovery": []}
            }
        
        discovery_items = []
        item_list = []
        for item in peers:
            item_list.append(item)
        i = 0
        while i < len(item_list):
            item = item_list[i]
            i = i + 1
            discovery_items.append({
                "item": item,
                "params": {},  # no parameters needed for this check
                "metrics": []  # this check produces no perfdata
            })
        
        return {
            "changed": False,
            "msg": "discovered %d BGP peers" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    peers = _get_bgp_peers(ctx, params)
    
    # If no data available at all, return UNKNOWN
    if peers == None:
        return {
            "changed": False,
            "msg": "no BGP data available (SNMP error)",
            "data": {
                "state": STATE_UNKNOWN,
                "metrics": {},
                "details": ""
            }
        }
    
    # Look up the requested item
    data = peers.get(item)
    
    # If item not found, return UNKNOWN
    if data == None:
        return {
            "changed": False,
            "msg": "no data for peer %s" % item,
            "data": {
                "state": STATE_UNKNOWN,
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract states
    state = data.get("state", "undefined")
    operational_state = data.get("operational_state", "undefined")
    
    # Determine main status (BGP state)
    if state == "established":
        status = STATE_OK
    elif state == "undefined":
        status = STATE_UNKNOWN
    else:
        status = STATE_CRIT
    
    # If operational state is "halted", being un-established is fine (per Checkmk logic)
    if operational_state == "halted":
        status = STATE_OK
    
    # Determine operational status
    if operational_state == "running":
        op_status = STATE_OK
    elif operational_state == "undefined":
        op_status = STATE_UNKNOWN
    else:
        op_status = STATE_WARN
    
    # Build summary messages (checkmk-style)
    summary = "Status with peer %s is %s" % (item, state)
    op_summary = "operational status: %s" % operational_state
    
    # Return combined result
    return {
        "changed": False,
        "msg": "%s; %s" % (summary, op_summary),
        "data": {
            "state": status,
            "metrics": {},
            "details": "%s. %s" % (summary, op_summary)
        }
    }