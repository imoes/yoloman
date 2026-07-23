def main(ctx, params):
    # Discovery mode: discover the single service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch SNMP data for system events
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines() if res.stdout else []
    # Parse SNMP output: alternating label/value pairs per line
    events = {}
    used_names = set()

    def get_item_name(name):
        counter = 2
        new_name = name
        while True:
            if new_name in used_names:
                new_name = "%s %d" % (name, counter)
                counter += 1
            else:
                used_names.add(new_name)
                break
        return new_name

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Split on '=' to separate OID from value, then extract last two parts
        parts = stripped.split()
        if len(parts) < 3:
            continue
        # Format: OID.100.<value> or similar; extract label (100.x) and value
        # Try to extract label from the OID suffix: ...100.<label> and ...200.<value>
        # Simplify: look for label/value pairs on consecutive lines or within same line
        # Checkmk's implementation uses parse_liebert_without_unit: label,value per line
        # Given the example output, each line is: OID.label value
        # So split by whitespace and assume last two tokens are label and value
        tokens = stripped.split()
        if len(tokens) < 2:
            continue
        # Take the last two tokens as label and value
        label = tokens[-2].strip()
        value = tokens[-1].strip()
        if not label:
            continue
        name = get_item_name(label)
        events[name] = value

    # Identify active events: not "Inactive Event" (case-insensitive)
    active_events = []
    for key, val in events.items():
        if val and val.lower() != "inactive event":
            active_events.append((key, val))

    # Determine state and message
    if not active_events:
        return {
            "changed": False,
            "msg": "Normal",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    # Format multi-line details for each active event
    detail_lines = []
    for key, val in active_events:
        detail_lines.append("%s: %s" % (key, val))
    details = "\n".join(detail_lines)
    msg = "Active events detected"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "CRIT", "metrics": {}, "details": details}
    }
