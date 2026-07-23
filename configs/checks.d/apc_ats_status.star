# Map SNMP enum values to strings for messages
COM_STATUS_NAMES = {
    1: "NeverDiscovered",
    2: "Established",
    3: "Lost",
}
REDUNDANCY_NAMES = {
    1: "Lost",
    2: "Redundant",
}
SOURCE_NAMES = {
    1: "A",
    2: "B",
}
OVERCURRENT_NAMES = {
    1: "Exceeded",
    2: "OK",
}
POWERSUPPLY_STATUS_NAMES = {
    0: "not available",
    1: "failed",
    2: "OK",
}


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: return the selected source as the only item
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.318.1.1.8.5.1.1.0",  # com_state
            ".1.3.6.1.4.1.318.1.1.8.5.1.2.0",  # source
            ".1.3.6.1.4.1.318.1.1.8.5.1.3.0",  # redundancy
            ".1.3.6.1.4.1.318.1.1.8.5.1.4.0",  # overcurrent
            ".1.3.6.1.4.1.318.1.1.8.5.1.5.0",  # 5V
            ".1.3.6.1.4.1.318.1.1.8.5.1.6.0",  # 24V
            ".1.3.6.1.4.1.318.1.1.8.5.1.7.0",  # 3.3V
            ".1.3.6.1.4.1.318.1.1.8.5.1.8.0",  # 1.0V
        ], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Parse simple snmpwalk output: "OID = INTEGER: value"
        lines = res.stdout.splitlines()
        if len(lines) < 8:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        values = []
        for line in lines:
            parts = line.strip().split(" = INTEGER: ")
            if len(parts) == 2 and parts[1].isdigit():
                values.append(int(parts[1]))
            else:
                return {"changed": False, "msg": "discovered 0 items",
                        "data": {"discovery": []}}

        if len(values) != 8:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Extract selected source (index 1)
        selected_source = values[1]
        if selected_source != 1 and selected_source != 2:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        item = "ATS Status"
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": item, "params": {"power_source": SOURCE_NAMES.get(selected_source, "A")},
                     "metrics": []}
                ]}}

    # Check mode
    item = params.get("item", "")
    if item != "ATS Status":
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all required OIDs in one call
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.318.1.1.8.5.1.1.0",  # com_state
        ".1.3.6.1.4.1.318.1.1.8.5.1.2.0",  # source
        ".1.3.6.1.4.1.318.1.1.8.5.1.3.0",  # redundancy
        ".1.3.6.1.4.1.318.1.1.8.5.1.4.0",  # overcurrent
        ".1.3.6.1.4.1.318.1.1.8.5.1.5.0",  # 5V
        ".1.3.6.1.4.1.318.1.1.8.5.1.6.0",  # 24V
        ".1.3.6.1.4.1.318.1.1.8.5.1.7.0",  # 3.3V
        ".1.3.6.1.4.1.318.1.1.8.5.1.8.0",  # 1.0V
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse simple snmpwalk output
    lines = res.stdout.splitlines()
    if len(lines) < 8:
        return {"changed": False, "msg": "incomplete SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = []
    for line in lines:
        parts = line.strip().split(" = INTEGER: ")
        if len(parts) == 2 and parts[1].isdigit():
            values.append(int(parts[1]))
        else:
            values.append(None)

    if len(values) != 8:
        return {"changed": False, "msg": "incomplete SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    com_state, source, redundancy, overcurrent, p5v, p24v, p33v, p10v = values

    # Extract power_source from params
    expected_source = params.get("power_source", "A")
    expected_source_int = 1 if expected_source == "A" else 2

    # Check power source
    if source == None or source != expected_source_int:
        actual_source = SOURCE_NAMES.get(source, "unknown") if source != None else "unknown"
        return {"changed": False, "msg": "Power source Changed from %s to %s" % (expected_source, actual_source),
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Check communication status
    if com_state == 1:
        return {"changed": False, "msg": "Communication Status: never Discovered",
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    if com_state == 3:
        return {"changed": False, "msg": "Communication Status: lost",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Check redundancy
    if redundancy == 1:
        return {"changed": False, "msg": "redundancy lost",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Check overcurrent
    if overcurrent == 1:
        return {"changed": False, "msg": "exceeded output current threshold",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Check power supplies
    for name, val, idx in [("5V", p5v, 0), ("24V", p24v, 1), ("3.3V", p33v, 2), ("1.0V", p10v, 3)]:
        if val != None and val == 1:
            return {"changed": False, "msg": "%s power supply failed" % name,
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # All checks OK
    return {"changed": False, "msg": "Power source %s selected, Device fully redundant" % expected_source,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
