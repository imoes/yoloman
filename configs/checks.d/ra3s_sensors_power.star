def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.20916.1.13.1.2.1.1"
        ], mutates=False)

        # Check if any digital sensor exists by looking for at least one entry
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no digital sensors discovered",
                    "data": {"discovery": []}}

        # Parse the first OID to determine sensor type (we only need to detect presence)
        # Digital sensor type detection relies on the number of fields in the section
        # We'll discover once per digital sensor (one entry per sensor index)
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Extract the value part (after "= ")
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            # This is just to detect if sensor data exists; we'll use a single item
            # Since the original Checkmk plugin yields one Service per sensor,
            # and there's no clear item name, use "Sensor" as the item.
            items.append({
                "item": "Sensor",
                "params": {},
                "metrics": ["device_state"]
            })
            break  # Only one sensor item needed

        return {"changed": False, "msg": "discovered %d power sensor(s)" % len(items),
                "data": {"discovery": items}}

    # Check mode - check item
    item = params.get("item", "")
    if item != "Sensor":
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Query the digital sensor section OIDs to determine if power is detected
    # OID 1 (temperature Celsius) and OID 3 (power state)
    temp_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.20916.1.13.1.2.1.1.3"
    ], mutates=False)

    if temp_res.rc != 0 or not temp_res.stdout.strip():
        return {"changed": False, "msg": "no power sensor data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse SNMP output: OID = TYPE: value
    line = temp_res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_part = parts[1].strip()
    # Extract the actual value after the colon (e.g., "INTEGER: 1" -> "1")
    colon_idx = value_part.find(":")
    if colon_idx == -1:
        return {"changed": False, "msg": "invalid SNMP response format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_val = value_part[colon_idx + 1:].strip()

    # The power state is "1" for detected, "0" for not detected
    power_detected = raw_val == "1"

    # Determine state: OK if power detected, CRIT if not
    state = "OK" if power_detected else "CRIT"
    status_text = "power detected" if power_detected else "no power detected"

    return {
        "changed": False,
        "msg": status_text,
        "data": {
            "state": state,
            "metrics": {"device_state": 1 if power_detected else 0},
            "details": ""
        }
    }