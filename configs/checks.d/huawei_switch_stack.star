_STACK_ROLE_NAMES = {
    "1": "master",
    "2": "standby",
    "3": "slave",
}
_UNKNOWN_ROLE = "unknown"

def _snmpwalk(ctx, community, host, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed for %s: %s" % (base_oid, res.stderr))
    return res.stdout

def _parse_snmp_table(output):
    result = []
    for line in output.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        # parts[0] is OID string, parts[1] is "TYPE: value"
        value_part = parts[1].strip()
        # Extract value after ": "
        val = value_part[value_part.find(": ") + 2:] if ": " in value_part else value_part
        result.append(val.strip('"').strip("'"))
    return result

def _gather_section(ctx, community, host):
    # Fetch stack enabled info (single scalar at .1.3.6.1.4.1.2011.5.25.183.1.5)
    enabled_output = _snmpwalk(ctx, community, host, ".1.3.6.1.4.1.2011.5.25.183.1.5")
    enabled_vals = _parse_snmp_table(enabled_output)
    # Fetch role info (.1.3.6.1.4.1.2011.5.25.183.1.20.1 + OID end + .3)
    role_output = _snmpwalk(ctx, community, host, ".1.3.6.1.4.1.2011.5.25.183.1.20.1")
    role_lines = []
    for line in role_output.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        # Extract the end part after base
        if not oid_part.startswith(".1.3.6.1.4.1.2011.5.25.183.1.20.1."):
            continue
        end_oid = oid_part[len(".1.3.6.1.4.1.2011.5.25.183.1.20.1."):]
        value_part = parts[1].strip()
        val = value_part[value_part.find(": ") + 2:] if ": " in value_part else value_part
        role_lines.append([end_oid.strip(), val.strip('"').strip("'")])

    if not enabled_vals or not enabled_vals[0] == "1":
        return {}

    return {line[0]: _STACK_ROLE_NAMES.get(line[1], _UNKNOWN_ROLE) for line in role_lines}

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        section = _gather_section(ctx, community, host)
        items = []
        for item, role in section.items():
            items.append({
                "item": item,
                "params": {"expected_role": role},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d stack members" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    section = _gather_section(ctx, community, host)

    if item not in section:
        return {
            "changed": False,
            "msg": "stack member %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    current_role = section[item]
    expected_role = params.get("expected_role", _UNKNOWN_ROLE)

    if current_role == _UNKNOWN_ROLE:
        state = "CRIT"
        summary = _UNKNOWN_ROLE
    elif current_role == expected_role:
        state = "OK"
        summary = current_role
    else:
        state = "CRIT"
        summary = "Unexpected role: %s (Expected: %s)" % (current_role, expected_role)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }