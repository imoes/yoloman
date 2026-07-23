# ===== check module: ciena_tunnel =====
# Translated from Checkmk's ciena_tunnel check plugin
# Reads SNMP data from Ciena 5142/5171 devices for tunnel oper-state checks

# SNMP base OIDs for each platform
TUNNEL_OID_BASE_5171 = ".1.3.6.1.4.1.1271.2.1.18.1.2.2.1"
TUNNEL_OID_BASE_5142 = ".1.3.6.1.4.1.1271.2.1.18.1.2.6.1"

# Tunnel name OID (2) and oper state OID (7 for 5171, 4 for 5142)
TUNNEL_NAME_OID = ".2"
TUNNEL_OPER_STATE_OID_5171 = ".7"
TUNNEL_OPER_STATE_OID_5142 = ".4"

# OperState enum values
OPER_STATE_ENABLED = "1"
OPER_STATE_DISABLED = "2"

# SysObjectID and SysDescID OIDs for device detection
OID_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
OID_SYS_DESC_ID = ".1.3.6.1.2.1.1.1.0"

def _get_snmp_value(ctx, base_oid, item_index, suffix_oid):
    """Fetch a single SNMP value for given base OID + index + suffix."""
    full_oid = base_oid + suffix_oid + "." + item_index
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-On", "localhost", full_oid], mutates=False)
    if res.rc != 0:
        return None
    line = res.stdout.strip()
    # Format: "<oid> = <TYPE>: <value>"
    eq_idx = line.find("=")
    if eq_idx == -1:
        return None
    value_part = line[eq_idx+1:].strip()
    # Extract just the value (e.g., "STRING: foo" -> "foo", "INTEGER: 1" -> "1")
    if ":" in value_part:
        value_part = value_part.split(":", 1)[1].strip()
    # Remove surrounding quotes if present
    if value_part.startswith('"') and value_part.endswith('"'):
        value_part = value_part[1:-1]
    return value_part

def _parse_tunnel_section(ctx):
    """Gather all tunnels and their oper states from SNMP."""
    # Detect device type
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-On", "localhost", OID_SYS_OBJECT_ID], mutates=False)
    sys_object_id = ""
    if res.rc == 0:
        eq_idx = res.stdout.strip().find("=")
        if eq_idx != -1:
            sys_object_id = res.stdout.strip()[eq_idx+1:].strip().split(":", 1)[1].strip() if ":" in res.stdout.strip() else ""

    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-On", "localhost", OID_SYS_DESC_ID], mutates=False)
    sys_desc = ""
    if res.rc == 0:
        eq_idx = res.stdout.strip().find("=")
        if eq_idx != -1:
            sys_desc = res.stdout.strip()[eq_idx+1:].strip().split(":", 1)[1].strip().strip('"') if ":" in res.stdout.strip() else ""

    is_5171 = "5171" in sys_desc and (sys_object_id.startswith(".1.3.6.1.4.1.1271.1.2.11") or sys_object_id.startswith(".1.3.6.1.4.1.6141.1.96"))
    is_5142 = "5142" in sys_desc and (sys_object_id.startswith(".1.3.6.1.4.1.1271.1.2.11") or sys_object_id.startswith(".1.3.6.1.4.1.6141.1.96"))

    base_oid = TUNNEL_OID_BASE_5171 if is_5171 else (TUNNEL_OID_BASE_5142 if is_5142 else None)
    if base_oid == None:
        return {}

    # Get tunnel name OID suffix
    name_oid = TUNNEL_NAME_OID
    oper_oid = TUNNEL_OPER_STATE_OID_5171 if is_5171 else TUNNEL_OPER_STATE_OID_5142

    # We need to enumerate tunnel indices. snmpwalk the base OID to get indices.
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid], mutates=False)
    if res.rc != 0:
        return {}

    tunnels = {}
    seen_indices = set()
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Parse OID to extract index
        # e.g., ".1.3.6.1.4.1.1271.2.1.18.1.2.2.1.2.1" where .2 is name OID and .1 is index
        # or ".1.3.6.1.4.1.1271.2.1.18.1.2.2.1.2.1.1" etc.
        if not oid_part.startswith(base_oid):
            continue

        remainder = oid_part[len(base_oid):].strip(".")
        # First number after base is the OID suffix number (2 or 7/4)
        tokens = remainder.split(".")
        if len(tokens) < 2:
            continue
        oid_num = tokens[0]
        if oid_num != "2":  # We only care about name OID
            continue
        index = tokens[1] if len(tokens) > 1 else ""
        if not index or index in seen_indices:
            continue

        seen_indices.add(index)

        # Now fetch name and state for this index
        name = _get_snmp_value(ctx, base_oid, index, name_oid)
        state = _get_snmp_value(ctx, base_oid, index, oper_oid)

        if name and state in [OPER_STATE_ENABLED, OPER_STATE_DISABLED]:
            tunnels[name] = state

    return tunnels

def main(ctx, params):
    if params.get("_discover"):
        tunnels = _parse_tunnel_section(ctx)
        out = []
        for item, oper_state in tunnels.items():
            out.append({"item": item, "params": {"discovered_oper_state": oper_state},
                        "metrics": []})
        return {"changed": False, "msg": "discovered %d tunnels" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    tunnels = _parse_tunnel_section(ctx)

    if item not in tunnels:
        return {"changed": False, "msg": "tunnel not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    current_state = tunnels[item]
    discovered_state = params.get("discovered_oper_state", "")

    # State logic: OK if current == discovered, CRIT otherwise
    if current_state == discovered_state:
        state = "OK"
    else:
        state = "CRIT"

    state_name = "enabled" if current_state == OPER_STATE_ENABLED else "disabled"
    return {"changed": False, "msg": "Tunnel is %s" % state_name,
            "data": {"state": state, "metrics": {}, "details": ""}}
