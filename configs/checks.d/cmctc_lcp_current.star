# Sensor type to description mapping (from _CMCTC_LCP_SENSORS)
_SENSOR_TYPES = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# SNMP trees (indices)
_TREES = ["3", "4", "5", "6"]

# Status mapping (map_sensor_state)
_STATUS_MAP = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}

# Unit mapping (map_unit)
_UNIT_MAP = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " °C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}


def _parse_sensor_data(output_lines):
    """Parse snmpwalk output for cmctc_lcp sensors (trees 3-6)."""
    result = []
    # Process each tree block (4 blocks)
    for tree in _TREES:
        # Find lines for this tree block (base OID: .1.3.6.1.4.1.2606.4.2.{tree})
        base_oid = ".1.3.6.1.4.1.2606.4.2.%s.5.2.1" % tree
        # Parse each line
        for line in output_lines:
            if line.find(base_oid) == -1:
                continue
            # Parse OID and value
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Extract index (last part after final dot)
            oid_tail = oid_part.rsplit(".", 1)
            if len(oid_tail) != 2:
                continue
            idx_str = oid_tail[1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            # Extract values from this line
            # Format: OID = TYPE: value
            if val_part.find(":") == -1:
                continue
            val_type, val_str = val_part.split(":", 1)
            val_str = val_str.strip()
            # This line contains one field; need to group by index
            # We'll collect all fields for each index
            result.append({
                "tree": tree,
                "index": idx,
                "oid_tail": oid_tail[0],
                "type": val_type.strip(),
                "value": val_str,
            })
    # Group by (tree, index) and extract fields
    sensors = {}
    for entry in result:
        key = (entry["tree"], entry["index"])
        if key not in sensors:
            sensors[key] = {}
        # Map OID tail to field name
        tail = entry["oid_tail"]
        # Fields: 1=Index, 2=typeid, 4=status, 5=reading, 6=high, 7=low, 8=warn, 2=description (oid 7.2.1.2)
        if tail.endswith(".1"):
            sensors[key]["index"] = entry["value"]
        elif tail.endswith(".2"):
            sensors[key]["typeid"] = entry["value"]
        elif tail.endswith(".4"):
            sensors[key]["status"] = entry["value"]
        elif tail.endswith(".5"):
            sensors[key]["reading"] = entry["value"]
        elif tail.endswith(".6"):
            sensors[key]["high"] = entry["value"]
        elif tail.endswith(".7"):
            sensors[key]["low"] = entry["value"]
        elif tail.endswith(".8"):
            sensors[key]["warn"] = entry["value"]
    # Now build sensor objects
    items = []
    for key in sensors:
        d = sensors[key]
        typeid = d.get("typeid")
        if typeid not in _SENSOR_TYPES:
            continue
        sensor_spec = _SENSOR_TYPES[typeid]
        desc = d.get("description", "")
        item = ""
        if sensor_spec[0] != None:
            item = sensor_spec[0] + " - " + key[0] + "." + str(key[1])
        else:
            item = key[0] + "." + str(key[1])
        # Build Sensor
        sensor = {
            "status": d.get("status", "1"),
            "reading": 0.0,
            "high": 0.0,
            "low": 0.0,
            "warn": 0.0,
            "description": desc,
            "type_": sensor_spec[1],
        }
        # Parse numeric fields
        for f in ["reading", "high", "low", "warn"]:
            if f in d and d[f].isdigit():
                sensor[f] = float(d[f])
            elif f in d:
                # Try to parse float - no try/except allowed, so guard with isdigit
                # For float strings that may contain dots, use a helper approach
                # Since Starlark has no float parsing, we'll assume simple integers or simple floats
                # For simplicity, treat all non-digit as 0.0
                if d[f].find(".") != -1:
                    parts = d[f].split(".")
                    if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                        sensor[f] = float(d[f])
                elif d[f].isdigit() or (d[f].startswith("-") and d[f][1:].isdigit()):
                    sensor[f] = float(d[f])
        items.append((item, sensor))
    return dict(items)


def _get_snmp_output(ctx, params):
    """Run snmpwalk for cmctc_lcp section."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oids = [
        ".1.3.6.1.4.1.2606.4.2.3.5.2.1",
        ".1.3.6.1.4.1.2606.4.2.4.5.2.1",
        ".1.3.6.1.4.1.2606.4.2.5.5.2.1",
        ".1.3.6.1.4.1.2606.4.2.6.5.2.1",
        ".1.3.6.1.4.1.2606.4.2.3.7.2.1.2",
        ".1.3.6.1.4.1.2606.4.2.4.7.2.1.2",
        ".1.3.6.1.4.1.2606.4.2.5.7.2.1.2",
        ".1.3.6.1.4.1.2606.4.2.6.7.2.1.2",
    ]
    # We need all oids in one walk to correlate items, so do separate walks and merge
    lines = []
    for oid in base_oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        lines.extend(res.stdout.splitlines())
    return lines


def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        lines = _get_snmp_output(ctx, params)
        section = _parse_sensor_data(lines)
        # Filter for "current" type only
        discovered = []
        for item, sensor in section.items():
            if sensor["type_"] == "current":
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": ["current"],
                })
        return {
            "changed": False,
            "msg": "discovered %d current sensors" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode
    item = params.get("item", "")
    if item == None:
        item = ""
    lines = _get_snmp_output(ctx, params)
    section = _parse_sensor_data(lines)
    sensor = section.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Get sensor data
    reading = sensor.get("reading", 0.0)
    status = sensor.get("status", "1")
    description = sensor.get("description", "")
    unit = _UNIT_MAP.get(sensor.get("type_", "current"), "")
    # Status to state and text
    status_info = _STATUS_MAP.get(status, (3, "unknown"))
    state_code = status_info[0]
    extra_text = status_info[1]
    # Build infotext
    infotext = ""
    if description != "":
        infotext = "[%s] " % description
    # State from status
    state = "OK"
    if state_code == 2:
        state = "CRIT"
    elif state_code == 1:
        state = "WARN"
    elif state_code == 3:
        state = "UNKNOWN"
    # Check levels (params is a tuple (warn, crit))
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    if warn != None and crit != None:
        # levels provided
        if reading >= float(crit):
            state = "CRIT"
        elif reading >= float(warn):
            state = "WARN"
    # If no levels, check device levels
    if warn == None or crit == None:
        low = sensor.get("low", 0.0)
        high = sensor.get("high", 0.0)
        if low > 0 or high > 0:
            if reading >= high or reading <= low:
                state = "CRIT"
    # Summary
    unit_str = unit if unit != None else ""
    summary = "%s%d%s" % (infotext, int(reading), unit_str)
    details = ""
    # Build extra info for levels
    if warn != None and crit != None:
        details = " (warn/crit at %d/%d%s)" % (int(warn), int(crit), unit_str)
    else:
        low = sensor.get("low", 0.0)
        high = sensor.get("high", 0.0)
        if low > 0 or high > 0:
            if reading >= high or reading <= low:
                details = " (device lower/upper crit at %f/%f%s)" % (low, high, unit_str)
    if details != "":
        summary = summary + details
    # Metrics
    metrics = {"current": reading}
    # Return
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }