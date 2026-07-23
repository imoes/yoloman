def main(ctx, params):
    # ===== Helper: parse SNMP data =====
    def _parse_snmp():
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Base OIDs for watchdog sensors
        base_general = ".1.3.6.1.4.1.21239.5.1.1"
        base_data = ".1.3.6.1.4.1.21239.5.1.2.1"

        # Fetch general info: version OID (.2) and temp_unit OID (.7)
        res_general = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_general + ".2", base_general + ".7"
        ], mutates=False)
        lines_general = res_general.stdout.splitlines()
        version_str = ""
        temp_unit_raw = ""
        for line in lines_general:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_part = parts[0].strip()
                val = parts[1].strip()
                if oid_part.endswith(".2"):
                    version_str = val
                elif oid_part.endswith(".7"):
                    temp_unit_raw = val.strip('"').strip("'")

        # Determine temp unit
        temp_unit = "C"
        if temp_unit_raw == "0":
            temp_unit = "F"
        elif temp_unit_raw == "1":
            temp_unit = "C"

        # Parse version: e.g., "3.0.0" -> 300, "3.2.0" -> 320
        version = 300
        if version_str and version_str.replace(".", "").isdigit():
            version = int(version_str.replace(".", ""))

        # Fetch sensor data: descr(3), availability(4), temp(5), humidity(6), dew(7)
        res_data = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_data + ".3", base_data + ".4", base_data + ".5",
            base_data + ".6", base_data + ".7", base_data + ".8"
        ], mutates=False)
        lines_data = res_data.stdout.splitlines()

        # Group by sensor index (OIDEnd is the first component after base_data)
        raw_lines = {}  # {index: {3:descr,4:avail,5:temp,...}}
        for line in lines_data:
            line = line.strip()
            if not line or " = " not in line:
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip().strip('"').strip("'")
            # Extract index (last component after the base_data OID)
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 13:  # base_data has 8 components, then .<oid>.<idx>
                continue
            oid_num = oid_parts[-2]  # second to last is the OID number (3..8)
            idx = oid_parts[-1]      # last is index
            if idx not in raw_lines:
                raw_lines[idx] = {}
            raw_lines[idx][oid_num] = val_part

        # Build parsed structure
        parsed = {"general": {}, "temp": {}, "humidity": {}, "dew": {}}
        for idx, data_dict in raw_lines.items():
            descr = data_dict.get("3", "")
            avail = data_dict.get("4", "0")
            temp = data_dict.get("5", "")
            humidity = data_dict.get("6", "")
            dew = data_dict.get("7", "")

            wd_name = "Watchdog " + idx
            parsed["general"][wd_name] = {"descr": descr, "availability": avail}
            if temp != "":
                parsed["temp"]["Temperature " + idx] = (temp, temp_unit)
            if humidity != "":
                parsed["humidity"]["Humidity " + idx] = humidity
            if dew != "":
                parsed["dew"]["Dew point " + idx] = (dew, temp_unit)

        return parsed

    # ===== Discovery mode =====
    if params.get("_discover"):
        parsed = _parse_snmp()
        out = []
        for key in parsed.get("temp", {}):
            out.append({
                "item": key,
                "params": {"levels": (25.0, 30.0), "levels_lower": (5.0, 0.0)},
                "metrics": ["temp"]
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out}
        }

    # ===== Check mode =====
    item = params.get("item", "")
    if item == "":
        fail("item must be provided for check mode")

    parsed = _parse_snmp()
    data = parsed.get("temp", {}).get(item)
    if not data:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract temp string and unit
    temp_str, unit = data
    temp_c = 0.0
    if temp_str == "":
        return {
            "changed": False,
            "msg": "invalid temperature value: empty string",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    temp_c = float(temp_str) / 10.0 if temp_str.replace(".", "").replace("-", "").isdigit() else 0.0

    # Convert Fahrenheit to Celsius if needed
    if unit.upper() == "F":
        temp_c = (temp_c - 32.0) * 5.0 / 9.0

    # Round to 1 decimal using int(x * 10 + 0.5) / 10.0
    temp_c_rounded = int(temp_c * 10 + 0.5) / 10.0

    # Apply thresholds from params (Checkmk defaults: levels (25,30), levels_lower (5,0))
    warn = params.get("levels", (25.0, 30.0))
    warn_high = warn[0] if (type(warn) == "list" and len(warn) >= 1) else 25.0
    crit_high = warn[1] if (type(warn) == "list" and len(warn) >= 2) else 30.0
    warn_low = params.get("levels_lower", (5.0, 0.0))
    warn_low_val = warn_low[0] if (type(warn_low) == "list" and len(warn_low) >= 1) else 5.0
    crit_low_val = warn_low[1] if (type(warn_low) == "list" and len(warn_low) >= 2) else 0.0

    # Determine state
    state = "OK"
    summary = "%s C" % str(temp_c_rounded)

    if temp_c >= crit_high:
        state = "CRIT"
        summary = "%s C (crit > %s)" % (str(temp_c_rounded), str(crit_high))
    elif temp_c >= warn_high:
        state = "WARN"
        summary = "%s C (warn > %s)" % (str(temp_c_rounded), str(warn_high))
    elif temp_c <= crit_low_val:
        state = "CRIT"
        summary = "%s C (crit < %s)" % (str(temp_c_rounded), str(crit_low_val))
    elif temp_c <= warn_low_val:
        state = "WARN"
        summary = "%s C (warn < %s)" % (str(temp_c_rounded), str(warn_low_val))

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temp": temp_c},
            "details": ""
        }
    }