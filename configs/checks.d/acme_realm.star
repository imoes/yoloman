# ===== module-level constants =====
OID_BASE = ".1.3.6.1.4.1.9148.3.2.1.2.4.1"
OID_INBOUND = "3"
OID_OUTBOUND = "5"
OID_TOTAL_INBOUND = "7"
OID_TOTAL_OUTBOUND = "11"
OID_STATE = "30"

# map state code -> (dev_state_code, readable_text)
MAP_STATES = {
    "3": (0, "in service"),
    "4": (1, "contraints violation"),
    "7": (2, "call load reduction"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discover realms by walking the SNMP tree
        base_oid = OID_BASE
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + "." + OID_INBOUND
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 realms (snmpwalk failed)",
                "data": {"discovery": []}
            }

        # Parse output lines like: <full_oid> = INTEGER: <realm_index>
        realms = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split()
            if len(parts) < 3:
                continue
            # OID format: base + "." + OID_INBOUND + "." + realm_index
            # We need the realm index (last component after base OID)
            full_oid = parts[0]
            # Extract realm index by removing base OID prefix
            if full_oid.startswith(base_oid + "."):
                suffix = full_oid[len(base_oid) + 1:]
                if suffix.isdigit():
                    realm_name = suffix
                    realms.append({
                        "item": realm_name,
                        "params": {},
                        "metrics": ["inbound", "outbound"]
                    })
                elif suffix == "":
                    # Single realm without index suffix - use 1 as name
                    realms.append({
                        "item": "1",
                        "params": {},
                        "metrics": ["inbound", "outbound"]
                    })
            elif full_oid == base_oid + "." + OID_INBOUND:
                # Single realm without index suffix - use 1 as name
                realms.append({
                    "item": "1",
                    "params": {},
                    "metrics": ["inbound", "outbound"]
                })

        return {
            "changed": False,
            "msg": "discovered %d realms" % len(realms),
            "data": {"discovery": realms}
        }

    # Check mode: single item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Gather SNMP data for this realm
    # We need: inbound, outbound, total_inbound, total_outbound, state
    # For item (realm index), OIDs are:
    #   .1.3.6.1.4.1.9148.3.2.1.2.4.1.<index>.3  -> inbound
    #   .1.3.6.1.4.1.9148.3.2.1.2.4.1.<index>.5  -> outbound
    #   .1.3.6.1.4.1.9148.3.2.1.2.4.1.<index>.7  -> total_inbound
    #   .1.3.6.1.4.1.9148.3.2.1.2.4.1.<index>.11 -> total_outbound
    #   .1.3.6.1.4.1.9148.3.2.1.2.4.1.<index>.30 -> state
    base = OID_BASE + "." + item
    oid_inbound = base + "." + OID_INBOUND
    oid_outbound = base + "." + OID_OUTBOUND
    oid_total_inbound = base + "." + OID_TOTAL_INBOUND
    oid_total_outbound = base + "." + OID_TOTAL_OUTBOUND
    oid_state = base + "." + OID_STATE

    # Use snmpget for each OID (more reliable than parsing snmpwalk output for specific item)
    res_inbound = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid_inbound
    ], mutates=False)
    res_outbound = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid_outbound
    ], mutates=False)
    res_total_inbound = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid_total_inbound
    ], mutates=False)
    res_total_outbound = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid_total_outbound
    ], mutates=False)
    res_state = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid_state
    ], mutates=False)

    # Check if any query failed
    if res_inbound.rc != 0 or res_inbound.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "realm %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if res_outbound.rc != 0 or res_outbound.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "realm %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if res_total_inbound.rc != 0 or res_total_inbound.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "realm %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if res_total_outbound.rc != 0 or res_total_outbound.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "realm %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if res_state.rc != 0 or res_state.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "realm %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: "<oid> = <type>: <value>"
    def parse_snmp_value(output):
        stripped = output.strip()
        if stripped == "":
            return None
        eq_pos = stripped.find(" = ")
        if eq_pos == -1:
            return None
        type_val = stripped[eq_pos + 3:].split(": ", 1)
        if len(type_val) < 2:
            return None
        return type_val[1].strip()

    inbound_str = parse_snmp_value(res_inbound.stdout)
    outbound_str = parse_snmp_value(res_outbound.stdout)
    total_inbound_str = parse_snmp_value(res_total_inbound.stdout)
    total_outbound_str = parse_snmp_value(res_total_outbound.stdout)
    state_str = parse_snmp_value(res_state.stdout)

    # Validate values exist
    if inbound_str == None or outbound_str == None or total_inbound_str == None or total_outbound_str == None or state_str == None:
        return {
            "changed": False,
            "msg": "realm %s data incomplete" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract numeric values (strip trailing spaces, newlines, etc.)
    # Guard against non-digit values before conversion
    inbound = int(inbound_str) if inbound_str.isdigit() else -1
    outbound = int(outbound_str) if outbound_str.isdigit() else -1
    total_inbound = int(total_inbound_str) if total_inbound_str.isdigit() else -1
    total_outbound = int(total_outbound_str) if total_outbound_str.isdigit() else -1

    if inbound == -1 or outbound == -1 or total_inbound == -1 or total_outbound == -1:
        return {
            "changed": False,
            "msg": "realm %s numeric conversion error" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map state
    state_key = state_str.strip()
    if state_key not in MAP_STATES:
        return {
            "changed": False,
            "msg": "realm %s unknown state %s" % (item, state_key),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    dev_state, dev_state_readable = MAP_STATES[state_key]

    # Build summary message
    summary = "Status: %s, Inbound: %d/%d, Outbound: %d/%d" % (
        dev_state_readable, inbound, total_inbound, outbound, total_outbound
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK" if dev_state == 0 else ("WARN" if dev_state == 1 else "CRIT"),
            "metrics": {
                "inbound": inbound,
                "outbound": outbound
            },
            "details": ""
        }
    }
