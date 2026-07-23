# Map PDU state integers to readable status strings (v4 specific)
DEVICE_STATES_V4 = {
    0: ("OK", "normal"),
    1: ("CRIT", "disabled"),
    2: ("CRIT", "purged"),
    5: ("WARN", "reading"),
    6: ("WARN", "settle"),
    7: ("CRIT", "not found"),
    8: ("CRIT", "lost"),
    9: ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}

# SNMP OID for device identification (sysObjectID)
SYSOBJECT_OID = ".1.3.6.1.2.1.1.2.0"
# Base OID for sentry_pdu_v4 section
PDU_BASE_OID = ".1.3.6.1.4.1.1718.4.1.3"
# OID suffixes: 2.1.3 (plug name), 3.1.2 (state), 3.1.3 (power)
OID_NAME = PDU_BASE_OID + ".2.1.3"
OID_STATE = PDU_BASE_OID + ".3.1.2"
OID_POWER = PDU_BASE_OID + ".3.1.3"


def _parse_snmp_line(line):
    """Parse a single snmpget/snmpwalk output line."""
    parts = line.strip().split(" = ", 1)
    if len(parts) != 2:
        return "", ""
    oid_part = parts[0].strip()
    value_part = parts[1].strip()
    # Remove type prefix if present (STRING:, INTEGER:, etc.)
    if ":" in value_part:
        value = value_part.split(":", 1)[1].strip().strip('"')
        return oid_part, value
    return oid_part, value_part


def _extract_plug_index(oid):
    """Extract plug index from OID like .1.3.6.1.4.1.1718.4.1.3.2.1.3.1."""
    parts = oid.rsplit(".", 1)
    if len(parts) != 2:
        return -1
    idx_str = parts[1]
    return int(idx_str) if idx_str.isdigit() else -1


def _get_snmp_data(ctx, params):
    """Fetch PDU data via SNMP and return list of tuples (name, state, power)."""
    # Get sysObjectID to verify it's a Sentry v4 device
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), SYSOBJECT_OID], mutates=False)
    
    if res.rc != 0:
        return []
    if ".1.3.6.1.4.1.1718.4" not in res.stdout:
        return []
    
    # Fetch all required OIDs
    name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), OID_NAME], mutates=False)
    state_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), OID_STATE], mutates=False)
    power_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), OID_POWER], mutates=False)
    
    if name_res.rc != 0 or state_res.rc != 0 or power_res.rc != 0:
        return []
    
    # Parse SNMP lines into dictionaries
    names = {}
    states = {}
    powers = {}
    
    for line in name_res.stdout.splitlines():
        if line.strip():
            oid, val = _parse_snmp_line(line)
            if oid and val:
                names[oid] = val
    
    for line in state_res.stdout.splitlines():
        if line.strip():
            oid, val = _parse_snmp_line(line)
            if oid and val and val.isdigit():
                states[oid] = int(val)
    
    for line in power_res.stdout.splitlines():
        if line.strip():
            oid, val = _parse_snmp_line(line)
            if oid and val:
                if val.isdigit():
                    powers[oid] = int(val)
                else:
                    powers[oid] = None
    
    # Build list of PDU entries by extracting plug index from OID
    pdu_data = []
    for oid_name, name_val in names.items():
        idx = _extract_plug_index(oid_name)
        if idx < 0:
            continue
        
        state_oid = OID_STATE + "." + str(idx)
        power_oid = OID_POWER + "." + str(idx)
        
        state = states.get(state_oid, 0)
        power = powers.get(power_oid)
        
        pdu_data.append((name_val, state, power))
    
    return pdu_data


def main(ctx, params):
    if params.get("_discover"):
        pdu_data = _get_snmp_data(ctx, params)
        if not pdu_data:
            return {"changed": False, "msg": "no PDU outlets found or not a Sentry v4 device",
                    "data": {"discovery": []}}
        
        discovery_items = []
        for name, state, power in pdu_data:
            metrics = ["power"] if power != None else []
            discovery_items.append({
                "item": name,
                "params": {},
                "metrics": metrics
            })
        
        return {"changed": False, "msg": "discovered %d PDU outlets" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode - single item
    item = params.get("item", "")
    pdu_data = _get_snmp_data(ctx, params)
    
    if not pdu_data:
        return {"changed": False, "msg": "no PDU outlets found or not a Sentry v4 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Find the requested item
    pdu = None
    for name, state, power in pdu_data:
        if name == item:
            pdu = (state, power)
            break
    
    if pdu == None:
        return {"changed": False, "msg": "PDU outlet not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state_int, power_val = pdu
    
    # Determine status string and state
    state_entry = DEVICE_STATES_V4.get(state_int)
    if state_entry:
        monstate, status_str = state_entry
    else:
        monstate = "UNKNOWN"
        status_str = str(state_int)
    
    # Build message and metrics
    msg_parts = ["Status: " + status_str]
    metrics = {}
    
    if power_val != None:
        msg_parts.append("Power: %d Watt" % power_val)
        metrics["power"] = power_val
    
    # Check required_state parameter (optional)
    required_state = params.get("required_state")
    if required_state != None:
        if status_str != required_state:
            monstate = "CRIT"
    
    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": monstate, "metrics": metrics, "details": ""}}