def main(ctx, params):
    # Discovery mode: yield one service (always one for this check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: gather SNMP data for .1.3.6.1.4.1.2.3.51.3.1.4
    # Checkmk uses snmp_get_tree; simulate by running snmpwalk on the OID
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
        ".1.3.6.1.4.1.2.3.51.3.1.4"
    ], mutates=False)

    # Parse SNMP output: expected lines like "SNMPv2-SMI::enterprises.2.3.51.3.1.4 = STRING: \"<state>\""
    # Each line: "oid = STRING: \"<value>\"" or similar
    lines = res.stdout.strip().split("\n") if res.stdout.strip() else []

    # Extract values from SNMP output
    section = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Find the last quote after '='
        idx = stripped.find(" = ")
        if idx == -1:
            continue
        value_part = stripped[idx + 3:].strip()
        # Remove surrounding quotes if present
        if value_part.startswith('"') and value_part.endswith('"'):
            value = value_part[1:-1]
        else:
            value = value_part
        if value:
            section.append([value])

    if not section or not section[0]:
        return {
            "changed": False,
            "msg": "Health info not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse state and alerts per Checkmk logic
    num_alerts = int((len(section) - 1) / 3) if len(section) > 1 else 0

    infotext = ""
    for i in range(num_alerts):
        state = section[num_alerts + 1 + i][0] if (num_alerts + 1 + i) < len(section) else "unknown"
        text = section[num_alerts * 2 + 1 + i][0] if (num_alerts * 2 + 1 + i) < len(section) else "unknown"
        if infotext != "":
            infotext += ", "
        infotext += text + "(" + state + ")"

    state = section[0][0]
    # Map states: 255=OK, 0=CRIT(manual), 2=CRIT, 4=WARN, else UNKNOWN
    if state == "255":
        summary = "no problem found"
        check_state = "OK"
    elif state == "0":
        summary = infotext + " - manual log clearing needed to recover state"
        check_state = "CRIT"
    elif state == "2":
        summary = infotext
        check_state = "CRIT"
    elif state == "4":
        summary = infotext
        check_state = "WARN"
    else:
        summary = infotext
        check_state = "UNKNOWN"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": check_state,
            "metrics": {},
            "details": ""
        }
    }
