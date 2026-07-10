def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch all voltage sensors via SNMP
        # OID base: .1.3.6.1.4.1.9148.3.3.1.2.1.1
        # OIDs: 3=descr, 4=value, 5=state
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
            ctx.facts().get("hostname", "localhost"),
            ".1.3.6.1.4.1.9148.3.3.1.2.1.1.3",
            ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4",
            ".1.3.6.1.4.1.9148.3.3.1.2.1.1.5"
        ], mutates=False)
        # snmpwalk returns lines like: OID = STRING/INTEGER: value
        # We need to parse into (descr, value_str, state) tuples
        # Instead, use snmpbulkget or parse the raw snmpwalk output
        # But Checkmk checks assume parse function exists; we'll simulate parsing

        # Simpler: use snmpget with explicit OID numbers
        # Since snmpwalk output format is consistent, we parse it
        out = []
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            # No data; try snmpbulkget if available or fail gracefully
            # Checkmk detection is startswith .1.3.6.1.2.1.1.2.0 .1.3.6.1.4.1.9148
            # If host is ACME, we expect data; otherwise skip
            return {
                "changed": False,
                "msg": "discovered 0 voltage sensors",
                "data": {"discovery": []}
            }
        # Group lines by index: descr line i, value line i, state line i
        # Format: OID = type: value
        # Extract index from OID: .1.3.6.1.4.1.9148.3.3.1.2.1.1.3.1 -> 1
        # We'll parse descr, value, state in order
        # But snmpwalk returns all descr OIDs, then all value OIDs, then all state OIDs
        # So: lines[0..n-1] = descrs, lines[n..2n-1] = values, lines[2n..3n-1] = states
        # Find count by counting lines starting with voltage descr OID
        descr_lines = []
        value_lines = []
        state_lines = []
        for line in lines:
            if ".1.3.6.1.4.1.9148.3.3.1.2.1.1.3." in line:
                descr_lines.append(line)
            elif ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4." in line:
                value_lines.append(line)
            elif ".1.3.6.1.4.1.9148.3.3.1.2.1.1.5." in line:
                state_lines.append(line)
        # Now, if we have data, parse tuples
        for i in range(min(len(descr_lines), len(value_lines), len(state_lines))):
            # Extract index from descr OID: .1.3.6.1.4.1.9148.3.3.1.2.1.1.3.N
            descr_oid = descr_lines[i].split(" ")[0].strip()
            index = descr_oid.rsplit(".", 1)[-1]
            # Extract description text: "ACMEPACKET-ENVMON-MIB::apEnvMonVoltageStatusDescr.N = STRING: MAIN 1.20V"
            if " = " in descr_lines[i]:
                descr = descr_lines[i].split(" = ", 1)[1].strip()
            else:
                descr = ""
            # Extract value (integer) from value line
            value_str = ""
            if " = " in value_lines[i]:
                value_str = value_lines[i].split(" = ", 1)[1].strip()
                # Remove possible prefix like "INTEGER: "
                if ":" in value_str:
                    value_str = value_str.split(":", 1)[1].strip()
            # Extract state (integer) from state line
            state_str = ""
            if " = " in state_lines[i]:
                state_str = state_lines[i].split(" = ", 1)[1].strip()
                if ":" in state_str:
                    state_str = state_str.split(":", 1)[1].strip()
            # Only include if state != "7" (not present)
            if state_str != "7":
                out.append({
                    "item": descr,
                    "params": {},
                    "metrics": ["voltage"]
                })
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: one item
    item = params.get("item", "")
    # Build OID for this item index; but we need to map item description to index
    # Instead, re-run snmpwalk and parse to find this item's state/value
    # Since discovery already found the mapping, we replicate the same fetch and parse
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
        ctx.facts().get("hostname", "localhost"),
        ".1.3.6.1.4.1.9148.3.3.1.2.1.1.3",
        ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4",
        ".1.3.6.1.4.1.9148.3.3.1.2.1.1.5"
    ], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "no data retrieved",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    # Group lines as before
    descr_lines = []
    value_lines = []
    state_lines = []
    for line in lines:
        if ".1.3.6.1.4.1.9148.3.3.1.2.1.1.3." in line:
            descr_lines.append(line)
        elif ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4." in line:
            value_lines.append(line)
        elif ".1.3.6.1.4.1.9148.3.3.1.2.1.1.5." in line:
            state_lines.append(line)
    # Find matching item
    voltage = None
    rstate = None
    for i in range(min(len(descr_lines), len(value_lines), len(state_lines))):
        descr_oid = descr_lines[i].split(" ")[0].strip()
        if " = " in descr_lines[i]:
            descr = descr_lines[i].split(" = ", 1)[1].strip()
        else:
            descr = ""
        if descr != item:
            continue
        # Found the item
        value_str = ""
        if " = " in value_lines[i]:
            value_str = value_lines[i].split(" = ", 1)[1].strip()
            if ":" in value_str:
                value_str = value_str.split(":", 1)[1].strip()
        state_str = ""
        if " = " in state_lines[i]:
            state_str = state_lines[i].split(" = ", 1)[1].strip()
            if ":" in state_str:
                state_str = state_str.split(":", 1)[1].strip()
        if value_str == "" or state_str == "":
            return {
                "changed": False,
                "msg": "missing data for sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        voltage = float(value_str) / 1000.0
        rstate = state_str
        break

    if voltage == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map rstate to Checkmk state and text
    ACME_ENVIRONMENT_STATES = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown"),
    }
    state_key = str(rstate)
    if state_key in ACME_ENVIRONMENT_STATES:
        state, readable = ACME_ENVIRONMENT_STATES[state_key]
    else:
        state = "UNKNOWN"
        readable = "unknown state"

    # Determine overall state: CRIT if state_key in ["5","6"], WARN if in ["3","4"], OK if in ["1","2"], else UNKNOWN
    # Note: Checkmk states are strings: "OK", "WARN", "CRIT"
    if state_key in ["5", "6"]:
        state = "CRIT"
    elif state_key in ["3", "4"]:
        state = "WARN"
    elif state_key in ["1", "2"]:
        state = "OK"
    else:
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": readable + ", voltage: %.3f V" % voltage,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }
