def main(ctx, params):
    # Constants: SNMP OIDs for UMG device detection and temperature data
    DEVICE_OID = ".1.3.6.1.2.1.1.2.0"
    BASE_OID = ".1.3.6.1.4.1.34278"
    # Device type OIDs (for detection only)
    DEVICE_96_OID = ".1.3.6.1.4.1.34278.8.6"
    DEVICE_604_OID = ".1.3.6.1.4.1.34278.10.1"
    DEVICE_508_OID = ".1.3.6.1.4.1.34278.10.4"
    # Temperature section OIDs (base for misc section)
    # We need to fetch:
    # - Base section: .1.3.6.1.4.1.34278.8 (device info)
    # - Section 8 (misc): contains frequency and temperatures
    MISC_OID = ".1.3.6.1.4.1.34278.8"

    # Helper: run snmpwalk to fetch temperature data
    # For discovery and check, we use snmpwalk to get temperature values
    # Temperatures are in section 8, after frequency: the first value is frequency,
    # subsequent values are temperatures (one per sensor)
    # Format: OID = INTEGER: value
    def _walk_temperature(community, host):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, MISC_OID], mutates=False)
        if res.rc != 0:
            return None
        temps = []
        freq = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Parse: .1.3.6.1.4.1.34278.8.x = INTEGER: value
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            value_str = value_part.strip()
            if value_str.startswith("INTEGER: "):
                val = int(value_str[9:])
                # First value after base is frequency (oid ends with .1 usually)
                # Then temperatures follow (.2, .3, etc.)
                base, suffix = oid_part.rsplit(".", 1)
                if suffix == "1":
                    freq = val / 100.0
                elif suffix.isdigit() and int(suffix) >= 2:
                    temps.append((int(suffix) - 1, val / 10.0))
        return {"freq": freq, "temps": temps}

    # Discovery mode: enumerate temperature sensors
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        data = _walk_temperature(community, host)
        if data == None:
            return {"changed": False, "msg": "failed to retrieve SNMP data",
                    "data": {"discovery": []}}
        discovery = []
        for num, temp in data["temps"]:
            if temp != -1000:  # -1000 indicates invalid/missing sensor
                # Suggest default temperature thresholds (Checkmk default)
                discovery.append({
                    "item": str(num),
                    "params": {
                        "levels": (25, 30),  # typical defaults: warn=25°C, crit=30°C
                    },
                    "metrics": ["temperature"]
                })
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: one item (temperature sensor number)
    item = params.get("item", "")
    if not item:
        fail("item is required for check mode")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    data = _walk_temperature(community, host)
    if data == None:
        return {"changed": False, "msg": "failed to retrieve SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the sensor reading
    temp_value = None
    for num, temp in data["temps"]:
        if str(num) == item:
            temp_value = temp
            break

    if temp_value == None or temp_value == -1000:
        return {"changed": False, "msg": "sensor %s not found or invalid" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply temperature thresholds from params
    # Checkmk default: levels=(25, 30), but allow override via "levels" tuple
    levels = params.get("levels", (25.0, 30.0))
    warn_high, crit_high = levels
    # Lower thresholds default to None (no lower bound check)
    # We assume only upper thresholds matter for ambient temperature

    # Determine state
    state = "OK"
    if temp_value >= crit_high:
        state = "CRIT"
    elif temp_value >= warn_high:
        state = "WARN"

    # Build message
    msg = "Temperature External %s: %f °C" % (item, temp_value)
    if state != "OK":
        msg += " (warn/crit at %f/%f °C)" % (warn_high, crit_high)

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"temperature": temp_value},
                     "details": ""}}